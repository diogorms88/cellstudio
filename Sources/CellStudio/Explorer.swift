import CellCore
import SwiftUI

/// Nó da árvore do explorador de projeto (Estação ▸ Robôs ▸ Programas de teach ▸ projeto ▸ programa).
struct TreeNode: Identifiable {
    let id: String
    var title: String
    var icon: String
    var tint: Color
    var selection: Selection?
    var children: [TreeNode]?
    var badge: String? = nil
}

struct ProjectExplorer: View {
    @EnvironmentObject var app: AppState
    @State private var expanded: Set<String> = ["station", "robots", "parts"]
    @State private var filter = ""

    var body: some View {
        DockPanel(title: "Explorador de projeto") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { app.objectWillChange.send() } label: { DXQSymbol(symbol: "arrow.clockwise") }
                        .help("Atualizar")
                    Button { expandAll() } label: { DXQSymbol(symbol: "rectangle.expand.vertical") }
                        .help("Expandir tudo")
                    Button { expanded = ["station", "robots"] } label: { DXQSymbol(symbol: "rectangle.compress.vertical") }
                        .help("Recolher")
                    TextField("Filtrar", text: $filter).textFieldStyle(.roundedBorder).font(DXQ.font)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DXQ.blueText)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                Rectangle().fill(DXQ.border).frame(height: 1)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered(tree)) { row($0, depth: 0) }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var tree: [TreeNode] {
        var robotNodes: [TreeNode] = []
        for r in app.robots {
            var kids: [TreeNode] = []
            if let bk = r.backup {
                let projects = bk.projects.map { p in
                    TreeNode(id: p.url.path, title: p.name, icon: "car.side.fill", tint: Color(white: 0.35),
                             selection: .project(r.id, p.url.path),
                             children: p.programs.map { g in
                                 TreeNode(id: g.url.path, title: g.name, icon: "doc.text", tint: Color(white: 0.5),
                                          selection: .program(r.id, g.url.path), children: nil)
                             })
                }
                kids.append(TreeNode(id: "teach-\(r.id)", title: "Programas de teach", icon: "folder.fill",
                                     tint: Color(red: 0.95, green: 0.75, blue: 0.3), selection: .robot(r.id), children: projects))
            }
            robotNodes.append(TreeNode(id: "robot-\(r.id)", title: r.name, icon: "gearshape.2.fill",
                                       tint: r.hidden3D ? Color(white: 0.6) : Color(red: 0.85, green: 0.55, blue: 0.15), selection: .robot(r.id),
                                       children: kids.isEmpty ? nil : kids,
                                       badge: r.hidden3D ? "fora do 3D" : (app.modelProblems[r.id] != nil ? "sem modelo 3D" : (r.id == app.activeRobotID ? "ativo" : nil))))
        }
        let parts = app.parts.map { p in
            TreeNode(id: "part-\(p.id)", title: p.name, icon: p.isPaintTarget ? "paintbrush.fill" : "cube", tint: p.isPaintTarget ? .orange : Color(white: 0.4),
                     selection: .part(p.id), children: nil)
        }
        return [TreeNode(id: "station", title: app.stationName, icon: "building.2.fill", tint: Color(red: 0.25, green: 0.45, blue: 0.7),
                         selection: .station,
                         children: [TreeNode(id: "robots", title: "Robôs", icon: "square.stack.3d.up.fill", tint: Color(white: 0.4), selection: .station, children: robotNodes),
                                    TreeNode(id: "parts", title: "Objetos 3D", icon: "cube.transparent", tint: Color(white: 0.4), selection: .station, children: parts)])]
    }

    private func filtered(_ nodes: [TreeNode]) -> [TreeNode] {
        guard !filter.isEmpty else { return nodes }
        return nodes.compactMap { n in
            let kids = n.children.map(filtered)
            if n.title.localizedCaseInsensitiveContains(filter) || !(kids?.isEmpty ?? true) {
                var c = n; c.children = kids; return c
            }
            return nil
        }
    }

    private func expandAll() {
        func walk(_ n: [TreeNode]) { for x in n { if x.children != nil { expanded.insert(x.id); walk(x.children!) } } }
        walk(tree)
    }

    private func row(_ n: TreeNode, depth: Int) -> AnyView {
        let isOpen = expanded.contains(n.id) || !filter.isEmpty
        let isSelected = n.selection != nil && n.selection == app.selection && !(n.id == "robots" || n.id == "parts" || n.id.hasPrefix("teach-"))
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Group {
                    if n.children != nil {
                        Image(systemName: isOpen ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                            .font(.system(size: Platform.isPhone ? 10 : 7))
                            .foregroundStyle(Color(white: 0.35))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(n.id) }
                    } else { Color.clear }
                }
                .frame(width: Platform.isPhone ? 26 : 12)
                DXQSymbol(symbol: n.icon, tint: n.tint).frame(width: 16)
                Text(n.title).font(DXQ.font).foregroundStyle(Color(white: 0.1)).lineLimit(1)
                if let b = n.badge {
                    Text(b).font(.system(size: 9)).padding(.horizontal, 4).background(DXQ.selection, in: Capsule())
                }
            }
            .padding(.leading, CGFloat(depth) * 16 + 4)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: DXQ.rowHeight, maxHeight: DXQ.rowHeight, alignment: .leading)
            .background(isSelected ? DXQ.selection : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(n) }
            .onTapGesture { select(n) }
            .contextMenu { contextMenu(n) }
            if isOpen, let kids = n.children {
                ForEach(kids) { row($0, depth: depth + 1) }
            }
        })
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func select(_ n: TreeNode) {
        if n.children != nil && n.selection == .station { toggle(n.id); return }
        app.selection = n.selection
        switch n.selection {
        case .robot(let id): if app.robots.first(where: { $0.id == id })?.hidden3D != true { app.activate(id) }
        case .program(let rid, let path): app.open(program: path, robot: rid)
        case .project(let rid, _): app.activate(rid); toggle(n.id)
        default: break
        }
    }

    private func open(_ n: TreeNode) {
        if case .program(let rid, let path) = n.selection {
            app.open(program: path, robot: rid)
            app.loadOpenProgramForSimulation()
        } else { toggle(n.id) }
    }

    private func item(_ title: String, _ icon: String?, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let icon, let img = DXQIcons.image(icon, size: 16) { Label { Text(title) } icon: { Image(platformImage: img) } } else { Text(title) }
        }
        .disabled(!enabled)
    }

    /// Menus do DXQ (DirObjects): pasta "Programas de teach", projeto de teach e programa.
    @ViewBuilder private func contextMenu(_ n: TreeNode) -> some View {
        if n.id.hasPrefix("teach-"), case .robot(let rid) = n.selection {
            teachFolderMenu(rid)
        } else {
            nodeMenu(n)
        }
    }

    @ViewBuilder private func teachFolderMenu(_ rid: UUID) -> some View {
        item("Importar vários projetos de teach do RobCAD", nil, enabled: false) {}
        item("Excluir programas de teach não usados…", "general_cleanup") { app.dxqSheet = .unusedPrograms(robot: rid) }
        item("Adicionar projeto de teach", "addteachproject") { app.addTeachProject(robot: rid) }
        if let dir = app.teachDir(rid) {
            item("Colar", "general_paste", enabled: app.explorerClipboard?.url.pathExtension.lowercased() == "tt") { app.explorerPaste(into: dir, robot: rid) }
        }
        item("Exportar projetos de teach", "general_export") { app.exportTeachProjects(robot: rid) }
        item("Importar projetos de teach", "general_import") { app.importTeachProjects(robot: rid) }
    }

    @ViewBuilder private func projectMenu(_ rid: UUID, _ url: URL) -> some View {
        item("Abrir todos os programas", "programeditor_loadallmodule") { app.openAllPrograms(project: url, robot: rid) }
        item("Fechar todos os programas abertos", "programeditor_closeallmodule") { app.closeAllPrograms(project: url) }
        item("Verificar programa(s)", "general_validate") { app.checkPrograms(project: url, robot: rid) }
        Menu("Utilitários") {
            item(Platform.revealTitle, nil) { Platform.reveal(url) }
            item("Recarregar do disco", "general_refresh") { app.refreshBackup(rid) }
        }
        item("Exportar para RobCAD", nil, enabled: false) {}
        item("Importar do RobCAD", nil, enabled: false) {}
        item("Iniciar EcoPaintJet Generator", nil, enabled: false) {}
        item("Distribuir programas", nil, enabled: false) {}
        item("Comparador", "general_compare", enabled: !(app.project(url, robot: rid)?.programs.isEmpty ?? true)) {
            if let g = app.project(url, robot: rid)?.programs.first { app.dxqSheet = .compare(url: g.url, robot: rid) }
        }
        item("Excluir programas de teach não usados…", "general_cleanup") { app.dxqSheet = .unusedPrograms(robot: rid) }
        item("Editor de pincéis", "brusheditor") { app.showBrushSheet = true }
        Divider()
        item("Renomear", "general_rename") { app.promptRename(url, robot: rid) }
        item("Substituir texto no nome", "general_rename") { app.dxqSheet = .replaceText(project: url, robot: rid) }
        item("Excluir", "dirobjects_deleteteachproject") { app.deleteItem(url, robot: rid) }
        Divider()
        item("Adicionar programa de teach", "addteachprogram") { app.addTeachProgram(project: url, robot: rid) }
        item("Importar programa de teach", "general_import") { app.importTeachPrograms(project: url, robot: rid) }
        item("Exportar projeto de teach", "general_export") { app.exportTeachProjects(robot: rid, only: url) }
        Divider()
        item("Recortar", "general_cut") { app.explorerCopy(url, robot: rid, cut: true) }
        item("Copiar", "general_copy") { app.explorerCopy(url, robot: rid, cut: false) }
        item("Colar", "general_paste", enabled: app.explorerClipboard.map { $0.url.pathExtension.lowercased() == "tip" } ?? false) { app.explorerPaste(into: url, robot: rid) }
    }

    @ViewBuilder private func nodeMenu(_ n: TreeNode) -> some View {
        switch n.selection {
        case .project(let rid, let path):
            projectMenu(rid, URL(fileURLWithPath: path))
        case .program(let rid, let path):
            let url = URL(fileURLWithPath: path)
            item("Abrir", "programeditorcommon_teachprogramopen") { app.open(program: path, robot: rid) }
            item("Simular", "programeditorcommon_simulatemodule") { app.open(program: path, robot: rid); app.loadOpenProgramForSimulation(); app.play() }
            item("Verificar programa", "general_validate") {
                if let proj = app.slot(rid)?.backup?.projects.first(where: { $0.programs.contains { $0.url == url } }),
                   let g = proj.programs.first(where: { $0.url == url }), let s = app.slot(rid) { app.checkPrograms([g], project: proj, robot: s) }
            }
            item("Comparador", "general_compare") { app.dxqSheet = .compare(url: url, robot: rid) }
            Divider()
            item("Renomear", "general_rename") { app.promptRename(url, robot: rid) }
            item("Excluir", "dirobjects_deleteteachprogram") { app.deleteItem(url, robot: rid) }
            item("Exportar programa de teach", "general_export") {
                if let dest = Dialogs.chooseFolders("Pasta de destino do programa", prompt: "Exportar").first {
                    for f in [url, url.deletingPathExtension().appendingPathExtension("tid")] where FileManager.default.fileExists(atPath: f.path) {
                        try? FileManager.default.copyItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
                    }
                    app.info("\(url.deletingPathExtension().lastPathComponent) exportado para \(dest.path)")
                }
            }
            Divider()
            item("Recortar", "general_cut") { app.explorerCopy(url, robot: rid, cut: true) }
            item("Copiar", "general_copy") { app.explorerCopy(url, robot: rid, cut: false) }
            Button(Platform.revealTitle) { Platform.reveal(url) }
        case .part(let id):
            Button("Usar como alvo de pintura") { app.setPaintTarget(id) }
            Button("Remover", role: .destructive) { app.removePart(id) }
        case .robot(let id):
            let slot = app.robots.first { $0.id == id }
            if slot?.hidden3D == true {
                Button("Mostrar na Vista 3D") { app.setRobotIn3D(id, true) }
            } else {
                Button("Tornar robô ativo") { app.activate(id) }
                Button("Remover da Vista 3D") { app.setRobotIn3D(id, false) }
            }
            Divider()
            if let bk = slot?.backup {
                Button("Recarregar backup") { app.openBackup(bk.root) }
                Button(Platform.isMac ? "Mostrar backup no Finder" : "Compartilhar backup…") { Platform.reveal(bk.root) }
            }
            Divider()
            Button("Excluir da estação…", role: .destructive) { app.deleteRobot(id) }
        case .station:
            Button("Adicionar robô (backup do flash)…") { app.addRobotsFromBackup() }
            Divider()
            Button("Remover todos os robôs da Vista 3D") { app.setAllRobotsIn3D(false) }.disabled(app.robotsIn3D.isEmpty)
            Button("Mostrar todos os robôs na Vista 3D") { app.setAllRobotsIn3D(true) }.disabled(!app.robots.contains(where: \.hidden3D))
            Divider()
            Button("Renomear estação…") { app.renameStation() }
            Button("Nova estação…") { app.newStation() }
        default:
            EmptyView()
        }
    }
}

// MARK: - Características (property grid)

struct PropertyRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(spacing: 0) {
            Text(key).font(DXQ.font).foregroundStyle(Color(white: 0.15))
                .frame(width: 130, alignment: .leading).padding(.leading, 22)
            Rectangle().fill(DXQ.border).frame(width: 1)
            Text(value).font(DXQ.font).foregroundStyle(Color(white: 0.15)).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 21)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.93)).frame(height: 1) }
    }
}

struct PropertyCategory<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill").font(.system(size: 7))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.leading, 6)
            .frame(height: 22)
            .background(DXQ.categoryBG)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open { content }
        }
    }
}

struct PropertiesPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        DockPanel(title: "Características") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch app.selection {
                    case .robot(let id): if let r = app.robots.first(where: { $0.id == id }) { robotProps(r) }
                    case .program(let rid, let path): programProps(rid, path)
                    case .project(let rid, let path): if let p = app.project(robot: rid, path: path) { projectProps(p) }
                    case .part(let id): if let part = app.parts.first(where: { $0.id == id }) { partProps(part) }
                    default: stationProps
                    }
                }
            }
        }
    }

    private var stationProps: some View {
        Group {
            PropertyCategory(title: "1 - Estação") {
                PropertyRow(key: "Nome", value: app.stationName)
                PropertyRow(key: "Robôs", value: app.robots.isEmpty ? "Nenhum" : app.robots.map(\.name).joined(separator: ", "))
                PropertyRow(key: "Objetos 3D", value: "\(app.parts.count)")
            }
            PropertyCategory(title: "2 - Robô ativo") {
                if app.robots.isEmpty {
                    PropertyRow(key: "Nome", value: "Nenhum robô carregado")
                } else {
                    PropertyRow(key: "Nome", value: app.robot.name)
                    jointSliders
                }
            }
        }
    }

    private func robotProps(_ r: RobotSlot) -> some View {
        let m = r.model
        return Group {
            PropertyCategory(title: "1 - Robô") {
                PropertyRow(key: "Nome", value: m.name)
                PropertyRow(key: "Dados de máquina", value: m.source)
                PropertyRow(key: "Eixos", value: m.railEnabled ? "6 + trilho" : "6")
                if let bk = r.backup { PropertyRow(key: "Projetos de teach", value: "\(bk.projects.count)") }
            }
            PropertyCategory(title: "2 - Base (estação)") {
                PropertyRow(key: "X / Y / Z", value: String(format: "%.2f / %.2f / %.2f", m.base.x, m.base.y, m.base.z))
                PropertyRow(key: "A / B / C", value: String(format: "%.3f / %.3f / %.3f", m.base.a, m.base.b, m.base.c))
            }
            if r.id == app.activeRobotID {
                PropertyCategory(title: "3 - Posição articular") { jointSliders }
                PropertyCategory(title: "4 - TCP (ferramenta ativa)") {
                    PropertyRow(key: "X / Y / Z", value: String(format: "%.1f / %.1f / %.1f", app.tcp.x, app.tcp.y, app.tcp.z))
                    PropertyRow(key: "A / B / C", value: String(format: "%.2f / %.2f / %.2f", app.tcp.a, app.tcp.b, app.tcp.c))
                    PropertyRow(key: "Ferramenta", value: String(format: "%.1f, %.1f, %.1f, %.1f, %.1f, %.1f", app.activeTool.x, app.activeTool.y, app.activeTool.z, app.activeTool.a, app.activeTool.b, app.activeTool.c))
                }
            }
            PropertyCategory(title: "5 - Parâmetros DH") {
                ForEach(Array(m.joints.enumerated()), id: \.offset) { i, j in
                    PropertyRow(key: j.name, value: String(format: "θ₀ %.0f  d %.1f  a %.1f  α %.0f  [%.0f…%.0f]", j.thetaOffset, j.d, j.a, j.alpha, j.min, j.max))
                }
                if m.railEnabled {
                    PropertyRow(key: "Trilho", value: String(format: "[%.0f…%.0f] mm, %.0f mm/s", m.railMin, m.railMax, m.railMaxVelocity))
                }
            }
            warningProps(r)
        }
    }

    /// Limites de aviso da simulação (como no DXQ: margem antes do limite de cada eixo e singularidade do punho).
    private func warningProps(_ r: RobotSlot) -> some View {
        let id = r.id
        func bind<T>(_ get: @escaping (SimulationWarningSettings) -> T, _ set: @escaping (inout SimulationWarningSettings, T) -> Void) -> Binding<T> {
            Binding(get: { get(app.robots.first { $0.id == id }?.warnings ?? .init()) },
                    set: { v in var w = app.robots.first { $0.id == id }?.warnings ?? .init(); set(&w, v); app.setWarnings(w, for: id) })
        }
        let n = r.model.joints.count
        return PropertyCategory(title: "6 - Limites de aviso (simulação)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Erros (limite de eixo, fora de alcance, singularidade) são sempre verificados. Os avisos abaixo vêm desligados, como no DXQ.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Avisar perto do limite dos eixos", isOn: bind({ $0.enableJointLimitWarnings }, { $0.enableJointLimitWarnings = $1 }))
                    .toggleStyle(.checkbox)
                HStack {
                    Text("Margem (A1…A6)").font(DXQ.font)
                    TextField("", value: bind({ $0.jointWarningMax.first ?? 0 }, { w, v in
                        w.jointWarningMin = Array(repeating: v, count: n); w.jointWarningMax = Array(repeating: v, count: n)
                    }), format: .number).frame(width: 60)
                    Text("°").font(DXQ.font)
                    if r.model.railEnabled {
                        Text("Trilho").font(DXQ.font)
                        TextField("", value: bind({ $0.railWarningMax }, { w, v in w.railWarningMin = v; w.railWarningMax = v }), format: .number).frame(width: 60)
                        Text("mm").font(DXQ.font)
                    }
                }
                HStack {
                    Text("Singularidade: |A5| ≤").font(DXQ.font)
                    TextField("", value: bind({ $0.singularityWarningLimit }, { $0.singularityWarningLimit = $1 }), format: .number).frame(width: 60)
                    Text("° (0 = desligado)").font(DXQ.font)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .padding(8)
        }
    }

    private var jointSliders: some View {
        VStack(spacing: 2) {
            if app.robot.railEnabled {
                slider("E1", value: Binding(get: { app.joints.rail }, set: { var j = app.joints; j.rail = $0; app.joints = j }),
                       range: app.robot.railMin...app.robot.railMax, unit: "mm")
            }
            ForEach(app.robot.joints.indices, id: \.self) { i in
                slider(app.robot.joints[i].name,
                       value: Binding(get: { app.joints.q[i] }, set: { var j = app.joints; j.q[i] = $0; app.joints = j }),
                       range: app.robot.joints[i].min...app.robot.joints[i].max, unit: "°")
            }
        }
        .padding(.vertical, 4)
    }

    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(DXQ.font).frame(width: 26, alignment: .leading).padding(.leading, 22)
            Slider(value: value, in: range).controlSize(.mini)
            Text(String(format: "%8.2f %@", value.wrappedValue, unit)).font(.system(size: 11, design: .monospaced)).frame(width: 82, alignment: .trailing)
        }
        .padding(.trailing, 6)
        .frame(height: 20)
    }

    private func programProps(_ rid: UUID, _ path: String) -> some View {
        let p = app.openProgram?.url.path == path ? app.openProgram : nil
        return Group {
            PropertyCategory(title: "1 - Programa") {
                PropertyRow(key: "Nome", value: p?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                PropertyRow(key: "Robô", value: app.robots.first { $0.id == rid }?.name ?? "")
                if let p {
                    PropertyRow(key: "Instruções", value: "\(p.commands.count)")
                    PropertyRow(key: "Declarações", value: "\(p.declarations.count)")
                    PropertyRow(key: "Pontos", value: "\(p.declarations.filter { $0.type == "POINT" }.count)")
                }
            }
            PropertyCategory(title: "2 - Diversos") {
                PropertyRow(key: "Caminho completo", value: path)
            }
            if p != nil, app.editorSelection.count == 1, let l = app.editorLines.first(where: { app.editorSelection.contains($0.index) }), l.kind != .blank {
                selectedCommandProps(l)
            }
            if !app.program.points.isEmpty {
                PropertyCategory(title: "4 - Simulação") {
                    PropertyRow(key: "Movimentos", value: "\(app.program.points.count)")
                    PropertyRow(key: "Com aplicação", value: "\(app.program.points.filter(\.paintOn).count)")
                    PropertyRow(key: "Duração", value: String(format: "%.1f s", app.samples.last?.time ?? 0))
                    PropertyRow(key: "Fora de alcance", value: app.unreachable.isEmpty ? "nenhum" : "\(app.unreachable.count)")
                }
            }
        }
    }

    /// Comando selecionado no editor (como a grade de propriedades do DXQ: parâmetros e o ponto usado).
    private func selectedCommandProps(_ l: EcoProgramLine) -> some View {
        let routine = app.openSystem.routine(l.name)
        let point = app.targetPoint(of: l)
        return PropertyCategory(title: "3 - Comando selecionado") {
            PropertyRow(key: "Linha", value: "\(l.lineNumber)")
            PropertyRow(key: "Comando", value: l.kind == .comment ? "Comentário" : l.name + (l.isDisabled ? " (desativado)" : ""))
            if let g = routine?.group, !g.isEmpty { PropertyRow(key: "Grupo", value: EcoSystemDeclarations.groupTitle(g)) }
            ForEach(Array(l.args.enumerated()), id: \.offset) { i, a in
                let decl = routine.flatMap { i < $0.parameters.count ? $0.parameters[i] : nil }
                PropertyRow(key: decl.map { "\($0.name) (\($0.type))" } ?? "Parâmetro \(i + 1)", value: a)
            }
            if let c = l.trailingComment { PropertyRow(key: "Comentário", value: c) }
            if let d = point, d.args.count >= 7 {
                let axis = (d.args.first ?? "").lowercased() == "axis"
                let n = d.args.dropFirst().prefix(7).map { $0 }
                PropertyRow(key: "Ponto \(d.name)", value: d.args.first ?? "")
                PropertyRow(key: axis ? "A1 / A2 / A3" : "X / Y / Z", value: n.prefix(3).joined(separator: " / "))
                PropertyRow(key: axis ? "A4 / A5 / A6" : "A / B / C", value: n.dropFirst(3).prefix(3).joined(separator: " / "))
                if n.count > 6 { PropertyRow(key: "E1 (trilho)", value: n[6]) }
            }
        }
    }

    private func projectProps(_ p: EcoTalkProject) -> some View {
        Group {
            PropertyCategory(title: "1 - Projeto de teach") {
                PropertyRow(key: "Nome", value: p.name)
                PropertyRow(key: "Programas", value: "\(p.programs.count)")
            }
            PropertyCategory(title: "2 - Diversos") { PropertyRow(key: "Caminho completo", value: p.url.path) }
        }
    }

    private func partProps(_ p: Part) -> some View {
        let id = p.id
        return Group {
            PropertyCategory(title: "1 - Objeto 3D") {
                PropertyRow(key: "Nome", value: p.name)
                PropertyRow(key: "Triângulos", value: "\(p.mesh.indices.count / 3)")
                PropertyRow(key: "Arquivo", value: p.url?.path ?? "(gerado)")
                PropertyRow(key: "Alvo de pintura", value: p.isPaintTarget ? "Sim" : "Não")
            }
            PropertyCategory(title: "2 - Posição na estação") {
                PropertyRow(key: "OBJECT usado", value: p.objectName == "station" ? "Origem da estação" : (p.objectName ?? "Posicionamento manual"))
                Picker("OBJECT", selection: Binding(get: { app.parts.first(where: { $0.id == id })?.objectName ?? "manual" }, set: { app.assignPartObject(id, objectID: $0) })) {
                    Text("Posicionamento manual").tag("manual")
                    if let name = p.objectName, !app.partObjects.contains(where: { $0.id == name }) { Text(name).tag(name) }
                    ForEach(app.partObjects) { object in Text(object.id == "station" ? object.name : object.id).tag(object.id) }
                }.padding(8)
                PoseEditor(pose: Binding(get: { app.parts.first(where: { $0.id == id })?.offset ?? p.offset }, set: { app.updatePartOffset(id, $0) }))
                    .padding(8)
            }
        }
    }
}
