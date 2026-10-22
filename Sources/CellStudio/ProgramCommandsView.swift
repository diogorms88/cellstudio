import CellCore
import SwiftUI

// Editor de programa por comandos, como o ProgramEditor do DXQ: o .tip é uma lista de comandos (uma linha cada),
// editada pelo menu do botão direito / barra de ferramentas e por diálogos, nunca como texto livre.

enum EditorColors {
    static let text = Color(white: 0.2)
    static let comment = Color(red: 0, green: 0.55, blue: 0)
    static let motion = Color(red: 0.0, green: 0.25, blue: 0.75)
    static let process = Color(red: 0.75, green: 0.35, blue: 0.0)
    static let keyword = Color(red: 0.5, green: 0.0, blue: 0.55)
    static let lineNumber = Color(red: 0.1, green: 0.5, blue: 0.1)
    static let simLine = Color(red: 1, green: 0.93, blue: 0.55)

    static func color(for line: EcoProgramLine, system: EcoSystemDeclarations) -> Color {
        if line.kind == .comment { return comment }
        if line.isDisabled { return Color(white: 0.55) }
        switch line.name {
        case "PTP", "LIN", "CIRC", "PTP_REL", "LIN_REL", "PTP_MODE", "SPLINE", "SPLINE_START_TANG", "SPLINE_END_TANG": return motion
        case "IF", "ELSIF", "ELSE", "END_IF", "WHILE", "END_WHILE", "LOOP", "END_LOOP", "CALL", "LABEL", "GOTO", "RETURN",
             "RSELECT", "RDESELECT", "ASSIGNMENT": return keyword
        default:
            switch system.routine(line.name)?.group {
            case "MOVEMENT": return motion
            case "PROCESS", "GEOMETRIC", "DYNAMIC": return process
            case "OTHER": return keyword
            default: return text
            }
        }
    }

    static func commandTitle(_ name: String) -> String {
        switch name {
        case "ASSIGNMENT": "Atribuição (:=)"
        case "//": "Comentário (//)"
        default: name
        }
    }
}

// MARK: - Lista de comandos (aba Código fonte)

struct ProgramCommandList: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let lines = app.editorLines
        let system = app.openSystem
        VStack(spacing: 0) {
            EditorToolbar()
            ScrollViewReader { proxy in
                List(selection: $app.editorSelection) {
                    ForEach(lines) { line in
                        CommandRow(line: line, system: system, isSimLine: app.highlightedLine == line.lineNumber,
                                   isErrorLine: app.editorErrorLine == line.lineNumber)
                            .tag(line.index)
                            .id(line.index)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .contextMenu(forSelectionType: Int.self) { ids in
                    CommandContextMenu(ids: ids)
                } primaryAction: { ids in
                    if let first = ids.min() { app.editorSelection = [first]; app.editSelectedCommand() }
                }
                .onDeleteCommand { app.deleteCommands() }
                .onCopyCommand { app.copyCommands(); return [] }
                .onCutCommand { app.cutCommands(); return [] }
                .onPasteCommand(of: [.plainText]) { _ in app.pasteCommands() }
                .onChange(of: app.highlightedLine) { _, line in
                    if let line { withAnimation(.none) { proxy.scrollTo(line - 1, anchor: .center) } }
                }
            }
            CommandStatusBar(lines: lines)
        }
    }
}

struct CommandRow: View {
    let line: EcoProgramLine
    let system: EcoSystemDeclarations
    let isSimLine: Bool
    var isErrorLine = false

    var body: some View {
        HStack(spacing: 0) {
            Text("\(line.lineNumber)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorColors.lineNumber)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 4)
            Rectangle().fill(isErrorLine ? Color.red : (isSimLine ? Color.orange : Color(white: 0.88))).frame(width: isSimLine || isErrorLine ? 3 : 1)
            content
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .background(isErrorLine ? Color(red: 1, green: 0.8, blue: 0.78) : (isSimLine ? EditorColors.simLine : Color.clear))
        .overlay(alignment: .trailing) {
            if isErrorLine { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).padding(.trailing, 6) }
        }
        .contentShape(Rectangle())
        .help(line.isDisabled ? "Comando desativado (##): o controlador ignora esta linha" : line.text.trimmingCharacters(in: .whitespaces))
    }

    @ViewBuilder private var content: some View {
        // tudo encostado à esquerda (a indentação do arquivo não é mostrada nem alterada)
        let indent = Text("")
        switch line.kind {
        case .blank:
            Text(" ")
        case .comment:
            indent + Text("//" + line.body).foregroundColor(EditorColors.comment)
        case .command:
            let c = EditorColors.color(for: line, system: system)
            let disabled = line.isDisabled ? Text("##").foregroundColor(Color(white: 0.55)) : Text("")
            let body = Text(line.body).foregroundColor(c)
            let comment = line.trailingComment.map { Text("  //" + $0).foregroundColor(EditorColors.comment) } ?? Text("")
            (indent + disabled + (line.isDisabled ? body.italic() : body) + comment)
                .strikethrough(line.isDisabled, color: Color(white: 0.6))
        }
    }
}

struct CommandStatusBar: View {
    @EnvironmentObject var app: AppState
    let lines: [EcoProgramLine]
    var body: some View {
        let sel = app.editorSelection
        HStack(spacing: 10) {
            Text("\(lines.filter { $0.kind == .command }.count) comandos")
            if !sel.isEmpty { Text(sel.count == 1 ? "Linha \((sel.first ?? 0) + 1)" : "\(sel.count) linhas selecionadas") }
            if lines.contains(where: \.isDisabled) { Text("\(lines.filter(\.isDisabled).count) desativados").foregroundStyle(.secondary) }
            Spacer()
            if app.openProgramDirty { Text("Alterado – salve com ⌘S").foregroundStyle(.orange) }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Color(white: 0.96))
        .overlay(alignment: .top) { Rectangle().fill(DXQ.border).frame(height: 1) }
    }
}

/// Menu "Inserir um comando" (grupos do system.ttu + comandos da linguagem).
struct InsertCommandMenu: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let used = Set(app.editorLines.map(\.name))
        ForEach(app.openSystem.insertGroups(showAll: app.showAllCommandsOnInsert, used: used), id: \.group) { g in
            Menu(EcoSystemDeclarations.groupTitle(g.group)) {
                ForEach(g.commands, id: \.self) { name in
                    Button(EditorColors.commandTitle(name)) { app.insertCommand(name) }
                }
            }
        }
        Divider()
        Toggle("Mostrar todos os comandos", isOn: $app.showAllCommandsOnInsert)
    }
}

/// Menu do botão direito (mesma ordem do `ProgramEditorViewModel.InitContextMenu` do DXQ).
struct CommandContextMenu: View {
    @EnvironmentObject var app: AppState
    let ids: Set<Int>

    private func run(_ f: @escaping () -> Void) -> () -> Void {
        { if !ids.isEmpty && !ids.isSubset(of: app.editorSelection) { app.editorSelection = ids }; f() }
    }

    var body: some View {
        let lines = app.editorLines.filter { ids.contains($0.index) }
        let hasCommand = lines.contains { $0.kind == .command }
        Button("Recortar", action: run(app.cutCommands)).disabled(ids.isEmpty)
        Button("Copiar", action: run(app.copyCommands)).disabled(ids.isEmpty)
        Button("Colar", action: run(app.pasteCommands)).disabled(app.editClipboard.lines.isEmpty)
        Divider()
        Button("Desfazer", action: app.undoEdit).disabled(app.editUndo.isEmpty)
        Button("Refazer", action: app.redoEdit).disabled(app.editRedo.isEmpty)
        Divider()
        Button("Remover comando", action: run(app.deleteCommands)).disabled(ids.isEmpty)
        Button("Modificar (gravar posição atual no ponto)", action: run(app.modifyPoints))
            .disabled(!lines.contains { l in app.targetPoint(of: l).map { d in app.openProgram?.declarations.contains { $0.name == d.name } ?? false } ?? false })
        Button("Editar comando…", action: run(app.editSelectedCommand)).disabled(lines.count != 1 || lines.first?.kind == .blank)
        Menu("Inserir um comando") { InsertCommandMenu() }
        Divider()
        Button("Selecionar todos os comandos", action: app.selectAllCommands)
        Button("Selecionar todos os comandos iguais", action: run(app.selectEverySame)).disabled(!hasCommand)
        Button("Desmarcar todos") { app.editorSelection = [] }
        Divider()
        Button("Transformar linha em comentário", action: run(app.commentOutCommands)).disabled(!hasCommand)
        Button("Retirar comentário", action: run(app.commentInCommands)).disabled(!lines.contains { $0.kind == .comment })
        Button("Desativar comando", action: run { app.setCommandsDisabled(true) })
            .disabled(!lines.contains { EcoProgramEditor.canDisable($0) && !$0.isDisabled })
        Button("Ativar comando", action: run { app.setCommandsDisabled(false) }).disabled(!lines.contains(where: \.isDisabled))
        if lines.count == 1, lines.first?.name == "CALL" {
            Divider()
            Button("Abrir subprograma", action: run { app.openSelectedSubprogram() })
            Button("Abrir e simular", action: run { app.openSelectedSubprogram(simulate: true) })
        }
        Divider()
        Button("Mostrar bits de colisão usados") { app.showUsedCollisionBits = true }
        Button("Inverter sentido do movimento", action: run(app.reverseCommands)).disabled(ids.count < 2)
        Button("Reindexar pontos selecionados…", action: run { app.showReindex = true }).disabled(!hasCommand)
        Button("Mover robô até o ponto", action: run(app.moveRobotToSelectedPoint)).disabled(!lines.contains { app.targetPoint(of: $0) != nil })
        Menu("Transformar pontos") { PointTransformMenu(run: run) }.disabled(!hasCommand)
        Divider()
        Button("Mover para cima", action: run { app.moveCommands(-1) }).disabled(ids.isEmpty || (ids.min() ?? 0) == 0)
        Button("Mover para baixo", action: run { app.moveCommands(1) }).disabled(ids.isEmpty)
    }
}

/// Barra de ferramentas do editor (atalhos dos itens mais usados do menu).
struct EditorToolbar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 2) {
            Menu {
                InsertCommandMenu()
            } label: {
                HStack(spacing: 3) { DXQSymbol(symbol: "plus.rectangle.on.rectangle"); Text("Inserir") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Inserir um comando depois da linha selecionada")
            bar("pencil", "Editar comando (duplo clique)", enabled: app.editorSelection.count == 1) { app.editSelectedCommand() }
            bar("scope", "Modificar: gravar a posição atual do robô no ponto", enabled: app.canModify) { app.modifyPoints() }
            bar("location.viewfinder", "Mover robô até o ponto", enabled: !app.editorSelection.isEmpty) { app.moveRobotToSelectedPoint() }
            bar("trash", "Remover comando (⌫)", enabled: !app.editorSelection.isEmpty) { app.deleteCommands() }
            Divider().frame(height: 16)
            bar("arrow.up", "Mover para cima", enabled: !app.editorSelection.isEmpty) { app.moveCommands(-1) }
            bar("arrow.down", "Mover para baixo", enabled: !app.editorSelection.isEmpty) { app.moveCommands(1) }
            bar("text.bubble", "Transformar em comentário / retirar comentário", enabled: !app.editorSelection.isEmpty) {
                app.canCommentOut ? app.commentOutCommands() : app.commentInCommands()
            }
            bar("nosign", "Desativar / ativar comando (##)", enabled: app.canDisable || app.canEnable) {
                app.setCommandsDisabled(app.canDisable)
            }
            Divider().frame(height: 16)
            bar("arrow.uturn.backward", "Desfazer (⌘Z)", enabled: !app.editUndo.isEmpty) { app.undoEdit() }
                .keyboardShortcut("z", modifiers: .command)
            bar("arrow.uturn.forward", "Refazer (⇧⌘Z)", enabled: !app.editRedo.isEmpty) { app.redoEdit() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(Color(white: 0.985))
        .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
    }

    private func bar(_ icon: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DXQSymbol(symbol: icon).saturation(enabled ? 1 : 0).opacity(enabled ? 1 : 0.4).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Diálogo de comando (inserir / editar)

struct CommandEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let request: CommandEditRequest

    enum Kind {
        case enumeration([String]), number, bool, string, program, text, comment, instance
    }

    struct Param: Identifiable {
        let id: Int
        var name: String
        var type: String
        var kind: Kind
        var optional: Bool
        var include = true
        var value = ""                // texto / enum / número / instância existente
        var isNew = false
        var newName = ""
        var newArgs: [String] = []
    }

    @State private var params: [Param] = []
    @State private var rawText = ""
    @State private var routine: EcoSystemDeclarations.Routine?
    @State private var error: String?
    @State private var ready = false

    private static let newTag = "\u{1}novo"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: request.line == nil ? "plus.rectangle.on.rectangle" : "pencil")
                    .foregroundStyle(DXQ.blue)
                Text((request.line == nil ? "Inserir " : "Editar ") + EditorColors.commandTitle(request.name)).font(.headline)
                Spacer()
                if let g = routine?.group, !g.isEmpty { Text(EcoSystemDeclarations.groupTitle(g)).font(.caption).foregroundStyle(.secondary) }
            }
            if let r = routine, r.enableCondition != nil {
                Label("Este comando depende da configuração do robô (\(r.enableCondition ?? ""))", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if routine == nil {
                        Text("Texto do comando").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: $rawText).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    } else if params.isEmpty {
                        Text("Este comando não tem parâmetros.").foregroundStyle(.secondary)
                    }
                    ForEach($params) { $p in
                        ParamEditor(param: $p, newTag: Self.newTag, line: contextLine)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 60, maxHeight: 460)
            Divider()
            Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(EditorColors.motion)
                .lineLimit(2).textSelection(.enabled)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .sheetFrame(width: 520)
        .onAppear(perform: setup)
    }

    /// Linha usada para saber SETTOOL/SETOBJECT em vigor (pontos novos em Object/World).
    private var contextLine: Int { (request.line ?? request.after ?? 0) + 1 }

    private var argsOut: [String] {
        var out = params.map { p -> String? in
            guard p.include else { return nil }
            if case .instance = p.kind, p.isNew { return p.newName }
            if case .string = p.kind { return "\"" + p.value.replacingOccurrences(of: "\"", with: "") + "\"" }
            return p.value
        }
        while let last = out.last, last == nil, params[out.count - 1].optional { out.removeLast() }
        return out.map { $0 ?? "" }
    }

    private var preview: String {
        guard let r = routine else { return rawText }
        if r.name == "//" { return "//" + (params.first?.value ?? "") }
        return EcoProgramEditor.format(name: r.name, args: argsOut)
    }

    private func kind(_ type: String) -> Kind {
        let sys = app.openSystem
        if let values = sys.enums[type] { return .enumeration(values) }
        switch type {
        case "REAL", "LREAL", "INT", "DINT", "SINT", "UINT", "UDINT", "USINT", "WORD", "DWORD", "BYTE": return .number
        case "BOOL": return .bool
        case "STRING": return .string
        case "SUB": return .program
        case "COMMENT": return .comment
        case "EXPRESSION", "EXPRESSION_BOOL", "EXPRESSION_INT", "VARIABLE", "LABEL": return .text
        default:
            if sys.blocks[type] != nil || !app.visibleDeclarations(type: type).isEmpty { return .instance }
            return .text
        }
    }

    private func setup() {
        guard !ready else { return }
        ready = true
        let sys = app.openSystem
        let existing = request.line.flatMap { row in app.editorLines.first { $0.index == row } }
        if request.name == "//" || existing?.kind == .comment {
            routine = EcoSystemDeclarations.builtins.first { $0.name == "//" }
            params = [Param(id: 0, name: "Comentário", type: "COMMENT", kind: .comment, optional: false, value: existing?.body ?? " ")]
            return
        }
        guard let r = sys.routine(request.name) else {
            rawText = existing?.body ?? request.name
            return
        }
        routine = r
        var taken = Set(app.visibleDeclarations().map(\.decl.name))
        params = r.parameters.enumerated().map { i, decl in
            var p = Param(id: i, name: decl.name, type: decl.type, kind: kind(decl.type), optional: decl.optional)
            let current = existing.flatMap { i < $0.args.count ? $0.args[i] : nil }
            if let current {
                p.value = current
                if case .string = p.kind { p.value = current.replacingOccurrences(of: "\"", with: "") }
            } else {
                p.include = !decl.optional
                switch p.kind {
                case .enumeration(let values): p.value = values.first ?? ""
                case .number: p.value = "0"
                case .bool: p.value = "TRUE"
                case .program: p.value = app.openProject?.programs.first?.name ?? ""
                case .instance:
                    // como no DXQ: pontos e trigger frames novos; outros dados → o último usado no programa
                    if ["POINT", "POINT_M", "TRIGGERFRAME"].contains(decl.type) {
                        p.isNew = true
                    } else {
                        let usedNames = app.editorLines.flatMap(\.args)
                        let options = app.visibleDeclarations(type: decl.type).map(\.decl.name)
                        p.value = usedNames.last { options.contains($0) } ?? options.first ?? ""
                        p.isNew = options.isEmpty
                    }
                default: p.value = decl.type.hasPrefix("EXPRESSION_INT") ? "1" : ""
                }
            }
            if case .instance = p.kind {
                let prefix = app.openProgram.map { EcoProgramEditor.prefix(for: decl.type, in: $0, fallback: sys.defaultPrefix(for: decl.type)) } ?? "P"
                p.newName = EcoProgramEditor.nextFreeName(prefix: prefix, taken: taken)
                taken.insert(p.newName)
                p.newArgs = decl.type.hasPrefix("POINT") ? app.currentPointArgs(mode: "Object", line: contextLine) : app.defaultArgs(type: decl.type)
            }
            return p
        }
    }

    private func commit() {
        guard routine != nil else {
            let t = rawText.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { error = "Digite o comando"; return }
            app.applyCommand(request, text: t, newDeclarations: []); dismiss(); return
        }
        let taken = Set(app.visibleDeclarations().map { $0.decl.name.uppercased() })
        var newDecls: [(name: String, type: String, args: [String])] = []
        for p in params where p.include {
            if case .instance = p.kind, p.isNew {
                let n = p.newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { error = "Nome inválido em \(p.name)"; return }
                guard !taken.contains(n.uppercased()), !newDecls.contains(where: { $0.name.uppercased() == n.uppercased() }) else {
                    error = "\(n) já existe"; return
                }
                newDecls.append((n, p.type, p.newArgs))
            } else if case .number = p.kind, Double(p.value) == nil, app.visibleDeclarations().first(where: { $0.decl.name == p.value }) == nil {
                error = "\(p.name): número inválido"; return
            } else if p.value.trimmingCharacters(in: .whitespaces).isEmpty, !(p.kind.isComment) {
                error = "Preencha \(p.name)"; return
            }
        }
        app.applyCommand(request, text: preview, newDeclarations: newDecls)
        dismiss()
    }
}

private extension CommandEditorSheet.Kind {
    var isComment: Bool { if case .comment = self { return true }; return false }
}

struct ParamEditor: View {
    @EnvironmentObject var app: AppState
    @Binding var param: CommandEditorSheet.Param
    let newTag: String
    let line: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(param.name).font(.system(size: 12, weight: .semibold))
                Text(param.type).font(.caption).foregroundStyle(.secondary)
                if param.optional {
                    Spacer()
                    Toggle("usar", isOn: $param.include).toggleStyle(.checkbox).font(.caption)
                }
            }
            if param.include { editor }
        }
    }

    @ViewBuilder private var editor: some View {
        switch param.kind {
        case .enumeration(let values):
            Picker("", selection: $param.value) {
                if !values.contains(param.value) { Text(param.value).tag(param.value) }
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .bool:
            Picker("", selection: $param.value) { Text("TRUE").tag("TRUE"); Text("FALSE").tag("FALSE") }.labelsHidden().pickerStyle(.segmented)
        case .program:
            Picker("", selection: $param.value) {
                let names = app.openProject?.programs.map(\.name) ?? []
                if !names.contains(param.value) { Text(param.value).tag(param.value) }
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .instance:
            instanceEditor
        case .comment:
            TextField("comentário", text: $param.value).textFieldStyle(.roundedBorder)
        case .number, .string, .text:
            TextField(param.type.hasPrefix("EXPRESSION") ? "expressão (ex.: X > 1, GET_MOTION_STATE(…))" : "", text: $param.value)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var instanceEditor: some View {
        let options = app.visibleDeclarations(type: param.type)
        Picker("", selection: Binding(get: { param.isNew ? newTag : param.value },
                                      set: { if $0 == newTag { param.isNew = true } else { param.isNew = false; param.value = $0 } })) {
            Text("＋ Novo: \(param.newName)").tag(newTag)
            Divider()
            if !param.value.isEmpty, !options.contains(where: { $0.decl.name == param.value }) { Text(param.value).tag(param.value) }
            ForEach(options, id: \.decl.name) { o in
                Text(o.scope == "Programa" ? o.decl.name : "\(o.decl.name)  (\(o.scope.lowercased()))").tag(o.decl.name)
            }
        }
        .labelsHidden()
        if param.isNew {
            HStack {
                Text("Nome").font(.caption)
                TextField("", text: $param.newName).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            DeclarationFieldsEditor(type: param.type, args: $param.newArgs, line: line)
        } else if let d = options.first(where: { $0.decl.name == param.value })?.decl {
            Text(d.args.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Campos de um dado (bloco do system.ttu). POINT: modo + coordenadas, com "posição atual do robô".
struct DeclarationFieldsEditor: View {
    @EnvironmentObject var app: AppState
    let type: String
    @Binding var args: [String]
    let line: Int

    private var labels: [String] {
        if type.hasPrefix("POINT") {
            let axis = (args.first ?? "").lowercased() == "axis"
            return ["Modo"] + (axis ? ["A1", "A2", "A3", "A4", "A5", "A6"] : ["X", "Y", "Z", "A", "B", "C"]) + ["E1 (trilho)", "Aux2", "Aux3"]
        }
        if let b = app.openSystem.blocks[type.uppercased()] { return b.fields.map(\.name) }
        return args.indices.map { "Valor \($0 + 1)" }
    }

    private func enumValues(_ i: Int) -> [String]? {
        if type.hasPrefix("POINT") { return i == 0 ? ["Object", "Axis", "World"] : nil }
        guard let f = app.openSystem.blocks[type.uppercased()]?.fields, i < f.count else { return nil }
        if f[i].type == "BOOL" { return ["TRUE", "FALSE"] }
        return app.openSystem.enums[f[i].type]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if type.hasPrefix("POINT") {
                HStack {
                    Button {
                        args = app.currentPointArgs(mode: args.first ?? "Object", line: line, keepAux: args.count >= 10 ? Array(args[8...9]) : [])
                    } label: { Label("Posição atual do robô", systemImage: "scope") }
                    Text("(\(app.openProgramOwner?.name ?? "robô"))").font(.caption).foregroundStyle(.secondary)
                }
            }
            let cols = [GridItem(.adaptive(minimum: 120), spacing: 8)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let values = enumValues(i) {
                            Picker("", selection: binding(i, recompute: type.hasPrefix("POINT") && i == 0)) {
                                ForEach(values, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        } else {
                            TextField("", text: binding(i)).font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    private func binding(_ i: Int, recompute: Bool = false) -> Binding<String> {
        Binding(get: { i < args.count ? args[i] : "" }, set: { v in
            while args.count <= i { args.append("0") }
            if recompute, args[i] != v {
                // trocar o modo recalcula as coordenadas a partir da posição atual (como o DXQ ao converter o ponto)
                args = app.currentPointArgs(mode: v, line: line, keepAux: args.count >= 10 ? Array(args[8...9]) : [])
            } else {
                args[i] = v
            }
        })
    }
}

// MARK: - Aba Dados (tabela, como o "Quadriculado" do DXQ)

struct ProgramDataGrid: View {
    @EnvironmentObject var app: AppState
    @State private var filter = "Todos"
    @State private var selection: Set<String> = []

    struct Row: Identifiable { var id: String { decl.name }; let decl: EcoTalkDeclaration; let uses: Int }

    var body: some View {
        let decls = app.openProgram?.declarations ?? []
        let types = ["Todos"] + Array(Set(decls.map(\.type))).sorted()
        let rows = decls.filter { filter == "Todos" || $0.type == filter }.map { Row(decl: $0, uses: app.referencesCount($0.name)) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Tipo", selection: $filter) { ForEach(types, id: \.self) { Text($0).tag($0) } }
                    .frame(width: 180).controlSize(.small)
                Menu { newMenu } label: { Label("Novo", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                Button { edit(selection.first) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                    .disabled(selection.count != 1).help("Editar dado")
                Button { modify() } label: { Image(systemName: "scope") }.buttonStyle(.borderless)
                    .disabled(selectedPoints(rows).isEmpty).help("Modificar: gravar a posição atual do robô no ponto")
                Button { remove(rows) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    .disabled(selection.isEmpty).help("Remover (só dados sem uso)")
                Spacer()
                Text("\(rows.count) de \(decls.count)").font(.caption).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .frame(height: 26)
            .phoneHorizontalScroll()
            .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
            Group {
            if Platform.isPhone {
                List(rows, selection: $selection) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.decl.name).font(.system(size: 14, design: .monospaced)).bold()
                            Text(r.decl.type).foregroundStyle(EditorColors.motion)
                            Spacer()
                            Text("\(r.uses) uso(s)").font(.caption).foregroundStyle(r.uses == 0 ? .orange : .secondary)
                        }
                        Text(r.decl.args.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .listStyle(.plain)
            } else {
            Table(rows, selection: $selection) {
                TableColumn("Nome") { r in Text(r.decl.name).font(.system(size: 12, design: .monospaced)) }.width(min: 50, ideal: 70, max: 140)
                TableColumn("Tipo") { r in Text(r.decl.type).foregroundStyle(EditorColors.motion) }.width(min: 50, ideal: 80, max: 120)
                TableColumn("Valor") { r in
                    Text(r.decl.args.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(r.decl.args.joined(separator: ", "))
                }.width(min: 160, ideal: 400)
                TableColumn("Usos") { r in Text("\(r.uses)").foregroundStyle(r.uses == 0 ? .orange : .primary) }.width(40)
            }
            .dxqTableStyle()
            }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Editar…") { edit(ids.first) }.disabled(ids.count != 1)
                Button("Modificar (gravar posição atual)") { selection = ids; modify() }
                    .disabled(!decls.contains { ids.contains($0.name) && $0.type == "POINT" })
                Button("Mover robô até o ponto") { moveTo(ids.first) }
                    .disabled(!(decls.first { $0.name == ids.first }?.type == "POINT"))
                Menu("Novo") { newMenu }
                Divider()
                Button("Remover") { selection = ids; remove(rows) }
                    .disabled(ids.isEmpty || ids.contains { app.referencesCount($0) > 0 })
            } primaryAction: { ids in edit(ids.first) }
        }
    }

    @ViewBuilder private var newMenu: some View {
        let blockTypes = app.openSystem.blocks.keys.sorted()
        let used = Set((app.openProgram?.declarations ?? []).map(\.type))
        ForEach(Array(used).sorted(), id: \.self) { t in Button(t) { app.dataEdit = DataEditRequest(name: nil, type: t) } }
        if !blockTypes.isEmpty {
            Divider()
            Menu("Outros tipos") {
                ForEach(blockTypes.filter { !used.contains($0) }, id: \.self) { t in Button(t) { app.dataEdit = DataEditRequest(name: nil, type: t) } }
            }
        }
    }

    private func selectedPoints(_ rows: [Row]) -> [EcoTalkDeclaration] {
        rows.map(\.decl).filter { selection.contains($0.name) && $0.type == "POINT" }
    }

    private func edit(_ name: String?) {
        guard let name, let d = app.openProgram?.declarations.first(where: { $0.name == name }) else { return }
        app.dataEdit = DataEditRequest(name: name, type: d.type)
    }

    private func firstLine(using name: String) -> Int {
        app.editorLines.first { $0.kind == .command && EcoProgramEditor.references($0, declared: [name]).contains(name) }?.lineNumber ?? 1
    }

    private func modify() {
        let points = (app.openProgram?.declarations ?? []).filter { selection.contains($0.name) && $0.type == "POINT" }
        guard !points.isEmpty else { return }
        app.mutateProgram { prog in
            for d in points {
                let aux = d.args.count >= 10 ? Array(d.args[8...9]) : []
                EcoProgramEditor.setDeclaration(name: d.name, type: d.type,
                                                args: app.currentPointArgs(mode: d.args.first ?? "Object", line: firstLine(using: d.name), keepAux: aux), in: &prog)
            }
        }
        app.info("Posição atual gravada em: " + points.map(\.name).joined(separator: ", "))
    }

    private func moveTo(_ name: String?) {
        guard let name else { return }
        let line = firstLine(using: name)
        let saved = app.editorSelection
        app.editorSelection = [line - 1]
        app.moveRobotToSelectedPoint()
        app.editorSelection = saved
    }

    private func remove(_ rows: [Row]) {
        let used = selection.filter { app.referencesCount($0) > 0 }
        if !used.isEmpty { app.warn("Não removido (em uso no programa): " + used.sorted().joined(separator: ", ")) }
        let names = selection.subtracting(used)
        guard !names.isEmpty else { return }
        app.mutateProgram { prog in for n in names { EcoProgramEditor.removeDeclaration(n, in: &prog) } }
        selection = []
    }
}

struct DataEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let request: DataEditRequest
    @State private var name = ""
    @State private var args: [String] = []
    @State private var error: String?
    @State private var ready = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.name == nil ? "Novo \(request.type)" : "Editar \(request.name ?? "")").font(.headline)
            HStack {
                Text("Nome").font(.caption)
                TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 160)
                Text(request.type).font(.caption).foregroundStyle(.secondary)
            }
            if let n = request.name {
                let uses = app.referencesCount(n)
                Text(uses == 0 ? "Sem uso no programa" : "Usado em \(uses) comando(s); renomear atualiza todos")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DeclarationFieldsEditor(type: request.type, args: $args, line: 1)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .sheetFrame(width: 460)
        .onAppear {
            guard !ready else { return }
            ready = true
            if let n = request.name, let d = app.openProgram?.declarations.first(where: { $0.name == n }) {
                name = d.name; args = d.args
            } else {
                name = app.newDeclarationName(type: request.type)
                args = request.type.hasPrefix("POINT") ? app.currentPointArgs(mode: "Object", line: 1) : app.defaultArgs(type: request.type)
            }
        }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { error = "Nome inválido"; return }
        if n.caseInsensitiveCompare(request.name ?? "") != .orderedSame,
           app.visibleDeclarations().contains(where: { $0.decl.name.caseInsensitiveCompare(n) == .orderedSame }) {
            error = "\(n) já existe"; return
        }
        app.applyDeclaration(oldName: request.name, name: n, type: request.type, args: args)
        dismiss()
    }
}

// MARK: - Bits de colisão usados / reindexar

struct UsedCollisionBitsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable { let id = UUID(); let program: String; let line: Int; let command: String; let pin: String; let state: String }

    var body: some View {
        let rows = collect()
        VStack(alignment: .leading, spacing: 10) {
            Text("Bits de colisão usados – \(app.openProgram?.name ?? "")").font(.headline)
            Text("Inclui os subprogramas chamados com CALL.").font(.caption).foregroundStyle(.secondary)
            if Platform.isPhone {
                ForEach(rows) { r in
                    HStack {
                        Text("\(r.program):\(r.line)").font(.system(size: 13, design: .monospaced))
                        Text(r.command).foregroundStyle(EditorColors.keyword)
                        Text(r.pin).bold()
                        Spacer()
                        Text(r.state).foregroundStyle(.secondary)
                    }
                    .font(DXQ.font)
                    Divider()
                }
            } else {
            Table(rows) {
                TableColumn("Programa") { r in Text(r.program) }
                TableColumn("Linha") { r in Text("\(r.line)") }.width(44)
                TableColumn("Comando") { r in Text(r.command).foregroundStyle(EditorColors.keyword) }.width(70)
                TableColumn("Bit") { r in Text(r.pin).bold() }
                TableColumn("Estado") { r in Text(r.state) }.width(50)
            }
            .frame(minHeight: 240)
            }
            HStack {
                Text("\(Set(rows.map { $0.pin.uppercased() }).count) bits diferentes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .sheetFrame(width: 520, height: 420)
    }

    private func collect() -> [Row] {
        guard let p = app.openProgram, let proj = app.openProject else { return [] }
        var out: [Row] = [], visited = Set<String>(), queue = [p]
        while let prog = queue.first {
            queue.removeFirst()
            guard visited.insert(prog.name.uppercased()).inserted else { continue }
            out += EcoProgramEditor.collisionBits(prog).map { Row(program: prog.name, line: $0.line, command: $0.command, pin: $0.pin, state: $0.state) }
            for l in EcoProgramEditor.lines(prog) where l.kind == .command && !l.isDisabled && l.name == "CALL" {
                if let callee = proj.programs.first(where: { $0.name.caseInsensitiveCompare(l.args.first ?? "") == .orderedSame }) { queue.append(callee) }
            }
        }
        return out
    }
}

struct ReindexSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var prefix = "P"
    @State private var start = "1"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reindexar pontos selecionados").font(.headline)
            Text("Os pontos usados pelos comandos selecionados são renomeados em sequência, na ordem do programa. Nomes já usados por outros pontos são pulados.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Prefixo"); TextField("", text: $prefix).frame(width: 70)
                Text("Começar em"); TextField("", text: $start).frame(width: 60)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reindexar") {
                    app.reindexPoints(prefix: prefix.trimmingCharacters(in: .whitespaces), start: Int(start) ?? 1)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prefix.isEmpty || Int(start) == nil)
            }
        }
        .padding(16)
        .sheetFrame(width: 420)
    }
}
