import Foundation

/// Leitor do machinedata1.cfg do controlador Dürr (grupos MC.KINEMATIC:n e MC.KINEMATIC:n.Joint:k).
/// Mesmo formato lido pelo DXQ em MachineDataFromCatalogLoader.
public enum MachineData {
    public struct ParseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Lê um arquivo INI simples: [grupo] e chave = valor (ignora comentários // e ;).
    public static func parseINI(_ text: String) -> [String: [String: String]] {
        var groups: [String: [String: String]] = [:]
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix(";") || line.isEmpty { continue }
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                current = String(line[line.index(after: line.startIndex)..<end])
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            groups[current, default: [:]][key] = value
        }
        return groups
    }

    public static func load(_ url: URL, kinematic: Int = 0) throws -> RobotModel {
        let text = try String(contentsOf: url, encoding: .isoLatin1)
        var m = try parse(text, kinematic: kinematic)
        m.source = url.path
        return m
    }

    public static func parse(_ text: String, kinematic k: Int = 0) throws -> RobotModel {
        let g = parseINI(text)
        let prefix = "MC.KINEMATIC:\(k)"
        guard let mc = g[prefix] else { throw ParseError(message: "Grupo [\(prefix)] não encontrado") }
        func d(_ grp: [String: String]?, _ key: String, _ def: Double = 0) -> Double { grp?[key].flatMap { Double($0) } ?? def }

        let base = Pose(x: d(mc, "baseX"), y: d(mc, "baseY"), z: d(mc, "baseZ"), a: d(mc, "baseA"), b: d(mc, "baseB"), c: d(mc, "baseC"))
        var joints: [DHJoint] = []
        var rail: [String: String]?
        var idx = 0
        // os eixos podem vir como "Joint:0" ou "Joint1"
        while let j = g["\(prefix).Joint:\(idx)"] ?? g["\(prefix).Joint\(idx + 1)"] {
            idx += 1
            let type = (j["jointTypName"] ?? "ROT").uppercased()
            if type == "LIN" || joints.count >= 6 {
                if type == "LIN", rail == nil { rail = j }
                continue
            }
            joints.append(DHJoint(name: "A\(joints.count + 1)",
                                  kind: .revolute,
                                  thetaOffset: d(j, "rotationAroundZ"),
                                  d: d(j, "displacementAlongZ"),
                                  a: d(j, "displacementAlongX"),
                                  alpha: d(j, "rotationAroundX"),
                                  min: d(j, "minPos", -180),
                                  max: d(j, "maxPos", 180),
                                  maxVelocity: d(j, "maxVelo", 120)))
        }
        guard joints.count == 6 else { throw ParseError(message: "Esperava 6 eixos rotativos, achei \(joints.count)") }

        var model = RobotModel(name: mc["name"] ?? "Robô", base: base, joints: joints, tool: Pose())
        model.robotType = mc["robotTypName"]
        if let r = rail {
            model.railEnabled = true
            model.railMin = d(r, "minPos", 0)
            model.railMax = d(r, "maxPos", 1000)
            model.railMaxVelocity = d(r, "maxVelo", 1000)
            model.railPre = Pose(x: d(r, "preLinkFrameX"), y: d(r, "preLinkFrameY"), z: d(r, "preLinkFrameZ"),
                                 a: d(r, "preLinkFrameA"), b: d(r, "preLinkFrameB"), c: d(r, "preLinkFrameC"))
            model.railPost = Pose(x: d(r, "postLinkFrameX"), y: d(r, "postLinkFrameY"), z: d(r, "postLinkFrameZ"),
                                  a: d(r, "postLinkFrameA"), b: d(r, "postLinkFrameB"), c: d(r, "postLinkFrameC"))
        }
        return model
    }
}
