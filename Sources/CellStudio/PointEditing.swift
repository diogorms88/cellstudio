import CellCore
import Foundation
import simd

/// Diálogos da guia Transformação.
enum PointToolSheet: String, Identifiable {
    case values, rotate, mirror, distance
    var id: String { rawValue }
}

/// Edição dos pontos selecionados no editor, como a guia "Transformation" do DXQ (StartTabTransformationViewModel):
/// deslocar/girar por passo em Mundo, Objeto, Ferramenta ou Eixos, valores informados, restaurar, converter tipo,
/// copiar/colar orientação e E1, girar em torno de vetor, espelhar e distância entre pontos.
/// Só os pontos locais do módulo (no .tid dele) são alterados; o tipo do ponto (Axis/World/Object) é mantido.
extension AppState {
    struct PointTarget {
        var decl: EcoTalkDeclaration
        var line: Int
    }

    /// POINTs locais usados pelos comandos selecionados, na ordem do programa (cada um uma vez).
    var selectedPointTargets: [PointTarget] {
        guard let p = openProgram else { return [] }
        let local = p.declarations.filter { $0.type.uppercased() == "POINT" }
        let names = Set(local.map(\.name))
        var seen = Set<String>(), out: [PointTarget] = []
        for l in selectedLines where l.kind == .command {
            for n in EcoProgramEditor.references(l, declared: names) where seen.insert(n.uppercased()).inserted {
                if let d = local.first(where: { $0.name == n }) { out.append(PointTarget(decl: d, line: l.lineNumber)) }
            }
        }
        return out
    }

    /// Contexto de cada ponto: ferramenta e objeto em vigor na linha, robô dono e semente da inversa.
    private func pointContexts(_ targets: [PointTarget]) -> [String: PointContext] {
        guard let owner = openProgramOwner else { return [:] }
        let frames = frameContexts(lines: targets.map(\.line))
        var out: [String: PointContext] = [:]
        for t in targets {
            let f = frames[t.line] ?? EcoFrameContext()
            var m = owner.model
            m.tool = f.tool
            out[t.decl.name] = PointContext(robot: m, object: f.object, seed: owner.joints)
        }
        return out
    }

    /// Aplica `f` em cada ponto selecionado (uma entrada no desfazer), atualiza o caminho no 3D e leva o robô ao último ponto.
    func transformSelectedPoints(_ what: String, quiet: Bool = false,
                                 _ f: (PointRecord, PointContext) -> Result<PointRecord, PointTransform.Failure>) {
        let targets = selectedPointTargets
        guard !targets.isEmpty else { warn("Selecione no editor os comandos com os pontos a transformar"); return }
        rememberPointsForReset(targets)
        let ctx = pointContexts(targets)
        var failed: [String] = [], axisSkipped: [String] = [], changed = 0
        mutateProgram { prog in
            for t in targets {
                guard let rec = PointRecord(args: t.decl.args), let c = ctx[t.decl.name] else { failed.append(t.decl.name); continue }
                switch f(rec, c) {
                case .success(let r):
                    EcoProgramEditor.setDeclaration(name: t.decl.name, type: t.decl.type, args: r.args, in: &prog)
                    changed += 1
                case .failure(.axisNotSupported): axisSkipped.append(t.decl.name)
                case .failure(.unreachable): failed.append(t.decl.name)
                }
            }
        }
        if !failed.isEmpty { warn("\(what): fora de alcance, não alterados – " + failed.joined(separator: ", ")) }
        if !axisSkipped.isEmpty { warn("\(what): só vale para pontos World/Object – pontos Axis mantidos: " + axisSkipped.joined(separator: ", ")) }
        guard changed > 0 else { return }
        previewModule()
        showRobotAtPoint(targets.last!)
        if !quiet { info("\(what): \(changed) ponto(s) – " + targets.map(\.decl.name).joined(separator: ", ")) }
    }

    /// Guarda as coordenadas originais na primeira transformação da seleção atual.
    private func rememberPointsForReset(_ targets: [PointTarget]) {
        if pointResetKey.url != openProgram?.url || pointResetKey.selection != editorSelection {
            pointResetSnapshot = [:]
            pointResetKey = (openProgram?.url, editorSelection)
        }
        for t in targets where pointResetSnapshot[t.decl.name] == nil { pointResetSnapshot[t.decl.name] = t.decl.args }
    }

    var canResetPoints: Bool {
        !pointResetSnapshot.isEmpty && pointResetKey.url == openProgram?.url && pointResetKey.selection == editorSelection
    }

    /// "Reset point coordinates": volta os pontos ao que eram antes das transformações desta seleção.
    func resetPointCoordinates() {
        guard canResetPoints, let p = openProgram else { return }
        let snap = pointResetSnapshot
        mutateProgram { prog in
            for d in p.declarations where snap[d.name] != nil {
                EcoProgramEditor.setDeclaration(name: d.name, type: d.type, args: snap[d.name]!, in: &prog)
            }
        }
        pointResetSnapshot = [:]
        previewModule()
        if let last = selectedPointTargets.last { showRobotAtPoint(last) }
        info("Coordenadas restauradas: " + snap.keys.sorted().joined(separator: ", "))
    }

    /// Botão +/− da guia: `index` 0…5 = X,Y,Z,A,B,C (ou A1…A6 em Eixos), 6 = E1.
    func jogSelectedPoints(index: Int, sign: Double) {
        var off = PointOffset()
        let names: [String]
        if index == 6 {
            off.rail = sign * pointStepMm
        } else if pointSystem == .joint {
            off.joints[index] = sign * pointStepDeg
        } else {
            let v = sign * (index < 3 ? pointStepMm : pointStepDeg)
            switch index {
            case 0: off.pose.x = v
            case 1: off.pose.y = v
            case 2: off.pose.z = v
            case 3: off.pose.a = v
            case 4: off.pose.b = v
            default: off.pose.c = v
            }
        }
        names = pointSystem == .joint ? ["A1", "A2", "A3", "A4", "A5", "A6", "E1"] : ["X", "Y", "Z", "A", "B", "C", "E1"]
        let sys = pointSystem
        transformSelectedPoints("\(sign > 0 ? "+" : "−")\(names[index]) em \(sys.rawValue)", quiet: true) { PointTransform.shift($0, by: off, in: sys, $1) }
    }

    /// "Modify selected commands": desloca pelos valores informados no sistema escolhido.
    func applyPointOffset(_ off: PointOffset, in sys: PointCoordSystem) {
        transformSelectedPoints("Modificar em \(sys.rawValue)") { PointTransform.shift($0, by: off, in: sys, $1) }
    }

    func convertSelectedPoints(to mode: String) {
        transformSelectedPoints("Converter para \(mode)") { PointTransform.convert($0, to: mode, $1) }
    }

    func rotateSelectedPoints(start: Vec3, end: Vec3, angle: Double) {
        transformSelectedPoints(String(format: "Girar %.1f° em torno do vetor", angle)) { PointTransform.rotate($0, start: start, end: end, angle: angle, $1) }
    }

    func mirrorSelectedPoints(plane: MirrorPlane, offset: Double) {
        transformSelectedPoints("Espelhar no plano \(plane.rawValue)") { PointTransform.mirror($0, plane: plane, offset: offset, $1) }
    }

    /// Copia a orientação (no mundo) do último ponto selecionado.
    func copyPointOrientation() {
        guard let t = selectedPointTargets.last, let rec = PointRecord(args: t.decl.args), let c = pointContexts([t])[t.decl.name] else { return }
        orientationClipboard = PointTransform.world(rec, c).rotation
        info("Orientação de \(t.decl.name) copiada")
    }

    func pastePointOrientation() {
        guard let r = orientationClipboard else { return }
        transformSelectedPoints("Colar orientação") { PointTransform.setOrientation($0, world: r, $1) }
    }

    func copyPointRail() {
        guard let t = selectedPointTargets.last, let rec = PointRecord(args: t.decl.args) else { return }
        railClipboard = rec.rail
        info("E1 de \(t.decl.name) copiado: \(EcoProgramEditor.formatNumber(rec.rail)) mm")
    }

    func pastePointRail() {
        guard let v = railClipboard else { return }
        transformSelectedPoints("Colar E1") { rec, _ in var r = rec; r.rail = v; return .success(r) }
    }

    /// Posição de cada ponto selecionado no mundo e no objeto (para a distância e os padrões dos diálogos).
    func selectedPointPositions() -> [(name: String, world: Vec3, object: Vec3)] {
        let targets = selectedPointTargets
        let ctx = pointContexts(targets)
        return targets.compactMap { t in
            guard let rec = PointRecord(args: t.decl.args), let c = ctx[t.decl.name] else { return nil }
            let w = PointTransform.world(rec, c)
            return (t.decl.name, w.position, (c.object.matrix.inverse * w).position)
        }
    }

    /// Mostra o robô dono no ponto (sem mensagem), como o DXQ faz com o último ponto selecionado.
    private func showRobotAtPoint(_ t: PointTarget) {
        guard let i = robots.firstIndex(where: { $0.id == openProgramOwner?.id }),
              let d = openProgram?.declarations.first(where: { $0.name == t.decl.name }),
              let rec = PointRecord(args: d.args), let c = pointContexts([PointTarget(decl: d, line: t.line)])[d.name],
              let state = PointTransform.joints(rec, c) else { return }
        stop()
        if robots[i].id == activeRobotID { joints = state } else { robots[i].joints = state; scene.updateRobot(robots[i]) }
    }

    // MARK: Seleção no 3D

    /// Clique num ponto do caminho: seleciona no editor o comando que gerou o ponto (abre o módulo se for de outro).
    func selectPathPoint(entry: Int, index: Int, additive: Bool) {
        let target: (program: String, line: Int, robot: String)?
        if simulateAllRobots {
            guard simulationRuns.indices.contains(entry), simulationRuns[entry].origin.indices.contains(index),
                  let slot = robots.first(where: { $0.id == simulationRuns[entry].robotID }) else { return }
            let o = simulationRuns[entry].origin[index]
            target = (o.program, o.line, slot.name)
        } else {
            guard origin.indices.contains(index) else { return }
            target = (origin[index].program, origin[index].line, openProgramOwner?.name ?? robot.name)
        }
        guard let t = target, t.line > 0 else { return }
        let same = openProgram.map { $0.name.caseInsensitiveCompare(t.program) == .orderedSame } ?? false
        if !same || (simulateAllRobots && openProgramOwner?.name != t.robot) {
            reveal(program: t.program, line: t.line, robot: t.robot)
            guard openProgram?.name.caseInsensitiveCompare(t.program) == .orderedSame else {
                info("Ponto de \(t.robot) em \(t.program):\(t.line)")
                return
            }
        }
        guard let l = editorLines.first(where: { $0.lineNumber == t.line }) else { return }
        if additive {
            if editorSelection.contains(l.index) { editorSelection.remove(l.index) } else { editorSelection.insert(l.index) }
        } else {
            editorSelection = [l.index]
        }
        highlightedLine = t.line
    }

    /// Pontos do caminho que vêm das linhas selecionadas no editor ficam amarelos no 3D.
    func syncPathSelection() {
        guard !simulateAllRobots, let p = openProgram else { scene.highlightPathPoints([]); return }
        let lines = Set(editorLines.filter { editorSelection.contains($0.index) }.map(\.lineNumber))
        guard !lines.isEmpty else { scene.highlightPathPoints([]); return }
        let idx = origin.indices.filter { origin[$0].program.caseInsensitiveCompare(p.name) == .orderedSame && lines.contains(origin[$0].line) }
        scene.highlightPathPoints(Set(idx))
    }
}
