#if os(iOS)
import CellCore
import SceneKit
import SwiftUI

// CellStudio no iPhone: as mesmas abas do ribbon e os mesmos painéis do Mac, organizados em
// cinco telas (Estação, Vista 3D, Editor, Análise, Mensagens). O ribbon de cada tela rola na horizontal.

@main
struct CellStudioPhoneApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(app)
                .onChange(of: phase) { _, p in if p == .background { app.saveLastSession() } }
        }
    }
}

enum PhoneTab: Hashable { case station, view3D, editor, analysis, messages }

struct PhoneRootView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var repo = RepoSync.shared
    @State private var tab: PhoneTab = PhoneDiagnostics.initialTab
    @State private var showCatalog = false

    var body: some View {
        TabView(selection: $tab) {
            PhoneStationScreen(tab: $tab, showCatalog: $showCatalog)
                .tabItem { Label("Estação", systemImage: "building.2") }.tag(PhoneTab.station)
                .badge(repo.updateAvailable ? "1" : nil)
            Phone3DScreen(showCatalog: $showCatalog)
                .tabItem { Label("Vista 3D", systemImage: "cube") }.tag(PhoneTab.view3D)
            PhoneEditorScreen()
                .tabItem { Label("Editor", systemImage: "doc.text") }.tag(PhoneTab.editor)
                .badge(app.openProgramDirty ? "•" : nil)
            PhoneAnalysisScreen()
                .tabItem { Label("Análise", systemImage: "sparkles") }.tag(PhoneTab.analysis)
                .badge(app.analysis.map { a in a.suggestions.filter { $0.severity <= .risk }.count } ?? 0)
            PhoneMessagesScreen()
                .tabItem { Label("Mensagens", systemImage: "text.bubble") }.tag(PhoneTab.messages)
                .badge(app.messages.filter { $0.level == .error }.count)
        }
        .preferredColorScheme(.light)
        // "Ver sugestões", bits e Claude levam para a tela Análise; erro da simulação mostra a linha no Editor
        .onChange(of: app.bottomTab) { _, t in if t > 0 { tab = .analysis } }
        .onChange(of: app.editorErrorLine) { _, l in if l != nil { tab = .editor } }
        .sheet(item: $app.partImportRequest) { request in PartObjectSheet(url: request.url) }
        .sheet(isPresented: $app.showBrushSheet) { BrushSheet() }
        .sheet(isPresented: $showCatalog) { CatalogSheet() }
        .sheet(item: $app.commandEdit) { CommandEditorSheet(request: $0) }
        .sheet(item: $app.dataEdit) { DataEditorSheet(request: $0) }
        .sheet(isPresented: $app.showUsedCollisionBits) { UsedCollisionBitsSheet() }
        .sheet(isPresented: $app.showReindex) { ReindexSheet() }
        .sheet(item: $app.pointSheet) { PointToolSheetView(kind: $0) }
        .sheet(item: $app.dxqSheet) { DXQSheetView(sheet: $0) }
        .onAppear { PhoneDiagnostics.run(app) }
        .task { await repo.checkForUpdate(); announceUpdate(app) }
    }
}

/// Diagnóstico (Mac Catalyst): CellStudio --snapshot saida.png [--tab 3d|station|editor|analysis|messages]
/// [--backup pasta]… [--program nome] [--seek 0.5]. Janela do tamanho de um iPhone, captura e sai.
@MainActor
enum PhoneDiagnostics {
    static let args = CommandLine.arguments

    static var initialTab: PhoneTab {
        switch args.firstIndex(of: "--tab").flatMap({ $0 + 1 < args.count ? args[$0 + 1] : nil }) {
        case "station": .station
        case "editor": .editor
        case "analysis": .analysis
        case "messages": .messages
        default: .view3D
        }
    }

    static func run(_ app: AppState) {
        let snap = args.firstIndex(of: "--snapshot").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        // sem --snapshot, --backup/--program só carregam a estação (teste no Simulador) e o app continua aberto
        guard snap != nil || args.contains("--backup") else { return }
        if snap != nil, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let phone = CGSize(width: 393, height: 852)
            scene.sizeRestrictions?.minimumSize = phone
            scene.sizeRestrictions?.maximumSize = phone
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let k = args.firstIndex(of: "--models"), k + 1 < args.count { app.modelsRoot = URL(fileURLWithPath: args[k + 1]) }
            for (k, a) in args.enumerated() where a == "--backup" && k + 1 < args.count { app.openBackup(URL(fileURLWithPath: args[k + 1])) }
            if let k = args.firstIndex(of: "--program"), k + 1 < args.count, let slot = app.robots.first(where: { $0.backup != nil }) {
                let name = args[k + 1].lowercased()
                if let prog = slot.backup!.projects.flatMap(\.programs).first(where: { $0.name.lowercased() == name }) {
                    app.activate(slot.id)
                    app.selection = .program(slot.id, prog.url.path)
                    app.open(program: prog.url.path, robot: slot.id)
                    app.loadOpenProgramForSimulation()
                    let f = args.firstIndex(of: "--seek").flatMap { Double(args[$0 + 1]) } ?? 0.5
                    app.scrub(to: Int(Double(max(app.samples.count - 1, 0)) * f))
                }
            }
            app.scene.frameAll()
            if args.contains("--analyze") { app.simulateAndAnalyze() }
        }
        guard let out = snap else { return }
        func finish() {
            // espera os modelos 3D (carregados em segundo plano) antes da captura
            if app.loadingParts > 0 || app.isPlaying || app.analyzing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: finish); return }
            app.scene.frameAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { capture() }
        }
        func capture() {
            snapshot(to: out)
            let nodes = app.scene.world.childNodes.map { "\($0.name ?? "node") bounds=\($0.boundingBox) hidden=\($0.isHidden)" }
            let viewInfo = "VIEW \(String(describing: app.scene.view?.bounds)) pov=\(String(describing: app.scene.view?.pointOfView?.position)) robots=\(app.robots.map(\.name)) problems=\(app.modelProblems.values)"
            try? ([viewInfo] + nodes + app.messages.map { "[\($0.level.rawValue)] \($0.text)" }).joined(separator: "\n")
                .write(to: out.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: finish)
    }

    static func snapshot(to url: URL) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            // a área Metal do SceneKit não entra no desenho da hierarquia: desenha o snapshot dela por cima
            func scnViews(_ v: UIView) -> [SCNView] { (v as? SCNView).map { [$0] } ?? v.subviews.flatMap(scnViews) }
            for s in scnViews(window) { s.snapshot().draw(in: s.convert(s.bounds, to: window)) }
        }
        try? image.pngData()?.write(to: url)
    }
}

// MARK: - Peças comuns

/// Ribbon do DXQ numa faixa que rola na horizontal; pode ser recolhido para dar espaço à tela.
struct PhoneRibbon<Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if expanded {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) { content }
                    .fixedSize()
                    .padding(.trailing, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(DXQ.ribbonBG)
            .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
        }
    }
}

/// Seletor das abas de uma tela + botão para recolher o ribbon.
struct PhoneTabPicker: View {
    let titles: [String]
    @Binding var selection: Int
    @Binding var ribbon: Bool

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $selection) {
                ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button { withAnimation(.easeInOut(duration: 0.15)) { ribbon.toggle() } } label: {
                Image(systemName: ribbon ? "chevron.up.square" : "slider.horizontal.3").font(.system(size: 18))
            }
            .accessibilityLabel(ribbon ? "Recolher ferramentas" : "Mostrar ferramentas")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DXQ.windowBG)
    }
}

/// Iniciar/parar, linha do tempo e velocidade (barra fixa sob a Vista 3D).
struct PhonePlaybackBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let times = app.simulateAllRobots ? app.simulationTimeline : app.samples.map(\.time)
        HStack(spacing: 10) {
            Button { app.isPlaying ? app.stop() : app.play() } label: {
                Image(systemName: app.isPlaying ? "stop.fill" : "play.fill").font(.system(size: 20))
                    .foregroundStyle(app.isPlaying ? .red : Color(red: 0.1, green: 0.55, blue: 0.2))
                    .frame(width: 36, height: 36)
            }
            .disabled(times.isEmpty && app.openProgram == nil)
            if times.isEmpty {
                Button("Simular programa aberto") { app.loadOpenProgramForSimulation(); app.play() }
                    .disabled(app.openProgram == nil)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { Double(app.playIndex) }, set: { app.scrub(to: Int($0)) }),
                           in: 0...Double(max(times.count - 1, 1)))
                    Text(String(format: "%.2f / %.2f s", times[min(app.playIndex, times.count - 1)], times.last ?? 0))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Menu {
                Picker("Velocidade", selection: $app.playbackSpeed) {
                    Text("1×").tag(1.0); Text("2×").tag(2.0); Text("5×").tag(5.0); Text("10×").tag(10.0)
                }
                Toggle("Todos os robôs", isOn: Binding(get: { app.simulateAllRobots }, set: { app.simulateAllRobots = $0; app.computeTrajectory() }))
                Toggle("Parar no erro", isOn: $app.stopOnError)
                Button("Ao início") { app.scrub(to: 0) }
                Button("Todos para home") { app.homeAllRobots() }
            } label: {
                Text(String(format: "%g×", app.playbackSpeed)).font(.system(size: 13, weight: .semibold)).frame(minWidth: 36, minHeight: 36)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - Estação (explorador, características, arquivos)

struct PhoneStationScreen: View {
    @EnvironmentObject var app: AppState
    @Binding var tab: PhoneTab
    @Binding var showCatalog: Bool
    @State private var showProperties = false
    @State private var showDownloads = false
    @ObservedObject private var repo = RepoSync.shared

    var body: some View {
        NavigationStack {
            ProjectExplorer()
                .navigationTitle(app.stationName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { fileMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showDownloads = true } label: {
                            Label("Download", systemImage: repo.updateAvailable ? "arrow.down.circle.badge.exclamationmark" : "arrow.down.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showProperties = true } label: { Label("Características", systemImage: "list.bullet.rectangle") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { app.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(app.editUndo.isEmpty)
                        Button { app.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(app.editRedo.isEmpty)
                    }
                }
                .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
                .navigationDestination(isPresented: $showProperties) {
                    PropertiesPanel().navigationTitle("Características").navigationBarTitleDisplayMode(.inline)
                }
        }
        // abrir um programa no explorador leva ao editor
        .onChange(of: app.openProgram?.url) { old, new in if new != nil, new != old, tab == .station { tab = .editor } }
    }

    private var fileMenu: some View {
        Menu {
            Section {
                Button { app.newStation() } label: { Label("Nova estação…", systemImage: "plus.square") }
                Button { Dialogs.chooseFolders("Pasta do backup/flash do robô (contém config/machinedata1.cfg)", multiple: true).forEach { app.openBackup($0) } }
                    label: { Label("Abrir backup de robô…", systemImage: "externaldrive.fill.badge.plus") }
                Button { openFile(["cellstation"]) { app.openStation($0) } } label: { Label("Abrir estação…", systemImage: "folder") }
                Button { saveFile("estacao.cellstation") { app.saveStation(to: $0) } } label: { Label("Salvar estação…", systemImage: "square.and.arrow.down") }
                Button { showDownloads = true } label: { Label("Download (GitHub)…", systemImage: "arrow.down.circle") }
                Button { app.saveOpenProgram() } label: { Label("Salvar programa", systemImage: "doc.badge.arrow.up") }.disabled(!app.openProgramDirty)
            }
            Section {
                Button { openFile(["hsf", "stl"]) { app.importPart($0, asBody: true) } } label: { Label("Importar carroceria…", systemImage: "car.side") }
                Button { openFile(["hsf", "stl", "obj", "usdz", "usd", "ply"]) { app.importPart($0) } } label: { Label("Importar peça 3D…", systemImage: "shippingbox") }
                Button { openFile(["src"]) { app.importProgram($0) } } label: { Label("Importar programa KRL…", systemImage: "square.and.arrow.down.on.square") }
                Button { saveFile("\(app.program.name).src") { app.exportProgram(to: $0) } } label: { Label("Exportar programa KRL…", systemImage: "square.and.arrow.up") }
            }
            Section {
                Button { if let u = Dialogs.chooseFolders("Pasta 3DObjects do DXQ3D.onsite (contém Robots/, Tools/…)").first { app.modelsRoot = u } }
                    label: { Label("Pasta de modelos 3D…", systemImage: "cube.transparent") }
                Button { showCatalog = true } label: { Label("Tipo do catálogo…", systemImage: "list.bullet") }
            }
        } label: {
            Label("Arquivo", systemImage: "folder")
        }
    }
}

// MARK: - Vista 3D

struct Phone3DScreen: View {
    @EnvironmentObject var app: AppState
    @Binding var showCatalog: Bool
    @State private var page = 0
    @AppStorage("phoneRibbon3D") private var ribbon = true

    var body: some View {
        VStack(spacing: 0) {
            PhoneTabPicker(titles: ["Vista 3D", "Objetos 3D", "Simulação"], selection: $page, ribbon: $ribbon)
            PhoneRibbon(expanded: $ribbon) {
                switch page {
                case 1: DXQObjects3DTab()
                case 2: DXQSimulationTab()
                default: DXQView3DTab(showCatalog: $showCatalog)
                }
            }
            Viewport3D(controller: app.scene)
                .overlay(alignment: .topLeading) { TCPOverlay().padding(8).allowsHitTesting(false) }
                .overlay(alignment: .bottomLeading) { AxisTriadOverlay(controller: app.scene).padding(6).allowsHitTesting(false) }
                .overlay(alignment: .top) { SimulationStopBanner().padding(8) }
                .overlay(alignment: .topTrailing) {
                    Button { app.scene.frameAll() } label: {
                        Image(systemName: "viewfinder").font(.system(size: 18)).padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(8)
                    .accessibilityLabel("Enquadrar tudo")
                }
                .ignoresSafeArea(.keyboard)
            PhonePlaybackBar()
        }
    }
}

// MARK: - Editor de programa

struct PhoneEditorScreen: View {
    @EnvironmentObject var app: AppState
    @State private var page = 0
    @AppStorage("phoneRibbonEditor") private var ribbon = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 0) {
            PhoneTabPicker(titles: ["Editor de programa", "Ferramentas"], selection: $page, ribbon: $ribbon)
            PhoneRibbon(expanded: $ribbon) {
                if page == 0 { DXQProgramEditorTab() } else { DXQProgramToolsTab() }
            }
            HStack(spacing: 14) {
                // seleção de várias linhas (copiar, transformar pontos, comentar…) fica no modo Selecionar
                Button(editMode == .active ? "OK" : "Selecionar") { editMode = editMode == .active ? .inactive : .active }
                    .disabled(app.openProgram == nil)
                if editMode == .active {
                    Button { app.copyCommands() } label: { Image(systemName: "doc.on.doc") }.disabled(app.editorSelection.isEmpty)
                    Button { app.cutCommands() } label: { Image(systemName: "scissors") }.disabled(app.editorSelection.isEmpty)
                    Button { app.pasteCommands() } label: { Image(systemName: "doc.on.clipboard") }
                    Button(role: .destructive) { app.deleteCommands() } label: { Image(systemName: "trash") }.disabled(app.editorSelection.isEmpty)
                }
                Spacer()
                Button { app.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(app.editUndo.isEmpty)
                Button { app.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(app.editRedo.isEmpty)
                Button { app.saveOpenProgram() } label: { Image(systemName: "square.and.arrow.down") }.disabled(!app.openProgramDirty)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DXQ.windowBG)
            ProgramEditorPanel()
                .environment(\.editMode, $editMode)
        }
    }
}

// MARK: - Análise da estação, bits de colisão, Claude

struct PhoneAnalysisScreen: View {
    @EnvironmentObject var app: AppState
    @AppStorage("phoneRibbonAnalysis") private var ribbon = false

    private var page: Binding<Int> {
        Binding(get: { [2: 0, 1: 1, 3: 2][app.bottomTab] ?? 0 }, set: { app.bottomTab = [2, 1, 3][$0] })
    }

    var body: some View {
        VStack(spacing: 0) {
            PhoneTabPicker(titles: ["Análise", "Bits de colisão", "Claude"], selection: page, ribbon: $ribbon)
            PhoneRibbon(expanded: $ribbon) { DXQAnalysisTab() }
            Group {
                switch page.wrappedValue {
                case 1: CollisionBitsPanel()
                case 2: ClaudeChatPanel(chat: app.claude)
                default: StationAnalysisPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Mensagens e Online

struct PhoneMessagesScreen: View {
    @EnvironmentObject var app: AppState
    @State private var page = 0
    @State private var ribbon = true

    var body: some View {
        VStack(spacing: 0) {
            PhoneTabPicker(titles: ["Mensagens", "Online"], selection: $page, ribbon: $ribbon)
            if page == 0 {
                MessagesContent()
            } else {
                PhoneRibbon(expanded: $ribbon) { DXQOnlineTab() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Estado: \(String(describing: app.connectionState))").font(DXQ.font)
                        if let t = app.telemetry {
                            Text("Status: \(t.status)")
                            Text("Aplicação: \(t.paintOn ? "LIGADA" : "desligada")").foregroundStyle(t.paintOn ? .orange : .secondary)
                            Text(t.joints.q.map { String(format: "%.1f", $0) }.joined(separator: "  ")).font(.system(size: 12, design: .monospaced))
                        }
                        JogPad()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            StatusBar().phoneHorizontalScroll()
        }
    }
}
#endif
