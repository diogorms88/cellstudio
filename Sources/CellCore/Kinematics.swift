import Foundation
import simd

public enum Kinematics {
    /// Transformações acumuladas: [base(+trilho), após A1, ..., após A6 (flange)] no sistema da estação.
    public static func frames(_ robot: RobotModel, _ s: JointState) -> [Mat4] {
        var t = robot.base.matrix
        if robot.railEnabled { t = t * robot.railPre.matrix * Mat4.translation(Vec3(0, 0, s.rail)) * robot.railPost.matrix }
        var out = [t]
        for (i, j) in robot.joints.enumerated() {
            t = t * j.transform(i < s.q.count ? s.q[i] : 0)
            out.append(t)
        }
        return out
    }

    public static func flange(_ robot: RobotModel, _ s: JointState) -> Mat4 {
        frames(robot, s).last!
    }

    public static func tcp(_ robot: RobotModel, _ s: JointState) -> Mat4 {
        flange(robot, s) * robot.tool.matrix
    }

    public struct IKResult {
        public var state: JointState
        public var converged: Bool
        public var positionError: Double      // mm
        public var orientationError: Double   // graus
    }

    /// Cinemática inversa numérica (mínimos quadrados amortecidos). Funciona para qualquer geometria,
    /// inclusive punhos oblíquos, e parte da solução atual para manter a configuração do braço.
    /// `respectLimits == false` resolve sem os limites dos eixos (para diagnosticar "alcançável, mas fora do limite").
    public static func inverse(_ robot: RobotModel, target: Pose, seed: JointState, iterations: Int = 200, respectLimits: Bool = true) -> IKResult {
        let first = solveFrom(robot, target: target, seed: seed, iterations: iterations, respectLimits: respectLimits)
        if first.converged || robot.joints.count < 6 { return first }
        // Mínimo local: tenta outras configurações (punho invertido, braço em outras posições)
        var best = first
        let h = JointState.home(for: robot)
        var seeds: [JointState] = []
        for base in [seed, h] {
            var flip = base
            flip.q[3] += flip.q[3] > 0 ? -180 : 180
            flip.q[4] = -flip.q[4]
            flip.q[5] += flip.q[5] > 0 ? -180 : 180
            seeds += [flip]
        }
        let toward = atan2(target.y - robot.base.y, target.x - robot.base.x) * 180 / .pi - robot.base.a
        for q2 in [-40.0, 0, 40] {
            for q5 in [-60.0, 60] {
                seeds.append(JointState(rail: seed.rail, q: [toward, q2, 0, 0, q5, 0] + Array(repeating: 0, count: robot.joints.count - 6)))
            }
        }
        for s0 in seeds {
            var s1 = s0
            if respectLimits { for k in s1.q.indices { s1.q[k] = Swift.min(Swift.max(s1.q[k], robot.joints[k].min), robot.joints[k].max) } }
            let r = solveFrom(robot, target: target, seed: s1, iterations: iterations, respectLimits: respectLimits)
            if r.converged { return r }
            if r.positionError + r.orientationError * 10 < best.positionError + best.orientationError * 10 { best = r }
        }
        return best
    }

    static func solveFrom(_ robot: RobotModel, target: Pose, seed: JointState, iterations: Int, respectLimits: Bool = true) -> IKResult {
        var s = seed
        let goal = target.matrix
        let n = robot.joints.count
        var lambda = 10.0
        var best = s
        var bestErr = Double.infinity

        func error(_ st: JointState) -> (pos: Vec3, rot: Vec3) {
            let m = tcp(robot, st)
            return (goal.position - m.position, rotationError(from: m.rotation, to: goal.rotation))
        }
        func cost(_ e: (pos: Vec3, rot: Vec3)) -> Double {
            simd_length_squared(e.pos) + simd_length_squared(e.rot * 500)  // 1 rad ≈ 500 mm
        }

        var e = error(s)
        for _ in 0..<iterations {
            let c = cost(e)
            if c < bestErr { bestErr = c; best = s }
            if simd_length(e.pos) < 0.01 && deg(simd_length(e.rot)) < 0.01 { break }

            // Jacobiano numérico 6×n
            var J = [[Double]](repeating: [Double](repeating: 0, count: n), count: 6)
            let h = 1e-4
            let m0 = tcp(robot, s)
            for k in 0..<n {
                var sp = s
                sp.q[k] += deg(h)
                let m1 = tcp(robot, sp)
                let dp = (m1.position - m0.position) / h
                let dr = rotationError(from: m0.rotation, to: m1.rotation) / h * 500
                for r in 0..<3 { J[r][k] = dp[r]; J[r + 3][k] = dr[r] }
            }
            let err = [e.pos.x, e.pos.y, e.pos.z, e.rot.x * 500, e.rot.y * 500, e.rot.z * 500]

            // (JᵀJ + λ²I) dq = Jᵀe
            var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var b = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in 0..<n { A[i][j] = (0..<6).reduce(0) { $0 + J[$1][i] * J[$1][j] } }
                A[i][i] += lambda * lambda
                b[i] = (0..<6).reduce(0) { $0 + J[$1][i] * err[$1] }
            }
            guard let dq = solve(A, b) else { break }

            var trial = s
            for k in 0..<n {
                let j = robot.joints[k]
                trial.q[k] = respectLimits ? Swift.min(Swift.max(s.q[k] + deg(dq[k]), j.min), j.max) : s.q[k] + deg(dq[k])
            }
            let et = error(trial)
            if cost(et) < c {
                s = trial; e = et
                lambda = Swift.max(lambda * 0.5, 1e-3)
            } else {
                lambda *= 4
                if lambda > 1e6 { break }
            }
        }
        let ef = error(best)
        let pe = simd_length(ef.pos), oe = deg(simd_length(ef.rot))
        return IKResult(state: best, converged: pe < 0.5 && oe < 0.1, positionError: pe, orientationError: oe)
    }

    /// Eliminação de Gauss com pivotamento parcial.
    static func solve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var M = A, x = b
        for c in 0..<n {
            var p = c
            for r in c + 1..<n where abs(M[r][c]) > abs(M[p][c]) { p = r }
            if abs(M[p][c]) < 1e-14 { return nil }
            M.swapAt(c, p); x.swapAt(c, p)
            for r in c + 1..<n {
                let f = M[r][c] / M[c][c]
                for k in c..<n { M[r][k] -= f * M[c][k] }
                x[r] -= f * x[c]
            }
        }
        for c in stride(from: n - 1, through: 0, by: -1) {
            var sum = x[c]
            for k in c + 1..<n { sum -= M[c][k] * x[k] }
            x[c] = sum / M[c][c]
        }
        return x
    }
}
