import Foundation

/// Cópia do flash de um controlador Dürr (pasta com config/machinedata1.cfg e teachcontrol/kin1),
/// tanto no formato "flash" (R11/config, R11/teachcontrol) quanto no de backup completo
/// (R22/application/control/config, …/teachcontrol).
public struct RobotBackup {
    public var root: URL
    public var robot: RobotModel
    public var kinDir: URL?
    public var systemData: [EcoTalkDeclaration]   // kin1/_global.tt/_globalvars.tid
    public var projects: [EcoTalkProject]
    /// config/rpcsetup.ini (equipamentos para a vista 3D, seção [3DOnSiteRCU1])
    public var setupURL: URL?
    /// teachcontrol/_system.tt/system.ttu (comandos, tipos e blocos de dados do controlador)
    public var system: EcoSystemDeclarations?
    /// BCU1/typelists/typelist.ini: tipos de carroceria em produção → projeto/programa que o robô roda
    public var typeList: [TypeListEntry] = []

    public static func load(_ root: URL) throws -> RobotBackup {
        guard let md = find(root, name: "machinedata1.cfg") else {
            throw MachineData.ParseError(message: "machinedata1.cfg não encontrado em \(root.lastPathComponent)")
        }
        let robot = try MachineData.load(md)
        let teach = md.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("teachcontrol/kin1")
        let kin = FileManager.default.fileExists(atPath: teach.path) ? teach : find(root, name: "kin1", directory: true)
        var projects: [EcoTalkProject] = []
        var sys: [EcoTalkDeclaration] = []
        if let kin {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: kin, includingPropertiesForKeys: nil)) ?? []
            projects = dirs.filter { $0.pathExtension == "tt" && $0.lastPathComponent.lowercased() != "_global.tt" }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
                .map(EcoTalkProject.load)
            let g = kin.appendingPathComponent("_global.tt/_globalvars.tid")
            sys = EcoTalk.parseData((try? String(contentsOf: g, encoding: .isoLatin1)) ?? "")
        }
        let ttu = kin.map { $0.deletingLastPathComponent().appendingPathComponent("_system.tt/system.ttu") }
        let system = ttu.flatMap { FileManager.default.fileExists(atPath: $0.path) ? EcoSystemDeclarations.load($0) : nil }
            ?? find(root, name: "system.ttu").flatMap(EcoSystemDeclarations.load)
        let setup = md.deletingLastPathComponent().appendingPathComponent("rpcsetup.ini")
        return RobotBackup(root: root, robot: robot, kinDir: kin, systemData: sys, projects: projects,
                           setupURL: FileManager.default.fileExists(atPath: setup.path) ? setup : nil, system: system,
                           typeList: TypeListEntry.load(root))
    }

    /// Procura o arquivo, preferindo o caminho mais curto (evita cópias antigas em subpastas).
    static func find(_ root: URL, name: String, directory: Bool = false) -> URL? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var best: URL?
        for case let u as URL in e where u.lastPathComponent == name {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir != directory { continue }
            if best == nil || u.pathComponents.count < best!.pathComponents.count { best = u }
        }
        return best
    }
}


/// Uma entrada do typelist.ini (ex.: [Type1] TypNo=1, Name=2700, Proj=Polo_MSE, Prog=Main, Description=Polo_Track).
public struct TypeListEntry: Hashable, Identifiable {
    /// seção do arquivo ([Type9]); o TypNo pode se repetir (ex.: Type6 e Type9 com TypNo=6)
    public var id: String { section }
    public var section: String
    public var number: Int
    public var name: String
    public var project: String
    public var program: String
    public var description: String

    public var isEmpty: Bool { project.isEmpty }
    public var label: String { "\(number) – \(name.isEmpty ? "?" : name)" + (description.isEmpty ? "" : " (\(description))") + " → \(project)/\(program)" }

    public static func parse(_ text: String) -> [TypeListEntry] {
        MachineData.parseINI(text).compactMap { section, kv -> TypeListEntry? in
            guard section.lowercased().hasPrefix("type"), let n = Int(kv["TypNo"] ?? "") else { return nil }
            return TypeListEntry(section: section, number: n, name: kv["Name"] ?? "", project: kv["Proj"] ?? "", program: kv["Prog"] ?? "",
                                 description: kv["Description"] ?? "")
        }.sorted { $0.number != $1.number ? $0.number < $1.number : $0.section.localizedStandardCompare($1.section) == .orderedAscending }
    }

    /// typelist.ini do backup (o "oficial", não cópias como typelist_nova.ini).
    public static func load(_ root: URL) -> [TypeListEntry] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var best: URL?
        for case let u as URL in e where u.lastPathComponent.lowercased() == "typelist.ini" {
            if best == nil || u.pathComponents.count < best!.pathComponents.count { best = u }
        }
        guard let url = best, let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return [] }
        return parse(text)
    }
}
