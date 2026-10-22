#if os(macOS)
import AppKit
import CellCore
import SceneKit
import SwiftUI
import simd
import UniformTypeIdentifiers

@main
struct CellStudioApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("CellStudio – DXQ3D.onsite para macOS") {
            MainWindow()
                .environmentObject(app)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nova estação…") { app.newStation() }
                Button("Abrir backup de robô…") {
                    Dialogs.chooseFolders("Selecione a pasta do backup/flash do robô", multiple: true).forEach { app.openBackup($0) }
                }.keyboardShortcut("b")
                Button("Abrir estação…") { openFile(["cellstation"]) { app.openStation($0) } }.keyboardShortcut("o")
                Button("Salvar estação…") { saveFile("estacao.cellstation") { app.saveStation(to: $0) } }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Salvar programa") { app.saveOpenProgram() }.keyboardShortcut("s")
                Divider()
                Button("Importar peça 3D…") { openFile(["hsf", "stl", "obj", "usdz", "usd", "ply"]) { app.importPart($0) } }.keyboardShortcut("i")
                Button("Importar carroceria…") { openFile(["hsf", "stl"]) { app.importPart($0, asBody: true) } }
                Button("Importar programa KRL…") { openFile(["src"]) { app.importProgram($0) } }
                Button("Exportar programa KRL…") { saveFile("\(app.program.name).src") { app.exportProgram(to: $0) } }
            }
            CommandMenu("Simulação") {
                Button("Simular programa aberto") { app.loadOpenProgramForSimulation(); app.play() }.keyboardShortcut("r")
                Button(app.isPlaying ? "Parar" : "Iniciar") { app.isPlaying ? app.stop() : app.play() }.keyboardShortcut(.space, modifiers: [.command])
                Button("Simular espessura") { app.simulatePaint() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Limpar tinta") { app.resetPaint() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillTerminate(_ notification: Notification) {
        guard !AppState.isSnapshotLaunch else { return }
        MainActor.assumeIsolated {
            AppState.shared?.saveLastSession()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Diagnóstico: CellStudio --snapshot saida.png [--backup pasta]… [--program nome] [--multi] [--seek 0.5]
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let app = AppState.shared else { return }
                if let w = NSApp.windows.first(where: { $0.isVisible }) { w.setFrame(NSRect(x: 0, y: 0, width: 1600, height: 980), display: true) }
                if let k = args.firstIndex(of: "--station"), k + 1 < args.count { app.openStation(URL(fileURLWithPath: args[k + 1])) }
                for (k, a) in args.enumerated() where a == "--backup" && k + 1 < args.count { app.openBackup(URL(fileURLWithPath: args[k + 1])) }
                app.simulateAllRobots = args.contains("--multi")
                if let k = args.firstIndex(of: "--program"), k + 1 < args.count, let slot = app.robots.first(where: { $0.backup != nil }) {
                    app.activate(slot.id)
                    let name = args[k + 1].lowercased()
                    if let proj = slot.backup!.projects.first(where: { $0.programs.contains { $0.name.lowercased() == name } }),
                       let prog = proj.programs.first(where: { $0.name.lowercased() == name }) {
                        app.selection = .program(slot.id, prog.url.path)
                        app.open(program: prog.url.path, robot: slot.id)
                        app.loadOpenProgramForSimulation()
                        let f = args.firstIndex(of: "--seek").flatMap { Double(args[$0 + 1]) } ?? 0.5
                        let count = app.simulateAllRobots ? app.simulationTimeline.count : app.samples.count
                        app.scrub(to: Int(Double(max(count - 1, 0)) * f))
                    }
                }
                if let k = args.firstIndex(of: "--part"), k + 1 < args.count {
                    let name = args.firstIndex(of: "--object").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                    let object = app.partObjects.first { $0.id == name || ($0.name == name && $0.robotID == app.activeRobotID) } ?? .station
                    app.loadPart(URL(fileURLWithPath: args[k + 1]), object: object)
                }
                app.scene.frameAll()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    if args.contains("--home") { AppState.shared?.homeAllRobots() }
                    if args.contains("--all"), let a = AppState.shared, !a.simulateAllRobots { a.simulateAllRobots = true; a.computeTrajectory() }
                    if args.contains("--station"), let a = AppState.shared, let f = args.firstIndex(of: "--seek").flatMap({ Double(args[$0 + 1]) }) {
                        a.scrub(toTime: (a.simulateAllRobots ? a.simulationTimeline.last : a.samples.last?.time).map { $0 * f } ?? 0)
                    }
                    if args.contains("--reveal"), let a = AppState.shared, let w = a.stationWaits.max(by: { $0.end - $0.start < $1.end - $1.start }) {
                        a.scrub(toTime: w.start); a.reveal(program: w.program, line: w.line, robot: w.robot)   // = clique na maior espera
                    }
                    if args.contains("--data") { AppState.shared?.editorTab = 1 }
                    for (k, x) in args.enumerated() where x == "--hide" && k + 1 < args.count {
                        if let a = AppState.shared, let r = a.robots.first(where: { $0.name == args[k + 1] }) { a.setRobotIn3D(r.id, false) }
                    }
                    if let k = args.firstIndex(of: "--type"), k + 1 < args.count, let a = AppState.shared {
                        let v = args[k + 1]
                        a.applyType(a.typeListOptions.first { $0.section == v || String($0.number) == v }?.section)
                    }
                    // --open R11:Cuv_Track/Assoalho (pode repetir): abre módulos em abas
                    for (k, a) in args.enumerated() where a == "--open" && k + 1 < args.count {
                        let spec = args[k + 1]
                        guard let app = AppState.shared, let colon = spec.firstIndex(of: ":"), let slash = spec.firstIndex(of: "/") else { continue }
                        let robot = String(spec[..<colon]), proj = String(spec[spec.index(after: colon)..<slash]), prog = String(spec[spec.index(after: slash)...])
                        if let slot = app.robots.first(where: { $0.name == robot }),
                           let p = slot.backup?.projects.first(where: { $0.name == proj })?.programs.first(where: { $0.name.caseInsensitiveCompare(prog) == .orderedSame }) {
                            app.open(program: p.url.path, robot: slot.id)
                        }
                    }
                    if args.contains("--bits") { AppState.shared?.bottomTab = 1 }
                    if args.contains("--analyze"), let a = AppState.shared {
                        if let k = args.firstIndex(of: "--proj"), k + 1 < args.count { a.analysisProgramKey = "proj:" + args[k + 1] }
                        a.simulateAndAnalyze()
                        if let k = args.firstIndex(of: "--focus"), k + 1 < args.count, let n = Int(args[k + 1]) {
                            func waitAndFocus() {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    MainActor.assumeIsolated {
                                        if a.analyzing { waitAndFocus(); return }
                                        let list = a.analysis?.suggestions ?? []
                                        if list.indices.contains(n) { a.focus(list[n]) }
                                        if let g = args.firstIndex(of: "--goto"), g + 1 < args.count, list.indices.contains(n),
                                           let rp = list[n].riskPoints.first(where: { $0.robot == args[g + 1] }) { a.goToRiskPoint(list[n], rp) }
                                        if args.contains("--delayed"), list.indices.contains(n) { a.showDelayedCollision(list[n]) }

                                        if args.contains("--apply"), list.indices.contains(n) { a.apply(list[n]) }
                                    }
                                }
                            }
                            waitAndFocus()
                        }
                    }
                    if args.contains("--play"), let a = AppState.shared { a.playbackSpeed = 25; a.stopOnError = !args.contains("--no-stop"); a.play() }
                    if args.contains("--editor-selftest"), let a = AppState.shared { Self.editorSelfTest(a) }
                    if args.contains("--points-selftest"), let a = AppState.shared { Self.pointsSelfTest(a) }
                    if args.contains("--pick-selftest"), let a = AppState.shared {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { Self.pickSelfTest(a) } }
                    }
                    if let k = args.firstIndex(of: "--insert"), k + 1 < args.count, let a = AppState.shared {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { a.insertCommand(args[k + 1]) } }
                    }
                    if let k = args.firstIndex(of: "--edit-line"), k + 1 < args.count, let a = AppState.shared, let n = Int(args[k + 1]) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { a.editorSelection = [n - 1]; a.editSelectedCommand() } }
                    }
                    AppState.shared?.scene.frameAll()
                }
            }
            // --serve N: fica aberto N segundos (teste do servidor MCP) em vez de tirar o snapshot
            if let k = args.firstIndex(of: "--serve"), k + 1 < args.count, let secs = Double(args[k + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    Self.finishSnapshot(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Diagnóstico do editor de programa (só em memória; nada é salvo).
    @MainActor
    static func editorSelfTest(_ a: AppState) {
        func dump(_ tag: String) {
            let l = a.editorLines.map { "\($0.lineNumber): \($0.text)" }.suffix(14).joined(separator: " | ")
            a.info("SELFTEST \(tag): \(l)")
        }
        let original = a.openProgram
        a.editorSelection = [11]
        a.applyCommand(CommandEditRequest(name: "GUN", line: nil, after: 11), text: "GUN(GUN1, GunOn, P4, TRG1)",
                       newDeclarations: [("P4", "POINT", a.currentPointArgs(mode: "Object", line: 12)), ("TRG1", "TRIGGERFRAME", a.defaultArgs(type: "TRIGGERFRAME"))])
        dump("inserido")
        a.info("SELFTEST dados: " + (a.openProgram?.declarations.suffix(2).map { "\($0.name):\($0.type)=\($0.args.joined(separator: ","))" }.joined(separator: " ; ") ?? ""))
        a.commentOutCommands(); dump("comentado")
        a.commentInCommands(); a.setCommandsDisabled(true); dump("desativado")
        a.setCommandsDisabled(false)
        a.modifyPoints()
        a.applyCommand(CommandEditRequest(name: "IF", line: nil, after: 12), text: "IF GET_MOTION_STATE(InBellCleaner, True) THEN", newDeclarations: [])
        dump("IF")
        a.copyCommands(); a.pasteCommands(); dump("colado")
        while !a.editUndo.isEmpty { a.undoEdit() }
        a.info("SELFTEST desfeito tudo: \(a.openProgram?.source == original?.source && a.openProgram?.data == original?.data ? "igual ao original" : "DIFERENTE")")
    }

    /// Guia Transformação num programa real: desloca, gira, converte, restaura e desfaz.
    @MainActor static func pointsSelfTest(_ a: AppState) {
        let original = a.openProgram
        let withPoints = a.editorLines.filter { l in
            a.editorSelection = [l.index]; return !a.selectedPointTargets.isEmpty
        }.prefix(4)
        a.editorSelection = Set(withPoints.map(\.index))
        let before = a.selectedPointPositions()
        func delta() -> [Vec3] { zip(before, a.selectedPointPositions()).map { $1.world - $0.world } }
        func fmt(_ v: [Vec3]) -> String { v.map { String(format: "(%.2f, %.2f, %.2f)", $0.x, $0.y, $0.z) }.joined(separator: " ") }
        a.info("SELFTEST PONTOS: " + a.selectedPointTargets.map { "\($0.decl.name)=\($0.decl.args.first ?? "")" }.joined(separator: ", "))
        a.pointSystem = .world; a.pointStepMm = 10
        a.jogSelectedPoints(index: 0, sign: 1)
        a.info("SELFTEST +X Mundo 10 mm → Δ " + fmt(delta()))
        a.resetPointCoordinates()
        a.info("SELFTEST restaurar → Δ " + fmt(delta()))
        a.pointSystem = .tool
        a.jogSelectedPoints(index: 2, sign: 1)
        a.info("SELFTEST +Z Ferramenta 10 mm → |Δ| " + delta().map { String(format: "%.2f", simd_length($0)) }.joined(separator: " "))
        a.resetPointCoordinates()
        a.pointSystem = .world; a.pointStepDeg = 5
        a.jogSelectedPoints(index: 5, sign: 1)
        a.info("SELFTEST +C Mundo 5° → Δ posição " + fmt(delta()))
        a.resetPointCoordinates()
        a.convertSelectedPoints(to: "World")
        a.info("SELFTEST converter World → " + a.selectedPointTargets.map { $0.decl.args.first ?? "" }.joined(separator: ",") + " Δ " + fmt(delta()))
        a.resetPointCoordinates()
        a.mirrorSelectedPoints(plane: .xz, offset: 0)
        a.mirrorSelectedPoints(plane: .xz, offset: 0)
        a.info("SELFTEST espelhar 2× → Δ " + fmt(delta()))
        while !a.editUndo.isEmpty { a.undoEdit() }
        a.info("SELFTEST PONTOS desfeito tudo: \(a.openProgram?.data == original?.data ? "igual ao original" : "DIFERENTE")")
    }

    /// Clique nos pontos do caminho: projeta o ponto na tela, "clica" ali e confere a linha selecionada no editor.
    @MainActor static func pickSelfTest(_ a: AppState) {
        let n = a.scene.pathPointCount
        var out: [String] = []
        for (k, i) in [n / 5, n / 2, n - 1].enumerated() where i >= 0 {
            guard let p = a.scene.screenPoint(entry: 0, index: i) else { continue }
            guard let hit = a.scene.pathPoint(at: CGPoint(x: p.x, y: p.y)) else { out.append("ponto \(i): nada"); continue }
            a.selectPathPoint(entry: hit.entry, index: hit.index, additive: k > 0)
            let o = a.origin.indices.contains(i) ? "\(a.origin[i].program):\(a.origin[i].line)" : "?"
            let sel = a.editorLines.filter { a.editorSelection.contains($0.index) }.map(\.lineNumber)
            out.append("ponto \(i) (\(o)) → acertou \(hit.index), linhas selecionadas \(sel), destacados \(a.scene.selectedPathPoints.count)")
        }
        a.info("SELFTEST CLIQUE: " + out.joined(separator: " | "))
    }

    @MainActor
    static func finishSnapshot(to url: URL) {
        guard let app = AppState.shared else { return }
        if app.isPlaying || app.analyzing || (app.analysis != nil && app.stationEffects.count < (app.analysis?.suggestions.filter(\.applicable).count ?? 0) && CommandLine.arguments.contains("--effects")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finishSnapshot(to: url) }
            return
        }
        if app.loadingParts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finishSnapshot(to: url) }
            return
        }
        app.scene.frameAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            snapshot(to: url)
            let sugg = (app.analysis?.suggestions ?? []).enumerated().map { i, x in
                "SUG \(i) [\(x.severity)] \(x.robot) | \(x.title) | ganho \(x.gain.map { String(format: "%.2f", $0) } ?? "-") | \(x.program):\(x.line) | aplicável \(x.applicable)"
                + (app.stationEffects[x.id].map { e in String(format: " | ESTAÇÃO %.1f→%.1f (%@) colisões %d→%d erros+%d", e.stationBefore, e.stationAfter,
                    e.after.keys.sorted().map { String(format: "%@ %.1f→%.1f", $0, e.before[$0] ?? 0, e.after[$0] ?? 0) }.joined(separator: ", "), e.collisionsBefore, e.collisionsAfter, e.newErrors) } ?? "") }.joined(separator: "\n")
            let report0 = sugg + "\n" + (app.analysis.map { a in a.breakdowns.map { String(format: "CICLO %@ %.1f s", $0.robot, $0.total) }.joined(separator: "\n") } ?? "")
            let dur = String(format: "DURACAO amostras %.2f s | timeline %.2f s | programa %@ | ações %d (delay %d)", app.samples.last?.time ?? 0, app.simulationTimeline.last ?? 0,
                             app.program.name, app.programActionsList.count, app.programActionsList.filter { $0.kind == .delay }.count)
            let runsInfo = app.simulationRuns.map { run -> String in
                let name = app.robots.first { $0.id == run.robotID }?.name ?? "?"
                let first = run.samples.first { s in zip(s.state.q, run.start.q).contains { abs($0 - $1) > 1e-3 } || abs(s.state.rail - run.start.rail) > 1e-3 }?.time ?? -1
                return String(format: "RUN %@ começa a mover em %.2f s, fim %.2f s, delays %d", name, first, run.samples.last?.time ?? 0, run.actions.filter { $0.kind == .delay }.count)
            }.joined(separator: "\n")
            let state = "ROBOS " + app.robots.map { "\($0.name)\($0.hidden3D ? "(fora do 3D)" : "")" }.joined(separator: " ") + "\nESTADO ativo=\(app.activeRobotID.flatMap { id in app.robots.first { $0.id == id }?.name } ?? "nenhum") | programa=\(app.program.name) pontos=\(app.program.points.count) | abas=\(app.openTabs.map { $0.program.name }) | aberto=\(app.openProgram?.name ?? "-") linha=\(app.highlightedLine.map(String.init) ?? "-") sel=\(app.editorSelection.sorted()) | tipo=\(app.selectedTypeKey ?? "-")\n"
                + app.robots.map { r in "SELECAO \(r.name): \(app.simulationProgramURL(for: r.id).map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent } ?? "-")" }.joined(separator: "\n")
            let linkName = ["pé/carro", "A1→A2", "braço", "antebraço", "punho A4→A5", "punho A5→A6", "pistola"]
            let conf = (app.analysis?.conflicts ?? []).map { c in
                String(format: "CONFLITO %@×%@ %.0f mm simult=%@ | %@ em %.1f s (%@) × %@ em %.1f s (%@) | local (%.0f, %.0f, %.0f)", c.robotA, c.robotB, c.minDistance,
                       c.simultaneous ? "sim" : "não", c.robotA, c.closestATime, linkName[min(c.closestLinks.a, 6)], c.robotB, c.closestBTime, linkName[min(c.closestLinks.b, 6)],
                       c.location.x, c.location.y, c.location.z) }.joined(separator: "\n")
            let zonesTxt = app.stationZones.sorted { ($0.owner, $0.start) < ($1.owner, $1.start) }
                .map { String(format: "ZONA %@ %@ %.1f–%.1f", $0.owner, $0.pin, $0.start, $0.end) }.joined(separator: "\n")
            let confDet = (app.analysis?.conflicts ?? []).map { c in
                String(format: "REGIAO %@×%@ %.0f mm | A %.1f–%.1f | B %.1f–%.1f | protegido=%@ parcial=%@", c.robotA, c.robotB, c.minDistance,
                       c.aTime.lowerBound, c.aTime.upperBound, c.bTime.lowerBound, c.bTime.upperBound, c.protectedBy ?? "-", c.partiallyProtectedBy ?? "-") }.joined(separator: "\n")
            let report = state + "\n" + conf + "\n" + confDet + "\n" + zonesTxt + "\n" + dur + "\n" + runsInfo + "\n" + report0 + "\n" + app.messages.map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n") + (app.simulationStop.map { "\nFAIXA: \($0.robot) parou com erro em \($0.program):\($0.line) – \($0.text)" } ?? "\nFAIXA: nenhuma")
            let bounds = app.scene.world.childNodes.map { node in
                "\(node.name ?? "node") bounds=\(node.boundingBox) position=\(node.position)"
            }.joined(separator: "\n")
            try? (report + "\n" + bounds).write(to: url.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    @MainActor static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write("SNAPSHOT: sem janela/visão (janelas: \(NSApp.windows.map { "\($0.className) visível=\($0.isVisible) \($0.frame)" }))\n".data(using: .utf8)!)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        // a área Metal do SceneKit não entra no cache; desenha o snapshot dela por cima
        func scnViews(_ v: NSView) -> [SCNView] { (v as? SCNView).map { [$0] } ?? v.subviews.flatMap(scnViews) }
        image.lockFocus()
        for s in scnViews(view) {
            var r = s.convert(s.bounds, to: view)
            if view.isFlipped { r.origin.y = view.bounds.height - r.maxY }
            s.snapshot().draw(in: r)
            // o triedro (sobreposto em SwiftUI) também some sob o Metal: redesenha no canto inferior esquerdo
            if let ctl = AppState.shared?.scene, ctl.view === s {
                let renderer = ImageRenderer(content: AxisTriadCanvas(controller: ctl))
                renderer.scale = 1
                renderer.nsImage?.draw(in: NSRect(x: r.minX + 6, y: r.minY + 6, width: 72, height: 72))
            }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        // diálogo aberto (sheet) vai para <arquivo>-sheet.png
        if let sheet = window.attachedSheet, let sv = sheet.contentView, let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: srep)
            try? srep.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("sheet.png"))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
