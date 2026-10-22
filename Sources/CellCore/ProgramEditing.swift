import Foundation

/// Uma linha do .tip como o editor de programa a mostra (uma linha = um comando, como o `CmdElementViewModel` do DXQ).
public struct EcoProgramLine: Hashable, Identifiable {
    public enum Kind: Hashable { case blank, comment, command }

    public var id: Int { index }
    public var index: Int            // 0-based
    public var text: String          // linha original, sem quebra
    public var indent: String
    public var kind: Kind
    /// `##` – comando desativado (o controlador ignora)
    public var isDisabled: Bool
    /// nome em maiúsculas (PTP, GUN, IF, CALL, ASSIGNMENT, //)
    public var name: String
    /// corpo sem indentação, sem `##` e sem comentário no fim
    public var body: String
    public var args: [String]
    public var trailingComment: String?

    public var lineNumber: Int { index + 1 }

    public static func parse(_ text: String, index: Int) -> EcoProgramLine {
        let indent = String(text.prefix { $0 == " " || $0 == "\t" })
        var body = text.dropFirst(indent.count).trimmingCharacters(in: .whitespaces)
        if body.isEmpty {
            return EcoProgramLine(index: index, text: text, indent: indent, kind: .blank, isDisabled: false, name: "", body: "", args: [])
        }
        if body.hasPrefix("//") {
            return EcoProgramLine(index: index, text: text, indent: indent, kind: .comment, isDisabled: false, name: "//",
                                  body: String(body.dropFirst(2)), args: [])
        }
        var disabled = false
        if body.hasPrefix("##") { disabled = true; body = body.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        var comment: String?
        if let c = Self.commentStart(body) {
            comment = String(body[body.index(c, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<c]).trimmingCharacters(in: .whitespaces)
        }
        let (name, args) = Self.split(body)
        return EcoProgramLine(index: index, text: text, indent: indent, kind: .command, isDisabled: disabled,
                              name: name, body: body, args: args, trailingComment: comment)
    }

    /// `//` fora de string
    static func commentStart(_ s: String) -> String.Index? {
        var inString = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\"" { inString.toggle() }
            let n = s.index(after: i)
            if !inString, ch == "/", n < s.endIndex, s[n] == "/" { return i }
            i = n
        }
        return nil
    }

    static let flowKeywords: Set<String> = ["IF", "ELSIF", "ELSE", "END_IF", "WHILE", "END_WHILE", "LOOP", "END_LOOP", "LABEL", "GOTO", "RETURN"]

    /// Nome e parâmetros de um comando: `PTP(P1)`, `IF expr THEN`, `CALL x()`, `X := expr`.
    static func split(_ body: String) -> (String, [String]) {
        let up = body.uppercased()
        let firstWord = String(up.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        if firstWord == "CALL" {
            let rest = body.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ("CALL", [rest.replacingOccurrences(of: "()", with: "").trimmingCharacters(in: .whitespaces)])
        }
        if flowKeywords.contains(firstWord) {
            var rest = body.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)
            for suffix in [" THEN", " DO"] where rest.uppercased().hasSuffix(suffix) { rest = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
            if rest.uppercased() == "THEN" || rest.uppercased() == "DO" { rest = "" }
            return (firstWord, rest.isEmpty ? [] : [rest])
        }
        if let assign = body.range(of: ":="), !body[..<assign.lowerBound].contains("(") {
            return ("ASSIGNMENT", [body[..<assign.lowerBound].trimmingCharacters(in: .whitespaces),
                                   body[assign.upperBound...].trimmingCharacters(in: .whitespaces)])
        }
        if let open = body.firstIndex(of: "("), let close = body.lastIndex(of: ")"), open < close {
            return (body[..<open].trimmingCharacters(in: .whitespaces).uppercased(), EcoTalk.splitArgs(String(body[body.index(after: open)..<close])))
        }
        return (firstWord.isEmpty ? up : firstWord, [])
    }

    /// Abre um bloco (a linha seguinte fica um nível mais para dentro).
    public var opensBlock: Bool { kind == .command && ["IF", "ELSIF", "ELSE", "WHILE", "LOOP", "RSELECT"].contains(name) }
}

/// Operações do editor de programa sobre um `EcoTalkProgram` (.tip + .tid), linha a linha,
/// preservando a formatação e as quebras de linha (CRLF) do arquivo.
public enum EcoProgramEditor {
    // MARK: Linhas

    public static func newline(_ s: String) -> String { s.contains("\r\n") ? "\r\n" : "\n" }

    public static func rawLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var lines = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }      // quebra final
        return lines
    }

    static func join(_ lines: [String], like original: String) -> String {
        guard !lines.isEmpty else { return "" }
        let nl = newline(original)
        let trailing = original.isEmpty || original.hasSuffix("\n")
        return lines.joined(separator: nl) + (trailing ? nl : "")
    }

    public static func lines(_ p: EcoTalkProgram) -> [EcoProgramLine] {
        rawLines(p.source).enumerated().map { EcoProgramLine.parse($0.element, index: $0.offset) }
    }

    static func edit(_ p: inout EcoTalkProgram, _ f: (inout [String]) -> Void) {
        var l = rawLines(p.source)
        f(&l)
        p.source = join(l, like: p.source.isEmpty ? "\r\n" : p.source)
    }

    /// Indentação para um comando inserido depois da linha `after` (nil = início).
    public static func indent(after: Int?, in p: EcoTalkProgram) -> String {
        let ls = lines(p)
        guard let after, ls.indices.contains(after) else { return ls.first(where: { $0.kind == .command })?.indent ?? "" }
        let ref = ls[after]
        return ref.opensBlock ? ref.indent + "  " : ref.indent
    }

    /// Insere linhas depois de `after` (nil = no início). Devolve os índices novos.
    @discardableResult
    public static func insert(_ newLines: [String], after: Int?, in p: inout EcoTalkProgram) -> [Int] {
        let count = rawLines(p.source).count
        let at = after.map { min($0 + 1, count) } ?? 0
        edit(&p) { $0.insert(contentsOf: newLines, at: at) }
        return Array(at..<(at + newLines.count))
    }

    public static func delete(_ rows: Set<Int>, in p: inout EcoTalkProgram) {
        edit(&p) { l in for i in rows.sorted(by: >) where l.indices.contains(i) { l.remove(at: i) } }
    }

    public static func replace(_ row: Int, with text: String, in p: inout EcoTalkProgram) {
        edit(&p) { l in if l.indices.contains(row) { l[row] = text } }
    }

    /// "Transformar linha em comentário": `//` antes do comando.
    public static func commentOut(_ rows: Set<Int>, in p: inout EcoTalkProgram) {
        let ls = lines(p)
        edit(&p) { l in
            for i in rows where ls.indices.contains(i) && ls[i].kind == .command {
                l[i] = ls[i].indent + "//" + ls[i].text.dropFirst(ls[i].indent.count).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// "Retirar comentário": tira o `//` de linhas que voltam a ser comandos.
    public static func commentIn(_ rows: Set<Int>, in p: inout EcoTalkProgram) {
        let ls = lines(p)
        edit(&p) { l in
            for i in rows where ls.indices.contains(i) && ls[i].kind == .comment {
                let body = ls[i].body.trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty, EcoProgramLine.parse(body, index: 0).kind == .command else { continue }
                l[i] = ls[i].indent + body
            }
        }
    }

    /// Comandos que podem ser desativados (`##`): não vale para estrutura de blocos.
    public static func canDisable(_ line: EcoProgramLine) -> Bool {
        line.kind == .command && !["IF", "ELSIF", "ELSE", "END_IF", "WHILE", "END_WHILE", "LOOP", "END_LOOP", "RSELECT", "RDESELECT"].contains(line.name)
    }

    public static func setDisabled(_ rows: Set<Int>, _ disabled: Bool, in p: inout EcoTalkProgram) {
        let ls = lines(p)
        edit(&p) { l in
            for i in rows where ls.indices.contains(i) && canDisable(ls[i]) && ls[i].isDisabled != disabled {
                let rest = l[i].dropFirst(ls[i].indent.count).trimmingCharacters(in: .whitespaces)
                l[i] = ls[i].indent + (disabled ? "##" + rest : String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    /// "Inverter sentido do movimento": inverte a ordem das linhas selecionadas, nas mesmas posições.
    public static func reverse(_ rows: Set<Int>, in p: inout EcoTalkProgram) {
        let sorted = rows.sorted()
        edit(&p) { l in
            guard sorted.allSatisfy({ l.indices.contains($0) }) else { return }
            let texts = sorted.map { l[$0] }
            for (k, i) in sorted.enumerated() { l[i] = texts[texts.count - 1 - k] }
        }
    }

    /// Move as linhas selecionadas uma posição para cima (-1) ou para baixo (+1). Devolve a nova seleção.
    public static func move(_ rows: Set<Int>, by delta: Int, in p: inout EcoTalkProgram) -> Set<Int> {
        let sorted = rows.sorted()
        var l = rawLines(p.source)
        guard let first = sorted.first, let last = sorted.last, first + delta >= 0, last + delta < l.count else { return rows }
        let block = sorted.map { l[$0] }
        for i in sorted.reversed() { l.remove(at: i) }
        let at = first + delta
        l.insert(contentsOf: block, at: at)
        p.source = join(l, like: p.source)
        return Set(at..<(at + block.count))
    }

    // MARK: Formatação de comandos

    public static func format(name: String, args: [String]) -> String {
        switch name.uppercased() {
        case "CALL": return "CALL \((args.first ?? "").replacingOccurrences(of: "()", with: ""))()"
        case "IF", "ELSIF": return "\(name.uppercased()) \(args.first ?? "") THEN"
        case "WHILE", "LOOP": return "\(name.uppercased()) \(args.first ?? "") DO"
        case "ELSE", "END_IF", "END_WHILE", "END_LOOP", "RETURN": return name.uppercased()
        case "LABEL", "GOTO": return "\(name.uppercased()) \(args.first ?? "")"
        case "ASSIGNMENT": return "\(args.first ?? "") := \(args.count > 1 ? args[1] : "")"
        case "//": return "//" + (args.first ?? "")
        default: return "\(name.uppercased())(\(args.joined(separator: ", ")))"
        }
    }

    /// Linhas a inserir para um comando (blocos levam o fechamento junto, como no DXQ).
    public static func insertion(name: String, args: [String], indent: String) -> [String] {
        let first = indent + format(name: name, args: args)
        switch name.uppercased() {
        case "IF": return [first, indent + "END_IF"]
        case "WHILE": return [first, indent + "END_WHILE"]
        case "LOOP": return [first, indent + "END_LOOP"]
        default: return [first]
        }
    }

    // MARK: Dados (.tid)

    public static func declarationLines(_ p: EcoTalkProgram) -> [String] { rawLines(p.data) }

    public static func formatNumber(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    public static func formatDeclaration(name: String, type: String, args: [String]) -> String {
        args.count == 1 && !type.hasPrefix("POINT") && !["TOOL", "OBJECT", "TRIGGERFRAME"].contains(type)
            ? "\(name) : \(type) := \(args[0])"
            : "\(name) : \(type) := (\(args.joined(separator: ", ")))"
    }

    /// Cria ou substitui a declaração `name` no .tid (nova vai para o fim da seção `// TIPO`).
    public static func setDeclaration(name: String, type: String, args: [String], in p: inout EcoTalkProgram) {
        let text = formatDeclaration(name: name, type: type, args: args)
        var l = rawLines(p.data)
        let decls = EcoTalk.parseData(p.data)
        if let d = decls.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            l[d.line - 1] = text
        } else if let lastOfType = decls.last(where: { $0.type == type.uppercased() }) {
            l.insert(text, at: lastOfType.line)
        } else {
            if !l.isEmpty && !(l.last ?? "").isEmpty { l.append("//--------------------------------------------") }
            l.append("// \(type.uppercased())")
            l.append(text)
        }
        p.data = join(l, like: p.data.isEmpty ? (p.source.contains("\r\n") ? "\r\n" : "\n") : p.data)
    }

    public static func removeDeclaration(_ name: String, in p: inout EcoTalkProgram) {
        guard let d = EcoTalk.parseData(p.data).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        var l = rawLines(p.data)
        l.remove(at: d.line - 1)
        p.data = join(l, like: p.data)
    }

    /// Primeiro nome livre `prefixoN` (regra do DXQ), considerando as declarações locais e as do projeto.
    public static func nextFreeName(prefix: String, taken: Set<String>) -> String {
        let up = Set(taken.map { $0.uppercased() })
        for i in 1..<32000 where !up.contains((prefix + String(i)).uppercased()) { return prefix + String(i) }
        return prefix + "X"
    }

    /// Prefixo usado de fato no programa para um tipo (ex.: TR para TRIGGERFRAME), senão o padrão.
    public static func prefix(for type: String, in p: EcoTalkProgram, fallback: String) -> String {
        var count: [String: Int] = [:]
        for d in EcoTalk.parseData(p.data) where d.type == type.uppercased() {
            let pre = String(d.name.prefix { !$0.isNumber })
            if !pre.isEmpty, d.name.dropFirst(pre.count).allSatisfy(\.isNumber), !d.name.dropFirst(pre.count).isEmpty {
                count[pre, default: 0] += 1
            }
        }
        return count.max { $0.value < $1.value }?.key ?? fallback
    }

    /// Nomes de dados usados por um comando (para copiar/colar levar os pontos junto).
    public static func references(_ line: EcoProgramLine, declared: Set<String>) -> [String] {
        let up = Dictionary(declared.map { ($0.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let tokens = line.args.flatMap { $0.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) }.map(String.init)
        var out: [String] = []
        for t in tokens { if let n = up[t.uppercased()], !out.contains(n) { out.append(n) } }
        return out
    }

    /// Renomeia um dado no .tid e em todas as linhas do .tip (palavra inteira).
    public static func rename(_ old: String, to new: String, in p: inout EcoTalkProgram) {
        let rx = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: old) + "\\b", options: .caseInsensitive)
        func sub(_ s: String) -> String { rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: new)) }
        var l = rawLines(p.data)
        if let d = EcoTalk.parseData(p.data).first(where: { $0.name.caseInsensitiveCompare(old) == .orderedSame }) {
            l[d.line - 1] = sub(l[d.line - 1])
            p.data = join(l, like: p.data)
        }
        // só fora de comentários
        edit(&p) { lines in
            for i in lines.indices {
                let parsed = EcoProgramLine.parse(lines[i], index: i)
                guard parsed.kind == .command else { continue }
                if let c = EcoProgramLine.commentStart(lines[i]) {
                    lines[i] = sub(String(lines[i][..<c])) + lines[i][c...]
                } else {
                    lines[i] = sub(lines[i])
                }
            }
        }
    }

    /// "Reindexar pontos selecionados": renomeia os pontos usados pelas linhas, na ordem, para prefixoN, prefixoN+1…
    /// Nomes já ocupados por outros pontos são pulados. Devolve (antigo, novo).
    @discardableResult
    public static func reindexPoints(_ rows: Set<Int>, prefix: String, start: Int, in p: inout EcoTalkProgram) -> [(String, String)] {
        let decls = EcoTalk.parseData(p.data)
        let points = decls.filter { $0.type == "POINT" }
        let pointNames = Set(points.map(\.name))
        var ordered: [String] = []
        for l in lines(p) where rows.contains(l.index) && l.kind == .command {
            for r in references(l, declared: pointNames) where !ordered.contains(r) { ordered.append(r) }
        }
        let others = Set(decls.map { $0.name.uppercased() }).subtracting(ordered.map { $0.uppercased() })
        var plan: [(String, String)] = []
        var n = start
        for old in ordered {
            while others.contains((prefix + String(n)).uppercased()) { n += 1 }
            plan.append((old, prefix + String(n)))
            n += 1
        }
        // dois passos para não colidir (P3→P1 enquanto P1→P2…)
        for (i, (old, _)) in plan.enumerated() where old != plan[i].1 { rename(old, to: "__reidx\(i)__", in: &p) }
        for (i, (old, new)) in plan.enumerated() where old != new { rename("__reidx\(i)__", to: new, in: &p) }
        return plan.filter { $0.0 != $0.1 }
    }

    /// Aplica alterações da análise a um programa (de baixo para cima, para as linhas não se deslocarem).
    public static func apply(_ edits: [SourceEdit], to p: inout EcoTalkProgram) {
        func rank(_ op: SourceEdit.Op) -> Int {
            switch op { case .insertAfter: 0; case .replace, .disable, .delete: 1; case .insertBefore: 2 }
        }
        let sorted = edits.sorted { $0.line != $1.line ? $0.line > $1.line : rank($0.op) < rank($1.op) }
        edit(&p) { l in
            for e in sorted {
                let i = e.line - 1
                guard l.indices.contains(i) || (i == l.count && { if case .insertBefore = e.op { return true }; return false }()) else { continue }
                switch e.op {
                case .replace(let t): l[i] = t
                case .delete: l.remove(at: i)
                case .disable:
                    let indent = String(l[i].prefix { $0 == " " || $0 == "\t" })
                    let rest = l[i].dropFirst(indent.count)
                    if !rest.hasPrefix("##") { l[i] = indent + "##" + rest }
                case .insertBefore(let ts): l.insert(contentsOf: ts, at: i)
                case .insertAfter(let ts): l.insert(contentsOf: ts, at: i + 1)
                }
            }
        }
    }

    /// Bits de colisão usados (SET/RECEIVE de IONAME), com a linha.
    public static func collisionBits(_ p: EcoTalkProgram) -> [(line: Int, command: String, pin: String, state: String)] {
        lines(p).compactMap { l in
            guard l.kind == .command, !l.isDisabled, l.name == "SET" || l.name == "RECEIVE", l.args.count >= 2,
                  l.args[0].uppercased().hasPrefix("COLLISION") else { return nil }
            return (l.lineNumber, l.name, l.args[0], l.args[1])
        }
    }
}
