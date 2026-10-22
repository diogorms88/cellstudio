import CellCore
import Foundation
import Network
import simd
import SwiftUI

// Ponte com o Claude Code deste Mac:
// - servidor MCP (HTTP, só 127.0.0.1, com chave) que expõe a estação como ferramentas;
// - o painel "Claude" roda `claude -p` já conectado a esse servidor (login do Claude Code, sem chave de API).

final class MCPServer: @unchecked Sendable {
    static let shared = MCPServer()
    let port: UInt16 = 8765
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cellstudio.mcp")
    /// chave exigida no cabeçalho Authorization (gerada uma vez e guardada nas preferências)
    let token: String = {
        if let t = UserDefaults.standard.string(forKey: "mcpToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(t, forKey: "mcpToken")
        return t
    }()
    private(set) var running = false

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// Configuração para `claude --mcp-config` / `claude mcp add`.
    var configJSON: String {
        #"{"mcpServers":{"cellstudio":{"type":"http","url":"\#(url)","headers":{"Authorization":"Bearer \#(token)"}}}}"#
    }
    var addCommand: String {
        #"claude mcp add --transport http cellstudio \#(url) --header "Authorization: Bearer \#(token)""#
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .ready = st { self?.running = true }
                if case .failed = st { self?.running = false }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Task { @MainActor in AppState.shared?.warn("Servidor do Claude não iniciou: \(error.localizedDescription)") }
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                Task { await self.handle(req, on: c) }
            } else if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func send(_ c: NWConnection, status: String, body: Data = Data(), contentType: String = "application/json") {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func handle(_ req: HTTPRequest, on c: NWConnection) async {
        guard req.headers["authorization"] == "Bearer \(token)" else { send(c, status: "401 Unauthorized"); return }
        guard req.method == "POST" else { send(c, status: "405 Method Not Allowed"); return }
        guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any], let method = msg["method"] as? String else {
            send(c, status: "400 Bad Request"); return
        }
        let id = msg["id"]
        guard id != nil else { send(c, status: "202 Accepted"); return }     // notificação
        let params = msg["params"] as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "cellstudio", "version": "1.0"],
                      "instructions": ClaudeChat.rules]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": MCPTools.definitions]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await MCPTools.call(name, args)
            result = ["content": [["type": "text", "text": text]], "isError": isError]
        default:
            let err: [String: Any] = ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "método desconhecido: \(method)"]]
            send(c, status: "200 OK", body: (try? JSONSerialization.data(withJSONObject: err)) ?? Data())
            return
        }
        let resp: [String: Any] = ["jsonrpc": "2.0", "id": id!, "result": result]
        send(c, status: "200 OK", body: (try? JSONSerialization.data(withJSONObject: resp)) ?? Data())
    }
}

struct HTTPRequest {
    var method: String
    var headers: [String: String]
    var body: Data

    /// Requisição completa (cabeçalho + corpo pelo Content-Length) ou nil se ainda falta chegar.
    static func parse(_ d: Data) -> HTTPRequest? {
        guard let sep = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[sep.upperBound...]
        guard body.count >= len else { return nil }
        return HTTPRequest(method: first.first.map(String.init) ?? "", headers: headers, body: Data(body.prefix(len)))
    }
}

// MARK: - Ferramentas

enum MCPTools {
    static func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    static let editSchema: [String: Any] = [
        "type": "array",
        "description": "Alterações linha a linha (linhas 1-based do .tip atual).",
        "items": ["type": "object", "properties": [
            "robot": ["type": "string"], "program": ["type": "string"], "line": ["type": "integer"],
            "op": ["type": "string", "enum": ["replace", "insert_before", "insert_after", "delete", "disable"]],
            "text": ["type": "string", "description": "Texto da linha (replace) ou linhas separadas por \\n (insert_*)"]],
            "required": ["robot", "program", "line", "op"]]]

    static let definitions: [[String: Any]] = [
        ["name": "station_overview", "description": "Robôs da estação, programa de cada um, tempo de ciclo simulado (HOME-to-HOME), meta de ciclo, carroceria carregada e alterações pendentes.",
         "inputSchema": schema([:])],
        ["name": "run_analysis", "description": "Roda a análise da estação (colisão robô×robô < 100 mm entre todos os pares, folga à carroceria 50 mm, melhorias de tempo de ciclo) e devolve as sugestões com o efeito simulado na estação.",
         "inputSchema": schema(["wait_station_effects": ["type": "boolean", "description": "esperar a avaliação de cada sugestão na estação (padrão true)"]])],
        ["name": "list_suggestions", "description": "Sugestões da última análise (id, tipo, robô, título, ganho do robô, efeito na estação, se pode ser aplicada).",
         "inputSchema": schema(["kind": ["type": "string", "description": "filtro: colisao | ciclo"]])],
        ["name": "get_suggestion", "description": "Detalhe de uma sugestão: explicação, alterações nas linhas e efeito na estação.",
         "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
        ["name": "apply_suggestion", "description": "Aplica uma sugestão nos programas (em memória, com desfazer; o usuário salva no app). Recalcula a simulação e a análise.",
         "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
        ["name": "undo_last_change", "description": "Desfaz a última sugestão/alteração aplicada.", "inputSchema": schema([:])],
        ["name": "read_program", "description": "Linhas numeradas de um programa EcoTalk (.tip) de um robô; opcionalmente os dados (.tid).",
         "inputSchema": schema(["robot": ["type": "string"], "program": ["type": "string"], "from_line": ["type": "integer"], "to_line": ["type": "integer"],
                                "include_data": ["type": "boolean"]], required: ["robot", "program"])],
        ["name": "robot_trajectory", "description": "O que o robô faz no tempo (relógio da estação): ponto, programa:linha, pistola, TCP (mm), trilho E1 e eixos.",
         "inputSchema": schema(["robot": ["type": "string"], "from_s": ["type": "number"], "to_s": ["type": "number"], "step_s": ["type": "number", "description": "padrão 0.5"]], required: ["robot"])],
        ["name": "collision_report", "description": "Regiões em que dois robôs ficam a menos de 100 mm (todos os pares), com tempos, pontos, se é simultâneo e qual bit protege.",
         "inputSchema": schema([:])],
        ["name": "simulate_edits", "description": "E se? Simula a estação com alterações de linha (sem aplicar) e devolve ciclo por robô, ciclo da estação, colisões simultâneas e erros novos.",
         "inputSchema": schema(["edits": editSchema], required: ["edits"])],
        ["name": "propose_suggestion", "description": "Coloca uma sugestão sua no painel de Análise do app, com as alterações, para o usuário revisar e aplicar com o botão Aplicar.",
         "inputSchema": schema(["title": ["type": "string"], "detail": ["type": "string"], "robot": ["type": "string"], "edits": editSchema], required: ["title", "detail", "edits"])],
    ]

    static func json(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    /// 1 casa decimal, sem "53.299999…" no JSON
    static func r1(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", x)) }

    static func parseEdits(_ any: Any?) -> [SourceEdit] {
        (any as? [[String: Any]] ?? []).compactMap { e in
            guard let robot = e["robot"] as? String, let program = e["program"] as? String,
                  let line = (e["line"] as? Int) ?? (e["line"] as? Double).map(Int.init), let op = e["op"] as? String else { return nil }
            let text = e["text"] as? String ?? ""
            let lines = text.components(separatedBy: "\n").map { $0.hasPrefix(" ") ? $0 : "  " + $0 }
            let o: SourceEdit.Op
            switch op {
            case "replace": o = .replace(lines.first ?? "")
            case "insert_before": o = .insertBefore(lines)
            case "insert_after": o = .insertAfter(lines)
            case "delete": o = .delete
            case "disable": o = .disable
            default: return nil
            }
            return SourceEdit(robot: robot, program: program, line: line, op: o)
        }
    }

    @MainActor static func suggestionJSON(_ s: AnalysisSuggestion, _ app: AppState, full: Bool = false) -> [String: Any] {
        var d: [String: Any] = ["id": String(s.id.uuidString.prefix(8)), "kind": s.kind.rawValue, "severity": "\(s.severity)",
                                "robot": s.robot, "title": s.title, "where": s.program.isEmpty ? "" : "\(s.program):\(s.line)",
                                "applicable": s.applicable]
        if let g = s.gain { d["robot_gain_s"] = NSDecimalNumber(string: String(format: "%.2f", g)) }
        if let r = s.manualReason { d["manual_reason"] = r }
        if let e = app.stationEffects[s.id] {
            d["station_effect"] = ["station_cycle_before_s": r1(e.stationBefore), "station_cycle_after_s": r1(e.stationAfter),
                                   "per_robot_after_s": e.after.mapValues(r1), "collisions_before": e.collisionsBefore,
                                   "collisions_after": e.collisionsAfter, "new_kinematic_errors": e.newErrors]
        }
        if full {
            d["detail"] = s.detail
            if let c = s.bodyClearance { d["body_clearance_mm"] = Int(c) }
            d["edits"] = s.edits.map { e -> [String: Any] in
                var x: [String: Any] = ["robot": e.robot, "program": e.program, "line": e.line]
                switch e.op {
                case .replace(let t): x["op"] = "replace"; x["text"] = t
                case .insertBefore(let t): x["op"] = "insert_before"; x["text"] = t.joined(separator: "\n")
                case .insertAfter(let t): x["op"] = "insert_after"; x["text"] = t.joined(separator: "\n")
                case .delete: x["op"] = "delete"
                case .disable: x["op"] = "disable"
                }
                return x
            }
        }
        return d
    }

    @MainActor static func find(_ id: String, _ app: AppState) -> AnalysisSuggestion? {
        app.analysis?.suggestions.first { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
    }

    static func waitIdle(effects: Bool, timeout: Double = 120) async {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            let busy = await MainActor.run { () -> Bool in
                guard let a = AppState.shared else { return false }
                if a.analyzing { return true }
                guard effects, let an = a.analysis else { return false }
                return a.stationEffects.count < an.suggestions.filter(\.applicable).count
            }
            if !busy { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    static func call(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
        await MainActor.run { AppState.shared?.claudeActivity = "Claude: \(name)" }
        defer { Task { @MainActor in AppState.shared?.claudeActivity = nil } }
        switch name {
        case "run_analysis":
            await MainActor.run { AppState.shared?.simulateAndAnalyze() }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await waitIdle(effects: args["wait_station_effects"] as? Bool ?? true)
            return await MainActor.run { (summary(), false) }
        case "apply_suggestion":
            let ok = await MainActor.run { () -> String? in
                guard let a = AppState.shared, let s = find(args["id"] as? String ?? "", a) else { return "sugestão não encontrada" }
                guard s.applicable else { return "não pode ser aplicada automaticamente: \(s.manualReason ?? "")" }
                a.apply(s)
                return nil
            }
            if let err = ok { return (err, true) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await waitIdle(effects: false)
            return await MainActor.run { ("Aplicada (em memória; o usuário salva no app).\n" + summary(), false) }
        case "undo_last_change":
            await MainActor.run { AppState.shared?.undoLastApply() }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await waitIdle(effects: false)
            return await MainActor.run { ("Desfeito.\n" + summary(), false) }
        case "simulate_edits":
            let edits = parseEdits(args["edits"])
            guard !edits.isEmpty else { return ("nenhuma alteração válida", true) }
            let inputs = await MainActor.run { AppState.shared?.stationSimInputs() ?? [] }
            guard !inputs.isEmpty else { return ("sem simulação da estação; rode run_analysis antes", true) }
            let base = StationSimInput.evaluate(inputs, edits: [])
            let r = StationSimInput.evaluate(inputs, edits: edits)
            return (json(["per_robot_before_s": base.totals.mapValues(r1), "per_robot_after_s": r.totals.mapValues(r1),
                          "station_cycle_before_s": r1(base.totals.values.max() ?? 0), "station_cycle_after_s": r1(r.totals.values.max() ?? 0),
                          "simultaneous_collisions_before": base.collisions, "simultaneous_collisions_after": r.collisions,
                          "new_kinematic_errors": r.newErrors]), false)
        default:
            return await MainActor.run { sync(name, args) }
        }
    }

    @MainActor static func summary() -> String {
        guard let a = AppState.shared else { return "{}" }
        guard let an = a.analysis else { return "Sem análise. Use run_analysis." }
        return json(["cycle_s": Dictionary(uniqueKeysWithValues: an.breakdowns.map { ($0.robot, ["total": r1($0.total), "application": r1($0.application),
                                                                                                "air": r1($0.air), "waiting": r1($0.waiting), "stopped": r1($0.delays)]) }),
                     "ideal_cycle_s": a.idealCycleTime, "body_loaded": an.bodyLoaded,
                     "suggestions": an.suggestions.map { suggestionJSON($0, a) }])
    }

    @MainActor static func sync(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        guard let app = AppState.shared else { return ("app indisponível", true) }
        switch name {
        case "station_overview":
            let progs = app.robots.map { r -> [String: Any] in
                ["robot": r.name, "program": app.simulationProgramURL(for: r.id).map { "\($0.deletingLastPathComponent().deletingPathExtension().lastPathComponent)/\($0.deletingPathExtension().lastPathComponent)" } ?? "-",
                 "rail": r.model.railEnabled ? "E1 \(Int(r.model.railMin))…\(Int(r.model.railMax)) mm" : "sem trilho"]
            }
            return (json(["station": app.stationName, "robots": progs, "ideal_cycle_s": app.idealCycleTime,
                          "parts_loaded": app.parts.map(\.name), "pending_changes": app.aiModifiedPrograms.map(\.lastPathComponent),
                          "cycle_s": app.analysis?.breakdowns.reduce(into: [String: NSDecimalNumber]()) { $0[$1.robot] = r1($1.total) } ?? [:]]), false)
        case "list_suggestions":
            guard let an = app.analysis else { return ("Sem análise. Use run_analysis.", true) }
            let k = (args["kind"] as? String ?? "").lowercased()
            let items = an.suggestions.filter { s in
                let col = [.protectRegion, .adjustBit].contains(s.kind)
                return k.isEmpty || (k.hasPrefix("col") ? col : !col)
            }
            return (json(items.map { suggestionJSON($0, app) }), false)
        case "get_suggestion":
            guard let s = find(args["id"] as? String ?? "", app) else { return ("sugestão não encontrada", true) }
            app.focus(s)
            return (json(suggestionJSON(s, app, full: true)), false)
        case "read_program":
            guard let found = app.stationProgram(robot: args["robot"] as? String ?? "", program: args["program"] as? String ?? "") else {
                return ("programa não encontrado (use station_overview / robot_trajectory para ver nomes)", true)
            }
            let lines = EcoProgramEditor.rawLines(found.value.source)
            let a = Swift.max(1, (args["from_line"] as? Int) ?? 1), b = Swift.min(lines.count, (args["to_line"] as? Int) ?? lines.count)
            var out = a <= b ? (a...b).map { "\($0): \(lines[$0 - 1])" }.joined(separator: "\n") : ""
            if args["include_data"] as? Bool == true { out += "\n--- .tid ---\n" + found.value.data }
            return (out, false)
        case "robot_trajectory":
            guard let t = app.analysisTracks().first(where: { $0.name == (args["robot"] as? String ?? "") }) else { return ("robô sem simulação; rode run_analysis", true) }
            let from = args["from_s"] as? Double ?? 0, to = Swift.min(args["to_s"] as? Double ?? t.duration, t.duration)
            let step = Swift.max(args["step_s"] as? Double ?? 0.5, 0.05)
            var rows: [String] = ["t_s | ponto | programa:linha | pistola | TCP x,y,z mm | E1 | A1..A6"]
            var x = from
            while x <= to + 1e-9 && rows.count < 400 {
                let (st, p) = t.state(at: x)
                var r = t.robot
                if t.program.points.indices.contains(p), let tool = t.program.points[p].tool { r.tool = tool }
                let tcp = Kinematics.tcp(r, st).position
                let o = t.place(p)
                let paint = t.samples.first { $0.time >= x }?.paintOn ?? false
                rows.append(String(format: "%.2f | %@ | %@:%d | %@ | %.0f,%.0f,%.0f | %.0f | %@", x,
                                   t.program.points.indices.contains(p) ? t.program.points[p].name : "-", o.program, o.line, paint ? "ON" : "off",
                                   tcp.x, tcp.y, tcp.z, st.rail, st.q.map { String(format: "%.0f", $0) }.joined(separator: ",")))
                x += step
            }
            return (rows.joined(separator: "\n"), false)
        case "collision_report":
            guard let an = app.analysis else { return ("Sem análise. Use run_analysis.", true) }
            let tracks = app.analysisTracks()
            func pn(_ r: String, _ i: Int) -> String { tracks.first { $0.name == r }.flatMap { $0.program.points.indices.contains(i) ? $0.program.points[i].name : nil } ?? "\(i)" }
            return (json(an.conflicts.map { c -> [String: Any] in
                ["pair": "\(c.robotA) × \(c.robotB)", "min_distance_mm": Int(c.minDistance), "simultaneous": c.simultaneous,
                 "a_time_s": [r1(c.aTime.lowerBound), r1(c.aTime.upperBound)], "a_points": "\(pn(c.robotA, c.aPoints.lowerBound))–\(pn(c.robotA, c.aPoints.upperBound))",
                 "b_time_s": [r1(c.bTime.lowerBound), r1(c.bTime.upperBound)], "b_points": "\(pn(c.robotB, c.bPoints.lowerBound))–\(pn(c.robotB, c.bPoints.upperBound))",
                 "protected_by": c.protectedBy ?? "", "partially_protected_by": c.partiallyProtectedBy ?? ""]
            }), false)
        case "propose_suggestion":
            let edits = parseEdits(args["edits"])
            guard !edits.isEmpty else { return ("nenhuma alteração válida", true) }
            let s = AnalysisSuggestion(kind: .claude, severity: .improvement, robot: args["robot"] as? String ?? edits[0].robot,
                                       title: args["title"] as? String ?? "Sugestão do Claude", detail: args["detail"] as? String ?? "",
                                       gain: nil, program: edits[0].program, line: edits[0].line, time: 0, edits: edits)
            if app.analysis == nil { return ("rode run_analysis antes", true) }
            app.analysis?.suggestions.insert(s, at: 0)
            app.bottomTab = 2
            app.evaluateStationEffects()
            return ("Sugestão colocada no painel (id \(s.id.uuidString.prefix(8))). O usuário revisa e aplica.", false)
        default:
            return ("ferramenta desconhecida: \(name)", true)
        }
    }
}

// MARK: - Conversa com o Claude Code (claude -p)

struct ChatMessage: Identifiable {
    enum Role { case user, assistant, tool, error }
    let id = UUID()
    var role: Role
    var text: String
}

@MainActor
final class ClaudeChat: ObservableObject {
    nonisolated static let rules = """
    Você é o assistente de otimização do CellStudio (port do DXQ3D.onsite da Dürr para macOS), ligado a uma estação de robôs de pintura/vedação.
    Use as ferramentas do servidor "cellstudio" para ver a estação, as trajetórias, rodar a análise e simular alterações.
    Objetivos: (1) reduzir o tempo de ciclo HOME-to-HOME sem mudar velocidade (VEL) nem aceleração (ACC); (2) achar risco de colisão robô×robô (< 100 mm, todos os pares) e onde pôr bits de colisão (Collision1…16, livres).
    Regras: pontos com pistola ligada não mudam de posição (só o sentido da passada pode inverter); pontos no ar podem mudar sem colidir com a carroceria (folga mínima 50 mm);
    sempre confira com simulate_edits o efeito na estação inteira antes de propor; prefira propose_suggestion para o usuário aplicar; só use apply_suggestion se o usuário pedir.
    Não salve arquivos. Responda em português do Brasil, de forma objetiva, citando robô, programa:linha e o ganho em segundos.
    """

    @Published var messages: [ChatMessage] = []
    @Published var running = false
    private var sessionID: String?
    #if os(macOS)
    private var process: Process?

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func reset() { messages = []; sessionID = nil }

    func stop() { process?.terminate() }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        guard let exe = Self.claudePath() else {
            messages.append(ChatMessage(role: .error, text: "Claude Code não encontrado neste Mac (comando `claude`)."))
            return
        }
        MCPServer.shared.start()
        messages.append(ChatMessage(role: .user, text: prompt))
        running = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--mcp-config", MCPServer.shared.configJSON, "--strict-mcp-config",
                    "--allowedTools", "mcp__cellstudio",
                    "--append-system-prompt", Self.rules]
        if let sid = sessionID { args += ["--resume", sid] }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        final class Buffer: @unchecked Sendable { var data = Data() }
        let pending = Buffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            pending.data.append(chunk)
            while let nl = pending.data.firstIndex(of: 0x0A) {
                let line = pending.data[..<nl]
                pending.data = Data(pending.data[(nl + 1)...])
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                Task { @MainActor in self?.handle(obj) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                self?.running = false
                if proc.terminationStatus != 0, !e.isEmpty { self?.messages.append(ChatMessage(role: .error, text: e.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
        }
        do { try p.run(); process = p } catch {
            running = false
            messages.append(ChatMessage(role: .error, text: "Não consegui iniciar o Claude Code: \(error.localizedDescription)"))
        }
    }

    #else
    /// No iPhone não há o comando `claude`: a conversa vai direto para a API do Claude e as ferramentas
    /// da estação (MCPTools) rodam dentro do app.
    private var task: Task<Void, Never>?
    private lazy var api = ClaudeAPIChat()

    func reset() { messages = []; api.reset() }

    func stop() { task?.cancel() }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        messages.append(ChatMessage(role: .user, text: prompt))
        running = true
        task = Task {
            await api.send(prompt) { [weak self] m in self?.messages.append(m) }
            running = false
        }
    }
    #endif

    private func handle(_ obj: [String: Any]) {
        if let sid = obj["session_id"] as? String { sessionID = sid }
        switch obj["type"] as? String {
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty {
                    messages.append(ChatMessage(role: .assistant, text: t))
                } else if c["type"] as? String == "tool_use", let n = c["name"] as? String {
                    messages.append(ChatMessage(role: .tool, text: n.replacingOccurrences(of: "mcp__cellstudio__", with: "")))
                }
            }
        case "result":
            if obj["is_error"] as? Bool == true, let r = obj["result"] as? String { messages.append(ChatMessage(role: .error, text: r)) }
        default: break
        }
    }
}

// MARK: - Painel de conversa

struct ClaudeChatPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var chat: ClaudeChat
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Color(red: 0.8, green: 0.45, blue: 0.25))
                Text(Platform.isMac ? "Claude Code deste Mac – vê a estação pelas ferramentas do CellStudio"
                                    : "Claude – vê a estação pelas ferramentas do CellStudio").font(.system(size: 11))
                Spacer()
                if let a = app.claudeActivity { Text(a).font(.system(size: 10)).foregroundStyle(.secondary) }
                Button("Nova conversa") { chat.reset() }.disabled(chat.running)
                #if os(macOS)
                Button("Copiar comando MCP") {
                    Pasteboard.copy(MCPServer.shared.addCommand)
                    app.info("Comando copiado: cole no Terminal para usar a estação também numa sessão do Claude Code")
                }
                .help("Para conectar uma sessão do Claude Code no Terminal a este app")
                #else
                Button("Chave da API") { ClaudeAPIChat.askForKey() }
                #endif
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.horizontal, 8).frame(height: 28)
            Rectangle().fill(DXQ.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if chat.messages.isEmpty {
                            Text("Exemplos: \"Analisa a estação e me diz onde dá para ganhar tempo no R21\", \"Por que o R21 espera tanto?\", \"Onde colocar bits entre R11 e R21?\"")
                                .font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(chat.messages) { m in bubble(m).id(m.id) }
                        if chat.running { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Claude pensando…").font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.leading, 8) }
                    }
                    .padding(8)
                }
                .onChange(of: chat.messages.count) { _, _ in if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Rectangle().fill(DXQ.border).frame(height: 1)
            HStack(spacing: 6) {
                TextField("Pergunte ao Claude sobre a estação…", text: $input, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if chat.running { Button("Parar") { chat.stop() } } else {
                    Button(action: send) { Image(systemName: "paperplane.fill") }.disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(6)
        }
    }

    private func send() { let t = input; input = ""; chat.send(t) }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        switch m.role {
        case .user:
            HStack { Spacer(minLength: 60); Text(m.text).font(.system(size: 12)).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(DXQ.blue.opacity(0.12))).textSelection(.enabled) }
        case .assistant:
            Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                .font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.96))).textSelection(.enabled)
        case .tool:
            Label(m.text, systemImage: "wrench.and.screwdriver").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 8)
        case .error:
            Label(m.text, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
