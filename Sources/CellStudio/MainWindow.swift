import CellCore
#if os(macOS)
import AppKit
#endif
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var app: AppState
    @State private var tab = CommandLine.arguments.firstIndex(of: "--tab").flatMap { i in
        i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil } ?? "Vista 3D"
    @State private var showFileMenu = false
    @State private var showCatalog = false
    @State private var ribbonNaturalWidth: CGFloat = 0
    private let tabs = ["Editor de programa", "Ferramentas do editor", "Vista 3D", "Objetos 3D", "Simulação", "Análise IA", "Online"]

    var body: some View {
        VStack(spacing: 0) {
            quickAccessBar
            RibbonTabBar(tabs: tabs, selected: $tab) { showFileMenu = true }
                .popover(isPresented: $showFileMenu, arrowEdge: .bottom) { FileMenu(close: { showFileMenu = false }) }
            GeometryReader { geometry in
                let naturalWidth = max(ribbonNaturalWidth, geometry.size.width)
                let fitScale = min(1, geometry.size.width / naturalWidth)
                let verticalScale: CGFloat = tab == "Objetos 3D" ? 1 : fitScale
                ribbonBody
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { content in
                        Color.clear.preference(key: RibbonNaturalWidthKey.self, value: content.size.width)
                    })
                    .scaleEffect(x: fitScale, y: verticalScale, anchor: .topLeading)
                    .frame(width: naturalWidth * fitScale, height: 92, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .frame(height: 92)
                .clipped()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DXQ.ribbonBG)
                .overlay(alignment: .top) { Rectangle().fill(DXQ.border).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
                .onPreferenceChange(RibbonNaturalWidthKey.self) { width in
                    if abs(ribbonNaturalWidth - width) > 0.5 { ribbonNaturalWidth = width }
                }

            // tamanhos dos painéis ficam gravados (arrastar as divisórias)
            PersistentSplit(.horizontal, key: "leftColumn", defaultSize: 310, side: .first, minFirst: 220, minSecond: 520) {
                PersistentSplit(.vertical, key: "explorer", defaultSize: 420, side: .first, minFirst: 140, minSecond: 120) {
                    ProjectExplorer()
                } second: {
                    PropertiesPanel()
                }
            } second: {
                PersistentSplit(.vertical, key: "bottomDock", defaultSize: 200, side: .second, minFirst: 240, minSecond: 90) {
                    PersistentSplit(.horizontal, key: "programEditor", defaultSize: 380, side: .second, minFirst: 300, minSecond: 220) {
                        View3DPanel()
                    } second: {
                        ProgramEditorPanel()
                    }
                } second: {
                    BottomDock()
                }
            }
            .padding(3)
            .background(DXQ.windowBG)
            StatusBar()
        }
        .preferredColorScheme(.light)
        .sheet(item: $app.partImportRequest) { request in PartObjectSheet(url: request.url) }
        .sheet(isPresented: $app.showBrushSheet) { BrushSheet() }
        .sheet(isPresented: $showCatalog) { CatalogSheet() }
        .sheet(item: $app.commandEdit) { CommandEditorSheet(request: $0) }
        .sheet(item: $app.dataEdit) { DataEditorSheet(request: $0) }
        .sheet(isPresented: $app.showUsedCollisionBits) { UsedCollisionBitsSheet() }
        .sheet(isPresented: $app.showReindex) { ReindexSheet() }
        .sheet(item: $app.pointSheet) { PointToolSheetView(kind: $0) }
        .sheet(item: $app.dxqSheet) { DXQSheetView(sheet: $0) }
        .sheet(isPresented: $app.showDownloads) { NavigationStack { DownloadsView() }.frame(width: 560, height: 620) }
        .task { await RepoSync.shared.checkForUpdate(); announceUpdate(app) }
        .background(Color.white)
    }

    /// Barra de acesso rápido observada no DXQ acima das abas do ribbon.
    private var quickAccessBar: some View {
        ZStack {
            HStack(spacing: 2) {
                RibbonIconButton(icon: "dxq:general_station", help: "Nova estação") { app.newStation() }
                RibbonIconButton(icon: "dxq:3dgraphic_open", help: "Abrir backup de robô") { openBackup() }
                RibbonIconButton(icon: "dxq:general_folderopen", help: "Abrir estação") {
                    openFile(["cellstation"]) { app.openStation($0) }
                }
                RibbonIconButton(icon: "dxq:general_save", help: "Salvar programa", enabled: app.openProgramDirty) { app.saveOpenProgram() }
                Rectangle().fill(DXQ.border).frame(width: 1, height: 16).padding(.horizontal, 3)
                RibbonIconButton(icon: "dxq:general_undo", help: "Desfazer", enabled: !app.editUndo.isEmpty) { app.undoEdit() }
                RibbonIconButton(icon: "dxq:general_redo", help: "Refazer", enabled: !app.editRedo.isEmpty) { app.redoEdit() }
                Spacer(minLength: 0)
            }
            Text(quickAccessTitle)
                .font(.system(size: 11))
                .foregroundStyle(DXQ.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
    }

    private var quickAccessTitle: String {
        if let program = app.openProgram {
            let robot = app.robots.first(where: { $0.id == app.activeRobotID })?.name ?? "Programa"
            return "\(robot) – \(program.name) – CellStudio"
        }
        return "CellStudio – DXQ3D.onsite para macOS"
    }

    @ViewBuilder private var ribbonBody: some View {
        HStack(alignment: .top, spacing: 0) {
            switch tab {
            case "Editor de programa": DXQProgramEditorTab()
            case "Ferramentas do editor": DXQProgramToolsTab()
            case "Objetos 3D": DXQObjects3DTab()
            case "Simulação": DXQSimulationTab()
            case "Análise IA": DXQAnalysisTab()
            case "Online": DXQOnlineTab()
            default: DXQView3DTab(showCatalog: $showCatalog)
            }
        }
    }

    private var selectedPart: UUID? { if case .part(let id) = app.selection { return id }; return nil }

    private func copyTCP() {
        let t = app.tcp
        let s = String(format: "(World, %.3f, %.3f, %.3f, %.3f, %.3f, %.3f, %.2f, 0, 0)", t.x, t.y, t.z, t.a, t.b, t.c, app.joints.rail)
        Pasteboard.copy(s)
        app.info("Posição copiada: \(s)")
    }

    private func openBackup() {
        Dialogs.chooseFolders("Selecione a pasta do backup/flash do robô (contém config/machinedata1.cfg)", multiple: true).forEach { app.openBackup($0) }
    }
}

private struct RibbonNaturalWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: Abas do ribbon (também usadas nas telas do iPhone)

struct DXQSimulationTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            RibbonGroup(title: "Simulação") {
                RibbonLargeButton(title: app.isPlaying ? "Parar" : "Iniciar", icon: app.isPlaying ? "stop.fill" : "play.fill",
                                  tint: app.isPlaying ? .red : Color(red: 0.1, green: 0.55, blue: 0.2)) { app.isPlaying ? app.stop() : app.play() }
                RibbonColumn {
                    RibbonSmallButton(title: "Recalcular trajetória", icon: "arrow.triangle.2.circlepath") { app.computeTrajectory() }
                    RibbonSmallButton(title: "Ao início", icon: "backward.end.fill") { app.scrub(to: 0) }
                    RibbonSmallButton(title: "Todos para home", icon: "house.fill") { app.homeAllRobots() }
                }
                RibbonColumn {
                    RibbonSmallButton(title: "Todos os robôs", icon: "person.3", checked: app.simulateAllRobots) {
                        app.simulateAllRobots.toggle()
                        app.computeTrajectory()
                    }
                    RibbonSmallButton(title: "Pintar durante", icon: "paintbrush", checked: app.paintWhilePlaying) { app.paintWhilePlaying.toggle() }
                    RibbonSmallButton(title: "Parar no erro", icon: "exclamationmark.octagon", checked: app.stopOnError) { app.stopOnError.toggle() }
                }
            }
            if app.simulateAllRobots {
            RibbonGroup(title: "Tipo em produção") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("typelist.ini").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { app.selectedTypeKey ?? "" }, set: { app.applyType($0.isEmpty ? nil : $0) })) {
                        Text("Escolher programas à mão").tag("")
                        ForEach(app.typeListOptions) { t in Text(t.label).tag(t.section) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 220)
                    Text("Todos os robôs rodam o Proj/Prog do tipo").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
                RibbonGroup(title: "Programas da estação") {
                    LazyHGrid(rows: [GridItem(.fixed(22), spacing: 2), GridItem(.fixed(22), spacing: 2), GridItem(.fixed(22), spacing: 2)],
                              alignment: .top, spacing: 10) {
                        ForEach(app.robots) { slot in
                            let choices = app.simulationProgramChoices(for: slot.id)
                            HStack(spacing: 4) {
                                Text(slot.name).frame(width: 48, alignment: .leading)
                                if choices.isEmpty {
                                    Text("Sem programa").foregroundStyle(.secondary)
                                } else {
                                    Picker("", selection: Binding(get: {
                                        app.simulationProgramSelection[slot.id] ?? choices[0].id
                                    }, set: { value in
                                        app.setSimulationProgram(value, for: slot.id)
                                    })) {
                                        ForEach(choices) { choice in Text(choice.title).tag(choice.id) }
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 170)
                                }
                            }
                        }
                        if app.robots.isEmpty { Text("Nenhum robô carregado").foregroundStyle(.secondary) }
                    }
                    .font(DXQ.font)
                }
            }
            RibbonGroup(title: "Velocidade") {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("", selection: $app.playbackSpeed) {
                        Text("1×").tag(1.0); Text("2×").tag(2.0); Text("5×").tag(5.0); Text("10×").tag(10.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                    let times = app.simulateAllRobots ? app.simulationTimeline : app.samples.map(\.time)
                    if !times.isEmpty {
                        Slider(value: Binding(get: { Double(app.playIndex) }, set: { app.scrub(to: Int($0)) }),
                               in: 0...Double(max(times.count - 1, 1))).frame(width: 150).controlSize(.small)
                        let time = times[min(app.playIndex, times.count - 1)]
                        Text(String(format: "%.2f / %.2f s", time, times.last ?? 0))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            RibbonGroup(title: "Aplicação") {
                RibbonLargeButton(title: "Simular espessura", icon: "bolt.fill", tint: .orange) { app.simulatePaint() }
                RibbonColumn {
                    RibbonSmallButton(title: "Pincéis…", icon: "paintbrush.pointed") { app.showBrushSheet = true }
                    RibbonSmallButton(title: "Limpar tinta", icon: "eraser") { app.resetPaint() }
                    RibbonSmallButton(title: "Zigue-zague na peça", icon: "scribble") { app.generateZigzag(standoff: 250, overlap: 0.5) }
                }
            }
        }
    }
}

struct DXQAnalysisTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            RibbonGroup(title: "Análise da estação") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Programa da análise").font(.system(size: 10)).foregroundStyle(.secondary)
                    AnalysisProgramPicker(width: 210)
                    Text("Analisar = simula a estação desde HOME + análise").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                RibbonLargeButton(title: app.analyzing ? "Analisando…" : "Simular e\nanalisar", icon: "sparkles",
                                  tint: Color(red: 0.45, green: 0.25, blue: 0.8), enabled: !app.analyzing) { app.simulateAndAnalyze() }
                RibbonColumn {
                    RibbonSmallButton(title: "Ver sugestões", icon: "list.bullet.rectangle") { app.bottomTab = 2 }
                    RibbonSmallButton(title: "Desfazer sugestão", icon: "arrow.uturn.backward", enabled: !app.aiUndo.isEmpty) { app.undoLastApply() }
                    RibbonSmallButton(title: "Salvar alterações", icon: "square.and.arrow.down", enabled: !app.aiModifiedPrograms.isEmpty) { app.saveAnalysisChanges() }
                }
            }
            RibbonGroup(title: "Meta") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ciclo ideal HOME-to-HOME").font(.system(size: 11))
                    HStack(spacing: 4) {
                        TextField("", value: $app.idealCycleTime, format: .number.precision(.fractionLength(1)))
                            .frame(width: 64).textFieldStyle(.roundedBorder).controlSize(.small)
                        Text("s").font(.system(size: 11))
                    }
                    if let a = app.analysis, app.idealCycleTime > 0 {
                        let over = a.breakdowns.filter { $0.total > app.idealCycleTime }.map(\.robot)
                        Text(over.isEmpty ? "Todos na meta" : "Acima: " + over.joined(separator: ", "))
                            .font(.system(size: 10)).foregroundStyle(over.isEmpty ? .green : .red)
                    }
                }
                .padding(.horizontal, 6)
            }
            RibbonGroup(title: "Critérios") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Robô × robô: 100 mm, todos os pares").font(.system(size: 10))
                    HStack(spacing: 3) {
                        Text("Variação de tempo ±").font(.system(size: 10))
                        TextField("", value: $app.timingTolerance, format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 36).textFieldStyle(.roundedBorder).controlSize(.mini)
                        Text("s").font(.system(size: 10))
                    }
                    Text("Robô × carroceria: 50 mm").font(.system(size: 10))
                    Text("Velocidade e aceleração: não mudam").font(.system(size: 10))
                    Text("Pontos com pistola: só o sentido").font(.system(size: 10))
                }
                .foregroundStyle(Color(white: 0.3))
                .padding(.horizontal, 6)
            }
        }
    }
}

struct DXQOnlineTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            RibbonGroup(title: "Robô virtual") {
                RibbonLargeButton(title: "Conectar", icon: "cpu") { app.connectVirtual() }
            }
            RibbonGroup(title: "Gateway TCP") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Host", text: $app.tcpHost).frame(width: 120)
                        TextField("Porta", text: $app.tcpPort).frame(width: 50)
                    }
                    .textFieldStyle(.roundedBorder).font(DXQ.font)
                    RibbonSmallButton(title: "Conectar", icon: "network") { app.connectTCP() }
                }
            }
            RibbonGroup(title: "Conexão") {
                RibbonColumn {
                    RibbonSmallButton(title: "Desconectar", icon: "xmark.circle", enabled: app.connectionState != .disconnected) { app.disconnect() }
                    RibbonSmallButton(title: "Espelhar na vista 3D", icon: "arrow.left.arrow.right", checked: app.mirrorRobot) { app.mirrorRobot.toggle() }
                }
            }
            if let t = app.telemetry {
                RibbonGroup(title: "Dados online") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Status: \(t.status)")
                        Text("Aplicação: \(t.paintOn ? "LIGADA" : "desligada")").foregroundStyle(t.paintOn ? .orange : .secondary)
                        Text(t.joints.q.map { String(format: "%.1f", $0) }.joined(separator: "  ")).font(.system(size: 11, design: .monospaced))
                    }
                    .font(DXQ.font)
                }
            }
        }
    }
}

struct View3DPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        DockPanel(title: "Vista 3D") {
            VStack(spacing: 0) {
                DocumentTab(title: "Vista 3D")
                Viewport3D(controller: app.scene)
                    .overlay(alignment: .topLeading) { TCPOverlay().padding(8) }
                    .overlay(alignment: .bottomLeading) { AxisTriadOverlay(controller: app.scene).padding(6).allowsHitTesting(false) }
                    .overlay(alignment: .top) { SimulationStopBanner().padding(8) }
            }
        }
    }
}

#if os(macOS)
struct Viewport3D: NSViewRepresentable {
    let controller: SceneController

    func makeNSView(context: Context) -> SCNView {
        let v = PickingSCNView()
        // clique (sem arrastar) num ponto do caminho seleciona o comando no editor; ⌘/⇧ soma à seleção
        v.onDragEnd = { MainActor.assumeIsolated { controller.pushCameraHistory() } }
        v.onClick = { p, flags in
            MainActor.assumeIsolated { Self.click(controller, at: p, additive: flags.contains(.command) || flags.contains(.shift)) }
        }
        Self.configure(v, controller)
        return v
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}
}

/// SCNView que separa clique de arrasto (o arrasto continua girando a câmera).
final class PickingSCNView: SCNView {
    var onClick: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onDragEnd: (() -> Void)?
    private var downAt: CGPoint?

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if let d = downAt, hypot(p.x - d.x, p.y - d.y) < 4 {
            if event.clickCount == 1 { onClick?(p, event.modifierFlags) }
        } else if downAt != nil { onDragEnd?() }
        downAt = nil
    }
}
#else
/// Vista 3D no iPhone: um dedo gira, dois dedos movem/aproximam (controle de câmera do SceneKit);
/// toque num ponto do caminho seleciona o comando, toque longo soma à seleção.
struct Viewport3D: UIViewRepresentable {
    let controller: SceneController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        let c = context.coordinator
        v.addGestureRecognizer(UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:))))
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        long.delegate = c
        v.addGestureRecognizer(long)
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.delegate = c
        pan.cancelsTouchesInView = false
        v.addGestureRecognizer(pan)
        Self.configure(v, controller)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: SceneController
        init(_ controller: SceneController) { self.controller = controller }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            MainActor.assumeIsolated { Viewport3D.click(controller, at: g.location(in: v), additive: false) }
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let v = g.view else { return }
            MainActor.assumeIsolated { Viewport3D.click(controller, at: g.location(in: v), additive: true) }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            if g.state == .ended { MainActor.assumeIsolated { controller.pushCameraHistory() } }
        }

        // os gestos convivem com o controle de câmera do SCNView
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

extension Viewport3D {
    @MainActor static func configure(_ v: SCNView, _ controller: SceneController) {
        v.scene = controller.scene
        v.pointOfView = controller.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        controller.view = v
        DispatchQueue.main.async { controller.frameAll(); controller.saveHomeView() }
    }

    @MainActor static func click(_ controller: SceneController, at p: CGPoint, additive: Bool) {
        if let app = AppState.shared, app.measuring { app.measureClick(at: p); return }
        guard let hit = controller.pathPoint(at: p) else { return }
        AppState.shared?.selectPathPoint(entry: hit.entry, index: hit.index, additive: additive)
    }
}

/// Triedro X/Y/Z do mundo no canto da Vista 3D (HOOPS AxisTriad do DXQ), girando com a câmera.
struct AxisTriadOverlay: View {
    let controller: SceneController
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in AxisTriadCanvas(controller: controller) }
            .frame(width: 72, height: 72)
    }
}

struct AxisTriadCanvas: View {
    let controller: SceneController
    var body: some View {
        Canvas { ctx, size in
            guard let cam = controller.view?.pointOfView?.presentation else { return }
            let q = cam.simdWorldOrientation.inverse
            let w = controller.world.simdWorldOrientation
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let len = min(size.width, size.height) * 0.36
            let axes: [(String, SIMD3<Float>, Color)] = [("X", [1, 0, 0], .red), ("Y", [0, 1, 0], Color(red: 0, green: 0.75, blue: 0)), ("Z", [0, 0, 1], .blue)]
            // de trás para a frente, para o eixo que aponta para a tela ficar por cima
            let projected = axes.map { a -> (String, SIMD3<Float>, Color) in (a.0, q.act(w.act(a.1)), a.2) }.sorted { $0.1.z < $1.1.z }
            for (name, v, color) in projected {
                let end = CGPoint(x: c.x + CGFloat(v.x) * len, y: c.y - CGFloat(v.y) * len)
                var path = Path(); path.move(to: c); path.addLine(to: end)
                ctx.stroke(path, with: .color(color), lineWidth: 2.5)
                let lp = CGPoint(x: c.x + CGFloat(v.x) * (len + 9), y: c.y - CGFloat(v.y) * (len + 9))
                ctx.draw(Text(name).font(.system(size: 11, weight: .bold)).foregroundColor(color), at: lp)
            }
        }
        .frame(width: 72, height: 72)
    }
}

struct TCPOverlay: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let t = app.tcp
        VStack(alignment: .leading, spacing: 1) {
            if app.robots.isEmpty {
                Text("Nenhum robô carregado").bold()
            } else {
                Text(app.robot.name).bold()
                Text(String(format: "X %.1f  Y %.1f  Z %.1f", t.x, t.y, t.z))
                Text(String(format: "A %.2f  B %.2f  C %.2f", t.a, t.b, t.c))
                if app.robot.railEnabled { Text(String(format: "E1 %.1f mm", app.joints.rail)) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct JogPad: View {
    @EnvironmentObject var app: AppState
    @State private var step = 10.0
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                ForEach(Array(["X", "Y", "Z", "A", "B", "C"].enumerated()), id: \.offset) { i, n in
                    VStack(spacing: 1) {
                        jogButton("+\(n)") { app.jog(axis: i, by: i < 3 ? step : step / 10) }
                        jogButton("−\(n)") { app.jog(axis: i, by: i < 3 ? -step : -step / 10) }
                    }
                }
            }
            Picker("", selection: $step) { Text("1").tag(1.0); Text("10").tag(10.0); Text("50").tag(50.0); Text("100").tag(100.0) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170).controlSize(.small)
        }
    }

    private func jogButton(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 11)).frame(width: 26, height: 18)
                .background(Color.white).overlay(Rectangle().stroke(DXQ.border))
        }.buttonStyle(.plain)
    }
}

/// Menu "Arquivo" (backstage simplificado).
struct FileMenu: View {
    @EnvironmentObject var app: AppState
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("Abrir backup de robô…", "externaldrive.fill.badge.plus") {
                Dialogs.chooseFolders("Selecione a pasta do backup/flash do robô", multiple: true).forEach { app.openBackup($0) }
            }
            item("Abrir estação…", "folder") { openFile(["cellstation"]) { app.openStation($0) } }
            item("Salvar estação…", "square.and.arrow.down") { saveFile("estacao.cellstation") { app.saveStation(to: $0) } }
            item("Download (GitHub)…", "arrow.down.circle") { app.showDownloads = true }
            Divider()
            item("Importar carroceria…", "car.side") { openFile(["hsf", "stl"]) { app.importPart($0, asBody: true) } }
            item("Importar peça 3D…", "shippingbox") { openFile(["hsf", "stl", "obj", "usdz", "usd", "ply"]) { app.importPart($0) } }
            item("Importar programa KRL…", "square.and.arrow.down.on.square") { openFile(["src"]) { app.importProgram($0) } }
            item("Exportar programa KRL…", "square.and.arrow.up") { saveFile("\(app.program.name).src") { app.exportProgram(to: $0) } }
            #if os(macOS)
            Divider()
            item("Sair", "power") { NSApp.terminate(nil) }
            #endif
        }
        .padding(8)
        .frame(width: 260)
    }

    private func item(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button { close(); DispatchQueue.main.async(execute: a) } label: {
            Label(t, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BrushSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pincéis e simulação de espessura").font(.headline)
            ForEach($app.program.brushes) { $b in
                GroupBox(b.name) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        GridRow { Text("Vazão (ml/min)"); NumberField(label: "", value: $b.flowRate) }
                        GridRow { Text("Meio-ângulo do leque (°)"); NumberField(label: "", value: $b.coneHalfAngle) }
                        GridRow { Text("Perfil β"); NumberField(label: "", value: $b.beta) }
                        GridRow { Text("Eficiência de transferência"); NumberField(label: "", value: $b.transferEfficiency) }
                        GridRow { Text("Fração de sólidos"); NumberField(label: "", value: $b.solids) }
                    }
                }
            }
            GroupBox("Malha e cores") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("Resolução da malha (mm)"); NumberField(label: "", value: $app.refineEdge) }
                    GridRow { Text("Espessura alvo (µm)"); NumberField(label: "", value: $app.targetThickness) }
                }
                Text(app.paintStats).font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Spacer()
                Button("Aplicar malha") { app.rebuildSimulationMesh() }
                Button("Fechar") { app.refreshPaintColors(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .sheetFrame(width: 420)
    }
}

struct CatalogSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading) {
            Text("Tipo de robô do catálogo Dürr").font(.headline)
            Text("Usa medidas da tabela DurrRobotTypesFiles.xlsx. Para valores exatos, abra o backup do robô (machinedata1.cfg).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Buscar", text: $search).textFieldStyle(.roundedBorder)
            List(app.catalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { e in
                HStack { Text(e.name); Spacer(); Text(e.kind).foregroundStyle(.secondary) }
                    .contentShape(Rectangle())
                    .onTapGesture { app.selectCatalogRobot(e); dismiss() }
            }
            .frame(height: 360)
            HStack { Spacer(); Button("Cancelar") { dismiss() } }
        }
        .padding(16)
        .sheetFrame(width: 480)
    }
}

struct PartObjectSheet: View {
    @EnvironmentObject var app: AppState
    let url: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Importar carroceria").font(.title2)
            Text(url.lastPathComponent)
            Text("Escolha o sistema de coordenadas da peça na estação.")
            Picker("OBJECT", selection: $app.importObjectID) {
                ForEach(app.partObjects) { object in
                    Text(object.id == "station" ? object.name : object.id).tag(object.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar") { app.partImportRequest = nil }.keyboardShortcut(.cancelAction)
                Button("Importar") { app.confirmPartImport() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).sheetFrame(width: 520)
    }
}


/// Faixa vermelha quando a simulação para num erro (robô, programa:linha, mensagem).
struct SimulationStopBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let e = app.simulationStop {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e.robot) parou com erro" + (e.program.isEmpty ? "" : " em \(e.program):\(e.line)") + String(format: " (%.2f s)", e.time))
                        .font(.system(size: 12, weight: .bold))
                    Text(e.text).font(.system(size: 11)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if !e.program.isEmpty {
                    Button("Ver linha") { app.reveal(program: e.program, line: e.line, robot: e.robot); app.editorErrorLine = e.line }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button { app.simulationStop = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.78, green: 0.12, blue: 0.1).opacity(0.93)))
            .frame(maxWidth: 620)
        }
    }
}
