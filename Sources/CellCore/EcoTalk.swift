import Foundation
import simd

// Formato EcoTalk (controladores Dürr EcoRPC):
//   .tip – instruções, uma por linha:  LIN(P3)   GUN(GUN1, GunOn, PT1, TR1)   // comentário
//   .tid – dados:                      P3 : POINT := (Object, x, y, z, a, b, c, e1, e2, e3)
// Projeto = pasta <nome>.tt dentro de teachcontrol/kin1; globais em kin1/_global.tt/_globalvars.tid.

public struct EcoTalkDeclaration: Hashable {
    public var name: String
    public var type: String
    public var args: [String]
    public var line: Int

    public func number(_ i: Int) -> Double? { i < args.count ? Double(args[i]) : nil }
    public var numbers: [Double] { args.compactMap { Double($0) } }
}

public struct EcoTalkCommand: Hashable {
    public var line: Int          // 1-based no .tip
    public var name: String       // ex.: LIN, PTP, GUN, CALL
    public var args: [String]
    public var text: String
}

public enum EcoTalk {
    /// Lê um .tid em ordem de declaração.
    public static func parseData(_ text: String) -> [EcoTalkDeclaration] {
        var out: [EcoTalkDeclaration] = []
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            // NOME : TIPO := (a, b, c)    ou    NOME : TIPO := valor
            guard let colon = line.firstIndex(of: ":"), let assign = line.range(of: ":=") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let type = line[line.index(after: colon)..<assign.lowerBound].trimmingCharacters(in: .whitespaces)
            var value = line[assign.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("(") && value.hasSuffix(")") { value = String(value.dropFirst().dropLast()) }
            out.append(EcoTalkDeclaration(name: name, type: type.uppercased(), args: splitArgs(value), line: i + 1))
        }
        return out
    }

    /// Lê um .tip. Vários comandos podem dividir a linha com ';'.
    public static func parseProgram(_ text: String) -> [EcoTalkCommand] {
        var out: [EcoTalkCommand] = []
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("##") { continue }   // ## = comando desativado
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
            for part in line.split(separator: ";") {
                let cmd = part.trimmingCharacters(in: .whitespaces)
                if cmd.isEmpty { continue }
                var name = cmd, args: [String] = []
                if let open = cmd.firstIndex(of: "("), let close = cmd.lastIndex(of: ")"), open < close {
                    name = cmd[..<open].trimmingCharacters(in: .whitespaces)
                    args = splitArgs(String(cmd[cmd.index(after: open)..<close]))
                } else if let sp = cmd.firstIndex(of: " ") {
                    name = String(cmd[..<sp])
                    args = [cmd[sp...].trimmingCharacters(in: .whitespaces)]
                }
                // "CALL under()" → nome CALL, argumento "under"
                if name.uppercased().hasPrefix("CALL ") {
                    args = [String(name.dropFirst(5)).trimmingCharacters(in: .whitespaces)]
                    name = "CALL"
                }
                out.append(EcoTalkCommand(line: i + 1, name: name.uppercased(), args: args, text: cmd))
            }
        }
        return out
    }

    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0, inString = false
        for ch in s {
            if ch == "\"" { inString.toggle() }
            if !inString {
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                if ch == "," && depth == 0 { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            }
            cur.append(ch)
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !out.isEmpty { out.append(last) }
        return out
    }
}

/// Um programa (.tip + .tid) de um projeto.
public struct EcoTalkProgram: Identifiable, Hashable {
    public var id: String { url.path }
    public var name: String
    public var url: URL          // .tip
    public var source: String
    public var data: String

    public init(name: String, url: URL, source: String, data: String) {
        self.name = name; self.url = url; self.source = source; self.data = data
    }

    public var dataURL: URL { url.deletingPathExtension().appendingPathExtension("tid") }
    public var commands: [EcoTalkCommand] { EcoTalk.parseProgram(source) }
    public var declarations: [EcoTalkDeclaration] { EcoTalk.parseData(data) }

    public static func load(_ tip: URL) -> EcoTalkProgram {
        let src = (try? String(contentsOf: tip, encoding: .isoLatin1)) ?? ""
        let tid = tip.deletingPathExtension().appendingPathExtension("tid")
        let dat = (try? String(contentsOf: tid, encoding: .isoLatin1)) ?? ""
        return EcoTalkProgram(name: tip.deletingPathExtension().lastPathComponent, url: tip, source: src, data: dat)
    }

    public func save() throws {
        try source.write(to: url, atomically: true, encoding: .isoLatin1)
        try data.write(to: dataURL, atomically: true, encoding: .isoLatin1)
    }
}

/// Pasta <nome>.tt
public struct EcoTalkProject: Identifiable, Hashable {
    public var id: String { url.path }
    public var name: String
    public var url: URL
    public var programs: [EcoTalkProgram]
    public var projectData: [EcoTalkDeclaration]   // _GlobalVars.tid do projeto

    public static func load(_ dir: URL) -> EcoTalkProject {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let tips = files.filter { $0.pathExtension.lowercased() == "tip" }.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        let globals = files.first { $0.lastPathComponent.lowercased() == "_globalvars.tid" }
        let gtext = globals.flatMap { try? String(contentsOf: $0, encoding: .isoLatin1) } ?? ""
        return EcoTalkProject(name: dir.deletingPathExtension().lastPathComponent, url: dir,
                              programs: tips.map(EcoTalkProgram.load), projectData: EcoTalk.parseData(gtext))
    }
}

// MARK: - Interpretação para simulação

/// Ação de sincronização/tempo que acontece entre movimentos (vai para o escalonador da estação).
public struct EcoTalkSyncAction: Hashable {
    public enum Kind: Hashable { case set, receive, delay }
    public var kind: Kind
    public var pin: String          // ex.: Collision1
    public var high: Bool           // High (0) / Low (1) no controlador
    public var seconds: Double      // DELAY
    public var afterPoint: Int      // quantos pontos do RobotProgram vêm antes desta ação
    public var program: String
    public var line: Int

    public init(kind: Kind, pin: String, high: Bool, seconds: Double, afterPoint: Int, program: String, line: Int) {
        self.kind = kind; self.pin = pin; self.high = high; self.seconds = seconds
        self.afterPoint = afterPoint; self.program = program; self.line = line
    }
}

public struct EcoTalkRunResult {
    public var program: RobotProgram
    public var messages: [String]
    /// ponto i do RobotProgram → (programa, linha no .tip)
    public var origin: [(program: String, line: Int)]
    /// ponto i → cadeia de chamadas do programa principal até a linha do movimento (CALLs no meio)
    public var callChains: [[CallSite]] = []
    /// SET/RECEIVE (bits de colisão) e DELAY, na ordem de execução
    public var actions: [EcoTalkSyncAction] = []
    /// Ferramenta e objeto ativos na primeira vez que cada linha foi executada (chave `frameKey`)
    public var frames: [String: EcoFrameContext] = [:]

    public static func frameKey(program: String, line: Int) -> String { "\(program.uppercased()):\(line)" }
}

/// Linha de um programa (uma CALL ou o próprio movimento).
public struct CallSite: Hashable {
    public var program: String
    public var line: Int
    public init(program: String, line: Int) { self.program = program; self.line = line }
}

/// SETTOOL/SETOBJECT em vigor numa linha do programa.
public struct EcoFrameContext: Hashable {
    public var tool: Pose
    public var object: Pose
    public var toolName: String
    public var objectName: String
    public init(tool: Pose = Pose(), object: Pose = Pose(), toolName: String = "TOOL_ZERO", objectName: String = "BASE_ZERO") {
        self.tool = tool; self.object = object; self.toolName = toolName; self.objectName = objectName
    }
}

/// Converte um programa EcoTalk em movimentos e ações para a simulação.
/// - Movimentos: PTP/LIN/CIRC com pontos Axis/Object/World, SETTOOL/SETOBJECT, VEL, GUN/GUN_DIRECT, CALL.
/// - Fluxo: IF/ELSIF/ELSE/END_IF, LOOP n DO/END_LOOP, WHILE…DO/END_WHILE, LABEL/GOTO, RETURN, atribuição `X := expr`.
/// - Sincronização: SET/RECEIVE de bits (ex.: Collision1) e DELAY viram ações para o escalonador da estação.
/// Sinais externos (GET_BOOL_SYSTEMVAR) não existem offline: assume-se o caminho normal de produção (verdadeiro),
/// a menos que `systemVariables` diga o contrário.
public struct EcoTalkInterpreter {
    public let project: EcoTalkProject
    public let systemData: [EcoTalkDeclaration]
    public let robot: RobotModel
    public var systemVariables: [String: Bool] = [:]
    public var maxSteps = 200_000
    /// SETTOOL/SETOBJECT em vigor no início (ex.: módulo aberto sozinho, com o contexto de quando o Main o chama)
    public var initialFrames: EcoFrameContext?

    public init(project: EcoTalkProject, systemData: [EcoTalkDeclaration], robot: RobotModel) {
        self.project = project; self.systemData = systemData; self.robot = robot
    }

    final class State {
        var tool = Pose()
        var object = Pose()
        var toolName = "TOOL_ZERO"
        var objectName = "BASE_ZERO"
        var cartVel = 500.0
        var ptpPercent = 50.0
        var gunOn = false
        var brush = 1
        var vars: [String: EcoValue] = [:]
        var motionStates: [String: String] = [:]
        var prog: RobotProgram
        var messages: [String] = []
        var origin: [(String, Int)] = []
        var callStack: [CallSite] = []
        var chains: [[CallSite]] = []
        var actions: [EcoTalkSyncAction] = []
        var frames: [String: EcoFrameContext] = [:]
        var warned = Set<String>()
        var steps = 0
        var aborted = false
        init(prog: RobotProgram) { self.prog = prog }
        func warnOnce(_ key: String, _ msg: String) { if warned.insert(key).inserted { messages.append(msg) } }
    }

    public func run(_ programName: String) -> EcoTalkRunResult {
        let st = State(prog: RobotProgram(name: programName, brushes: [Brush(id: 1, name: "Cordão (sealing)", flowRate: 60, coneHalfAngle: 3, beta: 1, transferEfficiency: 1, solids: 1)]))
        if let f = initialFrames { st.tool = f.tool; st.object = f.object; st.toolName = f.toolName; st.objectName = f.objectName }
        execute(programName, depth: 0, st)
        var result = EcoTalkRunResult(program: st.prog, messages: st.messages, origin: st.origin.map { (program: $0.0, line: $0.1) },
                                actions: st.actions, frames: st.frames)
        result.callChains = st.chains
        return result
    }

    private func lookup(_ name: String, local: [EcoTalkDeclaration]) -> EcoTalkDeclaration? {
        let key = name.uppercased()
        return local.first { $0.name.uppercased() == key }
            ?? project.projectData.first { $0.name.uppercased() == key }
            ?? systemData.first { $0.name.uppercased() == key }
    }

    private func frame(_ d: EcoTalkDeclaration?) -> Pose? {
        guard let n = d?.numbers, n.count >= 6 else { return nil }
        return Pose(x: n[0], y: n[1], z: n[2], a: n[3], b: n[4], c: n[5])
    }

    // MARK: Estrutura de blocos

    /// Palavra-chave de controle no início do comando (usa o texto original, pois "IF NOT F(x) THEN" não é NOME(args)).
    static func keyword(_ cmd: EcoTalkCommand) -> String {
        let t = cmd.text.trimmingCharacters(in: .whitespaces).uppercased()
        for k in ["END_IF", "END_LOOP", "END_WHILE", "ELSIF", "ELSE", "IF", "LOOP", "WHILE", "GOTO", "LABEL", "RETURN", "EXIT"] {
            if t == k || t.hasPrefix(k + " ") || t.hasPrefix(k + "(") || (k == "RETURN" && t.hasPrefix("RETURN")) { return k }
        }
        return ""
    }

    struct Blocks {
        var next: [Int: Int] = [:]      // IF/ELSIF → próximo ramo (ELSIF/ELSE/END_IF)
        var endOf: [Int: Int] = [:]     // IF/ELSIF/ELSE/LOOP/WHILE → END correspondente
        var startOf: [Int: Int] = [:]   // END_LOOP/END_WHILE → início
        var labels: [String: Int] = [:]
    }

    static func blocks(_ cmds: [EcoTalkCommand], _ kws: [String]) -> Blocks {
        var b = Blocks()
        var stack: [(kind: String, idx: Int, branches: [Int])] = []
        for (i, k) in kws.enumerated() {
            switch k {
            case "IF": stack.append(("IF", i, [i]))
            case "ELSIF", "ELSE":
                if var top = stack.last, top.kind == "IF" {
                    b.next[top.branches.last!] = i
                    top.branches.append(i); stack[stack.count - 1] = top
                }
            case "END_IF":
                if let top = stack.last, top.kind == "IF" {
                    stack.removeLast()
                    b.next[top.branches.last!] = i
                    for br in top.branches { b.endOf[br] = i }
                }
            case "LOOP", "WHILE": stack.append((k, i, [i]))
            case "END_LOOP", "END_WHILE":
                if let top = stack.last, top.kind == (k == "END_LOOP" ? "LOOP" : "WHILE") {
                    stack.removeLast(); b.endOf[top.idx] = i; b.startOf[i] = top.idx
                }
            case "LABEL":
                let name = labelName(cmds[i].text)
                b.labels[name] = i
            default: break
            }
        }
        return b
    }

    static func labelName(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        for k in ["LABEL", "GOTO"] where t.uppercased().hasPrefix(k) { t = String(t.dropFirst(k.count)) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ():")).uppercased()
    }

    /// Texto da condição entre a palavra-chave e THEN/DO.
    static func condition(_ text: String, _ kw: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        t = String(t.dropFirst(kw.count))
        for suffix in [" THEN", " DO"] {
            if let r = t.range(of: suffix, options: [.backwards, .caseInsensitive]) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Execução

    private func execute(_ name: String, depth: Int, _ st: State) {
        guard depth < 16 else { st.messages.append("CALL aninhado demais em \(name)"); return }
        guard let p = project.programs.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            st.messages.append("Programa \(name) não encontrado no projeto \(project.name)"); return
        }
        let local = p.declarations
        let cmds = p.commands
        let kws = cmds.map(Self.keyword)
        let blk = Self.blocks(cmds, kws)
        var loopCount: [Int: Int] = [:]
        var pc = 0
        func eval(_ expr: String, _ line: Int) -> EcoValue {
            var ev = EcoExpression(text: expr)
            ev.resolve = { id in
                let u = id.uppercased()
                if let v = st.vars[u] { return v }
                if u == "TRUE" { return .number(1) }
                if u == "FALSE" { return .number(0) }
                if let d = self.lookup(id, local: local), let n = d.number(0) ?? d.numbers.first { return .number(n) }
                return .text(id)
            }
            ev.call = { fn, args in self.function(fn, args, st, p.name, line) }
            return ev.evaluate()
        }
        while pc < cmds.count {
            if st.aborted { return }
            st.steps += 1
            if st.steps > maxSteps {
                st.messages.append("Execução interrompida após \(maxSteps) instruções (laço infinito?) em \(p.name):\(cmds[pc].line)")
                st.aborted = true; return
            }
            let cmd = cmds[pc]
            let kw = kws[pc]
            switch kw {
            case "IF", "ELSIF":
                if kw == "ELSIF" && st.vars["__taken_\(blk.endOf[pc] ?? -1)"] != nil {
                    pc = (blk.endOf[pc] ?? pc) + 1; continue
                }
                let ok = eval(Self.condition(cmd.text, kw), cmd.line).truthy
                if ok {
                    st.vars["__taken_\(blk.endOf[pc] ?? -1)"] = .number(1)
                    pc += 1
                } else {
                    let nx = blk.next[pc] ?? (blk.endOf[pc] ?? pc)
                    if kws[nx] == "ELSE" { st.vars["__taken_\(blk.endOf[pc] ?? -1)"] = .number(1); pc = nx + 1 }
                    else if kws[nx] == "ELSIF" { pc = nx }
                    else { pc = nx + 1 }
                }
                continue
            case "ELSE":
                pc = (blk.endOf[pc] ?? pc) + 1; continue           // fim do ramo verdadeiro
            case "END_IF":
                // limpa a marca do bloco para permitir reexecução (laços)
                st.vars["__taken_\(pc)"] = nil
                pc += 1; continue
            case "LOOP":
                let n = Int(eval(Self.condition(cmd.text, "LOOP"), cmd.line).number.rounded())
                if loopCount[pc] == nil { loopCount[pc] = n }
                if (loopCount[pc] ?? 0) <= 0 { loopCount[pc] = nil; pc = (blk.endOf[pc] ?? pc) + 1 } else { pc += 1 }
                continue
            case "END_LOOP":
                if let s = blk.startOf[pc], let left = loopCount[s] {
                    if left - 1 > 0 { loopCount[s] = left - 1; pc = s + 1 } else { loopCount[s] = nil; pc += 1 }
                } else { pc += 1 }
                continue
            case "WHILE":
                if eval(Self.condition(cmd.text, "WHILE"), cmd.line).truthy { pc += 1 } else { pc = (blk.endOf[pc] ?? pc) + 1 }
                continue
            case "END_WHILE":
                pc = blk.startOf[pc] ?? (pc + 1); continue
            case "GOTO":
                let l = Self.labelName(cmd.text)
                if let t = blk.labels[l] { pc = t + 1 } else { st.messages.append("\(p.name):\(cmd.line) rótulo \(l) não encontrado"); pc += 1 }
                continue
            case "LABEL":
                pc += 1; continue
            case "RETURN", "EXIT":
                return
            default:
                break
            }
            // atribuição: X := expr
            if let r = cmd.text.range(of: ":="), !cmd.text.contains("(") || cmd.text.firstIndex(of: "(")! > r.lowerBound {
                let lhs = cmd.text[..<r.lowerBound].trimmingCharacters(in: .whitespaces).uppercased()
                st.vars[lhs] = eval(String(cmd.text[r.upperBound...]), cmd.line)
                pc += 1; continue
            }
            command(cmd, p, local, depth, st)
            pc += 1
        }
    }

    private func command(_ cmd: EcoTalkCommand, _ p: EcoTalkProgram, _ local: [EcoTalkDeclaration], _ depth: Int, _ st: State) {
        let a0 = cmd.args.first ?? ""
        let key = EcoTalkRunResult.frameKey(program: p.name, line: cmd.line)
        if st.frames[key] == nil { st.frames[key] = EcoFrameContext(tool: st.tool, object: st.object, toolName: st.toolName, objectName: st.objectName) }
        switch cmd.name {
        case "PTP", "LIN", "PTP_REL", "LIN_REL", "CIRC":
            let target = cmd.name == "CIRC" ? (cmd.args.count > 1 ? cmd.args[1] : a0) : a0
            guard var pt = point(target, local, st, motion: cmd.name.hasPrefix("PTP") ? .ptp : .lin) else {
                st.messages.append("\(p.name):\(cmd.line) ponto \(target) não declarado"); return
            }
            if cmd.name == "CIRC" {
                if let via = point(a0, local, st, motion: .lin) { pt.motion = .circ; pt.via = via.pose }
            }
            st.prog.points.append(pt)
            st.origin.append((p.name, cmd.line))
            st.chains.append(st.callStack + [CallSite(program: p.name, line: cmd.line)])
        case "SETTOOL":
            if let f = frame(lookup(a0, local: local)) { st.tool = f; st.toolName = a0 }
            else { st.messages.append("\(p.name):\(cmd.line) ferramenta \(a0) não declarada") }
        case "SETOBJECT":
            if let f = frame(lookup(a0, local: local)) { st.object = f; st.objectName = a0 }
            else { st.messages.append("\(p.name):\(cmd.line) objeto \(a0) não declarado") }
        case "VEL":
            if let d = lookup(a0, local: local), let v = d.number(0) {
                st.cartVel = v
                if let pct = d.numbers.last { st.ptpPercent = Swift.min(Swift.max(pct, 1), 100) }
            } else if let v = Double(a0) { st.cartVel = v }
        case "GUN", "GUN_DIRECT":
            let mode = (cmd.args.count > 1 ? cmd.args[1] : "").lowercased()
            if mode.contains("on") && !mode.contains("off") { st.gunOn = true }
            else if mode.contains("off") { st.gunOn = false }
        case "SETBRUSH", "SETBRUSH_DIRECT":
            st.brush = 1
        case "CALL":
            let callee = a0.replacingOccurrences(of: "()", with: "").trimmingCharacters(in: .whitespaces)
            st.callStack.append(CallSite(program: p.name, line: cmd.line))
            execute(callee, depth: depth + 1, st)
            st.callStack.removeLast()
        case "SET", "RECEIVE":
            guard cmd.args.count >= 2 else { return }
            let pin = cmd.args[0].trimmingCharacters(in: .whitespaces)
            let v = cmd.args[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard v == "high" || v == "low" else {
                st.warnOnce("io-\(pin)", "\(cmd.name)(\(pin), \(cmd.args[1])) não é bit High/Low – ignorado"); return
            }
            st.actions.append(EcoTalkSyncAction(kind: cmd.name == "SET" ? .set : .receive, pin: pin, high: v == "high",
                                                seconds: 0, afterPoint: st.prog.points.count, program: p.name, line: cmd.line))
        case "DELAY":
            let secs = Double(a0.trimmingCharacters(in: .whitespaces)) ?? (lookup(a0, local: local)?.number(0) ?? 0)
            if secs > 0 {
                st.actions.append(EcoTalkSyncAction(kind: .delay, pin: "", high: false, seconds: secs,
                                                    afterPoint: st.prog.points.count, program: p.name, line: cmd.line))
            }
        case "SET_MOTION_STATE":
            if cmd.args.count >= 2 { st.motionStates[cmd.args[0].uppercased()] = cmd.args[1].trimmingCharacters(in: .whitespaces).uppercased() }
        case "ACC", "OVERLAP", "RSELECT", "RDESELECT", "WAIT_PROCESS_READY", "PRINT", "MAINRUN":
            break
        default:
            st.warnOnce(cmd.name, "Instrução \(cmd.name) não é simulada (\(p.name):\(cmd.line))")
        }
    }

    private func point(_ target: String, _ local: [EcoTalkDeclaration], _ st: State, motion: MotionType) -> ProgramPoint? {
        guard let d = lookup(target, local: local), d.type == "POINT" else { return nil }
        let mode = (d.args.first ?? "").lowercased()
        let v = Array(d.numbers)
        guard v.count >= 6 else { return nil }
        let rail = v.count > 6 ? v[6] : 0
        var pt = ProgramPoint(name: d.name, motion: motion, pose: Pose(), rail: rail,
                              speed: motion == .ptp ? st.ptpPercent : st.cartVel, paintOn: st.gunOn, brush: st.brush)
        pt.tool = st.tool
        pt.ptpSpeed = st.ptpPercent
        switch mode {
        case "axis":
            pt.joints = Array(v[0..<6])
            var r = robot; r.tool = st.tool
            pt.pose = Pose(matrix: Kinematics.tcp(r, JointState(rail: rail, q: Array(v[0..<6]))))
        case "world":
            pt.pose = Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5])
        default:
            pt.pose = Pose(matrix: st.object.matrix * Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5]).matrix)
        }
        return pt
    }

    /// Funções usadas em condições. Sinais externos assumem o caminho normal de produção.
    private func function(_ fn: String, _ args: [EcoValue], _ st: State, _ prog: String, _ line: Int) -> EcoValue {
        switch fn.uppercased() {
        case "GET_BOOL_SYSTEMVAR":
            let name = args.count > 1 ? args[1].string : "?"
            let v = systemVariables[name] ?? true
            st.warnOnce("sv-\(name)", "\(prog):\(line) GET_BOOL_SYSTEMVAR(\(name)) sem controlador: assumido \(v ? "verdadeiro" : "falso")")
            return .number(v ? 1 : 0)
        case "GET_MOTION_STATE":
            let name = (args.first?.string ?? "").uppercased()
            let want = (args.count > 1 ? args[1].string : "TRUE").uppercased()
            return .number((st.motionStates[name] ?? "FALSE") == want ? 1 : 0)
        case "ABS": return .number(abs(args.first?.number ?? 0))
        default:
            st.warnOnce("fn-\(fn)", "\(prog):\(line) função \(fn) não simulada: resultado falso")
            return .number(0)
        }
    }
}

// MARK: - Expressões EcoTalk (NOT/AND/OR, comparações, aritmética, chamadas)

public enum EcoValue: Hashable {
    case number(Double)
    case text(String)
    var number: Double { if case .number(let n) = self { return n }; return 0 }
    var string: String {
        switch self { case .text(let s): return s; case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n) }
    }
    var truthy: Bool {
        switch self { case .number(let n): return n != 0; case .text(let s): return ["TRUE", "HIGH"].contains(s.uppercased()) }
    }
}

struct EcoExpression {
    enum Tok: Equatable { case num(Double), id(String), str(String), op(String), lp, rp, comma }
    var toks: [Tok] = []
    var i = 0
    var resolve: (String) -> EcoValue = { .text($0) }
    var call: (String, [EcoValue]) -> EcoValue = { _, _ in .number(0) }

    init(text: String) {
        var t: [Tok] = []
        let c = Array(text)
        var k = 0
        while k < c.count {
            let ch = c[k]
            if ch.isWhitespace { k += 1; continue }
            if ch == "\"" {
                var s = ""; k += 1
                while k < c.count && c[k] != "\"" { s.append(c[k]); k += 1 }
                k += 1; t.append(.str(s)); continue
            }
            if ch.isNumber || (ch == "." && k + 1 < c.count && c[k + 1].isNumber) {
                var s = ""
                while k < c.count && (c[k].isNumber || c[k] == ".") { s.append(c[k]); k += 1 }
                t.append(.num(Double(s) ?? 0)); continue
            }
            if ch.isLetter || ch == "_" {
                var s = ""
                while k < c.count && (c[k].isLetter || c[k].isNumber || c[k] == "_" || c[k] == ".") { s.append(c[k]); k += 1 }
                let u = s.uppercased()
                if ["AND", "OR", "XOR", "NOT", "MOD"].contains(u) { t.append(.op(u)) } else { t.append(.id(s)) }
                continue
            }
            if ch == "(" { t.append(.lp); k += 1; continue }
            if ch == ")" { t.append(.rp); k += 1; continue }
            if ch == "," { t.append(.comma); k += 1; continue }
            let two = k + 1 < c.count ? String([ch, c[k + 1]]) : ""
            if ["<>", "<=", ">=", "==", "!="].contains(two) { t.append(.op(two == "==" ? "=" : two == "!=" ? "<>" : two)); k += 2; continue }
            t.append(.op(String(ch))); k += 1
        }
        toks = t
    }

    mutating func evaluate() -> EcoValue { i = 0; return orExpr() }
    func peek() -> Tok? { i < toks.count ? toks[i] : nil }
    mutating func next() -> Tok? { defer { i += 1 }; return peek() }

    mutating func orExpr() -> EcoValue {
        var l = andExpr()
        while case .op(let o)? = peek(), o == "OR" || o == "XOR" {
            _ = next(); let r = andExpr()
            l = .number(o == "OR" ? ((l.truthy || r.truthy) ? 1 : 0) : ((l.truthy != r.truthy) ? 1 : 0))
        }
        return l
    }
    mutating func andExpr() -> EcoValue {
        var l = notExpr()
        while case .op("AND")? = peek() { _ = next(); let r = notExpr(); l = .number(l.truthy && r.truthy ? 1 : 0) }
        return l
    }
    mutating func notExpr() -> EcoValue {
        if case .op("NOT")? = peek() { _ = next(); return .number(notExpr().truthy ? 0 : 1) }
        return compare()
    }
    mutating func compare() -> EcoValue {
        let l = sum()
        if case .op(let o)? = peek(), ["=", "<>", "<", ">", "<=", ">="].contains(o) {
            _ = next(); let r = sum()
            let eq: Bool
            if case .number(let a) = l, case .number(let b) = r {
                switch o {
                case "<": return .number(a < b ? 1 : 0)
                case ">": return .number(a > b ? 1 : 0)
                case "<=": return .number(a <= b ? 1 : 0)
                case ">=": return .number(a >= b ? 1 : 0)
                default: eq = abs(a - b) < 1e-9
                }
            } else { eq = l.string.uppercased() == r.string.uppercased() }
            return .number((o == "=") == eq ? 1 : 0)
        }
        return l
    }
    mutating func sum() -> EcoValue {
        var l = product()
        while case .op(let o)? = peek(), o == "+" || o == "-" {
            _ = next(); let r = product(); l = .number(o == "+" ? l.number + r.number : l.number - r.number)
        }
        return l
    }
    mutating func product() -> EcoValue {
        var l = unary()
        while case .op(let o)? = peek(), o == "*" || o == "/" || o == "MOD" {
            _ = next(); let r = unary()
            switch o {
            case "*": l = .number(l.number * r.number)
            case "/": l = .number(r.number == 0 ? 0 : l.number / r.number)
            default: l = .number(r.number == 0 ? 0 : l.number.truncatingRemainder(dividingBy: r.number))
            }
        }
        return l
    }
    mutating func unary() -> EcoValue {
        if case .op("-")? = peek() { _ = next(); return .number(-unary().number) }
        return primary()
    }
    mutating func primary() -> EcoValue {
        guard let t = next() else { return .number(0) }
        switch t {
        case .num(let n): return .number(n)
        case .str(let s): return .text(s)
        case .lp:
            let v = orExpr()
            if case .rp? = peek() { _ = next() }
            return v
        case .id(let name):
            if case .lp? = peek() {
                _ = next()
                var args: [EcoValue] = []
                if case .rp? = peek() { _ = next(); return call(name, args) }
                while true {
                    args.append(orExpr())
                    if case .comma? = peek() { _ = next(); continue }
                    if case .rp? = peek() { _ = next() }
                    break
                }
                return call(name, args)
            }
            return resolve(name)
        default: return .number(0)
        }
    }
}
