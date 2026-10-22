import Foundation
import simd

/// Trajetória de um robô na estação (já no relógio comum, depois dos bits de colisão).
public struct RobotTrack {
    public var name: String
    public var robot: RobotModel
    public var program: RobotProgram
    public var samples: [TrajectorySample]
    public var origin: [(program: String, line: Int)]
    public var actions: [EcoTalkSyncAction]
    public var start: JointState
    /// cadeia de CALLs de cada ponto (do programa principal até a linha do movimento)
    public var chains: [[CallSite]]
    public init(name: String, robot: RobotModel, program: RobotProgram, samples: [TrajectorySample],
                origin: [(program: String, line: Int)], actions: [EcoTalkSyncAction], start: JointState, chains: [[CallSite]] = []) {
        self.name = name; self.robot = robot; self.program = program; self.samples = samples
        self.origin = origin; self.actions = actions; self.start = start; self.chains = chains
    }

    func chain(_ i: Int) -> [CallSite] {
        if chains.indices.contains(i), !chains[i].isEmpty { return chains[i] }
        let o = place(i)
        return [CallSite(program: o.program, line: o.line)]
    }

    /// Estado no instante t (antes do início: posição inicial; depois do fim: última posição).
    public func state(at t: Double) -> (state: JointState, point: Int) {
        guard let first = samples.first else { return (start, 0) }
        if t < first.time { return (start, first.pointIndex) }
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].time <= t { lo = m + 1 } else { hi = m } }
        let s = samples[Swift.max(0, lo - 1)]
        return (s.state, s.pointIndex)
    }

    public var duration: Double { samples.last?.time ?? 0 }

    public func place(_ point: Int) -> (program: String, line: Int) {
        origin.indices.contains(point) ? origin[point] : (program: "", line: 0)
    }
}

/// Região em que dois robôs ficam a menos da distância de segurança (em qualquer combinação de instantes).
public struct ConflictRegion: Identifiable {
    public let id = UUID()
    public var robotA: String
    public var robotB: String
    public var aTime: ClosedRange<Double>
    public var bTime: ClosedRange<Double>
    public var aPoints: ClosedRange<Int>
    public var bPoints: ClosedRange<Int>
    public var minDistance: Double
    /// os dois chegam perto no mesmo instante da simulação (colisão com o tempo atual)
    public var simultaneous: Bool
    public var simultaneousTime: Double?
    /// bit que já protege a região (os dois seguram o mesmo bit nos respectivos trechos)
    public var protectedBy: String?
    public var partiallyProtectedBy: String?
    /// posição do ponto mais próximo (para mostrar na Vista 3D)
    public var location: SIMD3<Double>
    /// instantes em que A e B ficam mais perto um do outro (podem ser diferentes)
    public var closestATime: Double = 0
    public var closestBTime: Double = 0
    /// elos que ficam mais perto (0 = pé/carro … 6 = ferramenta)
    public var closestLinks: (a: Int, b: Int) = (0, 0)
    /// bits que cada robô segura enquanto está na região (para explicar por que não protege)
    public var aPins: [String] = []
    public var bPins: [String] = []
    /// atraso mínimo (s) para os dois estarem na região ao mesmo tempo (0 = já se cruzam na simulação)
    public var timeGap: Double {
        Swift.max(0, Swift.max(aTime.lowerBound, bTime.lowerBound) - Swift.min(aTime.upperBound, bTime.upperBound))
    }
}

/// Onde colocar um bit de colisão novo para uma região.
public struct BitPlacement {
    public var robot: String
    public var pin: String
    public var setBefore: (program: String, line: Int)
    public var releaseAfter: (program: String, line: Int)
    public var setPoint: String
    public var releasePoint: String
    /// pontos protegidos (já estendidos para não cortar aplicação)
    public var points: ClosedRange<Int> = 0...0
    /// SET Low do mesmo bit dentro do trecho (ex.: Home.tip zera 1…16): o bit seria liberado no meio
    public var releasedInside: [EcoTalkSyncAction] = []
}

public enum StationAnalysis {
    /// Variação de tempo considerada na célula real (s): risco em instantes diferentes só conta como "risco"
    /// se um atraso dessa ordem já fizer os robôs se encontrarem; acima disso fica como informação.
    public static var timingTolerance = 5.0

    /// Conflitos robô × robô entre TODOS os pares. `step` = amostragem (s); `threshold` = distância de segurança (mm).
    public static func conflicts(_ tracks: [RobotTrack], zones: [StationScheduler.ZoneInterval],
                                 threshold: Double = 100, step: Double = 0.1) -> [ConflictRegion] {
        let duration = tracks.map(\.duration).max() ?? 0
        guard tracks.count > 1, duration > 0 else { return [] }
        let n = Int(ceil(duration / step)) + 1
        // poses de cada robô na grade de tempo comum
        struct Pose { var caps: [Capsule]; var lo: SIMD3<Double>; var hi: SIMD3<Double>; var point: Int }
        let grid: [[Pose]] = tracks.map { tr in
            (0..<n).map { k in
                let (s, p) = tr.state(at: Double(k) * step)
                let caps = RobotGeometry.capsules(tr.robot, s)
                let b = RobotGeometry.bounds(caps)
                return Pose(caps: caps, lo: b.min, hi: b.max, point: p)
            }
        }
        var out: [ConflictRegion] = []
        for a in 0..<tracks.count {
            for b in (a + 1)..<tracks.count {
                // células (i, j) em que A no instante i e B no instante j ficam perto demais
                var hits: [(Int, Int, Double)] = []
                let ga = grid[a], gb = grid[b]
                for i in 0..<n {
                    let pa = ga[i]
                    for j in 0..<n {
                        let pb = gb[j]
                        if simd_reduce_max(pa.lo - pb.hi) > threshold || simd_reduce_max(pb.lo - pa.hi) > threshold { continue }
                        let d = RobotGeometry.clearance(pa.caps, pb.caps).distance
                        if d < threshold { hits.append((i, j, d)) }
                    }
                }
                guard !hits.isEmpty else { continue }
                // agrupa células vizinhas (tolerância de 3 amostras) em regiões
                var parent = Array(hits.indices)
                func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
                var index: [Int: [Int]] = [:]
                for (h, c) in hits.enumerated() { index[c.0, default: []].append(h) }
                for (h, c) in hits.enumerated() {
                    for di in 0...3 {
                        for o in index[c.0 + di] ?? [] where o != h && abs(hits[o].1 - c.1) <= 3 {
                            let r1 = find(h), r2 = find(o)
                            if r1 != r2 { parent[r1] = r2 }
                        }
                    }
                }
                var groups: [Int: [Int]] = [:]
                for h in hits.indices { groups[find(h), default: []].append(h) }
                for (_, members) in groups {
                    let cells = members.map { hits[$0] }
                    let i0 = cells.map(\.0).min()!, i1 = cells.map(\.0).max()!
                    let j0 = cells.map(\.1).min()!, j1 = cells.map(\.1).max()!
                    let closest = cells.min { $0.2 < $1.2 }!
                    let simul = cells.filter { $0.0 == $0.1 }
                    let ta = (Double(i0) * step)...(Double(i1) * step), tb = (Double(j0) * step)...(Double(j1) * step)
                    let aPts = (ga[i0..<(i1 + 1)].map(\.point).min()!)...(ga[i0..<(i1 + 1)].map(\.point).max()!)
                    let bPts = (gb[j0..<(j1 + 1)].map(\.point).min()!)...(gb[j0..<(j1 + 1)].map(\.point).max()!)
                    let cl = RobotGeometry.clearance(ga[closest.0].caps, gb[closest.1].caps)
                    let ca = ga[closest.0].caps[cl.i], cb = gb[closest.1].caps[cl.j]
                    let loc = (ca.a + ca.b + cb.a + cb.b) / 4
                    var region = ConflictRegion(robotA: tracks[a].name, robotB: tracks[b].name, aTime: ta, bTime: tb,
                                                aPoints: aPts, bPoints: bPts, minDistance: closest.2,
                                                simultaneous: !simul.isEmpty, simultaneousTime: simul.first.map { Double($0.0) * step },
                                                protectedBy: nil, partiallyProtectedBy: nil, location: loc)
                    region.closestATime = Double(closest.0) * step
                    region.closestBTime = Double(closest.1) * step
                    region.closestLinks = (cl.i, cl.j)
                    (region.protectedBy, region.partiallyProtectedBy) = protection(region, zones: zones)
                    func held(_ r: String, _ t: ClosedRange<Double>) -> [String] {
                        Array(Set(zones.filter { $0.owner == r && $0.end > t.lowerBound && $0.start < t.upperBound }.map(\.pin)))
                            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    }
                    region.aPins = held(region.robotA, ta)
                    region.bPins = held(region.robotB, tb)
                    out.append(region)
                }
            }
        }
        return out.sorted { ($0.simultaneous ? 0 : 1, $0.minDistance) < ($1.simultaneous ? 0 : 1, $1.minDistance) }
    }

    /// Bit que protege a região: A segura o bit durante todo o seu trecho e B também (mesmo bit → exclusão mútua).
    static func protection(_ r: ConflictRegion, zones: [StationScheduler.ZoneInterval]) -> (String?, String?) {
        let eps = 0.15
        func coverage(_ robot: String, _ pin: String, _ t: ClosedRange<Double>) -> Double {
            let len = Swift.max(t.upperBound - t.lowerBound, 1e-6)
            let covered = zones.filter { $0.owner == robot && $0.pin == pin }.reduce(0.0) { acc, z in
                acc + Swift.max(0, Swift.min(z.end + eps, t.upperBound) - Swift.max(z.start - eps, t.lowerBound))
            }
            return t.upperBound - t.lowerBound < 1e-6
                ? (zones.contains { $0.owner == robot && $0.pin == pin && $0.start - eps <= t.lowerBound && $0.end + eps >= t.upperBound } ? 1 : 0)
                : covered / len
        }
        let pins = Set(zones.map(\.pin))
        var partial: String?
        for pin in pins.sorted() {
            let ca = coverage(r.robotA, pin, r.aTime), cb = coverage(r.robotB, pin, r.bTime)
            if ca >= 0.98 && cb >= 0.98 { return (pin, nil) }
            if ca > 0 && cb > 0 && partial == nil { partial = pin }
        }
        return (nil, partial)
    }

    /// Primeiro bit CollisionN (1…16) que nenhum robô da estação usa.
    public static func freePin(_ tracks: [RobotTrack], reserved: Set<String> = []) -> String? {
        // usado = algum robô pede a zona (SET High); SET Low de "limpeza" (ex.: Home.tip zera 1…16) não ocupa o bit
        let used = Set(tracks.flatMap { $0.actions.filter { $0.kind == .set && $0.high }.map { $0.pin.uppercased() } })
            .union(reserved.map { $0.uppercased() })
        return (1...16).map { "Collision\($0)" }.first { !used.contains($0.uppercased()) }
    }

    /// Onde colocar SET/RECEIVE (antes de entrar) e SET Low (depois de sair) para um robô e um trecho de pontos.
    /// Não divide uma aplicação: se o trecho começa/termina com a pistola ligada, estende até o início/fim da passada.
    public static func placement(_ track: RobotTrack, points: ClosedRange<Int>, pin: String) -> BitPlacement {
        let pts = track.program.points
        var s = points.lowerBound, e = points.upperBound
        while s > 0, pts.indices.contains(s), pts[s].paintOn { s -= 1 }
        while e + 1 < pts.count, pts[e + 1].paintOn { e += 1 }
        let name = { (i: Int) in pts.indices.contains(i) ? pts[i].name : "?" }
        // nível mais fundo em que início e fim estão no mesmo programa (ex.: no Main, em volta das CALLs)
        let ca = track.chain(s), cb = track.chain(e)
        var level = 0
        while level < Swift.min(ca.count, cb.count) - 1 && ca[level] == cb[level] { level += 1 }
        let a = ca[Swift.min(level, ca.count - 1)], b = cb[Swift.min(level, cb.count - 1)]
        var p = BitPlacement(robot: track.name, pin: pin, setBefore: (a.program, a.line), releaseAfter: (b.program, b.line),
                             setPoint: name(s), releasePoint: name(e))
        p.points = s...Swift.max(s, e)
        p.releasedInside = track.actions.filter { $0.kind == .set && !$0.high && $0.pin.caseInsensitiveCompare(pin) == .orderedSame
            && $0.afterPoint > s && $0.afterPoint <= e }
        return p
    }
}
