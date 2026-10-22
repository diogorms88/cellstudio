import Foundation
import simd

/// Malha triangular em mm, no sistema da estação.
public struct Mesh {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], indices: [UInt32]) {
        self.positions = positions
        self.indices = indices
        self.normals = normals.count == positions.count ? normals : Mesh.computeNormals(positions, indices)
    }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    static func computeNormals(_ p: [SIMD3<Float>], _ idx: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: p.count)
        for t in stride(from: 0, to: idx.count - 2, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let fn = simd_cross(p[b] - p[a], p[c] - p[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        return n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 0, 1) }
    }

    /// Junta vértices coincidentes (STL repete vértices por triângulo).
    public func welded(tolerance: Float = 0.01) -> Mesh {
        var map: [SIMD3<Int32>: UInt32] = [:]
        var pos: [SIMD3<Float>] = []
        var remap = [UInt32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>((p / tolerance).rounded(.toNearestOrEven))
            if let j = map[key] { remap[i] = j } else {
                let j = UInt32(pos.count); map[key] = j; pos.append(p); remap[i] = j
            }
        }
        return Mesh(positions: pos, indices: indices.map { remap[Int($0)] })
    }

    /// Subdivide triângulos até que nenhuma aresta passe de `maxEdge` mm, para que a
    /// espessura de tinta (calculada por vértice) tenha resolução suficiente.
    public func refined(maxEdge: Float, maxTriangles: Int = 1_500_000) -> Mesh {
        var pos = positions
        var tris = stride(from: 0, to: indices.count - 2, by: 3).map { (indices[$0], indices[$0 + 1], indices[$0 + 2]) }
        var midCache: [UInt64: UInt32] = [:]
        func mid(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
            if let m = midCache[key] { return m }
            let m = UInt32(pos.count)
            pos.append((pos[Int(a)] + pos[Int(b)]) / 2)
            midCache[key] = m
            return m
        }
        var changed = true
        while changed && tris.count < maxTriangles {
            changed = false
            var next: [(UInt32, UInt32, UInt32)] = []
            next.reserveCapacity(tris.count * 2)
            for (a, b, c) in tris {
                let pa = pos[Int(a)], pb = pos[Int(b)], pc = pos[Int(c)]
                let lab = simd_distance(pa, pb), lbc = simd_distance(pb, pc), lca = simd_distance(pc, pa)
                let longest = Swift.max(lab, lbc, lca)
                if longest <= maxEdge || next.count + tris.count > maxTriangles {
                    next.append((a, b, c)); continue
                }
                changed = true
                // divide pela aresta mais longa (bisseção), mantendo a malha sem buracos via cache de pontos médios
                if longest == lab { let m = mid(a, b); next.append((a, m, c)); next.append((m, b, c)) }
                else if longest == lbc { let m = mid(b, c); next.append((a, b, m)); next.append((a, m, c)) }
                else { let m = mid(c, a); next.append((a, b, m)); next.append((m, b, c)) }
            }
            tris = next
        }
        return Mesh(positions: pos, indices: tris.flatMap { [$0.0, $0.1, $0.2] })
    }
}

/// Modelo de deposição: leque cônico com perfil (1 − (r/R)²)^β, normalizado para que o
/// volume depositado por segundo seja vazão × eficiência × sólidos.
public final class PaintSimulator {
    public let mesh: Mesh
    public private(set) var thickness: [Float]  // µm (película seca)

    public init(mesh: Mesh) {
        self.mesh = mesh
        thickness = [Float](repeating: 0, count: mesh.positions.count)
    }

    public func reset() { thickness = [Float](repeating: 0, count: mesh.positions.count) }

    /// - Parameters:
    ///   - gun: posição do aplicador (mm) e direção do jato (eixo Z do TCP)
    ///   - dt: segundos
    public func deposit(gun: Mat4, brush: Brush, dt: Double) {
        let origin = SIMD3<Float>(gun.position)
        let dir = SIMD3<Float>(simd_normalize(gun.zAxis))
        let tanHalf = Float(tan(rad(brush.coneHalfAngle)))
        let beta = Float(brush.beta)
        // mm³/s de sólidos que chegam à peça
        let volumeRate = Float(brush.flowRate / 60 * 1000 * brush.transferEfficiency * brush.solids)
        let k = volumeRate * Float(dt) * (beta + 1) / .pi * 1000 // → µm·mm²

        let pos = mesh.positions, nrm = mesh.normals
        thickness.withUnsafeMutableBufferPointer { th in
            DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                let n = pos.count
                let lo = n * chunk / 16, hi = n * (chunk + 1) / 16
                for i in lo..<hi {
                    let v = pos[i] - origin
                    let axial = simd_dot(v, dir)
                    if axial <= 1 { continue }
                    let R = axial * tanHalf
                    let radial2 = simd_length_squared(v - axial * dir)
                    let u = radial2 / (R * R)
                    if u >= 1 { continue }
                    let cosInc = -simd_dot(nrm[i], dir)
                    // a malha pode ter normais invertidas (STL); considera as duas faces
                    let incidence = abs(cosInc)
                    if incidence < 0.05 { continue }
                    let profile = powf(1 - u, beta)
                    th[i] += k * profile * incidence / (R * R)
                }
            }
        }
    }

    public var stats: (min: Float, max: Float, mean: Float, coated: Int) {
        let coated = thickness.filter { $0 > 0.5 }
        guard !coated.isEmpty else { return (0, 0, 0, 0) }
        return (coated.min()!, coated.max()!, coated.reduce(0, +) / Float(coated.count), coated.count)
    }
}

/// Amostras de tempo ao longo do programa, usadas pela reprodução e pela simulação de pintura.
public struct TrajectorySample {
    public var time: Double
    public var state: JointState
    public var paintOn: Bool
    public var brush: Int
    public var pointIndex: Int

    public init(time: Double, state: JointState, paintOn: Bool, brush: Int, pointIndex: Int) {
        self.time = time; self.state = state; self.paintOn = paintOn; self.brush = brush; self.pointIndex = pointIndex
    }
}

/// Arco de circunferência por três pontos (CIRC: início, intermediário, fim).
struct Arc {
    let center: Vec3, u: Vec3, v: Vec3, radius: Double, sweep: Double

    init?(_ a: Vec3, _ b: Vec3, _ c: Vec3) {
        let ab = b - a, ac = c - a
        let n = simd_cross(ab, ac)
        let n2 = simd_length_squared(n)
        guard n2 > 1e-6 else { return nil }
        let center = a + (simd_cross(n, ab) * simd_length_squared(ac) + simd_cross(ac, n) * simd_length_squared(ab)) / (2 * n2)
        let r = simd_distance(center, a)
        let u = simd_normalize(a - center)
        let w = simd_normalize(n)
        let v = simd_cross(w, u)
        func ang(_ p: Vec3) -> Double {
            let d = p - center
            var t = atan2(simd_dot(d, v), simd_dot(d, u))
            if t < 0 { t += 2 * .pi }
            return t
        }
        let tb = ang(b), tc = ang(c)
        // o sentido é o que passa por b antes de chegar em c
        self.center = center; self.u = u; self.v = v; self.radius = r
        self.sweep = tb <= tc ? tc : tc - 2 * .pi
    }

    var length: Double { abs(sweep) * radius }
    func point(_ f: Double) -> Vec3 { center + radius * (cos(sweep * f) * u + sin(sweep * f) * v) }
}

public enum Trajectory {
    public typealias Result = (samples: [TrajectorySample], unreachable: [Int], issues: [MotionIssue])

    /// Amostra o programa e faz as verificações do controlador (como o MCU do DXQ):
    /// ponto não alcançável (571/572), posição final fora do limite de eixo (536), limite durante o movimento (502–504),
    /// punho singular (574), salto de eixo (545) e velocidade de eixo (507–509, reduzida como no MCU 530).
    public static func sample(program: RobotProgram, robot: RobotModel, start: JointState, dt: Double = 0.02,
                              warnings: SimulationWarningSettings = SimulationWarningSettings()) -> Result {
        var out: [TrajectorySample] = []
        var unreachable: [Int] = []
        var issues: [MotionIssue] = []
        var state = start
        var t = 0.0
        var activeTool = robot.tool
        var current = Pose(matrix: Kinematics.tcp(robot, state))
        var activeWarnings = Set<String>()
        let kin = robot.name

        func add(_ kind: MotionIssue.Kind, _ sev: MotionIssue.Severity, _ msg: (Int, String), _ i: Int) {
            let name = program.points[i].name
            guard !issues.contains(where: { $0.pointIndex == i && $0.code == msg.0 && $0.text == msg.1 }) else { return }
            issues.append(MotionIssue(kind: kind, severity: sev, code: msg.0, pointIndex: i, pointName: name, time: t, text: msg.1))
            if sev == .error && !unreachable.contains(i) { unreachable.append(i) }
        }

        /// Avisos configuráveis (borda de subida, como `IsInWarningRange` no DXQ).
        func checkWarnings(_ st: JointState, _ i: Int) {
            let now = Set(JointLimits.warnings(st, robot: robot, settings: warnings))
            for w in now.subtracting(activeWarnings) {
                add(w.hasPrefix("Robô próximo") ? .singularityWarning : .jointLimitWarning, .warning, (0, w), i)
            }
            activeWarnings = now
        }

        /// Alvo cartesiano: IK dentro dos limites; se falhar, IK livre diz se é limite de eixo (536) ou fora de alcance (571/572).
        func solveTarget(_ r: RobotModel, _ pose: Pose, seed: JointState, _ i: Int) -> JointState {
            let ik = Kinematics.inverse(r, target: pose, seed: seed)
            if ik.converged { return ik.state }
            let free = Kinematics.inverse(r, target: pose, seed: seed, respectLimits: false)
            if free.converged {
                var st = free.state
                let (lc, violations) = JointLimits.check(&st, robot: r, tryToFix: true)
                if lc != .error { return st }           // coube com ±360° (tryToFix do DXQ)
                for v in violations { add(.jointLimit, .error, McuMessage.jointLimitAtEnd(v, segment: program.points[i].name, kinematic: kin), i) }
                return ik.state
            }
            let at = program.points[i].name
            if free.positionError > 0.5 { add(.positionNotReachable, .error, McuMessage.positionNotReachable(kinematic: kin, at: at), i) }
            else { add(.orientationNotReachable, .error, McuMessage.orientationNotReachable(kinematic: kin, at: at), i) }
            return ik.state
        }

        for (i, p) in program.points.enumerated() {
            var r = robot
            r.tool = p.tool ?? robot.tool
            if r.tool != activeTool {
                // troca de ferramenta: a posição atual passa a ser medida com o novo TCP
                activeTool = r.tool
                current = Pose(matrix: Kinematics.tcp(r, state))
            }
            let command = "\(p.motion.rawValue)(\(p.name))"
            switch p.motion {
            case .ptp:
                var goal: JointState
                if let j = p.joints, j.count == r.joints.count {
                    goal = JointState(rail: p.rail, q: j)
                    // ponto Axis: o controlador recusa valores fora do limite (sem correção ±360°)
                    var probe = goal
                    let (lc, violations) = JointLimits.check(&probe, robot: r)
                    if lc == .error {
                        for v in violations { add(.jointLimit, .error, McuMessage.jointLimitAtEnd(v, segment: p.name, kinematic: kin), i) }
                    }
                } else {
                    var seed = state
                    seed.rail = p.rail
                    goal = solveTarget(r, p.pose, seed: seed, i)
                }
                goal.rail = p.rail
                if r.railEnabled, p.rail > r.railMax + 1e-9 || p.rail < r.railMin - 1e-9 {
                    let v = JointViolation(joint: -1, name: "E1", unit: "mm", value: p.rail, min: r.railMin, max: r.railMax)
                    add(.jointLimit, .error, McuMessage.jointLimitAtEnd(v, segment: p.name, kinematic: kin), i)
                }
                // tempo pelo eixo mais lento (velocidade máxima do machinedata × override %)
                let pct = Swift.max(p.speed, 1) / 100
                var duration = dt
                for k in goal.q.indices {
                    duration = Swift.max(duration, abs(goal.q[k] - state.q[k]) / (r.joints[k].maxVelocity * pct))
                }
                if r.railEnabled { duration = Swift.max(duration, abs(goal.rail - state.rail) / (r.railMaxVelocity * pct)) }
                let steps = Int(ceil(duration / dt))
                for s in 1...steps {
                    let f = Double(s) / Double(steps)
                    let e = f * f * (3 - 2 * f)
                    let q = zip(state.q, goal.q).map { $0 + ($1 - $0) * e }
                    t += dt
                    let st = JointState(rail: state.rail + (goal.rail - state.rail) * e, q: q)
                    checkWarnings(st, i)
                    out.append(TrajectorySample(time: t, state: st, paintOn: false, brush: p.brush, pointIndex: i))
                }
                state = goal
                current = Pose(matrix: Kinematics.tcp(r, state))
            case .lin, .circ:
                let target: Pose
                if let j = p.joints, j.count == r.joints.count {
                    var probe = JointState(rail: p.rail, q: j)
                    let (lc, violations) = JointLimits.check(&probe, robot: r)
                    if lc == .error {
                        for v in violations { add(.jointLimit, .error, McuMessage.jointLimitAtEnd(v, segment: p.name, kinematic: kin), i) }
                    }
                    target = Pose(matrix: Kinematics.tcp(r, JointState(rail: p.rail, q: j)))
                } else {
                    target = p.pose
                    // posição final do segmento: mesma análise do PTP (536 / 571 / 572)
                    var seed = state
                    seed.rail = p.rail
                    _ = solveTarget(r, target, seed: seed, i)
                }
                let endFailed = unreachable.contains(i)
                let arc = p.motion == .circ ? p.via.flatMap { Arc(current.position, $0.position, target.position) } : nil
                let dist = arc?.length ?? simd_distance(current.position, target.position)
                let duration = Swift.max(dist / Swift.max(p.speed, 1), abs(p.rail - state.rail) / r.railMaxVelocity, dt)
                let steps = Int(ceil(duration / dt))
                let rail0 = state.rail
                var pathReported = Set<String>()
                var worstVelocity: (k: Int, value: Double)?
                for s in 1...steps {
                    let f = Double(s) / Double(steps)
                    var seed = state
                    seed.rail = rail0 + (p.rail - rail0) * f
                    var goal = Pose.lerp(current, target, f)
                    if let arc { let q = arc.point(f); goal.x = q.x; goal.y = q.y; goal.z = q.z }
                    // como o interpolador do controlador: cada passo parte do anterior e mantém a configuração
                    // (sem procurar outras soluções, que fariam o braço/punho "virar" no meio do caminho)
                    let ik = Kinematics.solveFrom(r, target: goal, seed: seed, iterations: 100)
                    if !ik.converged && !endFailed {
                        // no meio do caminho: limite de eixo (502–504) ou fora de alcance (571/572)
                        let free = Kinematics.solveFrom(r, target: goal, seed: seed, iterations: 100, respectLimits: false)
                        if free.converged {
                            var st = free.state
                            let (lc, violations) = JointLimits.check(&st, robot: r, tryToFix: true)
                            if lc == .error {
                                for v in violations where pathReported.insert(v.name).inserted {
                                    add(.jointLimitOnPath, .error, McuMessage.jointLimitOnPath(v, command: command), i)
                                }
                            }
                        } else if pathReported.insert("reach").inserted {
                            let at = String(format: "%@ (%.0f %% do caminho)", command, f * 100)
                            add(free.positionError > 0.5 ? .positionNotReachable : .orientationNotReachable, .error,
                                free.positionError > 0.5 ? McuMessage.positionNotReachable(kinematic: kin, at: at)
                                                         : McuMessage.orientationNotReachable(kinematic: kin, at: at), i)
                        }
                    }
                    let next = JointState(rail: seed.rail, q: ik.state.q)
                    // salto de eixo (troca de configuração) e velocidade de eixo neste passo
                    for k in next.q.indices where k < state.q.count {
                        let dq = abs(next.q[k] - state.q[k])
                        if dq > 90, pathReported.insert("leap\(k)").inserted {
                            add(.jointLeap, .error, McuMessage.jointLeap(kinematic: kin, name: r.joints[k].name, from: state.q[k], to: next.q[k],
                                                                         at: String(format: "%@ (%.0f %% do caminho)", command, f * 100)), i)
                        } else if dq / dt > r.joints[k].maxVelocity, dq <= 90 {
                            if worstVelocity == nil || dq / dt / r.joints[k].maxVelocity > worstVelocity!.value / r.joints[worstVelocity!.k].maxVelocity {
                                worstVelocity = (k, dq / dt)
                            }
                        }
                    }
                    // punho singular: A5 passando por 0° num movimento cartesiano
                    if next.q.count > 4, abs(next.q[4]) < 0.5, pathReported.insert("sing").inserted {
                        add(.wristSingular, .error, McuMessage.wristSingular(kinematic: kin, at: String(format: "%@ (A5 = %.2f°)", command, next.q[4])), i)
                    }
                    state = next
                    t += dt
                    checkWarnings(state, i)
                    // a aplicação vale durante o movimento que chega no ponto
                    out.append(TrajectorySample(time: t, state: state, paintOn: p.paintOn, brush: p.brush, pointIndex: i))
                }
                if let w = worstVelocity {
                    let j = r.joints[w.k]
                    let msg = McuMessage.jointVelocity(joint: w.k, name: j.name, unit: j.kind == .revolute ? "°" : "mm",
                                                       value: w.value, limit: j.maxVelocity, command: command)
                    // o MCU reduz a velocidade do caminho (530, nível informação) em vez de parar
                    add(.jointVelocity, .info, (530, msg.1 + " – o controlador reduz a velocidade do caminho"), i)
                }
                current = target
            }
        }
        return (out, unreachable, issues)
    }
}
