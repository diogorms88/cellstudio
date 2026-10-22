import Foundation
import simd

/// Edição de pontos como a guia "Transformation" do DXQ (StartTabTransformationViewModel / H3DPoint):
/// deslocar e girar os pontos selecionados em Mundo, Objeto, Ferramenta ou Eixos, girar em torno de um vetor,
/// espelhar num plano, copiar/colar orientação. O ponto continua do mesmo tipo (Axis/World/Object) no .tid.
public enum PointCoordSystem: String, CaseIterable, Identifiable {
    case world = "Mundo", object = "Objeto", tool = "Ferramenta", joint = "Eixos"
    public var id: String { rawValue }
}

/// Deslocamento: X/Y/Z (mm), A/B/C (°), eixos A1…A6 (só em Eixos) e E1 (trilho).
public struct PointOffset: Equatable {
    public var pose: Pose
    public var joints: [Double]
    public var rail: Double
    public init(pose: Pose = Pose(), joints: [Double] = Array(repeating: 0, count: 6), rail: Double = 0) {
        self.pose = pose; self.joints = joints; self.rail = rail
    }
}

/// POINT do .tid: `[tipo, v1…v6, E1, aux…]` — tipo Axis (eixos em °), World ou Object (X,Y,Z,A,B,C).
public struct PointRecord: Equatable {
    public var mode: String
    public var values: [Double]
    public var rail: Double
    public var extra: [String]

    public init(mode: String, values: [Double], rail: Double, extra: [String] = []) {
        self.mode = mode; self.values = values; self.rail = rail; self.extra = extra
    }

    public init?(args: [String]) {
        guard args.count >= 7, let m = args.first, Double(m) == nil else { return nil }
        let v = args[1...6].compactMap { Double($0) }
        guard v.count == 6 else { return nil }
        mode = m
        values = v
        rail = args.count > 7 ? Double(args[7]) ?? 0 : 0
        extra = args.count > 8 ? Array(args[8...]) : []
    }

    public var args: [String] {
        let f = EcoProgramEditor.formatNumber
        return [mode] + values.map(f) + [f(rail)] + extra
    }

    public var isAxis: Bool { mode.lowercased() == "axis" }
    public var isWorld: Bool { mode.lowercased() == "world" }
    public var pose: Pose { Pose(x: values[0], y: values[1], z: values[2], a: values[3], b: values[4], c: values[5]) }
}

/// Onde o ponto vive: robô com a ferramenta em vigor (SETTOOL), objeto (SETOBJECT) e semente para a inversa.
public struct PointContext {
    public var robot: RobotModel
    public var object: Pose
    public var seed: JointState
    public init(robot: RobotModel, object: Pose, seed: JointState) {
        self.robot = robot; self.object = object; self.seed = seed
    }
}

public enum MirrorPlane: String, CaseIterable, Identifiable {
    case xy = "XY", xz = "XZ", yz = "YZ"
    public var id: String { rawValue }
}

public enum PointTransform {
    public enum Failure: Error, Equatable {
        case unreachable          // a inversa não chegou (ponto Axis ou deslocamento em Eixos)
        case axisNotSupported     // operação só para pontos cartesianos (como no DXQ)
    }

    /// Eixos do ponto: Axis direto; World/Object pela inversa partindo da semente.
    public static func joints(_ p: PointRecord, _ ctx: PointContext) -> JointState? {
        if p.isAxis { return JointState(rail: p.rail, q: p.values + Array(repeating: 0, count: max(0, ctx.robot.joints.count - 6))) }
        var seed = ctx.seed; seed.rail = p.rail
        let r = Kinematics.inverse(ctx.robot, target: Pose(matrix: world(p, ctx)), seed: seed)
        return r.converged ? r.state : nil
    }

    /// TCP do ponto no mundo.
    public static func world(_ p: PointRecord, _ ctx: PointContext) -> Mat4 {
        if p.isAxis { return Kinematics.tcp(ctx.robot, JointState(rail: p.rail, q: p.values + Array(repeating: 0, count: max(0, ctx.robot.joints.count - 6)))) }
        return p.isWorld ? p.pose.matrix : ctx.object.matrix * p.pose.matrix
    }

    /// Grava de volta no mesmo tipo. Axis: usa `joints` se veio de um deslocamento em Eixos, senão a inversa.
    public static func encode(world w: Mat4, rail: Double, joints: JointState? = nil, like p: PointRecord, _ ctx: PointContext) -> Result<PointRecord, Failure> {
        var out = p
        out.rail = rail
        if p.isAxis {
            if let j = joints {
                out.values = Array(j.q.prefix(6)); out.rail = j.rail
            } else {
                var seed = JointState(rail: rail, q: p.values + Array(repeating: 0, count: max(0, ctx.robot.joints.count - 6)))
                seed.rail = rail
                let r = Kinematics.inverse(ctx.robot, target: Pose(matrix: w), seed: seed)
                guard r.converged else { return .failure(.unreachable) }
                out.values = Array(r.state.q.prefix(6))
            }
        } else {
            let local = p.isWorld ? Pose(matrix: w) : Pose(matrix: ctx.object.matrix.inverse * w)
            out.values = [local.x, local.y, local.z, local.a, local.b, local.c]
        }
        return .success(out)
    }

    /// Rotação pura de uma pose (sem translação).
    static func rotation(_ p: Pose) -> Mat4 { Pose(a: p.a, b: p.b, c: p.c).matrix }

    /// `ShiftSelectedPoints`: Mundo/Objeto somam a posição e giram a orientação em torno dos eixos do sistema
    /// (Roff · R, no próprio ponto); Ferramenta multiplica à direita (P · Off); Eixos soma nos eixos.
    public static func shift(_ p: PointRecord, by off: PointOffset, in sys: PointCoordSystem, _ ctx: PointContext) -> Result<PointRecord, Failure> {
        let rail = p.rail + off.rail
        switch sys {
        case .world, .object:
            let base = sys == .world ? Mat4.identity : ctx.object.matrix
            let local = base.inverse * world(p, ctx)
            var m = rotation(off.pose) * Mat4(columns: (local.columns.0, local.columns.1, local.columns.2, SIMD4(0, 0, 0, 1)))
            let pos = local.position + off.pose.position
            m.columns.3 = SIMD4(pos.x, pos.y, pos.z, 1)
            return encode(world: base * m, rail: rail, like: p, ctx)
        case .tool:
            return encode(world: world(p, ctx) * off.pose.matrix, rail: rail, like: p, ctx)
        case .joint:
            guard var j = joints(p, ctx) else { return .failure(.unreachable) }
            for i in 0..<min(j.q.count, off.joints.count) { j.q[i] += off.joints[i] }
            j.rail = rail
            return encode(world: Kinematics.tcp(ctx.robot, j), rail: rail, joints: j, like: p, ctx)
        }
    }

    /// `RotateSelectedPointsAroundVector`: gira em torno do eixo start→end (coordenadas do objeto), ângulo em graus.
    public static func rotate(_ p: PointRecord, start: Vec3, end: Vec3, angle: Double, _ ctx: PointContext) -> Result<PointRecord, Failure> {
        guard !p.isAxis else { return .failure(.axisNotSupported) }
        let axis = end - start
        guard simd_length(axis) > 1e-9 else { return .success(p) }
        let r = Mat4(simd_quatd(angle: rad(angle), axis: simd_normalize(axis)))
        let local = ctx.object.matrix.inverse * world(p, ctx)
        let m = Mat4.translation(start) * r * Mat4.translation(-start) * local
        return encode(world: ctx.object.matrix * m, rail: p.rail, like: p, ctx)
    }

    /// `MirrorSelectedPointsOnPlane`: espelha no plano (coordenadas do objeto) que passa por `offset`.
    /// A direção da pistola (Z) e o X são espelhados; Y = Z × X mantém a ferramenta destra.
    public static func mirror(_ p: PointRecord, plane: MirrorPlane, offset: Double, _ ctx: PointContext) -> Result<PointRecord, Failure> {
        guard !p.isAxis else { return .failure(.axisNotSupported) }
        let k = plane == .xy ? 2 : (plane == .xz ? 1 : 0)
        func reflect(_ v: Vec3) -> Vec3 { var r = v; r[k] = -r[k]; return r }
        let local = ctx.object.matrix.inverse * world(p, ctx)
        var pos = local.position
        pos[k] = 2 * offset - pos[k]
        let x = reflect(local.xAxis), z = reflect(local.zAxis)
        let y = simd_cross(z, x)
        let m = Mat4(columns: (SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0), SIMD4(z.x, z.y, z.z, 0), SIMD4(pos.x, pos.y, pos.z, 1)))
        return encode(world: ctx.object.matrix * m, rail: p.rail, like: p, ctx)
    }

    /// Colar orientação: mantém a posição e usa a orientação (no mundo) copiada de outro ponto.
    public static func setOrientation(_ p: PointRecord, world r: simd_double3x3, _ ctx: PointContext) -> Result<PointRecord, Failure> {
        let w = world(p, ctx)
        let m = Mat4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), w.columns.3))
        return encode(world: m, rail: p.rail, like: p, ctx)
    }

    /// Converte o tipo do ponto (Axis/World/Object) sem mudar a posição do TCP.
    public static func convert(_ p: PointRecord, to mode: String, _ ctx: PointContext) -> Result<PointRecord, Failure> {
        guard mode.lowercased() != p.mode.lowercased() else { return .success(p) }
        let w = world(p, ctx)
        var target = p
        target.mode = mode
        if mode.lowercased() == "axis" {
            var seed = ctx.seed; seed.rail = p.rail
            let r = Kinematics.inverse(ctx.robot, target: Pose(matrix: w), seed: p.isAxis ? (joints(p, ctx) ?? seed) : seed)
            guard r.converged else { return .failure(.unreachable) }
            target.values = Array(r.state.q.prefix(6))
            return .success(target)
        }
        return encode(world: w, rail: p.rail, like: target, ctx)
    }
}

// MARK: - Ferramentas do editor (EcoTalkProgram.ConvertFrameToFrame / CorrectZeroPositionService / SmoothOrientation)

public extension PointTransform {
    /// Objeto-Objeto: o ponto fica no mesmo lugar do mundo, escrito no objeto novo: P' = N⁻¹ · V · P (só pontos Object).
    static func changeObject(_ p: PointRecord, from old: Pose, to new: Pose) -> PointRecord? {
        guard !p.isAxis, !p.isWorld else { return nil }
        return withPose(p, new.matrix.inverse * old.matrix * p.pose.matrix)
    }

    /// Ferramenta-Ferramenta: o robô faz o mesmo movimento (mesma flange) com a ferramenta nova: P' = P · V⁻¹ · N
    /// (pontos Object e World; Axis não muda).
    static func changeTool(_ p: PointRecord, from old: Pose, to new: Pose) -> PointRecord? {
        guard !p.isAxis else { return nil }
        return withPose(p, p.pose.matrix * old.matrix.inverse * new.matrix)
    }

    /// Correção da posição zero: desloca todos os pontos Object pelo delta D: P' = D · P.
    static func correctZero(_ p: PointRecord, delta: Pose) -> PointRecord? {
        guard !p.isAxis, !p.isWorld else { return nil }
        return withPose(p, delta.matrix * p.pose.matrix)
    }

    /// Suavizar orientação (modo linear do DXQ): o primeiro e o último mantêm a orientação; os do meio
    /// interpolam entre eles pela distância percorrida. Devolve as rotações novas, na ordem.
    static func smoothOrientations(_ poses: [Pose]) -> [Pose] {
        guard poses.count > 2 else { return poses }
        var dist = [0.0]
        for i in 1..<poses.count { dist.append(dist[i - 1] + simd_distance(poses[i].position, poses[i - 1].position)) }
        let total = dist.last!
        guard total > 1e-9 else { return poses }
        let a = poses.first!, b = poses.last!
        return poses.enumerated().map { i, p in
            guard i > 0, i < poses.count - 1 else { return p }
            var r = Pose.lerp(a, b, dist[i] / total)
            r.x = p.x; r.y = p.y; r.z = p.z
            return r
        }
    }

    static func withPose(_ p: PointRecord, _ m: Mat4) -> PointRecord {
        let q = Pose(matrix: m)
        var out = p
        out.values = [q.x, q.y, q.z, q.a, q.b, q.c]
        return out
    }
}
