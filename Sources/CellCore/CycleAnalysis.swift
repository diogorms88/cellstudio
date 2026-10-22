import Foundation
import simd

/// Alteração de uma linha de programa (aplicada pelo app, com desfazer).
public struct SourceEdit: Hashable {
    public enum Op: Hashable { case replace(String), insertBefore([String]), insertAfter([String]), delete, disable }
    public var robot: String
    public var program: String
    public var line: Int          // 1-based
    public var op: Op
    public init(robot: String, program: String, line: Int, op: Op) { self.robot = robot; self.program = program; self.line = line; self.op = op }
}

/// Ponto de um robô no momento do risco (para abrir no editor).
public struct RiskPoint: Identifiable, Hashable {
    public var id: String { robot }
    public var robot: String
    public var program: String
    public var line: Int
    public var point: String
    public var time: Double
}

public struct AnalysisSuggestion: Identifiable {
    public enum Kind: String {
        case reversePass = "Inverter sentido da passada"
        case linToPtp = "Movimento no ar: LIN → PTP"
        case removeAirPoint = "Ponto no ar desnecessário"
        case releaseBitEarlier = "Liberar bit de colisão mais cedo"
        case protectRegion = "Proteger região com bit de colisão"
        case adjustBit = "Ajustar bit de colisão existente"
        case notice = "Aviso da análise"
        case claude = "Sugestão do Claude"
    }
    public enum Severity: Int, Comparable {
        case critical, risk, improvement, info
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public let id = UUID()
    public var kind: Kind
    public var severity: Severity
    public var robot: String
    public var title: String
    public var detail: String
    /// ganho estimado de tempo (s), simulando o trecho antes e depois
    public var gain: Double?
    public var program: String
    public var line: Int
    public var time: Double
    public var edits: [SourceEdit] = []
    public var applicable: Bool { !edits.isEmpty && manualReason == nil }
    public var manualReason: String?
    /// folga mínima até a carroceria no trecho alterado (mm)
    public var bodyClearance: Double?
    /// caminho atual e proposto (TCP, mm na estação) para a Vista 3D
    public var currentPath: [SIMD3<Double>] = []
    public var proposedPath: [SIMD3<Double>] = []
    /// para mostrar um risco: cada robô no instante em que fica mais perto do outro (robô → tempo)
    public var poseTimes: [String: Double] = [:]
    /// ponto de cada robô no momento em que fica mais perto do outro
    public var riskPoints: [RiskPoint] = []

    public init(kind: Kind, severity: Severity, robot: String, title: String, detail: String, gain: Double?,
                program: String, line: Int, time: Double, edits: [SourceEdit] = []) {
        self.kind = kind; self.severity = severity; self.robot = robot; self.title = title; self.detail = detail
        self.gain = gain; self.program = program; self.line = line; self.time = time; self.edits = edits
    }
}

/// Tempo de ciclo HOME-to-HOME de um robô e onde ele vai.
public struct CycleBreakdown {
    public var robot: String
    public var total: Double
    public var application: Double
    public var air: Double
    public var waiting: Double
    public var delays: Double
}

public enum CycleAnalysis {
    /// Folga mínima até a carroceria para aceitar uma alteração de caminho (mm).
    public static var minBodyClearance = 50.0

    public static func breakdown(_ t: RobotTrack, waits: [StationScheduler.WaitInterval]) -> CycleBreakdown {
        var app = 0.0, motion = 0.0
        var prev = 0.0
        var lastState: JointState?
        for s in t.samples {
            let dt = s.time - prev
            prev = s.time
            let moved = lastState.map { l in zip(l.q, s.state.q).contains { abs($0 - $1) > 1e-6 } || abs(l.rail - s.state.rail) > 1e-6 } ?? true
            lastState = s.state
            guard moved else { continue }
            if s.paintOn { app += dt } else { motion += dt }
        }
        let wait = waits.filter { $0.robot == t.name }.reduce(0) { $0 + $1.end - $1.start }
        let total = t.duration
        return CycleBreakdown(robot: t.name, total: total, application: app, air: motion, waiting: wait,
                              delays: Swift.max(0, total - app - motion - wait))
    }

    // MARK: simulação de trechos

    /// Tempo de um trecho de pontos partindo do estado em que o robô começa o ponto `from`.
    static func windowTime(_ t: RobotTrack, from: Int, points: [ProgramPoint]) -> (time: Double, samples: [TrajectorySample], errors: Int) {
        let startTime = t.samples.first { $0.pointIndex == from }.map { $0.time - 0.02 } ?? 0
        let start = t.state(at: startTime).state
        let r = Trajectory.sample(program: RobotProgram(name: "trecho", points: points, brushes: t.program.brushes), robot: t.robot, start: start)
        return (r.samples.last?.time ?? 0, r.samples, r.issues.filter { $0.severity == .error }.count)
    }

    static func bodyClearance(_ t: RobotTrack, _ samples: [TrajectorySample], _ body: ObstacleGrid) -> Double {
        var best = Double.infinity
        for (k, s) in samples.enumerated() where k % 3 == 0 || k == samples.count - 1 {
            best = Swift.min(best, body.clearance(RobotGeometry.capsules(t.robot, s.state), limit: 400))
        }
        return best
    }

    static func tcpPath(_ t: RobotTrack, _ samples: [TrajectorySample]) -> [SIMD3<Double>] {
        samples.enumerated().filter { $0.offset % 4 == 0 || $0.offset == samples.count - 1 }.map { _, s in
            var r = t.robot
            r.tool = t.program.points.indices.contains(s.pointIndex) ? (t.program.points[s.pointIndex].tool ?? r.tool) : r.tool
            return Kinematics.tcp(r, s.state).position
        }
    }

    /// Compara trecho original × variante: ganho, folga à carroceria e se a variante é aceitável.
    static func evaluate(_ t: RobotTrack, from: Int, original: [ProgramPoint], variant: [ProgramPoint], body: ObstacleGrid)
        -> (gain: Double, clearance: Double, ok: Bool, current: [SIMD3<Double>], proposed: [SIMD3<Double>]) {
        let o = windowTime(t, from: from, points: original)
        let v = windowTime(t, from: from, points: variant)
        let co = bodyClearance(t, o.samples, body), cv = bodyClearance(t, v.samples, body)
        // folga exigida: 50 mm, ou a do caminho original se ele já passa mais perto
        let need = Swift.min(minBodyClearance, co)
        let ok = v.errors <= o.errors && cv >= need - 1
        return (o.time - v.time, cv, ok, tcpPath(t, o.samples), tcpPath(t, v.samples))
    }

    // MARK: sugestões de tempo de ciclo

    /// Linha → índice do ponto (só movimentos executados na simulação).
    static func pointIndex(_ t: RobotTrack) -> [String: Int] {
        var m: [String: Int] = [:]
        for (i, o) in t.origin.enumerated() { let k = "\(o.program.uppercased()):\(o.line)"; if m[k] == nil { m[k] = i } }
        return m
    }

    public static func cycleSuggestions(_ t: RobotTrack, body: ObstacleGrid?, source: (String) -> EcoTalkProgram?,
                                        minGain: Double = 0.1) -> [AnalysisSuggestion] {
        guard let body else {
            return [AnalysisSuggestion(kind: .notice, severity: .info, robot: t.name, title: "Carregue a carroceria",
                                       detail: "As sugestões que mudam o caminho só são feitas com a carroceria carregada (Objetos 3D), para não gerar colisão do robô com ela.",
                                       gain: nil, program: "", line: 0, time: 0)]
        }
        var out: [AnalysisSuggestion] = []
        out += reversePasses(t, body: body, source: source, minGain: minGain)
        out += airMoves(t, body: body, source: source, minGain: minGain)
        return out
    }

    static func isMotion(_ l: EcoProgramLine) -> Bool { l.kind == .command && !l.isDisabled && ["LIN", "PTP", "CIRC"].contains(l.name) }
    static func isGun(_ l: EcoProgramLine) -> Bool { l.kind == .command && !l.isDisabled && l.name == "GUN" && l.args.count >= 2 }

    /// Passadas `LIN(A) GUN(on) LIN(B)… GUN(off) LIN(Z)`: inverter = mesma posição dos pontos, sentido contrário,
    /// disparos trocados (o ponto de ligar vira o de desligar).
    static func reversePasses(_ t: RobotTrack, body: ObstacleGrid, source: (String) -> EcoTalkProgram?, minGain: Double) -> [AnalysisSuggestion] {
        var out: [AnalysisSuggestion] = []
        let index = pointIndex(t)
        let programs = Set(t.origin.map(\.program))
        for name in programs.sorted() {
            guard let prog = source(name) else { continue }
            let lines = EcoProgramEditor.lines(prog)
            var k = 0
            while k < lines.count {
                // início: GUN(…, GunOn, …) precedido por um LIN
                guard isGun(lines[k]), lines[k].args[1].lowercased().contains("on"), k > 0, lines[k - 1].name == "LIN", isMotion(lines[k - 1]) else { k += 1; continue }
                var block = [k - 1]
                var j = k
                var gunOn = false
                var ended = false
                while j < lines.count {
                    let l = lines[j]
                    if isGun(l) { gunOn = l.args[1].lowercased().contains("on") && !l.args[1].lowercased().contains("off"); block.append(j) }
                    else if l.name == "LIN" && isMotion(l) { block.append(j); if !gunOn { ended = true; break } }
                    else { break }
                    j += 1
                }
                defer { k = (block.last ?? k) + 1 }
                let motions = block.filter { lines[$0].name == "LIN" }
                guard ended, motions.count >= 2 else { continue }
                let pts = motions.map { index["\(name.uppercased()):\(lines[$0].lineNumber)"] }
                guard pts.allSatisfy({ $0 != nil }) else { continue }
                let pi = pts.map { $0! }
                guard pi == Array(pi[0]...pi[pi.count - 1]) else { continue }     // movimentos consecutivos
                let i0 = pi[0], ik = pi[pi.count - 1]
                // variante: mesmos pontos em ordem inversa; a aplicação de cada trecho vai junto
                var original = Array(t.program.points[i0...ik])
                var variant: [ProgramPoint] = []
                for r in 0..<original.count {
                    var p = t.program.points[ik - r]
                    p.paintOn = r == 0 ? false : t.program.points[ik - r + 1].paintOn
                    variant.append(p)
                }
                if ik + 1 < t.program.points.count { original.append(t.program.points[ik + 1]); variant.append(t.program.points[ik + 1]) }
                let ev = evaluate(t, from: i0, original: original, variant: variant, body: body)
                guard ev.gain >= minGain else { continue }
                // texto invertido: movimentos ao contrário, disparos de cada intervalo trocados e em ordem inversa
                var gaps: [[String]] = Array(repeating: [], count: motions.count - 1)
                var g = -1
                for b in block { if lines[b].name == "LIN" { g += 1 } else if g >= 0 && g < gaps.count { gaps[g].append(lines[b].body) } }
                func swapGun(_ s: String) -> String {
                    s.replacingOccurrences(of: "GunOn", with: "\u{1}").replacingOccurrences(of: "GunOff", with: "GunOn").replacingOccurrences(of: "\u{1}", with: "GunOff")
                }
                var newBodies: [String] = []
                let m = motions.count
                for r in 0..<m {
                    newBodies.append(lines[motions[m - 1 - r]].body)
                    if r < m - 1 { newBodies += gaps[m - 2 - r].reversed().map(swapGun) }
                }
                let indent = lines[block[0]].indent
                let edits = zip(block, newBodies).map { SourceEdit(robot: t.name, program: name, line: lines[$0.0].lineNumber, op: .replace(indent + $0.1)) }
                let first = t.program.points[i0].name, last = t.program.points[ik].name
                var s = AnalysisSuggestion(kind: .reversePass, severity: .improvement, robot: t.name,
                    title: "Inverter passada \(first) → \(last)",
                    detail: String(format: "Fazendo a passada de %@ para %@ (mesmos pontos, disparos trocados) o robô chega e sai melhor posicionado. Ganho simulado: %.2f s. Folga mínima à carroceria: %.0f mm.", last, first, ev.gain, ev.clearance),
                    gain: ev.gain, program: name, line: lines[block[0]].lineNumber,
                    time: t.samples.first { $0.pointIndex == i0 }?.time ?? 0, edits: edits)
                s.bodyClearance = ev.clearance
                s.currentPath = ev.current; s.proposedPath = ev.proposed
                if !ev.ok { s.manualReason = String(format: "a variante passa a %.0f mm da carroceria ou gera erro de cinemática", ev.clearance) }
                if ev.ok { out.append(s) }
            }
        }
        return out
    }

    /// Movimentos no ar (pistola desligada): LIN → PTP e pontos intermediários que podem sair.
    static func airMoves(_ t: RobotTrack, body: ObstacleGrid, source: (String) -> EcoTalkProgram?, minGain: Double) -> [AnalysisSuggestion] {
        var out: [AnalysisSuggestion] = []
        let pts = t.program.points
        var cache: [String: [EcoProgramLine]] = [:]
        func line(_ i: Int) -> EcoProgramLine? {
            let o = t.place(i)
            if cache[o.program] == nil { cache[o.program] = source(o.program).map(EcoProgramEditor.lines) ?? [] }
            return cache[o.program]?.first { $0.lineNumber == o.line }
        }
        /// nenhum GUN entre as linhas dos pontos a e b (no mesmo programa)
        func noGunBetween(_ a: Int, _ b: Int) -> Bool {
            let oa = t.place(a), ob = t.place(b)
            guard oa.program == ob.program, let ls = cache[oa.program] ?? source(oa.program).map(EcoProgramEditor.lines) else { return false }
            return !ls.contains { $0.lineNumber > oa.line && $0.lineNumber < ob.line && (isGun($0) || $0.name.hasPrefix("GUN") || $0.name.hasPrefix("SETBRUSH") || $0.name == "SET" || $0.name == "RECEIVE" || $0.name == "CALL") }
        }
        guard pts.count > 2 else { return [] }
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            guard !p.paintOn, !pts[i + 1].paintOn, p.motion == .lin, let l = line(i), l.name == "LIN", noGunBetween(i - 1, i), noGunBetween(i, i + 1) else { continue }
            // 1) tirar o ponto (vai direto do anterior ao seguinte)
            let orig = [pts[i], pts[i + 1]]
            let ev1 = evaluate(t, from: i, original: orig, variant: [pts[i + 1]], body: body)
            if ev1.ok && ev1.gain >= Swift.max(minGain, 0.15) {
                var s = AnalysisSuggestion(kind: .removeAirPoint, severity: .improvement, robot: t.name,
                    title: "Tirar ponto no ar \(p.name)",
                    detail: String(format: "O robô pode ir direto de %@ para %@ sem passar por %@ (pistola desligada). Ganho simulado: %.2f s. Folga mínima à carroceria: %.0f mm. A linha fica desativada (##), dá para voltar.", pts[i - 1].name, pts[i + 1].name, p.name, ev1.gain, ev1.clearance),
                    gain: ev1.gain, program: t.place(i).program, line: t.place(i).line,
                    time: t.samples.first { $0.pointIndex == i }?.time ?? 0,
                    edits: [SourceEdit(robot: t.name, program: t.place(i).program, line: t.place(i).line, op: .disable)])
                s.bodyClearance = ev1.clearance; s.currentPath = ev1.current; s.proposedPath = ev1.proposed
                out.append(s)
                continue
            }
            // 2) LIN → PTP com a % de PTP do VEL em vigor
            var v = pts[i]
            v.motion = .ptp
            v.speed = p.ptpSpeed ?? 100
            let ev2 = evaluate(t, from: i, original: orig, variant: [v, pts[i + 1]], body: body)
            if ev2.ok && ev2.gain >= Swift.max(minGain, 0.15) {
                let newText = l.indent + l.body.replacingOccurrences(of: "LIN", with: "PTP", options: .anchored)
                var s = AnalysisSuggestion(kind: .linToPtp, severity: .improvement, robot: t.name,
                    title: "LIN(\(p.name)) → PTP no ar",
                    detail: String(format: "Movimento sem aplicação: em PTP (mesmo VEL, %.0f%% de PTP) o robô chega mais rápido. Ganho simulado: %.2f s. Folga mínima à carroceria: %.0f mm.", v.speed, ev2.gain, ev2.clearance),
                    gain: ev2.gain, program: t.place(i).program, line: t.place(i).line,
                    time: t.samples.first { $0.pointIndex == i }?.time ?? 0,
                    edits: [SourceEdit(robot: t.name, program: t.place(i).program, line: t.place(i).line, op: .replace(newText + (l.trailingComment.map { " //" + $0 } ?? "")))])
                s.bodyClearance = ev2.clearance; s.currentPath = ev2.current; s.proposedPath = ev2.proposed
                out.append(s)
            }
        }
        return out
    }

    // MARK: bits de colisão

    /// Regiões sem proteção → onde colocar bit; espera longa → liberar o bit mais cedo.
    public static func collisionSuggestions(_ tracks: [RobotTrack], conflicts: [ConflictRegion],
                                            zones: [StationScheduler.ZoneInterval], waits: [StationScheduler.WaitInterval]) -> [AnalysisSuggestion] {
        var out: [AnalysisSuggestion] = []
        var reserved = Set<String>()
        func track(_ n: String) -> RobotTrack? { tracks.first { $0.name == n } }
        func bitEdits(_ p: BitPlacement) -> [SourceEdit] {
            let ind = "  "
            return [SourceEdit(robot: p.robot, program: p.setBefore.program, line: p.setBefore.line,
                               op: .insertBefore([ind + "SET( \(p.pin) ,High )", ind + "RECEIVE( \(p.pin) ,High )"])),
                    SourceEdit(robot: p.robot, program: p.releaseAfter.program, line: p.releaseAfter.line, op: .insertAfter([ind + "SET( \(p.pin) ,Low )"]))]
        }
        for c in conflicts where c.protectedBy == nil {
            guard let ta = track(c.robotA), let tb = track(c.robotB) else { continue }
            // bit novo e livre: estender um bit que já existe não protege se ele é liberado (SET Low) no meio do trecho
            let pin = StationAnalysis.freePin(tracks, reserved: reserved) ?? "Collision16"
            reserved.insert(pin)
            let pa = StationAnalysis.placement(ta, points: c.aPoints, pin: pin)
            let pb = StationAnalysis.placement(tb, points: c.bPoints, pin: pin)
            let plausible = c.simultaneous || c.timeGap <= StationAnalysis.timingTolerance
            func pinsText(_ r: String, _ p: [String]) -> String { "\(r) segura " + (p.isEmpty ? "nenhum bit" : p.joined(separator: ", ")) }
            let common = Set(c.aPins).intersection(c.bPins)
            let bitsInfo = "Bits na região: " + pinsText(c.robotA, c.aPins) + "; " + pinsText(c.robotB, c.bPins)
                + (common.isEmpty ? " – nenhum em comum, por isso não há exclusão entre eles." : " – \(common.sorted().joined(separator: ", ")) em comum, mas não cobre o trecho todo.")
            let timing = c.simultaneous ? "" : String(format: " Na simulação passam com %.1f s de diferença: só se encontram se um robô atrasar ≥ %.1f s.", abs(c.closestATime - c.closestBTime), c.timeGap)
            var s = AnalysisSuggestion(kind: .protectRegion,
                severity: c.simultaneous ? .critical : (plausible ? .risk : .info), robot: "\(c.robotA) × \(c.robotB)",
                title: (c.simultaneous ? "Colisão na simulação: " : (plausible ? "Risco de colisão: " : String(format: "Só com atraso ≥ %.0f s: ", c.timeGap))) + "\(c.robotA) × \(c.robotB) (\(String(format: "%.0f", c.minDistance)) mm"
                    + (c.simultaneous ? ", ao mesmo tempo)" : String(format: ", %@ %.1f s × %@ %.1f s)", c.robotA, c.closestATime, c.robotB, c.closestBTime)),
                detail: String(format: "%@ (%.1f–%.1f s, pontos %@–%@) e %@ (%.1f–%.1f s, pontos %@–%@) passam a %.0f mm (limite 100 mm)%@. %@: %@ pede %@ antes de %@:%d (%@) e libera depois de %@:%d (%@); %@ pede antes de %@:%d (%@) e libera depois de %@:%d (%@).",
                               c.robotA, c.aTime.lowerBound, c.aTime.upperBound, ta.program.points[c.aPoints.lowerBound].name, ta.program.points[c.aPoints.upperBound].name,
                               c.robotB, c.bTime.lowerBound, c.bTime.upperBound, tb.program.points[c.bPoints.lowerBound].name, tb.program.points[c.bPoints.upperBound].name,
                               c.minDistance, c.simultaneous ? String(format: " ao mesmo tempo (%.1f s)", c.simultaneousTime ?? 0) : " em instantes diferentes",
                               c.partiallyProtectedBy.map { "\($0) só protege parte da região (é liberado no meio do trecho); usar o bit livre \(pin)" } ?? "Usar o bit livre \(pin)",
                               c.robotA, pin, pa.setBefore.program, pa.setBefore.line, pa.setPoint, pa.releaseAfter.program, pa.releaseAfter.line, pa.releasePoint,
                               c.robotB, pb.setBefore.program, pb.setBefore.line, pb.setPoint, pb.releaseAfter.program, pb.releaseAfter.line, pb.releasePoint),
                gain: nil, program: pa.setBefore.program, line: pa.setBefore.line,
                time: c.simultaneousTime ?? c.aTime.lowerBound, edits: bitEdits(pa) + bitEdits(pb))
            /// onde o robô está na região e o que fez com os bits antes e depois (programa:linha, inclusive Main)
            func context(_ t: RobotTrack, _ pts: ClosedRange<Int>) -> String {
                let a0 = t.place(pts.lowerBound), a1 = t.place(pts.upperBound)
                let here = a0.program == a1.program ? "\(a0.program):\(a0.line)–\(a1.line)" : "\(a0.program):\(a0.line) → \(a1.program):\(a1.line)"
                let bits = t.actions.filter { $0.kind == .set && !($0.program.lowercased().hasPrefix("home")) }
                let before = bits.filter { $0.afterPoint <= pts.lowerBound }
                let lastRelease = before.last { !$0.high }
                let held = Set(before.reduce(into: [String: Bool]()) { $0[$1.pin] = $1.high }.filter(\.value).keys)
                let nextClaim = bits.first { $0.afterPoint > pts.upperBound && $0.high }
                var txt = "\(t.name) está em \(here)"
                txt += held.isEmpty ? " sem bit" : " com " + held.sorted().joined(separator: ", ")
                if let r = lastRelease { txt += "; antes liberou \(r.pin) em \(r.program):\(r.line)" }
                if let n = nextClaim { txt += "; o próximo bit que pede é \(n.pin) em \(n.program):\(n.line)" }
                return txt
            }
            s.detail = bitsInfo + timing + " " + context(ta, c.aPoints) + ". " + context(tb, c.bPoints) + ". " + s.detail
            s.currentPath = [c.location]
            s.poseTimes = [c.robotA: c.closestATime, c.robotB: c.closestBTime]
            for (t, time) in [(ta, c.closestATime), (tb, c.closestBTime)] {
                let p = t.state(at: time).point
                let o = t.place(p)
                s.riskPoints.append(RiskPoint(robot: t.name, program: o.program, line: o.line,
                                              point: t.program.points.indices.contains(p) ? t.program.points[p].name : "?", time: time))
            }
            // robô parado na posição HOME dentro da região: bit não resolve (o outro robô passa por onde ele fica parado)
            func parkedAtHome(_ t: RobotTrack, _ r: ClosedRange<Int>) -> Bool {
                let pts = t.program.points
                return r.count > pts.count / 2 && pts.indices.contains(r.lowerBound) && pts[r.lowerBound].name.uppercased().contains("HOME")
            }
            if parkedAtHome(tb, c.bPoints) || parkedAtHome(ta, c.aPoints) {
                let parked = parkedAtHome(tb, c.bPoints) ? c.robotB : c.robotA
                let mover = parked == c.robotB ? c.robotA : c.robotB
                let moverPts = parked == c.robotB ? (ta, c.aPoints) : (tb, c.bPoints)
                s.manualReason = "\(mover) passa (pontos \(moverPts.0.program.points[moverPts.1.lowerBound].name)–\(moverPts.0.program.points[moverPts.1.upperBound].name)) por onde \(parked) fica parado em HOME; bit não resolve: revisar a posição desses pontos (ex.: E1 do trilho)"
            } else if let inside = (pa.releasedInside + pb.releasedInside).first {
                s.manualReason = "o bit seria liberado no meio do trecho por SET(\(pin), Low) em \(inside.program):\(inside.line) (ex.: Home.tip zera 1…16); colocar os bits à mão"
            } else if pa.setBefore.program != pa.releaseAfter.program || pb.setBefore.program != pb.releaseAfter.program {
                s.manualReason = "o trecho começa e termina em programas diferentes (CALL); colocar os bits à mão"
            }
            out.append(s)
        }
        // esperas: o dono segurou o bit além do último ponto em que chega perto do robô que espera
        for w in waits {
            guard let owner = w.blockedBy, let tOwner = track(owner),
                  let z = zones.first(where: { $0.owner == owner && $0.pin == w.pin && $0.start <= w.end + 0.05 && $0.end >= w.end - 0.05 }) else { continue }
            let near = conflicts.filter { ($0.robotA == owner && $0.robotB == w.robot) || ($0.robotB == owner && $0.robotA == w.robot) }
                .map { $0.robotA == owner ? $0.aTime : $0.bTime }
                .filter { $0.lowerBound <= z.end && $0.upperBound >= z.start }
            let lastNear = near.map(\.upperBound).max()
            // o SET Low que liberou a zona: o mais próximo do ponto em que o dono estava ao liberar
            let ptEnd = tOwner.state(at: z.end).point
            let release = tOwner.actions.filter { $0.kind == .set && !$0.high && $0.pin.caseInsensitiveCompare(w.pin) == .orderedSame }
                .min { abs($0.afterPoint - ptEnd) < abs($1.afterPoint - ptEnd) }
            // pediu o bit muito antes de chegar perto: pedir logo antes da primeira aproximação
            if let firstNear = near.map(\.lowerBound).min(), firstNear > z.start + 0.5 {
                let pt = tOwner.state(at: firstNear).point
                let target = StationAnalysis.placement(tOwner, points: pt...pt, pin: w.pin).setBefore
                let ptStart = tOwner.state(at: z.start).point
                let claims = tOwner.actions.filter { $0.pin.caseInsensitiveCompare(w.pin) == .orderedSame && $0.high && abs($0.afterPoint - ptStart) <= 1 }
                let gain = Swift.min(w.end - w.start, firstNear - z.start)
                var s = AnalysisSuggestion(kind: .releaseBitEarlier, severity: .improvement, robot: owner,
                    title: "\(owner) pede \(w.pin) mais tarde (\(w.robot) espera \(String(format: "%.1f", w.end - w.start)) s)",
                    detail: String(format: "%@ pede %@ em %.1f s, mas só chega a menos de 100 mm da área de %@ em %.1f s (%@). Pedindo o bit logo antes de %@:%d, %@ não precisa esperar esse tempo. Ganho estimado: até %.1f s (confirme recalculando a simulação).",
                                   owner, w.pin, z.start, w.robot, firstNear, tOwner.program.points[pt].name, target.program, target.line, w.robot, gain),
                    gain: gain, program: target.program, line: target.line, time: z.start)
                if !claims.isEmpty, claims.allSatisfy({ $0.program.caseInsensitiveCompare(target.program) == .orderedSame }) {
                    s.edits = claims.map { SourceEdit(robot: owner, program: $0.program, line: $0.line, op: .delete) }
                        + [SourceEdit(robot: owner, program: target.program, line: target.line, op: .insertBefore(["  SET( \(w.pin) ,High )", "  RECEIVE( \(w.pin) ,High )"]))]
                } else {
                    s.manualReason = "o SET/RECEIVE de \(w.pin) está em outro programa (ex.: Main); mover à mão para antes de \(target.program):\(target.line)"
                }
                out.append(s)
            }
            if let lastNear, lastNear < z.end - 0.3 {
                let pt = tOwner.state(at: lastNear).point
                // não libera no meio de uma aplicação: vai até o fim da passada
                let target = StationAnalysis.placement(tOwner, points: pt...pt, pin: w.pin).releaseAfter
                let gain = Swift.min(w.end - w.start, z.end - lastNear)
                var s = AnalysisSuggestion(kind: .releaseBitEarlier, severity: .improvement, robot: owner,
                    title: "\(owner) libera \(w.pin) mais cedo (\(w.robot) espera \(String(format: "%.1f", w.end - w.start)) s)",
                    detail: String(format: "%@ segura %@ de %.1f a %.1f s, mas a última aproximação de %@ (< 100 mm) é em %.1f s (%@). Liberar logo depois de %@:%d reduz a espera de %@ em até %.1f s.",
                                   owner, w.pin, z.start, z.end, w.robot, lastNear, tOwner.program.points[pt].name, target.program, target.line, w.robot, gain),
                    gain: gain, program: target.program, line: target.line, time: lastNear)
                if let r = release, r.program.caseInsensitiveCompare(target.program) == .orderedSame {
                    s.edits = [SourceEdit(robot: owner, program: r.program, line: r.line, op: .delete),
                               SourceEdit(robot: owner, program: target.program, line: target.line, op: .insertAfter(["  SET( \(w.pin) ,Low )"]))]
                } else {
                    s.manualReason = "o SET Low de \(w.pin) está em outro programa; mover à mão"
                }
                out.append(s)
            } else if lastNear == nil {
                out.append(AnalysisSuggestion(kind: .releaseBitEarlier, severity: .info, robot: owner,
                    title: "\(w.robot) espera \(String(format: "%.1f", w.end - w.start)) s por \(w.pin) sem risco com \(owner)",
                    detail: "Enquanto \(owner) segura \(w.pin), os dois nunca chegam a menos de 100 mm. Verificar se o bit protege outro robô; se não, a espera pode ser eliminada.",
                    gain: w.end - w.start, program: w.program, line: w.line, time: w.start))
            }
        }
        return out
    }
}
