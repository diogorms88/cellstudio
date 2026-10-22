import CellCore
import Foundation
import simd

/// Pedido para o diálogo de comando: inserir (`line == nil`, depois de `after`) ou editar a linha `line`.
struct CommandEditRequest: Identifiable {
    let id = UUID()
    var name: String
    var line: Int?
    var after: Int?
}

/// Pedido para o editor de dado (.tid): `name == nil` cria um novo do tipo `type`.
struct DataEditRequest: Identifiable {
    let id = UUID()
    var name: String?
    var type: String
}

/// Ações do editor de programa (menu do botão direito, como o `ProgramEditorViewModel.InitContextMenu` do DXQ).
extension AppState {
    // MARK: Contexto

    var openProgramOwner: RobotSlot? {
        guard let p = openProgram else { return nil }
        return robots.first { $0.backup?.projects.contains { $0.programs.contains { $0.url == p.url } } ?? false }
    }

    var openProject: EcoTalkProject? {
        guard let p = openProgram, let bk = openProgramOwner?.backup,
              var proj = bk.projects.first(where: { $0.programs.contains { $0.url == p.url } }) else { return nil }
        if let i = proj.programs.firstIndex(where: { $0.url == p.url }) { proj.programs[i] = p }
        return proj
    }

    var openSystem: EcoSystemDeclarations { openProgramOwner?.backup?.system ?? EcoSystemDeclarations() }

    var editorLines: [EcoProgramLine] { openProgram.map(EcoProgramEditor.lines) ?? [] }

    var canEditProgram: Bool { openProgram != nil }

    /// Todos os dados visíveis no programa aberto: locais (.tid), do projeto e do sistema (_globalvars).
    func visibleDeclarations(type: String? = nil) -> [(decl: EcoTalkDeclaration, scope: String)] {
        guard let p = openProgram else { return [] }
        var out: [(EcoTalkDeclaration, String)] = p.declarations.map { ($0, "Programa") }
        let local = Set(out.map { $0.0.name.uppercased() })
        for d in openProject?.projectData ?? [] where !local.contains(d.name.uppercased()) { out.append((d, "Projeto")) }
        let seen = Set(out.map { $0.0.name.uppercased() })
        for d in openProgramOwner?.backup?.systemData ?? [] where !seen.contains(d.name.uppercased()) { out.append((d, "Sistema")) }
        guard let type else { return out }
        return out.filter { $0.0.type == type.uppercased() }
    }

    // MARK: Desfazer

    func mutateProgram(_ f: (inout EcoTalkProgram) -> Void) {
        guard var p = openProgram else { return }
        let before = p
        f(&p)
        guard p.source != before.source || p.data != before.data else { return }
        editUndo.append(before)
        if editUndo.count > 200 { editUndo.removeFirst() }
        editRedo = []
        openProgram = p
        openProgramDirty = true
    }

    func undoEdit() {
        guard let prev = editUndo.popLast(), let cur = openProgram else { return }
        editRedo.append(cur)
        openProgram = prev
        openProgramDirty = true
        editorSelection = editorSelection.filter { $0 < EcoProgramEditor.rawLines(prev.source).count }
    }

    func redoEdit() {
        guard let next = editRedo.popLast(), let cur = openProgram else { return }
        editUndo.append(cur)
        openProgram = next
        openProgramDirty = true
        editorSelection = editorSelection.filter { $0 < EcoProgramEditor.rawLines(next.source).count }
    }

    // MARK: Seleção

    func selectAllCommands() { editorSelection = Set(editorLines.filter { $0.kind != .blank }.map(\.index)) }

    /// "Selecionar todos os comandos iguais"
    func selectEverySame() {
        let names = Set(editorLines.filter { editorSelection.contains($0.index) && $0.kind == .command }.map(\.name))
        editorSelection = Set(editorLines.filter { $0.kind == .command && names.contains($0.name) }.map(\.index))
    }

    var selectedLines: [EcoProgramLine] { editorLines.filter { editorSelection.contains($0.index) } }

    // MARK: Área de transferência

    func copyCommands() {
        guard let p = openProgram, !editorSelection.isEmpty else { return }
        let ls = selectedLines
        let declared = Set(p.declarations.map(\.name))
        let refs = ls.flatMap { EcoProgramEditor.references($0, declared: declared) }
        let declLines = EcoProgramEditor.declarationLines(p)
        let decls = p.declarations.filter { d in refs.contains(d.name) }.map { declLines[$0.line - 1] }
        editClipboard = (ls.map(\.text), decls)
        Pasteboard.copy(ls.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    }

    func cutCommands() { copyCommands(); deleteCommands() }

    func deleteCommands() {
        guard !editorSelection.isEmpty else { return }
        let rows = editorSelection
        mutateProgram { EcoProgramEditor.delete(rows, in: &$0) }
        let first = rows.min() ?? 0
        editorSelection = editorLines.indices.contains(first) ? [first] : (editorLines.isEmpty ? [] : [editorLines.count - 1])
    }

    /// Cola depois da seleção; dados referenciados que não existem são criados (com nome novo se o nome já for de outro valor).
    func pasteCommands() {
        guard let p = openProgram, !editClipboard.lines.isEmpty else { return }
        var lines = editClipboard.lines
        var renamed: [String] = []
        var newDecls: [(String, String, [String])] = []
        let existing = Dictionary(p.declarations.map { ($0.name.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var taken = Set(visibleDeclarations().map(\.decl.name))
        for text in editClipboard.decls {
            guard let d = EcoTalk.parseData(text).first else { continue }
            if let e = existing[d.name.uppercased()] {
                if e.type == d.type && e.args == d.args { continue }
                let prefix = String(d.name.prefix { !$0.isNumber })
                let new = EcoProgramEditor.nextFreeName(prefix: prefix.isEmpty ? d.name : prefix, taken: taken)
                taken.insert(new)
                let rx = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: d.name) + "\\b", options: .caseInsensitive)
                lines = lines.map { rx.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: new) }
                newDecls.append((new, d.type, d.args))
                renamed.append("\(d.name) → \(new)")
            } else {
                newDecls.append((d.name, d.type, d.args))
            }
        }
        // reindenta o bloco colado para o nível da linha de destino
        let after = editorSelection.max()
        let target = EcoProgramEditor.indent(after: after, in: p)
        let minIndent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        lines = lines.map { target + $0.dropFirst(min(minIndent, $0.prefix { $0 == " " }.count)) }
        var inserted: [Int] = []
        mutateProgram { prog in
            for (n, t, a) in newDecls { EcoProgramEditor.setDeclaration(name: n, type: t, args: a, in: &prog) }
            inserted = EcoProgramEditor.insert(lines, after: after, in: &prog)
        }
        editorSelection = Set(inserted)
        if !renamed.isEmpty { info("Colado com dados renomeados para não sobrescrever: " + renamed.joined(separator: ", ")) }
    }

    // MARK: Comentário / desativar / ordem

    func commentOutCommands() { let r = editorSelection; mutateProgram { EcoProgramEditor.commentOut(r, in: &$0) } }
    func commentInCommands() { let r = editorSelection; mutateProgram { EcoProgramEditor.commentIn(r, in: &$0) } }
    func setCommandsDisabled(_ d: Bool) { let r = editorSelection; mutateProgram { EcoProgramEditor.setDisabled(r, d, in: &$0) } }
    func reverseCommands() { let r = editorSelection; mutateProgram { EcoProgramEditor.reverse(r, in: &$0) } }

    func moveCommands(_ delta: Int) {
        var sel = editorSelection
        mutateProgram { sel = EcoProgramEditor.move(editorSelection, by: delta, in: &$0) }
        editorSelection = sel
    }

    func reindexPoints(prefix: String, start: Int) {
        let r = editorSelection
        var plan: [(String, String)] = []
        mutateProgram { plan = EcoProgramEditor.reindexPoints(r, prefix: prefix, start: start, in: &$0) }
        info(plan.isEmpty ? "Reindexar: nada a renomear" : "Pontos renomeados: " + plan.map { "\($0.0)→\($0.1)" }.joined(separator: ", "))
    }

    var canEnable: Bool { selectedLines.contains { $0.isDisabled } }
    var canDisable: Bool { selectedLines.contains { EcoProgramEditor.canDisable($0) && !$0.isDisabled } }
    var canCommentIn: Bool { selectedLines.contains { $0.kind == .comment } }
    var canCommentOut: Bool { selectedLines.contains { $0.kind == .command } }

    // MARK: Subprogramas

    /// CALL selecionado → programa chamado
    var selectedCallee: EcoTalkProgram? {
        guard editorSelection.count == 1, let l = selectedLines.first, l.kind == .command, l.name == "CALL",
              let name = l.args.first else { return nil }
        return openProject?.programs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func openSelectedSubprogram(simulate: Bool = false) {
        guard let callee = selectedCallee, let owner = openProgramOwner else { return }
        if openProgramDirty { warn("Salve \(openProgram?.name ?? "") antes de trocar de programa: as alterações seriam descartadas"); return }
        open(program: callee.url.path, robot: owner.id)
        selection = .program(owner.id, callee.url.path)
        if simulate { loadOpenProgramForSimulation(); play() }
    }

    // MARK: Pontos

    /// SETTOOL/SETOBJECT em vigor numa linha: da última simulação do programa da estação, ou rodando o próprio programa.
    func frameContext(line: Int) -> EcoFrameContext { frameContexts(lines: [line])[line] ?? EcoFrameContext() }

    /// O mesmo para várias linhas, rodando o programa uma vez só.
    func frameContexts(lines: [Int]) -> [Int: EcoFrameContext] {
        guard let p = openProgram, let owner = openProgramOwner, let bk = owner.backup, let proj = openProject else { return [:] }
        let interp = EcoTalkInterpreter(project: proj, systemData: bk.systemData, robot: owner.model)
        var runs: [EcoTalkRunResult] = []
        if let url = simulationProgramURL(for: owner.id), let src = proj.programs.first(where: { $0.url == url }), src.url != p.url {
            runs.append(interp.run(src.name))
        }
        runs.append(interp.run(p.name))
        var out: [Int: EcoFrameContext] = [:]
        for line in lines {
            search: for r in runs {
                for l in stride(from: line, through: 1, by: -1) {
                    if let f = r.frames[EcoTalkRunResult.frameKey(program: p.name, line: l)] { out[line] = f; break search }
                }
            }
        }
        return out
    }

    /// Valores de um POINT na posição atual do robô dono do programa, no modo pedido (Axis/World/Object).
    func currentPointArgs(mode: String, line: Int, keepAux: [String] = []) -> [String] {
        guard let owner = openProgramOwner else { return [] }
        let j = owner.joints
        let f = EcoProgramEditor.formatNumber
        let aux = keepAux.count >= 2 ? keepAux : ["0", "0"]
        switch mode.lowercased() {
        case "axis":
            return ["Axis"] + j.q.prefix(6).map(f) + [f(j.rail)] + aux
        default:
            let ctx = frameContext(line: line)
            var m = owner.model; m.tool = ctx.tool
            let world = Kinematics.tcp(m, j)
            let pose = mode.lowercased() == "world" ? Pose(matrix: world) : Pose(matrix: ctx.object.matrix.inverse * world)
            let name = mode.lowercased() == "world" ? "World" : "Object"
            return [name] + [pose.x, pose.y, pose.z, pose.a, pose.b, pose.c].map(f) + [f(j.rail)] + aux
        }
    }

    /// POINT alvo de uma linha (último ponto local referenciado: PTP(P1), GUN(…, PT10, TR10), CIRC(aux, alvo)).
    func targetPoint(of line: EcoProgramLine) -> EcoTalkDeclaration? {
        guard let p = openProgram, line.kind == .command else { return nil }
        let points = visibleDeclarations(type: "POINT").map(\.decl)
        let refs = EcoProgramEditor.references(line, declared: Set(points.map(\.name)))
        guard let name = refs.last else { return nil }
        return p.declarations.first { $0.name == name } ?? points.first { $0.name == name }
    }

    var canModify: Bool { selectedLines.contains { l in targetPoint(of: l).map { d in openProgram?.declarations.contains { $0.name == d.name } ?? false } ?? false } }

    /// "Modificar": grava a posição atual do robô no ponto dos comandos selecionados, mantendo o modo (Axis/Object/World).
    func modifyPoints() {
        guard let owner = openProgramOwner else { return }
        var done: [String] = []
        let targets = selectedLines.compactMap { l -> (EcoTalkDeclaration, Int)? in
            guard let d = targetPoint(of: l), openProgram?.declarations.contains(where: { $0.name == d.name }) ?? false else { return nil }
            return (d, l.lineNumber)
        }
        mutateProgram { prog in
            for (d, line) in targets where !done.contains(d.name) {
                let mode = d.args.first ?? "Object"
                let aux = d.args.count >= 10 ? Array(d.args[8...9]) : []
                EcoProgramEditor.setDeclaration(name: d.name, type: d.type, args: currentPointArgs(mode: mode, line: line, keepAux: aux), in: &prog)
                done.append(d.name)
            }
        }
        if done.isEmpty { warn("Nenhum ponto local nos comandos selecionados") }
        else { info("Posição atual de \(owner.name) gravada em: " + done.joined(separator: ", ")) }
    }

    /// Leva o robô dono até o ponto do comando selecionado (para conferir antes de Modificar).
    func moveRobotToSelectedPoint() {
        guard let l = selectedLines.first(where: { targetPoint(of: $0) != nil }), let d = targetPoint(of: l),
              let i = robots.firstIndex(where: { $0.id == openProgramOwner?.id }) else { return }
        let v = d.numbers
        guard v.count >= 6 else { return }
        let rail = v.count > 6 ? v[6] : robots[i].joints.rail
        var state: JointState
        if (d.args.first ?? "").lowercased() == "axis" {
            state = JointState(rail: rail, q: Array(v[0..<6]))
        } else {
            let ctx = frameContext(line: l.lineNumber)
            var m = robots[i].model; m.tool = ctx.tool
            let local = Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5])
            let world = (d.args.first ?? "").lowercased() == "world" ? local : Pose(matrix: ctx.object.matrix * local.matrix)
            var seed = robots[i].joints; seed.rail = rail
            let ik = Kinematics.inverse(m, target: world, seed: seed)
            state = ik.state
            if !ik.converged { warn("\(d.name): posição fora de alcance (aproximação mostrada)") }
        }
        stop()
        if robots[i].id != activeRobotID {
            robots[i].joints = state
            scene.updateRobot(robots[i])
        } else {
            joints = state
        }
        info("\(robots[i].name) em \(d.name)")
    }

    // MARK: Inserir / editar comando

    func insertCommand(_ name: String) {
        guard canEditProgram else { return }
        commandEdit = CommandEditRequest(name: name, line: nil, after: editorSelection.max())
    }

    func editSelectedCommand() {
        guard let l = selectedLines.first, l.kind != .blank else { return }
        commandEdit = CommandEditRequest(name: l.name, line: l.index, after: nil)
    }

    /// Grava o comando do diálogo (novos dados primeiro, como o DXQ faz ao criar pontos/trigger frames).
    func applyCommand(_ req: CommandEditRequest, text: String, newDeclarations: [(name: String, type: String, args: [String])]) {
        guard let p = openProgram else { return }
        var selected: Set<Int> = []
        mutateProgram { prog in
            for d in newDeclarations { EcoProgramEditor.setDeclaration(name: d.name, type: d.type, args: d.args, in: &prog) }
            if let row = req.line {
                let old = EcoProgramEditor.lines(p)[row]
                let comment = old.trailingComment.map { " //" + $0 } ?? ""
                EcoProgramEditor.replace(row, with: old.indent + (old.isDisabled ? "##" : "") + text + comment, in: &prog)
                selected = [row]
            } else {
                let indent = EcoProgramEditor.indent(after: req.after, in: prog)
                let parsed = EcoProgramLine.parse(text, index: 0)
                let block = EcoProgramEditor.insertion(name: parsed.name, args: parsed.args, indent: indent)
                let lines = ["IF", "WHILE", "LOOP"].contains(parsed.name) ? block : [indent + text]
                selected = [EcoProgramEditor.insert(lines, after: req.after, in: &prog).first ?? 0]
            }
        }
        editorSelection = selected
    }

    // MARK: Dados

    func referencesCount(_ name: String) -> Int {
        editorLines.filter { $0.kind == .command && EcoProgramEditor.references($0, declared: [name]).contains(name) }.count
    }

    func applyDeclaration(oldName: String?, name: String, type: String, args: [String]) {
        mutateProgram { prog in
            if let old = oldName, old != name { EcoProgramEditor.rename(old, to: name, in: &prog) }
            EcoProgramEditor.setDeclaration(name: name, type: type, args: args, in: &prog)
        }
    }

    func removeDeclaration(_ name: String) {
        mutateProgram { EcoProgramEditor.removeDeclaration(name, in: &$0) }
    }

    /// Valores padrão de um bloco do system.ttu (ex.: TRIGGERFRAME → Object, 0, 0, 0, 0).
    func defaultArgs(type: String) -> [String] {
        if let b = openSystem.blocks[type.uppercased()] {
            return b.fields.map { f in
                if let d = f.defaultValue { return d }
                if let e = openSystem.enums[f.type]?.first { return e }
                return f.type == "BOOL" ? "FALSE" : "0"
            }
        }
        return ["0"]
    }

    func newDeclarationName(type: String) -> String {
        guard let p = openProgram else { return "New1" }
        let prefix = EcoProgramEditor.prefix(for: type, in: p, fallback: openSystem.defaultPrefix(for: type))
        return EcoProgramEditor.nextFreeName(prefix: prefix, taken: Set(visibleDeclarations().map(\.decl.name)))
    }
}
