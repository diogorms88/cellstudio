import Foundation
import simd

/// Uma linha da tabela de tipos de robô (gerada de DurrRobotTypesFiles.xlsx por tools/convert_robot_catalog.py).
public struct RobotCatalogEntry: Codable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var a1, theta1, a2, theta2, a3, d3, d4, d5: Double
    public var robotFile: String?
    public var linkFiles: [String: String]
    public var auxAssignment: String?

    public static func loadCatalog(from url: URL) throws -> [RobotCatalogEntry] {
        try JSONDecoder().decode([RobotCatalogEntry].self, from: Data(contentsOf: url))
            .filter { $0.a2 > 0 && $0.d4 != 0 } // só braços articulados com geometria completa
    }
}

public enum JointKind: String, Codable { case revolute, prismatic }

/// Junta no formato Denavit-Hartenberg usado pelo DXQ: T = Rz(θ) · Tz(d) · Tx(a) · Rx(α).
public struct DHJoint: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var kind: JointKind = .revolute
    public var thetaOffset: Double   // graus
    public var d: Double             // mm
    public var a: Double             // mm
    public var alpha: Double         // graus
    public var min: Double           // graus ou mm
    public var max: Double
    public var maxVelocity: Double = 120   // °/s ou mm/s

    public init(name: String, kind: JointKind = .revolute, thetaOffset: Double = 0, d: Double = 0, a: Double = 0, alpha: Double = 0, min: Double = -180, max: Double = 180, maxVelocity: Double = 120) {
        self.name = name; self.kind = kind; self.thetaOffset = thetaOffset; self.d = d; self.a = a; self.alpha = alpha; self.min = min; self.max = max; self.maxVelocity = maxVelocity
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, thetaOffset, d, a, alpha, min, max, maxVelocity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(JointKind.self, forKey: .kind) ?? .revolute
        thetaOffset = try c.decode(Double.self, forKey: .thetaOffset)
        d = try c.decode(Double.self, forKey: .d)
        a = try c.decode(Double.self, forKey: .a)
        alpha = try c.decode(Double.self, forKey: .alpha)
        min = try c.decode(Double.self, forKey: .min)
        max = try c.decode(Double.self, forKey: .max)
        maxVelocity = try c.decodeIfPresent(Double.self, forKey: .maxVelocity) ?? 120
    }

    public func transform(_ q: Double) -> Mat4 {
        let theta = kind == .revolute ? thetaOffset + q : thetaOffset
        let dd = kind == .prismatic ? d + q : d
        return Mat4.rotZ(rad(theta)) * Mat4.translation(Vec3(a, 0, dd)) * Mat4.rotX(rad(alpha))
    }
}

public struct RobotModel: Codable, Hashable {
    public var name: String
    public var base: Pose            // posição do robô na estação
    public var joints: [DHJoint]     // eixos principais (6)
    public var tool: Pose            // TCP relativo ao flange
    public var railEnabled: Bool
    public var railMin: Double
    public var railMax: Double
    /// O trilho translada em Z entre os frames pré/pós (preLinkFrame/postLinkFrame do machinedata).
    /// Padrão: B=90 → trilho ao longo do X da base.
    public var railPre: Pose = Pose(b: 90)
    public var railPost: Pose = Pose(b: -90)
    public var railMaxVelocity: Double = 1000
    /// Origem do dado: "catálogo" ou caminho do machinedata1.cfg
    public var source: String = "catálogo"
    /// Tipo cinemático (MachineData.RobotType), ex.: StandardArm, EcoPaint1
    public var robotType: String?
    /// Modelos 3D (.hsf) dos elos K1…K7, relativos a 3DObjects/Robots; "" quando não há
    public var linkFiles: [String] = []
    public var modelName: String?

    public init(name: String, base: Pose = Pose(), joints: [DHJoint], tool: Pose = Pose(z: 250), railEnabled: Bool = false, railMin: Double = 0, railMax: Double = 6000) {
        self.name = name; self.base = base; self.joints = joints; self.tool = tool
        self.railEnabled = railEnabled; self.railMin = railMin; self.railMax = railMax
    }

    enum CodingKeys: String, CodingKey { case name, base, joints, tool, railEnabled, railMin, railMax, railPre, railPost, railMaxVelocity, source, robotType, linkFiles, modelName }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        base = try c.decode(Pose.self, forKey: .base)
        joints = try c.decode([DHJoint].self, forKey: .joints)
        tool = try c.decode(Pose.self, forKey: .tool)
        railEnabled = try c.decode(Bool.self, forKey: .railEnabled)
        railMin = try c.decode(Double.self, forKey: .railMin)
        railMax = try c.decode(Double.self, forKey: .railMax)
        railPre = try c.decodeIfPresent(Pose.self, forKey: .railPre) ?? Pose(b: 90)
        railPost = try c.decodeIfPresent(Pose.self, forKey: .railPost) ?? Pose(b: -90)
        railMaxVelocity = try c.decodeIfPresent(Double.self, forKey: .railMaxVelocity) ?? 1000
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "catálogo"
        robotType = try c.decodeIfPresent(String.self, forKey: .robotType)
        linkFiles = try c.decodeIfPresent([String].self, forKey: .linkFiles) ?? []
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
    }

    /// Ordem dos elos no catálogo: K1 (base) … K7 (flange). K1 fica no frame da base, Kn+1 no frame após n eixos.
    public static let linkKeys = ["K1", "K2", "K3", "K4", "K5", "K6", "K7"]

    public mutating func assignModel(_ e: RobotCatalogEntry) {
        linkFiles = Self.linkKeys.map { e.linkFiles[$0] ?? "" }
        modelName = e.name
    }

    /// Escolhe no catálogo o tipo cujas medidas DH mais se aproximam das deste robô.
    public func bestCatalogMatch(_ catalog: [RobotCatalogEntry]) -> RobotCatalogEntry? {
        guard joints.count >= 4 else { return nil }
        let a1 = abs(joints[0].a), a2 = abs(joints[1].a), a3 = joints[2].a, d4 = abs(joints[3].d)
        func score(_ e: RobotCatalogEntry) -> Double {
            var s = abs(abs(e.a1) - a1) + abs(abs(e.a2) - a2) + abs(e.a3 - a3) + abs(abs(e.d4) - d4)
            if let t = robotType, t != e.kind { s += 30 }
            if e.linkFiles.isEmpty { s += 1000 }
            return s
        }
        guard let best = catalog.min(by: { score($0) < score($1) }), score(best) < 60 else { return nil }
        return best
    }

    /// Monta o modelo cinemático a partir do catálogo. Os comprimentos vêm da tabela da Dürr;
    /// altura da base, ângulos α e flange não constam nela (vêm do backup do controlador),
    /// por isso usamos valores típicos que o usuário pode ajustar.
    public init(catalog e: RobotCatalogEntry) {
        let isKukaLike = e.kind == "StandardArm" || e.kind == "ArticulatedArm"
        let baseHeight = isKukaLike ? 675.0 : 800.0
        joints = [
            DHJoint(name: "A1", thetaOffset: e.theta1, d: baseHeight, a: e.a1, alpha: -90, min: -180, max: 180),
            DHJoint(name: "A2", thetaOffset: -90 + e.theta2, a: e.a2, alpha: 0, min: -100, max: 100),
            DHJoint(name: "A3", d: e.d3, a: e.a3, alpha: -90, min: -170, max: 170),
            DHJoint(name: "A4", d: e.d4, alpha: 90, min: -350, max: 350),
            DHJoint(name: "A5", d: e.d5, alpha: -90, min: -125, max: 125),
            DHJoint(name: "A6", d: 150, alpha: 0, min: -350, max: 350),
        ]
        name = e.name
        robotType = e.kind
        linkFiles = Self.linkKeys.map { e.linkFiles[$0] ?? "" }
        modelName = e.name
        base = Pose()
        tool = Pose(z: 250)
        railEnabled = false
        railMin = 0
        railMax = 6000
    }

    public static let demo = RobotModel(catalog: RobotCatalogEntry(
        name: "Robô demo 6 eixos", kind: "EcoPaint1", a1: 300, theta1: 0, a2: 1000, theta2: 0, a3: 34.6, d3: 0, d4: 1513.92, d5: 0,
        robotFile: nil, linkFiles: [:]))
}

/// Estado articular: eixo de trilho (mm, opcional) + eixos principais (graus).
public struct JointState: Codable, Equatable, Hashable {
    public var rail: Double
    public var q: [Double]

    public init(rail: Double = 0, q: [Double]) { self.rail = rail; self.q = q }

    public static func home(for robot: RobotModel) -> JointState {
        var q = Array(repeating: 0.0, count: robot.joints.count)
        if q.count >= 5 { q[2] = 0; q[4] = 30 }
        return JointState(q: q)
    }
}
