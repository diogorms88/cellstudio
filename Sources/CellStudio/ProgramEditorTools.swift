import CellCore
import Foundation
import simd

/// Diálogos das guias do DXQ (Editor de programa, Ferramentas do editor, Vista 3D, Objetos 3D) e do explorador.
enum DXQSheet: Identifiable {
    case frameTransfer(kind: String)              // "OBJECT" (Objeto-Objeto) ou "TOOL" (Ferramenta-Ferramenta)
    case correctZero
    case mirrorTransfer
    case smoothOrientation
    case rename(url: URL, robot: UUID, isProject: Bool)
    case replaceText(project: URL, robot: UUID)
    case compare(url: URL, robot: UUID)
    case unusedPrograms(robot: UUID)
    case newItem(parent: URL, robot: UUID, isProject: Bool)
    case objectPlacement(part: UUID)
    case rotateObject(part: UUID)

    var id: String {
        switch self {
        case .frameTransfer(let k): return "frame-\(k)"
        case .correctZero: return "zero"
        case .mirrorTransfer: return "mirror"
        case .smoothOrientation: return "smooth"
        case .rename(let u, _, _): return "rename-\(u.path)"
        case .replaceText(let u, _): return "replace-\(u.path)"
        case .compare(let u, _): return "compare-\(u.path)"
        case .unusedPrograms(let r): return "unused-\(r)"
        case .newItem(let u, _, let p): return "new-\(p)-\(u.path)"
        case .objectPlacement(let p): return "place-\(p)"
        case .rotateObject(let p): return "rotobj-\(p)"
        }
    }
}

/// Guias "Editor de programa" e "Ferramentas do editor" do DXQ (ProgramEditorViewModel / EsProgramEditor).
extension AppState {
    // MARK: Vista do editor

    /// "Abrir todos os subprogramas": abre em abas os módulos chamados (CALL) pelo módulo aberto.
    func openAllSubmodules() {
        guard let p = openProgram, let owner = openProgramOwner, let proj = openProject else { return }
        let callees = editorLines.filter { $0.kind == .command && !$0.isDisabled && $0.name == "CALL" }.compactMap { $0.args.first }
        var opened: [String] = []
        for name in callees where !opened.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            if let g = proj.programs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                showTab(g, robot: owner.id); opened.append(g.name)
            }
        }
        showTab(p, robot: owner.id)
        info(opened.isEmpty ? "\(p.name) não chama subprogramas" : "Subprogramas abertos: " + opened.joined(separator: ", "))
    }

    // MARK: Ferramentas

    /// "Arrumar" (CleanUpProgramDeclarationScope): remove do .tid os dados que nenhum comando usa.
    func cleanupDeclarations() {
        guard let p = openProgram else { return }
        let names = Set(p.declarations.map(\.name))
        var used = Set<String>()
        for l in editorLines where l.kind == .command { used.formUnion(EcoProgramEditor.references(l, declared: names).map { $0.uppercased() }) }
        let unused = p.declarations.filter { !used.contains($0.name.uppercased()) }.map(\.name)
        guard !unused.isEmpty else { info("Arrumar: todos os dados de \(p.name) são usados"); return }
        mutateProgram { prog in for n in unused { EcoProgramEditor.removeDeclaration(n, in: &prog) } }
        info("Arrumar: \(unused.count) dado(s) sem uso removido(s) de \(p.name) – " + unused.joined(separator: ", "))
    }

    /// "Verificar" / "Verificar todos" / "Verificar programa(s)": roda os programas e lista avisos e comandos desconhecidos.
    func checkPrograms(_ programs: [EcoTalkProgram], project: EcoTalkProject, robot slot: RobotSlot) {
        guard let bk = slot.backup else { return }
        var proj = project
        if let op = openProgram, let i = proj.programs.firstIndex(where: { $0.url == op.url }) { proj.programs[i] = op }
        let interp = EcoTalkInterpreter(project: proj, systemData: bk.systemData, robot: slot.model)
        let keywords: Set<String> = ["IF", "ELSIF", "ELSE", "END_IF", "WHILE", "END_WHILE", "LOOP", "END_LOOP", "LABEL", "GOTO", "RETURN",
                                     "RSELECT", "RDESELECT", "CALL", "//"]
        let routines = bk.system?.routines ?? [:]
        var total = 0
        for g in programs {
            let prog = proj.programs.first { $0.url == g.url } ?? g
            var problems: [String] = []
            if !routines.isEmpty {
                for l in EcoProgramEditor.lines(prog) where l.kind == .command && !l.isDisabled && !l.text.contains(":=") {
                    let n = l.name.uppercased()
                    if !keywords.contains(n), routines[n] == nil, n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        problems.append("linha \(l.lineNumber + 0): comando desconhecido \(l.name)")
                    }
                }
            }
            problems += interp.run(prog.name).messages
            total += problems.count
            if problems.isEmpty { post(.info, "Verificar \(prog.name): sem erros", robot: slot.name) }
            for m in problems { post(.warning, "Verificar \(prog.name): \(m)", robot: slot.name) }
        }
        if programs.count > 1 { info("Verificação de \(programs.count) programas: \(total) aviso(s)") }
    }

    func checkOpenProgram() {
        guard let p = openProgram, let proj = openProject, let owner = openProgramOwner else { return }
        checkPrograms([p], project: proj, robot: owner)
    }

    func checkAllProgramsOfProject() {
        guard let proj = openProject, let owner = openProgramOwner else { return }
        checkPrograms(proj.programs, project: proj, robot: owner)
    }

    /// "Renomear e renumerar todos os pontos": seleciona tudo e abre o diálogo de reindexar.
    func renumberAllPoints() {
        selectAllCommands()
        showReindex = true
    }

    /// Valores (X,Y,Z,A,B,C) de um TOOL/OBJECT visível no programa.
    func framePose(type: String, name: String) -> Pose? {
        guard let d = visibleDeclarations(type: type).map(\.decl).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        let v = d.numbers
        guard v.count >= 6 else { return nil }
        return Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5])
    }

    /// Nomes de TOOL/OBJECT usados em SETTOOL/SETOBJECT do módulo (e o que vem do Main, se nenhum).
    func framesUsed(kind: String) -> [String] {
        let cmd = kind == "TOOL" ? "SETTOOL" : "SETOBJECT"
        var names: [String] = []
        for l in editorLines where l.kind == .command && !l.isDisabled && l.name == cmd {
            if let a = l.args.first, !names.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) { names.append(a) }
        }
        if names.isEmpty {
            let f = frameContext(line: editorLines.last?.lineNumber ?? 1)
            names.append(kind == "TOOL" ? f.toolName : f.objectName)
        }
        return names
    }

    /// "Objeto-Objeto" / "Ferramenta-Ferramenta" (EcoTalkProgram.ConvertFrameToFrame): troca o SETOBJECT/SETTOOL
    /// e reescreve os pontos para que fiquem no mesmo lugar (objeto) ou o robô faça o mesmo movimento (ferramenta).
    /// `newValues` cria um dado novo no .tid quando o nome ainda não existe.
    func transferFrame(kind: String, old: String, new: String, newValues: Pose?) {
        guard let p = openProgram else { return }
        let isTool = kind == "TOOL"
        let cmd = isTool ? "SETTOOL" : "SETOBJECT"
        guard let oldPose = framePose(type: kind, name: old) ?? (old.uppercased().hasSuffix("_ZERO") ? Pose() : nil) else {
            warn("\(old): \(kind) não encontrado"); return
        }
        let newPose = newValues ?? framePose(type: kind, name: new)
        guard let newPose else { warn("\(new): \(kind) não encontrado"); return }
        let lines = editorLines
        let local = p.declarations.filter { $0.type.uppercased() == "POINT" }
        let localNames = Set(local.map(\.name))
        let ctx = frameContexts(lines: lines.filter { $0.kind == .command }.map(\.lineNumber))
        var converted = Set<String>(), skipped: [String] = []
        var replaced = 0
        mutateProgram { prog in
            if let v = newValues, framePose(type: kind, name: new) == nil {
                EcoProgramEditor.setDeclaration(name: new, type: kind,
                                                args: [v.x, v.y, v.z, v.a, v.b, v.c].map(EcoProgramEditor.formatNumber), in: &prog)
            }
            for l in lines where l.kind == .command {
                if l.name == cmd, let a = l.args.first, a.caseInsensitiveCompare(old) == .orderedSame {
                    EcoProgramEditor.replace(l.index, with: l.indent + EcoProgramEditor.format(name: cmd, args: [new]), in: &prog)
                    replaced += 1
                    continue
                }
                guard let f = ctx[l.lineNumber] else { continue }
                let current = isTool ? f.toolName : f.objectName
                guard current.caseInsensitiveCompare(old) == .orderedSame else { continue }
                for n in EcoProgramEditor.references(l, declared: localNames) where !converted.contains(n) {
                    guard let d = local.first(where: { $0.name == n }), let rec = PointRecord(args: d.args) else { continue }
                    let out = isTool ? PointTransform.changeTool(rec, from: oldPose, to: newPose) : PointTransform.changeObject(rec, from: oldPose, to: newPose)
                    if let out { EcoProgramEditor.setDeclaration(name: n, type: d.type, args: out.args, in: &prog); converted.insert(n) }
                    else { skipped.append(n) }
                }
            }
            // o módulo herdava o objeto/ferramenta de quem chama: põe o SET… novo depois do RSELECT (como o DXQ)
            if replaced == 0, !converted.isEmpty {
                let ls = EcoProgramEditor.lines(prog)
                let after = ls.first(where: { $0.kind == .command && $0.name == "RSELECT" })?.index
                _ = EcoProgramEditor.insert([EcoProgramEditor.indent(after: after, in: prog) + EcoProgramEditor.format(name: cmd, args: [new])], after: after, in: &prog)
            }
        }
        previewModule()
        info("\(isTool ? "Ferramenta-Ferramenta" : "Objeto-Objeto") \(old) → \(new): \(replaced) \(cmd) trocado(s), \(converted.count) ponto(s) recalculado(s)"
             + (skipped.isEmpty ? "" : " – mantidos (tipo Axis\(isTool ? "" : "/World")): " + Set(skipped).sorted().joined(separator: ", ")))
    }

    /// "Correção da posição zero" (CorrectZeroPositionService): desloca todos os pontos Object do módulo pelo delta.
    func correctZeroPosition(_ delta: Pose) {
        guard let p = openProgram else { return }
        var n = 0
        mutateProgram { prog in
            for d in p.declarations where d.type.uppercased() == "POINT" {
                guard let rec = PointRecord(args: d.args), let out = PointTransform.correctZero(rec, delta: delta) else { continue }
                EcoProgramEditor.setDeclaration(name: d.name, type: d.type, args: out.args, in: &prog); n += 1
            }
        }
        previewModule()
        info("Correção da posição zero: \(n) ponto(s) Object deslocado(s)")
    }

    /// "Espelhar/Transferir": espelha todos os pontos do módulo num plano do objeto. Com `target`, grava uma cópia
    /// espelhada no projeto de mesmo nome do outro robô (o módulo original não muda).
    func mirrorTransfer(plane: MirrorPlane, offset: Double, target: UUID?) {
        guard let p = openProgram, let owner = openProgramOwner else { return }
        let all = p.declarations.filter { $0.type.uppercased() == "POINT" }
        let names = Set(all.map(\.name))
        var lineOf: [String: Int] = [:]
        for l in editorLines where l.kind == .command {
            for n in EcoProgramEditor.references(l, declared: names) where lineOf[n] == nil { lineOf[n] = l.lineNumber }
        }
        let frames = frameContexts(lines: Array(Set(lineOf.values)))
        var mirrored = p, n = 0, axis: [String] = []
        for d in all {
            guard let rec = PointRecord(args: d.args) else { continue }
            let f = lineOf[d.name].flatMap { frames[$0] } ?? EcoFrameContext()
            var m = owner.model; m.tool = f.tool
            switch PointTransform.mirror(rec, plane: plane, offset: offset, PointContext(robot: m, object: f.object, seed: owner.joints)) {
            case .success(let r): EcoProgramEditor.setDeclaration(name: d.name, type: d.type, args: r.args, in: &mirrored); n += 1
            case .failure: axis.append(d.name)
            }
        }
        let note = axis.isEmpty ? "" : " – pontos Axis mantidos: " + axis.joined(separator: ", ")
        guard let target, target != owner.id, let ti = robots.firstIndex(where: { $0.id == target }), let tbk = robots[ti].backup else {
            mutateProgram { $0 = mirrored }
            previewModule()
            info("Espelhar no plano \(plane.rawValue) (\(EcoProgramEditor.formatNumber(offset)) mm): \(n) ponto(s)" + note)
            return
        }
        let projName = p.url.deletingLastPathComponent().lastPathComponent
        let dir = tbk.projects.first(where: { $0.url.lastPathComponent.caseInsensitiveCompare(projName) == .orderedSame })?.url
            ?? (tbk.kinDir ?? tbk.projects.first?.url.deletingLastPathComponent())?.appendingPathComponent(projName)
        guard let dir else { warn("\(robots[ti].name): pasta de projetos não encontrada"); return }
        let dest = dir.appendingPathComponent(p.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            guard Dialogs.confirm("Substituir \(p.name) em \(robots[ti].name)?", "\(dest.path) já existe. O arquivo atual vai para a Lixeira.",
                                  ok: "Substituir") else { return }
            for u in [dest, dest.deletingPathExtension().appendingPathExtension("tid")] where FileManager.default.fileExists(atPath: u.path) {
                try? FileManager.default.discard(u)
            }
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var copy = mirrored
            copy.url = dest
            // RSELECT/RDESELECT do robô de destino
            copy.source = copy.source.replacingOccurrences(of: "\"\(owner.name)\"", with: "\"\(robots[ti].name)\"")
            try copy.save()
        } catch { self.error("Espelhar/Transferir: \(error.localizedDescription)"); return }
        refreshBackup(robots[ti].id)
        info("Espelhar/Transferir: \(p.name) espelhado no plano \(plane.rawValue) e gravado em \(robots[ti].name)/\(projName) (\(n) pontos)" + note)
    }

    /// "Suavizar orientação…" (modo linear do DXQ): pontos selecionados entre o primeiro e o último.
    func smoothSelectedOrientation() {
        let targets = selectedPointTargets
        let recs = targets.compactMap { t in PointRecord(args: t.decl.args).map { (t, $0) } }.filter { !$0.1.isAxis }
        guard recs.count > 2 else { warn("Suavizar orientação: selecione pelo menos 3 pontos World/Object"); return }
        let smoothed = PointTransform.smoothOrientations(recs.map(\.1.pose))
        mutateProgram { prog in
            for (i, (t, rec)) in recs.enumerated() {
                let out = PointTransform.withPose(rec, smoothed[i].matrix)
                EcoProgramEditor.setDeclaration(name: t.decl.name, type: t.decl.type, args: out.args, in: &prog)
            }
        }
        previewModule()
        info("Orientação suavizada em \(recs.count) pontos (\(recs.first!.0.decl.name) → \(recs.last!.0.decl.name))")
    }

    /// "Copiar diferença de orientação": rotação (no mundo) do primeiro para o último ponto selecionado.
    func copyOrientationDelta() {
        let targets = selectedPointTargets
        guard targets.count >= 2, let a = worldRotation(targets.first!), let b = worldRotation(targets.last!) else {
            warn("Copiar diferença de orientação: selecione dois pontos"); return
        }
        orientationDeltaClipboard = b * a.transpose
        info("Diferença de orientação \(targets.first!.decl.name) → \(targets.last!.decl.name) copiada")
    }

    func pasteOrientationDelta() {
        guard let d = orientationDeltaClipboard else { return }
        let rotations = Dictionary(uniqueKeysWithValues: selectedPointTargets.compactMap { t in worldRotation(t).map { (t.decl.name, $0) } })
        transformSelectedPoints("Colar diferença de orientação") { rec, ctx in
            let r = PointTransform.world(rec, ctx).rotation
            return PointTransform.setOrientation(rec, world: d * r, ctx)
        }
        _ = rotations
    }

    private func worldRotation(_ t: PointTarget) -> simd_double3x3? {
        guard let rec = PointRecord(args: t.decl.args), let owner = openProgramOwner else { return nil }
        let f = frameContext(line: t.line)
        var m = owner.model; m.tool = f.tool
        return PointTransform.world(rec, PointContext(robot: m, object: f.object, seed: owner.joints)).rotation
    }

    /// Recarrega do disco o backup de um robô sem trocar o robô na estação (abas e seleção continuam).
    func refreshBackup(_ id: UUID) {
        guard let i = robots.firstIndex(where: { $0.id == id }), let root = robots[i].backup?.root,
              let bk = try? RobotBackup.load(root) else { return }
        robots[i].backup = bk
        objectWillChange.send()
    }

    // MARK: Vista 3D

    /// "Medir distância": dois cliques na geometria; o terceiro começa de novo.
    func measureClick(at p: CGPoint) {
        guard let q = scene.surfacePoint(at: p) else { return }
        if measurePoints.count >= 2 { measurePoints = [] }
        measurePoints.append(q)
        scene.showMeasurement(measurePoints)
        if measurePoints.count == 2 {
            let d = measurePoints[1] - measurePoints[0]
            info(String(format: "Distância: %.1f mm (ΔX %.1f, ΔY %.1f, ΔZ %.1f)", simd_length(d), d.x, d.y, d.z))
        }
    }

    /// Modo de renderização de robô / trilho / ferramenta / peças / célula (guias Objetos 3D e Vista 3D).
    func setRenderMode(_ key: String, _ mode: RenderMode) {
        renderModes[key] = mode
        switch key {
        case "robot": scene.apply(mode, to: scene.nodes(for: .robot))
        case "rail": scene.apply(mode, to: scene.nodes(for: .rail))
        case "tool": scene.apply(mode, to: scene.nodes(for: .tool))
        case "workpiece": scene.apply(mode, to: parts.filter(\.isPaintTarget).compactMap { scene.partNode($0.id) })
        case "cell": scene.apply(mode, to: parts.filter { !$0.isPaintTarget }.compactMap { scene.partNode($0.id) })
        default: scene.apply(mode, to: scene.nodes(for: .robot) + scene.nodes(for: .rail) + scene.nodes(for: .tool) + parts.compactMap { scene.partNode($0.id) })
        }
    }

    /// "Imprimir": imprime a imagem da Vista 3D.
    func printView() {
        guard let img = scene.snapshotImage() else { return }
        Platform.printImage(img)
    }
}
