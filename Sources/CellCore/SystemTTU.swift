import Foundation

/// Declarações do sistema do controlador (`teachcontrol/_system.tt/system.ttu`):
/// tipos enumerados, estruturas, rotinas (os comandos que o editor oferece em "Inserir um comando")
/// e blocos de dados (POINT, TOOL, TRIGGERFRAME…, com o prefixo usado para nomear instâncias novas).
public struct EcoSystemDeclarations {
    public struct Parameter: Hashable {
        public var name: String
        public var type: String
        public var optional: Bool
    }

    public struct Routine: Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var parameters: [Parameter]
        public var returnType: String?
        public var group: String
        /// condição `enable="…"` do controlador (não avaliável offline)
        public var enableCondition: String?
        public var isHidden: Bool { group.isEmpty }
    }

    public struct Field: Hashable {
        public var name: String
        public var type: String
        public var defaultValue: String?
    }

    public struct Block: Hashable {
        public var name: String
        public var prefix: String
        public var fields: [Field]
    }

    public var enums: [String: [String]] = [:]
    public var routines: [String: Routine] = [:]
    public var blocks: [String: Block] = [:]

    public init() {}

    public static let builtinGroupLogic = "Logic"
    public static let builtinGroupComment = "Comment"

    /// Comandos da própria linguagem (não estão no .ttu), como no `EcoTalkDeclarations.AddNativeCmd` do DXQ.
    public static let builtins: [Routine] = [
        Routine(name: "CALL", parameters: [Parameter(name: "progname", type: "SUB", optional: false)], group: builtinGroupLogic),
        Routine(name: "RETURN", parameters: [], group: builtinGroupLogic),
        Routine(name: "LABEL", parameters: [Parameter(name: "ident", type: "LABEL", optional: false)], group: builtinGroupLogic),
        Routine(name: "GOTO", parameters: [Parameter(name: "ident", type: "LABEL", optional: false)], group: builtinGroupLogic),
        Routine(name: "ASSIGNMENT", parameters: [Parameter(name: "varname", type: "VARIABLE", optional: false),
                                                 Parameter(name: "expression", type: "EXPRESSION", optional: false)], group: builtinGroupLogic),
        Routine(name: "IF", parameters: [Parameter(name: "expression", type: "EXPRESSION_BOOL", optional: false)], group: builtinGroupLogic),
        Routine(name: "ELSIF", parameters: [Parameter(name: "expression", type: "EXPRESSION_BOOL", optional: false)], group: builtinGroupLogic),
        Routine(name: "ELSE", parameters: [], group: builtinGroupLogic),
        Routine(name: "WHILE", parameters: [Parameter(name: "expression", type: "EXPRESSION_BOOL", optional: false)], group: builtinGroupLogic),
        Routine(name: "LOOP", parameters: [Parameter(name: "expression", type: "EXPRESSION_INT", optional: false)], group: builtinGroupLogic),
        Routine(name: "//", parameters: [Parameter(name: "comment", type: "COMMENT", optional: false)], group: builtinGroupComment),
    ]

    public func routine(_ name: String) -> Routine? {
        let key = name.uppercased()
        return routines[key] ?? Self.builtins.first { $0.name == key }
    }

    /// Grupos para o menu "Inserir um comando": grupo → nomes ordenados.
    /// `showAll == false` esconde rotinas com condição `enable` (dependem da configuração do robô),
    /// exceto as já usadas (`used`), como o DXQ faz com `ShowAllCommandsOnInsert`.
    public func insertGroups(showAll: Bool, used: Set<String> = []) -> [(group: String, commands: [String])] {
        var groups: [String: [String]] = [:]
        for r in routines.values where !r.isHidden {
            if !showAll, r.enableCondition != nil, !used.contains(r.name) { continue }
            groups[r.group, default: []].append(r.name)
        }
        for r in Self.builtins { groups[r.group, default: []].append(r.name) }
        let order = ["MOVEMENT", "DYNAMIC", "GEOMETRIC", "PROCESS", Self.builtinGroupLogic, "OTHER", Self.builtinGroupComment]
        return groups.map { ($0.key, $0.value.sorted()) }.sorted { a, b in
            let ia = order.firstIndex(of: a.0) ?? order.count, ib = order.firstIndex(of: b.0) ?? order.count
            return ia != ib ? ia < ib : a.0.localizedStandardCompare(b.0) == .orderedAscending
        }
    }

    public static func groupTitle(_ g: String) -> String {
        switch g {
        case "MOVEMENT": "Movimento"
        case "DYNAMIC": "Dinâmica"
        case "GEOMETRIC": "Geometria"
        case "PROCESS": "Processo"
        case "OTHER": "Outros"
        case builtinGroupLogic: "Lógica"
        case builtinGroupComment: "Comentário"
        case "Timer": "Temporizador"
        default: g
        }
    }

    /// Prefixo para uma instância nova (regra do `EcoTalkTid.GetNewTypeInstanceName`: POINT → P, TRIGGERFRAME → TRG, outros → New).
    public func defaultPrefix(for type: String) -> String {
        switch type.uppercased() {
        case "POINT", "POINT_M", "POLYPOINT": "P"
        case "TRIGGERFRAME": "TRG"
        default: "New"
        }
    }

    // MARK: Leitura

    public static func load(_ url: URL) -> EcoSystemDeclarations? {
        guard let text = (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> EcoSystemDeclarations {
        var d = EcoSystemDeclarations()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        var section = ""          // TYPE, VAR
        var block: Block?
        var structName: String?
        let routineRx = try! NSRegularExpression(pattern: #"^ROUTINE\s+(\w+)\s*\(([^)]*)\)\s*(?::\s*(\w+))?\s*(?:\{(.*)\})?\s*;"#)
        let blockRx = try! NSRegularExpression(pattern: #"^BLOCK\s+(\w+)\s*(?:\{\s*prefix\s*=\s*"([^"]*)"\s*\})?"#)

        func groups(_ rx: NSRegularExpression, _ s: String) -> [String?]? {
            guard let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
        }

        for line in lines {
            if line.isEmpty || line.hasPrefix("//") { continue }
            if let g = groups(blockRx, line), let name = g[0] {
                block = Block(name: name.uppercased(), prefix: g[1] ?? "", fields: [])
                continue
            }
            if line.hasPrefix("END_BLOCK") {
                if let b = block { d.blocks[b.name] = b }
                block = nil; continue
            }
            if line == "TYPE" || line == "VAR" { section = line; continue }
            if line.hasPrefix("END_TYPE") || line.hasPrefix("END_VAR") { section = ""; continue }
            if let g = groups(routineRx, line), let name = g[0] {
                var group = "", enable: String?
                for attr in (g[3] ?? "").components(separatedBy: "|") {
                    let kv = attr.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if kv[0] == "macro" { group = v } else if kv[0] == "enable" { enable = v }
                }
                let params = (g[1] ?? "").split(separator: ";").compactMap { p -> Parameter? in
                    let parts = p.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    var words = parts[0].split(separator: " ").map(String.init)
                    let optional = words.contains("OPTIONAL")
                    words.removeAll { ["OPTIONAL", "VAR_IN", "CONST", "VAR"].contains($0) }
                    return Parameter(name: words.last ?? "", type: parts[1].trimmingCharacters(in: .whitespaces).uppercased(), optional: optional)
                }
                d.routines[name.uppercased()] = Routine(name: name.uppercased(), parameters: params, returnType: g[2]?.uppercased(),
                                                        group: group, enableCondition: enable)
                continue
            }
            if section == "TYPE" {
                if let s = structName {
                    if line.hasPrefix("END_STRUCT") { structName = nil; _ = s }
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("STRUCT") { structName = name; continue }
                if rest.hasPrefix("("), let close = rest.lastIndex(of: ")") {
                    d.enums[name] = rest[rest.index(after: rest.startIndex)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            } else if section == "VAR", block != nil {
                // nome : TIPO [:= padrão];
                let body = line.hasSuffix(";") ? String(line.dropLast()) : line
                guard let colon = body.firstIndex(of: ":") else { continue }
                let name = body[..<colon].trimmingCharacters(in: .whitespaces)
                var type = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                var def: String?
                if let a = type.range(of: ":=") {
                    def = type[a.upperBound...].trimmingCharacters(in: .whitespaces)
                    type = type[..<a.lowerBound].trimmingCharacters(in: .whitespaces)
                }
                block?.fields.append(Field(name: name, type: type.uppercased(), defaultValue: def))
            }
        }
        return d
    }
}
