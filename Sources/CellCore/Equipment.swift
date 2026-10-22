import Foundation

/// Equipamentos 3D de um robô (trilho, carro, peças do punho, ferramenta), como o DXQ monta:
/// `rpcsetup.ini [3DOnSiteRCU1]` diz o que está instalado; `Tools.xml`, `DurrRobotParts.xml` e a aba
/// `AuxJointsFileAssignment` (rails.json) dizem quais arquivos .hsf usar.
public struct RobotEquipment: Codable, Hashable {
    public struct RailPart: Codable, Hashable { public var file: String; public var position: Double; public var length: Double }
    public var railParts: [RailPart] = []
    public var sled: String?
    public var robotParts: [Int: [String]] = [:]   // eixo → arquivos (relativos a 3DObjects/Robots)
    public var tool: String?                        // relativo a 3DObjects/Tools
    public var rootOffset: Double = 0               // mm (translação Z do arquivo K1, `GetRootOffsetFromFirstPart`)
    public var summary: [String] = []
    public init() {}
}

public struct RailEntry: Codable {
    public var type: String
    public var preA, preB, preC: Double
    public var sled: String
    public var sledWidth: Double
    public var rail1500: String
    public var rail2000: String
    public var railTypeId: String?
    public var singlePart: Bool
}

public enum EquipmentCatalog {
    /// Seção [3DOnSiteRCUn] do rpcsetup.ini.
    public static func readSetup(_ url: URL, rcu: Int = 1) -> (parts: [String], rail: String?, tool: String?)? {
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return nil }
        // valores podem ter comentário na mesma linha: "HL   ;V, L, HL…"
        let g = (MachineData.parseINI(text)["3DOnSiteRCU\(rcu)"] ?? [:]).mapValues {
            ($0.components(separatedBy: ";").first ?? $0).trimmingCharacters(in: .whitespaces)
        }
        let n = Int(g["NoOfUsedParts"] ?? "") ?? 0
        let parts = (1...max(n, 1)).compactMap { g["UsedPart\($0)"] }.filter { !$0.isEmpty }
        let rail = g["EcoRailType"].flatMap { $0.isEmpty ? nil : $0 }
        let tool = g["UsedTool"].flatMap { $0.isEmpty ? nil : $0 }
        if parts.isEmpty && rail == nil && tool == nil { return nil }
        return (parts, rail, tool)
    }

    /// ToolId → caminho (Tools.xml).
    public static func tools(_ url: URL) -> [String: String] {
        guard let x = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        let rx = try! NSRegularExpression(pattern: #"ToolId="([^"]+)">\s*<Name>[^<]*</Name>(?:\s*<Description>[^<]*</Description>)?\s*<Path>([^<]+)</Path>"#)
        for m in rx.matches(in: x, range: NSRange(x.startIndex..., in: x)) {
            out[String(x[Range(m.range(at: 1), in: x)!])] = String(x[Range(m.range(at: 2), in: x)!]).replacingOccurrences(of: "\\", with: "/")
        }
        return out
    }

    /// PartId → (eixo, arquivos) (DurrRobotParts.xml).
    public static func robotParts(_ url: URL) -> [String: (Int, [String])] {
        guard let x = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var joints: [String: Int] = [:]
        let cat = try! NSRegularExpression(pattern: #"CategoryId="([^"]+)">[\s\S]*?<AttachedToJoint>(-?\d+)</AttachedToJoint>"#)
        for m in cat.matches(in: x, range: NSRange(x.startIndex..., in: x)) {
            joints[String(x[Range(m.range(at: 1), in: x)!])] = Int(x[Range(m.range(at: 2), in: x)!])
        }
        var out: [String: (Int, [String])] = [:]
        let part = try! NSRegularExpression(pattern: #"PartId="([^"]+)">\s*<CategoryId>([^<]+)</CategoryId>([\s\S]*?)</Part>"#)
        let path = try! NSRegularExpression(pattern: #"<Path>([^<]+)</Path>"#)
        for m in part.matches(in: x, range: NSRange(x.startIndex..., in: x)) {
            let id = String(x[Range(m.range(at: 1), in: x)!])
            let body = String(x[Range(m.range(at: 3), in: x)!])
            let files = path.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
                String(body[Range($0.range(at: 1), in: body)!]).replacingOccurrences(of: "\\", with: "/")
            }
            out[id] = (joints[String(x[Range(m.range(at: 2), in: x)!])] ?? 0, files)
        }
        return out
    }

    /// Divide o curso do trilho em peças de 2000/1500 mm como o DXQ (`LoadRailModel`).
    static func railLayout(min: Double, max: Double, sledWidth: Double) -> (Int, Int, Double) {
        let need = max - min + sledWidth
        var best = (0, Int(ceil(need / 1500)), Double.infinity)
        for n2 in 0...20 {
            let rest = need - Double(n2) * 2000
            let n1 = rest <= 0 ? 0 : Int(ceil(rest / 1500))
            let total = Double(n2) * 2000 + Double(n1) * 1500
            if total >= need && total < best.2 { best = (n2, n1, total) }
        }
        let start = -(best.2 - need) / 2 + min - sledWidth / 2
        return (best.0, best.1, start)
    }

    public static func resolve(robot: RobotModel, catalog: [RobotCatalogEntry], rails: [RailEntry],
                               setup: (parts: [String], rail: String?, tool: String?),
                               tools: [String: String], parts: [String: (Int, [String])], rootOffset: Double) -> RobotEquipment {
        var eq = RobotEquipment()
        eq.rootOffset = rootOffset
        // trilho: tipo de eixo auxiliar do catálogo + mesmo pré-frame do machinedata
        if robot.railEnabled, setup.rail != nil || true,
           let aux = catalog.first(where: { $0.name == robot.modelName })?.auxAssignment {
            let cands = rails.filter { $0.type == aux && (setup.rail == nil || $0.railTypeId == setup.rail) }
            let p = robot.railPre
            if let r = cands.min(by: { abs($0.preA - p.a) + abs($0.preB - p.b) + abs($0.preC - p.c) < abs($1.preA - p.a) + abs($1.preB - p.b) + abs($1.preC - p.c) }),
               abs(r.preA - p.a) + abs(r.preB - p.b) + abs(r.preC - p.c) < 1 {
                eq.sled = r.sled
                if r.singlePart {
                    eq.railParts = [.init(file: r.rail1500, position: 0, length: 0)]
                } else {
                    let (n2, n1, start) = railLayout(min: robot.railMin, max: robot.railMax, sledWidth: r.sledWidth)
                    for i in 0..<n2 { eq.railParts.append(.init(file: r.rail2000, position: start + (Double(i) + 0.5) * 2000, length: 2000)) }
                    let s1 = start + Double(n2) * 2000
                    for i in 0..<n1 { eq.railParts.append(.init(file: r.rail1500, position: s1 + (Double(i) + 0.5) * 1500, length: 1500)) }
                }
                eq.summary.append("trilho \(r.railTypeId ?? aux) (\(eq.railParts.count) peças)")
            }
        }
        for id in setup.parts {
            if let (j, files) = parts[id] { eq.robotParts[j, default: []] += files; eq.summary.append("peça \(id) no eixo \(j)") }
        }
        if let t = setup.tool, let path = tools[t] { eq.tool = path; eq.summary.append("ferramenta \(t)") }
        return eq
    }
}
