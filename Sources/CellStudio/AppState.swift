import CellCore
import Foundation
import ModelIO
import QuartzCore
import simd
import SwiftUI
import UniformTypeIdentifiers

struct Part: Identifiable {
    let id = UUID()
    var name: String
    var url: URL?
    var mesh: Mesh
    var offset: Pose = Pose()
    var isPaintTarget = false
    var objectName: String?
}

/// A identificação inclui o robô para distinguir OBJECTs com o mesmo nome.
struct PartObject: Identifiable {
    var id: String
    var name: String
    var pose: Pose
    var robotID: UUID?
    static let station = PartObject(id: "station", name: "Origem da estação (0,0,0)", pose: Pose())
}

struct PartImportRequest: Identifiable {
    let id = UUID()
    var url: URL
}

/// Trajetória preparada para um robô dentro de uma simulação de estação.
struct RobotSimulationRun {
    let robotID: UUID
    let program: RobotProgram
    let start: JointState
    var samples: [TrajectorySample]
    let unreachable: [Int]
    var actions: [EcoTalkSyncAction] = []
    var issues: [MotionIssue] = []
    var origin: [(program: String, line: Int)] = []
    /// mensagens do interpretador (suposições, instruções não simuladas) – saem no início da execução
    var notes: [String] = []
    /// início de cada ponto na trajetória antes do escalonamento (para levar o tempo dos erros ao relógio da estação)
    var rawStarts: [Int: Double] = [:]
    /// trajetória antes do escalonamento (para reavaliar a estação trocando só um robô)
    var rawSamples: [TrajectorySample] = []
    var callChains: [[CallSite]] = []
}

/// Mensagem que sai durante a execução da simulação, no instante em que acontece (como as mensagens por passo do DXQ).
struct SimEvent {
    var time: Double
    var level: MessageLevel
    var text: String
    var robot: String
    var robotID: UUID?
    var isError = false
    var program = ""
    var line = 0
}

/// Erro que parou a simulação (faixa vermelha na Vista 3D).
struct SimulationStopInfo: Equatable {
    var robot: String
    var program: String
    var line: Int
    var text: String
    var time: Double
}

struct SimulationProgramChoice: Identifiable {
    let id: String
    let title: String
}

/// Um robô da estação, com o que veio do backup do controlador.
struct RobotSlot: Identifiable {
    let id = UUID()
    var model: RobotModel
    var joints: JointState
    var backup: RobotBackup?
    var equipment: RobotEquipment?
    /// Limites de aviso da simulação (como "SimulationInfo" do DXQ; desligados por padrão)
    var warnings = SimulationWarningSettings()
    /// Kinematic fora da Vista 3D (DXQ "Remove robot from 3D"): continua na estação, mas não aparece nem simula
    var hidden3D = false
    var name: String { model.name }
}

/// Erro/aviso de cinemática com a origem no programa (robô, programa, linha).
struct KinematicIssueRecord: Identifiable {
    let id = UUID()
    var robot: String
    var issue: MotionIssue
    var program: String
    var line: Int
}

enum MessageLevel: String, CaseIterable { case error = "Erro", warning = "Aviso", info = "Informação", simulation = "Simulação" }

struct AppMessage: Identifiable {
    let id = UUID()
    var level: MessageLevel
    var text: String
    var time: Date
    var robot: String
}

enum Selection: Hashable {
    case station
    case robot(UUID)
    case project(UUID, String)
    case program(UUID, String)
    case part(UUID)
}

/// Arquivo de estação salvo pelo CellStudio (.cellstation, JSON).
struct StationFile: Codable {
    struct PartRef: Codable { var name: String; var path: String?; var offset: Pose; var isPaintTarget: Bool; var objectName: String? }
    struct RobotRef: Codable { var model: RobotModel; var joints: JointState; var backupPath: String?; var hidden3D: Bool? = nil }
    var name: String?
    var robots: [RobotRef]?
    var robot: RobotModel?       // formato antigo (1 robô)
    var joints: JointState?
    var program: RobotProgram
    var parts: [PartRef]
    var activeRobotName: String? = nil
    var simulationProgramPaths: [String: String]? = nil
    var typeKey: String? = nil
}

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?
    private static let lastSessionName = "last-session.cellstation"

    static var isSnapshotLaunch: Bool { CommandLine.arguments.contains("--snapshot") }

    static func lastSessionURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CellStudio", isDirectory: true)
            .appendingPathComponent(lastSessionName)
    }

    // Estação
    @Published var stationName = "Estação"
    /// robô sem modelo 3D real → motivo (o robô não aparece na Vista 3D; sem robô simplificado)
    @Published var modelProblems: [UUID: String] = [:]
    /// nome gerado pelos robôs ("Estação R11 / R21") até o usuário escolher um nome
    var stationNameAuto = true
    @Published var robots: [RobotSlot] = []
    @Published var activeRobotID: UUID?
    @Published var selection: Selection? = .station
    @Published var catalog: [RobotCatalogEntry] = []

    var activeIndex: Int? { robots.firstIndex { $0.id == activeRobotID } ?? (robots.isEmpty ? nil : 0) }

    var robot: RobotModel {
        get { activeIndex.map { robots[$0].model } ?? .demo }
        set {
            guard let i = activeIndex else { return }
            robots[i].model = newValue
            invalidateTrajectory()
            scene.syncRobots(robots)
            recomputeTCP()
        }
    }

    var joints: JointState {
        get { activeIndex.map { robots[$0].joints } ?? .home(for: .demo) }
        set {
            guard let i = activeIndex else { return }
            robots[i].joints = newValue
            scene.updateRobot(robots[i])
            recomputeTCP()
        }
    }

    @Published private(set) var tcp = Pose()
    @Published var activeTool = Pose()

    // Programa aberto no editor
    @Published var openProgram: EcoTalkProgram? {
        didSet {
            if oldValue?.url != openProgram?.url { editorSelection = []; editUndo = []; editRedo = [] }
        }
    }
    /// Módulos abertos no editor (abas); `openProgram` é o da aba selecionada
    @Published var openTabs: [ProgramTab] = []
    /// tipo de produção escolhido no typelist.ini (todos os robôs rodam o Proj/Prog dele)
    @Published var selectedTypeKey: String?
    /// projeto escolhido para a análise ("proj:Nome"), quando não é um tipo do typelist
    @Published var analysisProjectKey = ""
    // Editor de programa por comandos (como o ProgramEditor do DXQ)
    @Published var editorSelection: Set<Int> = [] { didSet { if editorSelection != oldValue { syncPathSelection() } } }
    @Published var showAllCommandsOnInsert = false
    @Published var commandEdit: CommandEditRequest?
    @Published var dataEdit: DataEditRequest?
    @Published var showUsedCollisionBits = false
    @Published var showReindex = false
    // Edição de pontos (guia Transformação, como a "Transformation" do DXQ) – ver PointEditing.swift
    @Published var pointSystem: PointCoordSystem = .world
    @Published var pointStepMm = 1.0
    @Published var pointStepDeg = 1.0
    @Published var pointSheet: PointToolSheet?
    /// coordenadas dos pontos antes da primeira transformação da seleção atual ("Restaurar coordenadas")
    var pointResetSnapshot: [String: [String]] = [:]
    var pointResetKey: (url: URL?, selection: Set<Int>) = (nil, [])
    @Published var orientationClipboard: simd_double3x3?
    @Published var railClipboard: Double?
    @Published var orientationDeltaClipboard: simd_double3x3?
    // Guias do DXQ (DXQRibbon.swift / ProgramEditorTools.swift / ExplorerFileOps.swift)
    @Published var dxqSheet: DXQSheet?
    @Published var navigateMode: NavigateMode = .orbit { didSet { scene.setNavigateMode(navigateMode) } }
    /// Seleção: clique seleciona pontos (false) ou mede distância entre dois pontos da geometria (true)
    @Published var measuring = false { didSet { measurePoints = []; scene.showMeasurement([]) } }
    var measurePoints: [Vec3] = []
    @Published var renderModes: [String: RenderMode] = [:]
    @Published var showFloor = false { didSet { scene.setFloor(showFloor) } }
    /// Copiar/colar da Vista 3D: orientação ou trilho (E1)
    @Published var copyPasteRail = false
    /// Recortar/copiar programa ou projeto no explorador
    @Published var explorerClipboard: (url: URL, robot: UUID, cut: Bool)?
    var editUndo: [EcoTalkProgram] = []
    var editRedo: [EcoTalkProgram] = []
    var editClipboard: (lines: [String], decls: [String]) = ([], [])
    @Published var openProgramDirty = false
    @Published var editorTab = 0          // 0 código fonte, 1 dados
    @Published var highlightedLine: Int?
    var origin: [(program: String, line: Int)] = []

    // Programa em simulação (pontos já em coordenadas da estação)
    @Published var program = RobotProgram(name: "programa") { didSet { invalidateTrajectory(); scene.showPath(program); syncPathSelection() } }
    @Published var selectedPoint: ProgramPoint.ID?

    // Peças e pintura
    @Published var parts: [Part] = []
    @Published var partImportRequest: PartImportRequest?
    @Published var importObjectID = "station"
    @Published private(set) var loadingParts = 0
    private var stationGeneration = UUID()
    nonisolated private static let hsfLock = NSLock()

    nonisolated static func readHSF(_ url: URL) throws -> (parts: [HSFPart], warning: String?) {
        hsfLock.lock(); defer { hsfLock.unlock() }
        let parts = try HSF.load(url)
        return (parts, HSF.lastWarning)
    }

    var partObjects: [PartObject] {
        [PartObject.station] + robots.flatMap { robot in
            (robot.backup?.systemData ?? []).compactMap { d -> PartObject? in
                let n = d.numbers
                guard d.type.uppercased() == "OBJECT", n.count == 6 else { return nil }
                return PartObject(id: "\(robot.name) / \(d.name)", name: d.name,
                    pose: Pose(x: n[0], y: n[1], z: n[2], a: n[3], b: n[4], c: n[5]), robotID: robot.id)
            }
        }
    }

    var defaultPartObjectID: String {
        guard let name = openProgram?.commands.last(where: { $0.name == "SETOBJECT" })?.args.first else { return "station" }
        return partObjects.first { $0.robotID == activeRobotID && $0.name.uppercased() == name.uppercased() }?.id ?? "station"
    }

    func assignPartObject(_ id: UUID, objectID: String) {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return }
        if objectID == "manual" { parts[i].objectName = nil; return }
        guard let object = partObjects.first(where: { $0.id == objectID }) else { return }
        parts[i].objectName = object.id
        updatePartOffset(id, object.pose)
    }
    @Published var refineEdge: Double = 15
    @Published var targetThickness: Double = 20
    @Published var paintStats = "Sem simulação"
    @Published var showBrushSheet = false
    @Published var showDownloads = false
    private var simulator: PaintSimulator?
    private var simulatorPartID: UUID?

    // Reprodução
    @Published private(set) var samples: [TrajectorySample] = []
    @Published private(set) var unreachable: [Int] = []
    @Published var playIndex = 0 { didSet { if liveCursor != nil, liveCursor != playIndex { liveCursor = nil; livePoses = [:] } } }
    @Published var isPlaying = false
    @Published var playbackSpeed = 1.0
    @Published var paintWhilePlaying = true
    /// Quando ativo, a reprodução usa todos os robôs da estação no mesmo relógio.
    @Published var simulateAllRobots = false
    /// Programa selecionado para cada robô na simulação multi-kin (chave = URL do .tip).
    @Published var simulationProgramSelection: [UUID: String] = [:]
    @Published private(set) var simulationRuns: [RobotSimulationRun] = []
    /// SET/RECEIVE/DELAY do programa EcoTalk carregado (chave = nome do programa)
    private var programActions: (name: String, actions: [EcoTalkSyncAction]) = ("", [])
    /// Eventos de bits de colisão da última simulação (tempo, texto)
    @Published private(set) var stationEvents: [StationScheduler.Event] = []
    /// Painel de bits de colisão: quem foi dono de cada zona e quem esperou, no relógio da estação
    @Published private(set) var stationZones: [StationScheduler.ZoneInterval] = []
    @Published private(set) var stationWaits: [StationScheduler.WaitInterval] = []
    @Published private(set) var stationDuration: Double = 0
    var stationWaitTime: [String: Double] = [:]
    /// Erros e avisos de cinemática da última simulação (limite de eixo, fora de alcance, singularidade…)
    @Published var kinematicIssues: [KinematicIssueRecord] = []
    // Análise da estação (tempo de ciclo e bits de colisão) – ver StationAnalysisPanel.swift
    @Published var analysis: AnalysisReport?
    @Published var analyzing = false
    @Published var selectedSuggestionID: UUID?
    @Published var bottomTab = 0
    @Published var idealCycleTime: Double = UserDefaults.standard.double(forKey: "idealCycleTime") {
        didSet { UserDefaults.standard.set(idealCycleTime, forKey: "idealCycleTime") }
    }
    @Published var aiModifiedPrograms: Set<URL> = []
    /// variação de tempo da célula real (s) para classificar riscos em instantes diferentes
    @Published var timingTolerance: Double = {
        let v = UserDefaults.standard.double(forKey: "timingTolerance"); StationAnalysis.timingTolerance = v > 0 ? v : 5; return v > 0 ? v : 5
    }() {
        didSet { StationAnalysis.timingTolerance = timingTolerance; UserDefaults.standard.set(timingTolerance, forKey: "timingTolerance") }
    }
    /// efeito de cada sugestão na estação inteira (simulada com os bits de colisão)
    @Published var stationEffects: [UUID: StationEffect] = [:]
    var effectsTask: Task<Void, Never>?
    /// o que o Claude está fazendo agora pelo servidor MCP (mostrado na barra de status)
    @Published var claudeActivity: String?
    let claude = ClaudeChat()
    var aiUndo: [[(robot: UUID, program: EcoTalkProgram)]] = []
    var bodyGridCache: (key: String, grid: ObstacleGrid)?
    // Registro da execução: mensagens saem conforme o robô anda; no primeiro erro o robô para e fica vermelho
    @Published var stopOnError = true
    @Published var simulationStop: SimulationStopInfo?
    @Published var editorErrorLine: Int?
    var simEvents: [SimEvent] = []
    var postedEvents = 0
    var runMessageIDs = Set<UUID>()
    var runErrorCount = 0
    var runFinished = false
    var programNotes: [String] = []
    private var currentActions: [EcoTalkSyncAction] { programActions.name == program.name ? programActions.actions : [] }
    var programActionsList: [EcoTalkSyncAction] { programActions.actions }
    func setProgramActions(_ name: String, _ actions: [EcoTalkSyncAction]) { programActions = (name, actions) }

    /// Aplica DELAY e bits de colisão (regra do DXQ) sobre as trajetórias, no relógio comum da estação.
    private func schedule(_ runs: [RobotSimulationRun]) -> [RobotSimulationRun] {
        guard runs.contains(where: { !$0.actions.isEmpty }) else {
            stationEvents = []; stationZones = []; stationWaits = []; stationDuration = 0
            return runs
        }
        let names = Dictionary(uniqueKeysWithValues: robots.map { ($0.id, $0.name) })
        let inputs = runs.map { r in
            StationScheduler.Input(robot: names[r.robotID] ?? r.robotID.uuidString, samples: r.samples, actions: r.actions,
                                   pointCount: r.program.points.count, start: r.start)
        }
        let out = StationScheduler.run(inputs)
        stationEvents = out.events
        stationZones = out.zones
        stationWaits = out.waits
        stationDuration = out.duration
        stationWaitTime = out.waitTime
        return runs.map { r in
            var r = r
            if let s = out.samples[names[r.robotID] ?? ""], !s.isEmpty { r.samples = s }
            return r
        }
    }
    @Published private(set) var simulationTimeline: [Double] = []
    private var timer: Timer?
    /// Reprodução em curso ainda não publicada para a interface (ver `playbackTick`)
    private var liveCursor: Int?
    private var livePoses: [UUID: JointState] = [:]
    private var playClock = 0.0
    private var lastTick: CFTimeInterval = 0
    private var lastUIPublish: CFTimeInterval = 0
    private var lastColorUpdate: CFTimeInterval = 0
    private var paintDirty = false

    // Vista
    @Published var showPath = true { didSet { scene.pathNode.isHidden = !showPath } }
    @Published var showGrid = false { didSet { scene.gridNode.isHidden = !showGrid } }
    @Published var showFrames = true { didSet { scene.framesNode.isHidden = !showFrames } }

    // Conexão
    @Published var connectionState: ConnectionState = .disconnected
    @Published var telemetry: RobotTelemetry?
    @Published var mirrorRobot = true
    @Published var tcpHost = "192.168.0.10"
    @Published var tcpPort = "5050"
    private var connection: RobotConnection?

    // Modelos 3D do DXQ (pasta 3DObjects extraída da instalação)
    @Published var modelsRoot: URL? = CommandLine.arguments.contains("--no-models") ? nil : AppState.defaultModelsRoot() {
        didSet { if let u = modelsRoot { UserDefaults.standard.set(u.path, forKey: "modelsRoot") }; loadRobotModels() }
    }
    private var loadedModelKeys: [UUID: String] = [:]
    private var railNoticeShown = Set<UUID>()

    @Published var messages: [AppMessage] = []
    @Published var messageFilter: Set<MessageLevel> = Set(MessageLevel.allCases)
    let scene = SceneController()

    init(restoreSession: Bool = true) {
        if let url = Bundle.main.url(forResource: "robots", withExtension: "json"),
           let c = try? RobotCatalogEntry.loadCatalog(from: url) {
            catalog = c.sorted { $0.name < $1.name }
        }
        Self.shared = self
        ScopedAccess.restoreAll()
        let restored = restoreSession && (!Self.isSnapshotLaunch || CommandLine.arguments.contains("--restore")) &&
            (Self.lastSessionURL().map { url in FileManager.default.fileExists(atPath: url.path) && restoreStation(url, announce: false) } ?? false)
        if !restored {
            robots = []
            activeRobotID = nil
            scene.syncRobots(robots)
            recomputeTCP()
        }
        loadRobotModels()
        // servidor MCP local para o Claude Code (no diagnóstico só com --mcp, para não brigar pela porta)
        if Platform.isMac, !Self.isSnapshotLaunch || CommandLine.arguments.contains("--mcp") { MCPServer.shared.start() }
        if restored {
            // começa limpo: estação carregada, robôs em HOME, nenhum robô ativo e nenhuma trajetória na tela
            activeRobotID = nil
            program = RobotProgram(name: "programa")
            for i in robots.indices { robots[i].joints = homeState(for: robots[i]); scene.updateRobot(robots[i]) }
            scene.showPaths([])
            scene.highlight(robot: nil)
            info("Última estação restaurada automaticamente")
        } else {
            info("CellStudio iniciado – \(catalog.count) tipos de robô no catálogo. Abra um backup de robô em Arquivo ▸ Abrir backup.")
        }
    }

    // MARK: Mensagens

    func post(_ level: MessageLevel, _ text: String, robot: String? = nil) {
        messages.append(AppMessage(level: level, text: text, time: Date(), robot: robot ?? (activeIndex.map { robots[$0].name } ?? "")))
        if messages.count > 5000 { messages.removeFirst(messages.count - 5000) }
    }
    func info(_ s: String) { post(.info, s) }
    func warn(_ s: String) { post(.warning, s) }
    func error(_ s: String) { post(.error, s) }

    private func recomputeTCP() {
        var r = robot
        r.tool = activeTool
        tcp = Pose(matrix: Kinematics.tcp(r, joints))
    }

    // MARK: Modelos 3D dos robôs

    static func defaultModelsRoot() -> URL? {
        ScopedAccess.restoreAll()     // no iPhone a pasta escolhida fora do app precisa do acesso reaberto
        let fm = FileManager.default
        var candidates: [String] = []
        if let saved = UserDefaults.standard.string(forKey: "modelsRoot") { candidates.append(saved) }
        #if os(macOS)
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [home + "/Desktop/DXQ Portavel/_analise/inst/3DObjects",
                       home + "/Desktop/DXQ Portavel/3DObjects",
                       home + "/Documents/3DObjects"]
        #else
        // no iPhone: pasta 3DObjects copiada para "No meu iPhone ▸ CellStudio" (Documentos do app)
        candidates.append(Platform.documents.appendingPathComponent("3DObjects").path)
        #endif
        return candidates.first { fm.fileExists(atPath: $0 + "/Robots") }.map { URL(fileURLWithPath: $0) }
    }

    /// Procura o arquivo ignorando maiúsculas (a planilha da Dürr nem sempre bate com o nome real).
    nonisolated static func findFile(_ root: URL, _ rel: String) -> URL? {
        let u = root.appendingPathComponent(rel)
        let fm = FileManager.default
        if fm.fileExists(atPath: u.path) { return u }
        // pasta a pasta: no iPhone o sistema de arquivos diferencia maiúsculas (EcoRs_Kuka × EcoRS_Kuka)
        var cur = root
        for part in rel.split(separator: "/") where !part.isEmpty {
            let name = part.lowercased()
            guard let hit = (try? fm.contentsOfDirectory(atPath: cur.path))?.first(where: { $0.lowercased() == name }) else { return nil }
            cur = cur.appendingPathComponent(hit)
        }
        return cur
    }

    /// Decide trilho, carro, peças e ferramenta de cada robô (rpcsetup.ini + catálogos do DXQ).
    func resolveEquipment() {
        guard let mroot = modelsRoot else { return }
        let rails = Bundle.main.url(forResource: "rails", withExtension: "json")
            .flatMap { try? JSONDecoder().decode([RailEntry].self, from: Data(contentsOf: $0)) } ?? []
        let tools = EquipmentCatalog.tools(mroot.appendingPathComponent("Tools/Tools.xml"))
        let parts = EquipmentCatalog.robotParts(mroot.appendingPathComponent("Robots/DurrRobotParts.xml"))
        let fullCatalog = Bundle.main.url(forResource: "robots", withExtension: "json")
            .flatMap { try? JSONDecoder().decode([RobotCatalogEntry].self, from: Data(contentsOf: $0)) } ?? catalog
        // configuração por robô; sem seção própria, usa a de outro robô do mesmo tipo na estação
        var setups: [UUID: (parts: [String], rail: String?, tool: String?)] = [:]
        for r in robots { if let u = r.backup?.setupURL, let st = EquipmentCatalog.readSetup(u) { setups[r.id] = st } }
        for i in robots.indices where robots[i].model.modelName != nil {
            var st = setups[robots[i].id]
            var borrowed: String?
            if st == nil, let other = robots.first(where: { $0.id != robots[i].id && $0.model.modelName == robots[i].model.modelName && setups[$0.id] != nil }) {
                st = setups[other.id]; borrowed = other.name
            }
            guard let setup = st else { continue }
            // rootOffset: translação Z do arquivo K1 (lido junto com os modelos; aqui usa a do catálogo)
            let eq = EquipmentCatalog.resolve(robot: robots[i].model, catalog: fullCatalog, rails: rails, setup: setup,
                                              tools: tools, parts: parts, rootOffset: 0)
            robots[i].equipment = eq
            if !eq.summary.isEmpty {
                info("\(robots[i].name): " + eq.summary.joined(separator: ", ") + (borrowed.map { " (configuração de \($0))" } ?? ""))
            }
        }
    }

    /// Registra (uma vez) que o modelo 3D de um robô não pôde ser carregado, e por quê.
    func reportModelProblem(_ id: UUID, _ reason: String) {
        guard modelProblems[id] != reason, let slot = robots.first(where: { $0.id == id }) else { return }
        modelProblems[id] = reason
        warn("Modelo 3D de \(slot.name) não pôde ser carregado – \(reason). O robô não aparece na Vista 3D; a simulação e a análise continuam.")
    }

    func loadRobotModels() {
        guard let root = modelsRoot?.appendingPathComponent("Robots") else {
            for slot in robots {
                reportModelProblem(slot.id, "pasta de modelos 3D do DXQ (3DObjects) não encontrada – indique a pasta em Vista 3D ▸ Modelos 3D")
            }
            return
        }
        resolveEquipment()
        for slot in robots where !slot.model.linkFiles.contains(where: { !$0.isEmpty }) {
            reportModelProblem(slot.id, "tipo do robô não identificado no catálogo de modelos (machinedata: \(slot.model.robotType ?? "sem tipo")) – escolha em Vista 3D ▸ Tipo do catálogo")
        }
        // trilho sem modelo: precisa do rpcsetup.ini do backup ([3DOnSiteRCU1] EcoRailType)
        for slot in robots where slot.model.railEnabled && (slot.equipment?.railParts.isEmpty ?? true) && !railNoticeShown.contains(slot.id) {
            railNoticeShown.insert(slot.id)
            let why = slot.backup == nil ? "o robô não tem backup ligado à estação (abra o backup do flash dele)"
                                         : "o rpcsetup.ini do backup não indica o trilho (EcoRailType)"
            warn("Trilho de \(slot.name) não aparece na Vista 3D: \(why).")
        }
        for slot in robots where slot.model.linkFiles.contains(where: { !$0.isEmpty }) {
            let key = slot.model.linkFiles.joined(separator: "|")
            if loadedModelKeys[slot.id] == key { continue }
            loadedModelKeys[slot.id] = key
            let files = slot.model.linkFiles
            let eq = robots.first(where: { $0.id == slot.id })?.equipment
            let toolsRoot = modelsRoot?.appendingPathComponent("Tools")
            let id = slot.id
            let label = slot.model.modelName ?? slot.name
            DispatchQueue.global(qos: .userInitiated).async {
                var links: [[HSFPart]] = []
                var problems: [String] = []
                for f in files {
                    if f.isEmpty { links.append([]); continue }
                    guard let url = Self.findFile(root, f) else { links.append([]); problems.append("\(f) não encontrado"); continue }
                    do { links.append(try Self.readHSF(url).parts) } catch { links.append([]); problems.append("\(f): \(error.localizedDescription)") }
                }
                // equipamentos
                func load(_ base: URL?, _ rel: String) -> [HSFPart] {
                    guard let base, let u = Self.findFile(base, rel) else { problems.append("\(rel) não encontrado"); return [] }
                    do { return try Self.readHSF(u).parts } catch { problems.append("\(rel): \(error.localizedDescription)"); return [] }
                }
                var extras = SceneController.Extras()
                if let eq {
                    var cache: [String: [HSFPart]] = [:]
                    for p in eq.railParts {
                        if cache[p.file] == nil { cache[p.file] = load(root, p.file) }
                        extras.rail.append((cache[p.file]!, p.position))
                    }
                    if let s = eq.sled { extras.sled = load(root, s) }
                    for (j, fs) in eq.robotParts { extras.parts[j] = fs.flatMap { load(root, $0) } }
                    if let t = eq.tool { extras.tool = load(toolsRoot, t) }
                }
                // rootOffset = translação Z do arquivo K1 (a base do robô fica abaixo do frame de referência)
                if let k1 = files.first, !k1.isEmpty, let u = Self.findFile(root, k1), let d = try? Data(contentsOf: u) {
                    extras.rootOffset = Double(HSF.rootTranslation(d).z) * 1000
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let slot = self.robots.first(where: { $0.id == id }) else { return }
                        if links.allSatisfy(\.isEmpty) {
                            self.loadedModelKeys[id] = nil          // tenta de novo se a pasta/tipo mudar
                            self.reportModelProblem(id, "nenhum elo carregado (" + (problems.first ?? "arquivos HSF não encontrados") + ")")
                            return
                        }
                        self.modelProblems[id] = nil
                        self.scene.setRobotModels(slot, links: links)
                        self.scene.setRobotExtras(slot, extras)
                        let tris = links.reduce(0) { $0 + $1.reduce(0) { $0 + $1.indices.count / 3 } }
                        self.info("Modelo 3D \(label) carregado para \(slot.name): \(links.filter { !$0.isEmpty }.count) elos, \(tris) triângulos")
                        for p in problems { self.warn("Modelo 3D: \(p)") }
                    }
                }
            }
        }
    }

    // MARK: Robôs

    func activate(_ id: UUID) {
        guard activeRobotID != id else { return }
        stop()
        activeRobotID = id
        if let selected = simulationProgramURL(for: id) {
            simulationProgramSelection[id] = selected.path
        }
        invalidateTrajectory()
        recomputeTCP()
        scene.highlight(robot: id)
    }

    func openBackup(_ url: URL) {
        do {
            let bk = try RobotBackup.load(url)
            // o painel demo não pertence a uma estação real
            for p in parts where p.url == nil && p.name == "Painel demo" { removePart(p.id) }
            // um backup substitui o robô demo; robôs com o mesmo nome são atualizados
            robots.removeAll { $0.backup == nil && $0.model.source == "catálogo" }
            var home = JointState(rail: bk.robot.railEnabled ? min(max(0, bk.robot.railMin), bk.robot.railMax) : 0, q: [0, 0, 0, 0, 30, 0])
            if let p = bk.systemData.first(where: { $0.name.uppercased() == "RHOME" }), p.numbers.count >= 7 {
                home = JointState(rail: p.numbers[6], q: Array(p.numbers[0..<6]))
            }
            var model = bk.robot
            if let match = model.bestCatalogMatch(catalog) {
                model.assignModel(match)
            }
            let slot = RobotSlot(model: model, joints: home, backup: bk)
            if let i = robots.firstIndex(where: { $0.name == bk.robot.name }) { robots[i] = slot } else { robots.append(slot) }
            robots.sort { $0.name < $1.name }
            activeRobotID = slot.id
            simulationProgramSelection = simulationProgramSelection.filter { entry in
                robots.contains { slot in slot.id == entry.key }
            }
            if let first = bk.projects.flatMap(\.programs).first {
                simulationProgramSelection[slot.id] = first.url.path
            }
            if robots.count > 1, stationNameAuto { stationName = "Estação " + robots.map(\.name).joined(separator: " / ") }
            scene.syncRobots(robots)
            scene.highlight(robot: slot.id)
            recomputeTCP()
            selection = .robot(slot.id)
            if let mn = model.modelName { info("\(model.name): tipo identificado no catálogo como \(mn)") }
            if modelsRoot == nil { warn("Pasta de modelos 3D (3DObjects) não encontrada – use Vista 3D ▸ Modelos 3D…") }
            loadRobotModels()
            let nProg = bk.projects.reduce(0) { $0 + $1.programs.count }
            info("Backup \(url.lastPathComponent): robô \(bk.robot.name), \(bk.projects.count) projetos, \(nProg) programas")
            if bk.projects.isEmpty { warn("Nenhuma pasta teachcontrol/kin1 encontrada em \(url.lastPathComponent)") }
            scene.frameAll()
        } catch {
            self.error("Não foi possível abrir \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func selectCatalogRobot(_ e: RobotCatalogEntry) {
        var m = RobotModel(catalog: e)
        m.base = robot.base
        m.tool = robot.tool
        robot = m
        joints = .home(for: m)
        loadRobotModels()
        info("Tipo de robô: \(e.name) (\(e.kind)) – parâmetros DH aproximados do catálogo")
    }

    func moveTCP(to pose: Pose) {
        var r = robot
        r.tool = activeTool
        let res = Kinematics.inverse(r, target: pose, seed: joints)
        if !res.converged { warn(String(format: "Posição fora de alcance (erro %.1f mm / %.1f°)", res.positionError, res.orientationError)) }
        var s = res.state
        s.rail = joints.rail
        joints = s
    }

    func jog(axis: Int, by delta: Double) {
        var p = tcp
        switch axis {
        case 0: p.x += delta
        case 1: p.y += delta
        case 2: p.z += delta
        case 3: p.a += delta
        case 4: p.b += delta
        default: p.c += delta
        }
        moveTCP(to: p)
    }

    // MARK: Programas EcoTalk

    func project(robot id: UUID, path: String) -> EcoTalkProject? {
        robots.first { $0.id == id }?.backup?.projects.first { $0.url.path == path }
    }

    func simulationProgramChoices(for robotID: UUID) -> [SimulationProgramChoice] {
        guard let slot = robots.first(where: { $0.id == robotID }) else { return [] }
        return slot.backup?.projects.flatMap { project in
            project.programs.map { p in
                SimulationProgramChoice(id: p.url.path, title: "\(project.name)/\(p.name)")
            }
        } ?? []
    }

    func setSimulationProgram(_ path: String, for robotID: UUID) {
        simulationProgramSelection[robotID] = path
        invalidateTrajectory()
    }

    func simulationProgramURL(for robotID: UUID) -> URL? {
        guard let slot = robots.first(where: { $0.id == robotID }), let programs = slot.backup?.projects.flatMap(\.programs), !programs.isEmpty else {
            return nil
        }
        if let path = simulationProgramSelection[robotID], let selected = programs.first(where: { $0.url.path == path }) {
            return selected.url
        }
        if let openProgram, programs.contains(where: { $0.url == openProgram.url }) {
            return openProgram.url
        }
        if let sameName = openProgram.flatMap({ op in programs.first { $0.name.caseInsensitiveCompare(op.name) == .orderedSame } }) {
            return sameName.url
        }
        return programs.first?.url
    }

    func open(program path: String, robot id: UUID) {
        guard let slot = robots.first(where: { $0.id == id }), let bk = slot.backup else { return }
        for proj in bk.projects {
            if let p = proj.programs.first(where: { $0.url.path == path }) {
                activate(id)
                showTab(p, robot: id)
                // abrir para ver/editar não troca o programa que o robô roda na estação
                if simulationProgramSelection[id] == nil { simulationProgramSelection[id] = p.url.path }
                highlightedLine = nil
                previewModule()
                return
            }
        }
    }

    func saveOpenProgram() {
        guard let p = openProgram else { return }
        do {
            try p.save()
            openProgramDirty = false
            for ri in robots.indices {
                guard var bk = robots[ri].backup else { continue }
                for pi in bk.projects.indices {
                    if let gi = bk.projects[pi].programs.firstIndex(where: { $0.url == p.url }) {
                        bk.projects[pi].programs[gi] = p
                        robots[ri].backup = bk
                    }
                }
            }
            info("Programa salvo: \(p.url.lastPathComponent) + .tid")
        } catch { self.error("Erro ao salvar \(p.name): \(error.localizedDescription)") }
    }

    /// Interpreta o programa aberto (com seus CALLs) e prepara a simulação.
    func loadOpenProgramForSimulation() {
        guard let p = openProgram, let i = activeIndex, let bk = robots[i].backup,
              var proj = bk.projects.first(where: { $0.programs.contains { $0.url == p.url } }) else {
            warn("Abra um programa EcoTalk no explorador de projeto"); return
        }
        if let gi = proj.programs.firstIndex(where: { $0.url == p.url }) { proj.programs[gi] = p } // inclui edições não salvas
        // simular um módulo aberto roda só ele, neste robô (não muda o programa do robô na estação)
        simulateAllRobots = false
        var interp = EcoTalkInterpreter(project: proj, systemData: bk.systemData, robot: robots[i].model)
        interp.initialFrames = moduleEntryFrames(module: p.name, robot: robots[i])
        let res = interp.run(p.name)
        programNotes = res.messages      // saem no início da execução, como no DXQ
        programActions = (res.program.name, res.actions)
        program = res.program
        origin = res.origin
        if let first = res.program.points.first { activeTool = first.tool ?? Pose() }
        computeTrajectory()
        let gun = res.program.points.filter(\.paintOn).count
        post(.simulation, "\(proj.name)/\(p.name): \(res.program.points.count) movimentos, \(gun) com aplicação")
    }

    /// Posição home de um robô: ponto RHOME do backup (_globalvars.tid) ou a pose padrão do catálogo.
    func homeState(for slot: RobotSlot) -> JointState {
        if let p = slot.backup?.systemData.first(where: { $0.name.uppercased() == "RHOME" }), p.numbers.count >= 6 {
            let n = p.numbers
            return JointState(rail: n.count > 6 ? n[6] : 0, q: Array(n[0..<6]))
        }
        return .home(for: slot.model)
    }

    /// Para a simulação e leva todos os robôs para home.
    func homeAllRobots() {
        stop()
        for i in robots.indices {
            robots[i].joints = homeState(for: robots[i])
            scene.updateRobot(robots[i])
            scene.setSpray(robot: robots[i].id, on: false, brush: program.brushes.first ?? Brush(id: 1, name: ""), tool: activeTool)
        }
        invalidateTrajectory()
        highlightedLine = nil
        recomputeTCP()
        info("Todos os robôs em home: " + robots.map(\.name).joined(separator: ", "))
    }

    // MARK: Trajetória e reprodução

    func invalidateTrajectory() {
        samples = []
        unreachable = []
        simulationRuns = []
        simulationTimeline = []
        playIndex = 0
        stop()
    }

    func setWarnings(_ w: SimulationWarningSettings, for id: UUID) {
        guard let i = robots.firstIndex(where: { $0.id == id }) else { return }
        robots[i].warnings = w
        invalidateTrajectory()
    }

    func computeTrajectory() {
        if simulateAllRobots {
            computeAllRobotTrajectories()
            return
        }
        guard !program.points.isEmpty else { return }
        let r = Trajectory.sample(program: program, robot: robot, start: joints, warnings: activeIndex.map { robots[$0].warnings } ?? .init())
        samples = r.samples
        if let id = activeRobotID, !currentActions.isEmpty {
            let run = RobotSimulationRun(robotID: id, program: program, start: joints, samples: r.samples,
                                         unreachable: r.unreachable, actions: currentActions)
            samples = schedule([run]).first?.samples ?? r.samples
        }
        unreachable = r.unreachable
        simulationRuns = []
        simulationTimeline = []
        playIndex = 0
        scene.showPath(program, unreachable: Set(r.unreachable))
        if let id = activeRobotID {
            let run = RobotSimulationRun(robotID: id, program: program, start: joints, samples: samples, unreachable: r.unreachable,
                                         actions: currentActions, issues: r.issues, origin: origin.map { (program: $0.program, line: $0.line) },
                                         notes: programNotes, rawStarts: Self.pointStarts(r.samples))
            buildRunEvents([run])
        }
    }

    private func buildSimulationRun(for slot: RobotSlot) -> RobotSimulationRun? {
        let start = slot.joints
        // Robô com backup: sempre interpreta o programa escolhido para a estação (com CALLs, bits e DELAY),
        // incluindo edições ainda não salvas do programa aberto no editor.
        guard let backup = slot.backup, let url = simulationProgramURL(for: slot.id),
              var project = backup.projects.first(where: { $0.programs.contains { $0.url == url } }),
              let source = project.programs.first(where: { $0.url == url }) else {
            guard slot.id == activeRobotID, !program.points.isEmpty else { return nil }
            let result = Trajectory.sample(program: program, robot: slot.model, start: start, warnings: slot.warnings)
            return RobotSimulationRun(robotID: slot.id, program: program, start: start,
                                      samples: result.samples, unreachable: result.unreachable, actions: currentActions,
                                      issues: result.issues, origin: origin.map { (program: $0.program, line: $0.line) },
                                      notes: programNotes, rawStarts: Self.pointStarts(result.samples), rawSamples: result.samples)
        }
        if let op = openProgram, let gi = project.programs.firstIndex(where: { $0.url == op.url }) { project.programs[gi] = op }
        let result = EcoTalkInterpreter(project: project, systemData: backup.systemData, robot: slot.model).run(source.name)
        let sampled = Trajectory.sample(program: result.program, robot: slot.model, start: start, warnings: slot.warnings)
        return RobotSimulationRun(robotID: slot.id, program: result.program, start: start,
                                  samples: sampled.samples, unreachable: sampled.unreachable, actions: result.actions,
                                  issues: sampled.issues, origin: result.origin,
                                  notes: result.messages, rawStarts: Self.pointStarts(sampled.samples), rawSamples: sampled.samples,
                                  callChains: result.callChains)
    }

    private func computeAllRobotTrajectories() {
        stop()
        let built = robots.filter { !$0.hidden3D }.compactMap { buildSimulationRun(for: $0) }
        let runs = schedule(built)
        guard !runs.isEmpty else {
            simulationRuns = []; simulationTimeline = []; samples = []; unreachable = []; playIndex = 0
            scene.showPaths([])
            warn("Nenhum robô possui programa para a simulação multi-kin")
            return
        }
        simulationRuns = runs
        let simulatedIDs = Set(runs.map(\.robotID))
        let withoutProgram = robots.filter { !simulatedIDs.contains($0.id) && !$0.hidden3D }
        if !withoutProgram.isEmpty {
            warn("Sem programa para: " + withoutProgram.map(\.name).joined(separator: ", ") + ". Esses robôs permanecem parados.")
        }
        let times = Set([0.0] + runs.flatMap { $0.samples.map(\.time) }).sorted()
        simulationTimeline = times
        let activeRun = runs.first { $0.robotID == activeRobotID } ?? runs[0]
        samples = activeRun.samples
        unreachable = activeRun.unreachable
        playIndex = 0
        scene.showPaths(runs.map { (program: $0.program, unreachable: Set($0.unreachable)) })
        buildRunEvents(runs)
    }

    func play() {
        if samples.isEmpty {
            if openProgram != nil && program.points.isEmpty { loadOpenProgramForSimulation() } else { computeTrajectory() }
        }
        let count = simulateAllRobots ? simulationTimeline.count : samples.count
        guard count > 1 else { return }
        if playIndex >= count - 1 { playIndex = 0; if paintWhilePlaying { resetPaint() } }
        isPlaying = true
        if playIndex == 0 { beginRunLog() }
        timer?.invalidate()
        liveCursor = nil
        lastTick = CACurrentMediaTime()
        // relógio real: a velocidade escolhida vale de verdade (1× = tempo do robô), mesmo se a tela atrasar um quadro
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackTick() }
        }
    }

    /// Um quadro da reprodução: só o último instante vai para o 3D; a interface (listas, painéis, editor)
    /// é atualizada ~12×/s, porque cada atualização dela redesenha todas as telas.
    private func playbackTick() {
        guard isPlaying else { return }
        let times = simulateAllRobots ? simulationTimeline : samples.map(\.time)
        let count = times.count
        let now = CACurrentMediaTime()
        let elapsed = min(0.1, max(0, now - lastTick))      // depois de um travamento não salta o robô
        lastTick = now
        if liveCursor == nil {                               // começo ou o cursor foi movido por fora
            liveCursor = min(playIndex, max(0, count - 1))
            playClock = times.indices.contains(playIndex) ? times[playIndex] : 0
            livePoses = [:]
        }
        let from = liveCursor ?? 0
        guard from < count - 1 else { commitLive(); stop(); finishRun(); return }
        playClock += elapsed * playbackSpeed
        // último índice com tempo ≤ relógio (sempre anda pelo menos um passo)
        var lo = from + 1, hi = count
        while lo < hi { let mid = (lo + hi) / 2; if times[mid] <= playClock { lo = mid + 1 } else { hi = mid } }
        var to = max(from + 1, lo - 1)
        // "Parar no erro": o robô para exatamente no instante do primeiro erro
        if stopOnError, let errorTime = nextErrorTime(), errorTime <= times[to] + 1e-6 {
            var a = from + 1, b = to
            while a < b { let mid = (a + b) / 2; if times[mid] < errorTime - 1e-6 { a = mid + 1 } else { b = mid } }
            to = a
        }
        if paintWhilePlaying, parts.contains(where: \.isPaintTarget) {
            for i in (from + 1)...to { depositSample(i) }
            paintDirty = true
        }
        if simulateAllRobots { poseMultiRobots(at: times[to], commit: false) } else { poseSingleRobot(samples[to], commit: false) }
        liveCursor = to
        advanceEvents(to: times[to])
        let finished = to >= count - 1
        if !isPlaying || finished || now - lastUIPublish > 0.08 { commitLive() }
        if finished { stop(); finishRun(); return }
        if paintDirty, now - lastColorUpdate > 0.15 { refreshPaintColors() }
    }

    /// Publica para a interface o estado da reprodução (cursor, juntas, TCP, linha do editor).
    private func commitLive() {
        lastUIPublish = CACurrentMediaTime()
        guard let cursor = liveCursor else { return }
        if playIndex != cursor { playIndex = cursor }
        if !livePoses.isEmpty {
            var list = robots
            for (id, state) in livePoses { if let i = list.firstIndex(where: { $0.id == id }) { list[i].joints = state } }
            livePoses = [:]
            robots = list
            recomputeTCP()
        }
        if !simulateAllRobots, samples.indices.contains(cursor) {
            let s = samples[cursor]
            if origin.indices.contains(s.pointIndex), origin[s.pointIndex].program.lowercased() == openProgram?.name.lowercased(),
               highlightedLine != origin[s.pointIndex].line {
                highlightedLine = origin[s.pointIndex].line
            }
        }
    }

    /// Tempo do próximo erro ainda não mostrado nas mensagens.
    private func nextErrorTime() -> Double? {
        guard postedEvents < simEvents.count else { return nil }
        return simEvents[postedEvents...].first { $0.isError }?.time
    }

    /// Tinta do passo `i` (a pintura precisa de todos os passos; o 3D só do último).
    private func depositSample(_ i: Int) {
        guard let sim = ensureSimulator() else { return }
        if simulateAllRobots {
            guard simulationTimeline.indices.contains(i) else { return }
            let time = simulationTimeline[i]
            let dt = max(0, time - (i > 0 ? simulationTimeline[i - 1] : 0))
            for run in simulationRuns {
                guard time > 0, let s = sample(run, at: time), s.paintOn, run.program.points.indices.contains(s.pointIndex),
                      let slot = robots.first(where: { $0.id == run.robotID }) else { continue }
                var model = slot.model
                model.tool = run.program.points[s.pointIndex].tool ?? slot.model.tool
                sim.deposit(gun: partInverse() * Kinematics.tcp(model, s.state), brush: run.program.brush(s.brush), dt: dt)
            }
        } else {
            guard samples.indices.contains(i), samples[i].paintOn else { return }
            let s = samples[i]
            var r = robot
            r.tool = program.points[s.pointIndex].tool ?? activeTool
            let dt = i > 0 ? s.time - samples[i - 1].time : 0.02
            sim.deposit(gun: partInverse() * Kinematics.tcp(r, s.state), brush: program.brush(s.brush), dt: dt)
        }
    }

    func stop() {
        commitLive()
        liveCursor = nil
        isPlaying = false
        timer?.invalidate(); timer = nil
        refreshPaintColors()
    }

    /// Tempo de simulação no cursor atual (s).
    var currentSimTime: Double {
        if simulateAllRobots { return simulationTimeline.indices.contains(playIndex) ? simulationTimeline[playIndex] : 0 }
        return samples.indices.contains(playIndex) ? samples[playIndex].time : 0
    }

    /// Leva a simulação ao instante `time` (s).
    func scrub(toTime time: Double) {
        let times = simulateAllRobots ? simulationTimeline : samples.map(\.time)
        guard !times.isEmpty else { return }
        var lo = 0, hi = times.count
        while lo < hi { let mid = (lo + hi) / 2; if times[mid] < time { lo = mid + 1 } else { hi = mid } }
        stop()
        scrub(to: min(lo, times.count - 1))
    }

    /// Abre no editor o programa e a linha de um SET/RECEIVE (painel de bits).
    func reveal(program name: String, line: Int, robot robotName: String) {
        guard let slot = robots.first(where: { $0.name == robotName }), let bk = slot.backup else { return }
        let chosen = simulationProgramURL(for: slot.id)
        let project = bk.projects.first { p in p.programs.contains { $0.url == chosen } }
        let candidates = (project.map { [$0] } ?? []) + bk.projects
        guard let prog = candidates.lazy.compactMap({ $0.programs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }).first else { return }
        // só mostra a linha: não troca o robô ativo (isso descartaria a simulação conjunta)
        if openProgram?.url != prog.url { showTab(prog, robot: slot.id) }
        selection = .program(slot.id, prog.url.path)
        highlightedLine = line
    }

    func scrub(to i: Int) {
        if simulateAllRobots {
            guard simulationTimeline.indices.contains(i) else { return }
            playIndex = i
            applyMultiSamples(at: simulationTimeline[i], deposit: false)
            syncEvents(to: simulationTimeline[i])
            return
        }
        guard samples.indices.contains(i) else { return }
        playIndex = i
        applySample(samples[i], deposit: false)
        syncEvents(to: samples[i].time)
    }

    private func sample(_ run: RobotSimulationRun, at time: Double) -> TrajectorySample? {
        guard !run.samples.isEmpty else { return nil }
        var lo = 0, hi = run.samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if run.samples[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        return run.samples[max(0, lo - 1)]
    }

    private func applyMultiSamples(at time: Double, deposit: Bool) {
        if deposit, playIndex > 0 { depositSample(playIndex) }
        poseMultiRobots(at: time, commit: true)
    }

    /// Põe os robôs da simulação conjunta no instante `time`. Sem `commit`, só o 3D muda (a lista de robôs
    /// é publicada depois por `commitLive`).
    private func poseMultiRobots(at time: Double, commit: Bool) {
        for run in simulationRuns {
            guard let i = robots.firstIndex(where: { $0.id == run.robotID }) else { continue }
            let point: ProgramPoint?
            let state: JointState
            let paintOn: Bool
            let brushID: Int
            if time <= 0 {
                state = run.start; point = nil; paintOn = false; brushID = 1
            } else if let s = sample(run, at: time), run.program.points.indices.contains(s.pointIndex) {
                state = s.state; point = run.program.points[s.pointIndex]; paintOn = s.paintOn; brushID = s.brush
            } else {
                state = run.start; point = nil; paintOn = false; brushID = 1
            }
            var slot = robots[i]
            slot.joints = state
            if commit { robots[i] = slot } else { livePoses[slot.id] = state }
            scene.updateRobot(slot)
            let tool = point?.tool ?? slot.model.tool
            scene.setSpray(robot: run.robotID, on: paintOn, brush: run.program.brush(brushID), tool: tool)
        }
        if let active = robots.firstIndex(where: { $0.id == activeRobotID }) {
            if let run = simulationRuns.first(where: { $0.robotID == robots[active].id }), let s = time > 0 ? sample(run, at: time) : nil,
               run.program.points.indices.contains(s.pointIndex), let tool = run.program.points[s.pointIndex].tool, tool != activeTool {
                activeTool = tool
            }
            if commit { recomputeTCP() }
        }
    }

    private func applySample(_ s: TrajectorySample, deposit: Bool) {
        if deposit { depositSample(playIndex) }
        poseSingleRobot(s, commit: true)
    }

    private func poseSingleRobot(_ s: TrajectorySample, commit: Bool) {
        let p = program.points[s.pointIndex]
        if let t = p.tool, t != activeTool { activeTool = t }
        if commit {
            joints = s.state
            if origin.indices.contains(s.pointIndex), origin[s.pointIndex].program.lowercased() == openProgram?.name.lowercased() {
                if highlightedLine != origin[s.pointIndex].line { highlightedLine = origin[s.pointIndex].line }
            }
        } else if let i = activeIndex {
            var slot = robots[i]
            slot.joints = s.state
            livePoses[slot.id] = s.state
            scene.updateRobot(slot)
        }
        scene.setSpray(robot: activeRobotID, on: s.paintOn, brush: program.brush(s.brush), tool: activeTool)
    }

    // MARK: Pintura

    private func partInverse() -> Mat4 {
        guard let p = parts.first(where: { $0.id == simulatorPartID }) else { return .identity }
        return p.offset.matrix.inverse
    }

    private func ensureSimulator() -> PaintSimulator? {
        guard let part = parts.first(where: \.isPaintTarget) else { return nil }
        if simulatorPartID != part.id || simulator == nil {
            let edge = part.url?.pathExtension.lowercased() == "hsf" ? max(30, refineEdge) : refineEdge
            let refined = part.mesh.positions.count > 2_000_000 ? part.mesh : part.mesh.refined(maxEdge: Float(edge))
            if refined.positions.count > 2_000_000 { warn("Malha de pintura com mais de 2 milhões de vértices; refinamento adicional desativado para peças desse porte.") }
            simulator = PaintSimulator(mesh: refined)
            simulatorPartID = part.id
            scene.setPart(part, displayMesh: refined)
            post(.simulation, "Malha de simulação: \(refined.positions.count) vértices (aresta máx. \(Int(edge)) mm)")
        }
        return simulator
    }

    func simulatePaint() {
        if simulateAllRobots {
            if simulationRuns.isEmpty { computeTrajectory() }
        } else if samples.isEmpty {
            computeTrajectory()
        }
        guard let sim = ensureSimulator() else { warn("Marque uma peça como alvo de pintura"); return }
        sim.reset()
        let inv = partInverse()
        if simulateAllRobots {
            var prev = 0.0
            for time in simulationTimeline.dropFirst() {
                let dt = max(0, time - prev)
                for run in simulationRuns {
                    guard let s = sample(run, at: time), s.paintOn,
                          let i = robots.firstIndex(where: { $0.id == run.robotID }),
                          run.program.points.indices.contains(s.pointIndex) else { continue }
                    var model = robots[i].model
                    let point = run.program.points[s.pointIndex]
                    model.tool = point.tool ?? model.tool
                    sim.deposit(gun: inv * Kinematics.tcp(model, s.state), brush: run.program.brush(s.brush), dt: dt)
                }
                prev = time
            }
            if let last = simulationTimeline.indices.last { playIndex = last; applyMultiSamples(at: simulationTimeline[last], deposit: false) }
            refreshPaintColors()
            return
        }
        var prev = 0.0
        for s in samples {
            if s.paintOn {
                var r = robot
                r.tool = program.points[s.pointIndex].tool ?? activeTool
                sim.deposit(gun: inv * Kinematics.tcp(r, s.state), brush: program.brush(s.brush), dt: s.time - prev)
            }
            prev = s.time
        }
        playIndex = samples.count - 1
        if let last = samples.last { joints = last.state }
        refreshPaintColors()
    }

    func resetPaint() {
        simulator?.reset()
        refreshPaintColors()
    }

    func rebuildSimulationMesh() {
        simulator = nil
        _ = ensureSimulator()
        refreshPaintColors()
    }

    func refreshPaintColors() {
        lastColorUpdate = CACurrentMediaTime()
        paintDirty = false
        guard let sim = simulator, let id = simulatorPartID else { return }
        scene.colorPart(id: id, thickness: sim.thickness, target: Float(targetThickness))
        let s = sim.stats
        paintStats = s.coated == 0 ? "Nenhuma tinta depositada" :
            String(format: "Mín %.1f µm · Média %.1f µm · Máx %.1f µm · %d vértices", s.min, s.mean, s.max, s.coated)
    }

    func generateZigzag(standoff: Double, overlap: Double) {
        guard let part = parts.first(where: \.isPaintTarget) ?? parts.first else { warn("Carregue uma peça primeiro"); return }
        let b = part.mesh.bounds
        let o = part.offset
        var prog = RobotProgram.zigzag(minX: Double(b.min.x) + o.x, maxX: Double(b.max.x) + o.x,
                                       minY: Double(b.min.y) + o.y, maxY: Double(b.max.y) + o.y,
                                       z: Double(b.max.z) + o.z, standoff: standoff, overlap: overlap,
                                       brush: program.brushes.first ?? Brush(id: 1, name: "Pincel 1"))
        prog.name = "zigzag_\(part.name)"
        for i in prog.points.indices { prog.points[i].rail = joints.rail }
        origin = []
        activeTool = robot.tool
        program = prog
        info("Programa zigue-zague gerado: \(prog.points.count) pontos")
    }

    // MARK: Peças

    func addDemoPanel() {
        var p = Part(name: "Painel demo", mesh: STL.demoPanel())
        p.offset = Pose(x: 1700, y: 0, z: 0)
        p.isPaintTarget = parts.isEmpty
        parts.append(p)
        scene.setPart(p, displayMesh: p.mesh)
    }

    func importPart(_ url: URL, asBody: Bool = false) {
        if (asBody || url.pathExtension.lowercased() == "hsf"), robots.contains(where: { $0.backup != nil }) {
            importObjectID = defaultPartObjectID
            partImportRequest = PartImportRequest(url: url)
        } else {
            loadPart(url, object: nil)
        }
    }

    func confirmPartImport() {
        guard let request = partImportRequest,
              let object = partObjects.first(where: { $0.id == importObjectID }) else { return }
        partImportRequest = nil
        loadPart(request.url, object: object)
    }

    func loadPart(_ url: URL, object: PartObject?, restored: StationFile.PartRef? = nil) {
        let generation = stationGeneration
        loadingParts += 1
        info("Carregando… \(url.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var warning: String?
                let mesh = try Self.loadMesh(url) { warning = $0 }
                let loadWarning = warning
                let b = mesh.bounds
                DispatchQueue.main.async {
                    self.loadingParts -= 1
                    guard generation == self.stationGeneration else { return }
                    var p = Part(name: url.deletingPathExtension().lastPathComponent, url: url, mesh: mesh)
                    p.offset = object?.pose ?? Pose(x: 1700 - Double(b.min.x + b.max.x) / 2,
                        y: -Double(b.min.y + b.max.y) / 2, z: -Double(b.min.z) + 300)
                    p.objectName = object?.id
                    p.isPaintTarget = !self.parts.contains(where: \.isPaintTarget)
                    if let restored {
                        p.name = restored.name; p.offset = restored.offset
                        p.objectName = restored.objectName; p.isPaintTarget = restored.isPaintTarget
                    }
                    self.parts.append(p)
                    self.scene.setPart(p, displayMesh: mesh)
                    self.selection = .part(p.id)
                    self.scene.frameAll()
                    let size = b.max - b.min
                    let extent = max(size.x, size.y, size.z)
                    self.info("Peça \(p.name): \(mesh.indices.count / 3) triângulos, \(Int(size.x))×\(Int(size.y))×\(Int(size.z)) mm")
                    if let loadWarning { self.warn("HSF parcial: \(loadWarning)") }
                    if extent < 10 || extent > 20_000 { self.warn("Dimensões incomuns da peça. Confira a unidade do arquivo (esperada: metros no HSF).") }
                    if mesh.positions.count > 2_000_000 { self.warn("Peça com mais de 2 milhões de vértices; a simulação de pintura pode ser lenta.") }
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadingParts -= 1
                    self.error("Erro ao abrir \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated static func loadMesh(_ url: URL, warning: (String?) -> Void = { _ in }) throws -> Mesh {
        switch url.pathExtension.lowercased() {
        case "stl": return try STL.load(url)
        case "hsf":
            let result = try readHSF(url)
            warning(result.warning)
            var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
            positions.reserveCapacity(result.parts.reduce(0) { $0 + $1.positions.count })
            indices.reserveCapacity(result.parts.reduce(0) { $0 + $1.indices.count })
            for part in result.parts {
                let base = UInt32(positions.count)
                positions.append(contentsOf: part.positions.map { $0 * 1000 })
                indices.append(contentsOf: part.indices.map { $0 + base })
            }
            guard !indices.isEmpty else { throw STLError.invalid(result.warning ?? "Nenhum triângulo encontrado no HSF") }
            return Mesh(positions: positions, indices: indices)
        default:
            let asset = MDLAsset(url: url)
            var pos: [SIMD3<Float>] = [], idx: [UInt32] = []
            for case let m as MDLMesh in asset.childObjects(of: MDLMesh.self) {
                guard let attr = m.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
                let base = UInt32(pos.count)
                for i in 0..<m.vertexCount {
                    let p = attr.dataStart.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
                    pos.append(SIMD3(p[0], p[1], p[2]))
                }
                for case let sub as MDLSubmesh in m.submeshes ?? [] where sub.geometryType == .triangles {
                    let buf = sub.indexBuffer(asIndexType: .uInt32).map()
                    let ptr = buf.bytes.assumingMemoryBound(to: UInt32.self)
                    for k in 0..<sub.indexCount { idx.append(base + ptr[k]) }
                }
            }
            guard !idx.isEmpty else { throw STLError.invalid("Nenhuma malha triangular encontrada") }
            return Mesh(positions: pos, indices: idx)
        }
    }

    func updatePartOffset(_ id: UUID, _ pose: Pose) {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return }
        parts[i].offset = pose
        scene.movePart(id: id, pose: pose)
    }

    func setPaintTarget(_ id: UUID) {
        for i in parts.indices { parts[i].isPaintTarget = parts[i].id == id }
        simulator = nil
        simulatorPartID = nil
    }

    func removePart(_ id: UUID) {
        // Troca a seleção antes de publicar a remoção; o painel de propriedades
        // pode ser recalculado imediatamente pelo SwiftUI.
        if selection == .part(id) { selection = .station }
        parts.removeAll { $0.id == id }
        scene.removePart(id: id)
        if simulatorPartID == id { simulator = nil; simulatorPartID = nil }
    }

    // MARK: Conexão

    func connectVirtual() {
        if samples.isEmpty { computeTrajectory() }
        startConnection(VirtualRobotConnection(samples: samples, programName: program.name))
    }

    func connectTCP() {
        guard let port = Int(tcpPort) else { warn("Porta inválida"); return }
        startConnection(TCPLineConnection(host: tcpHost, port: port))
    }

    private func startConnection(_ c: RobotConnection) {
        connection?.disconnect()
        connection = c
        c.onState = { [weak self] st in
            MainActor.assumeIsolated {
                self?.connectionState = st
                if case .failed(let m) = st { self?.error("Conexão: \(m)") }
                if st == .connected { self?.info("Conectado: \(c.name)") }
            }
        }
        c.onTelemetry = { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.telemetry = t
                if self.mirrorRobot && !self.isPlaying {
                    self.joints = t.joints
                    self.scene.setSpray(robot: self.activeRobotID, on: t.paintOn, brush: self.program.brushes.first ?? Brush(id: 1, name: ""), tool: self.activeTool)
                }
            }
        }
        info("Conectando: \(c.name)")
        c.connect()
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
        telemetry = nil
    }

    // MARK: Arquivos

    private func currentStationFile() -> StationFile {
        var programPaths: [String: String] = [:]
        for slot in robots {
            if let path = simulationProgramSelection[slot.id] { programPaths[slot.name] = path }
        }
        return StationFile(name: stationName,
                    robots: robots.map { .init(model: $0.model, joints: $0.joints, backupPath: $0.backup?.root.path, hidden3D: $0.hidden3D ? true : nil) },
                    program: program,
                    parts: parts.map { .init(name: $0.name, path: $0.url?.path, offset: $0.offset, isPaintTarget: $0.isPaintTarget, objectName: $0.objectName) },
                    activeRobotName: activeRobotID.flatMap { id in robots.first(where: { $0.id == id })?.name },
                    simulationProgramPaths: programPaths, typeKey: selectedTypeKey)
    }

    private func encodedStation() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(currentStationFile())
    }

    func saveStation(to url: URL) {
        do {
            try encodedStation().write(to: url)
            info("Estação salva: \(url.lastPathComponent)")
        } catch { self.error("Erro ao salvar: \(error.localizedDescription)") }
    }

    func saveLastSession() {
        guard let url = Self.lastSessionURL() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encodedStation().write(to: url, options: .atomic)
        } catch {
            warn("Não foi possível salvar a última sessão: \(error.localizedDescription)")
        }
    }

    func openStation(_ url: URL) {
        _ = restoreStation(url, announce: true)
    }

    @discardableResult
    private func restoreStation(_ url: URL, announce: Bool) -> Bool {
        do {
            let f = try JSONDecoder().decode(StationFile.self, from: Data(contentsOf: url))
            stationGeneration = UUID()
            partImportRequest = nil
            for p in parts { scene.removePart(id: p.id) }
            parts = []
            simulator = nil; simulatorPartID = nil
            stationName = f.name ?? url.deletingPathExtension().lastPathComponent
            var slots: [RobotSlot] = []
            for r in f.robots ?? [] {
                let bk = r.backupPath.flatMap { try? RobotBackup.load(URL(fileURLWithPath: $0)) }
                var slot = RobotSlot(model: r.model, joints: r.joints, backup: bk)
                slot.hidden3D = r.hidden3D ?? false
                slots.append(slot)
            }
            if slots.isEmpty, let m = f.robot { slots = [RobotSlot(model: m, joints: f.joints ?? .home(for: m))] }
            robots = slots
            activeRobotID = slots.first(where: { $0.name == f.activeRobotName })?.id ?? slots.first?.id
            simulationProgramSelection = [:]
            for slot in slots {
                if let path = f.simulationProgramPaths?[slot.name] {
                    simulationProgramSelection[slot.id] = path
                }
            }
            selectedTypeKey = f.typeKey
            openTabs = []; openProgram = nil; openProgramDirty = false
            scene.syncRobots(robots)
            program = f.program
            for ref in f.parts {
                if let path = ref.path {
                    loadPart(URL(fileURLWithPath: path), object: nil, restored: ref)
                } else {
                    let p = Part(name: ref.name, mesh: STL.demoPanel(), offset: ref.offset, isPaintTarget: ref.isPaintTarget, objectName: ref.objectName)
                    parts.append(p); scene.setPart(p, displayMesh: p.mesh)
                }
            }
            recomputeTCP()
            if announce { info("Estação aberta: \(url.lastPathComponent)") }
            return true
        } catch {
            if announce { self.error("Erro ao abrir estação: \(error.localizedDescription)") }
            return false
        }
    }

    func importProgram(_ url: URL) {
        do {
            let src = try String(contentsOf: url, encoding: .isoLatin1)
            var dat = ""
            let datURL = url.deletingPathExtension().appendingPathExtension("dat")
            if FileManager.default.fileExists(atPath: datURL.path) { dat = (try? String(contentsOf: datURL, encoding: .isoLatin1)) ?? "" }
            var p = KRL.parse(src: src, dat: dat)
            p.name = url.deletingPathExtension().lastPathComponent
            p.brushes = program.brushes
            origin = []
            program = p
            info("Programa KRL \(p.name): \(p.points.count) movimentos importados")
        } catch { self.error("Erro ao ler programa: \(error.localizedDescription)") }
    }

    func exportProgram(to url: URL) {
        let e = KRL.export(program)
        do {
            try e.src.write(to: url, atomically: true, encoding: .isoLatin1)
            try e.dat.write(to: url.deletingPathExtension().appendingPathExtension("dat"), atomically: true, encoding: .isoLatin1)
            info("Programa exportado: \(url.lastPathComponent) + .dat")
        } catch { self.error("Erro ao exportar: \(error.localizedDescription)") }
    }
}
