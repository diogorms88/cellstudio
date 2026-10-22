import CellCore
import Foundation

/// Execução da simulação como no DXQ (`EcoTalkRcsDevice` / `RcsDevice.OnMessageChanged`):
/// as mensagens (comando executado, bits, avisos, erros) saem no instante da simulação em que acontecem;
/// no primeiro erro o robô para, fica vermelho (`MarkCurrentPositionAsInvalid`) e a linha do programa é indicada;
/// no fim sai "Simulação concluída com sucesso" ou "… com erros" (`Simulation_FinishedWithErrors`).
extension AppState {
    /// Início de cada ponto na trajetória (instante anterior à primeira amostra do ponto).
    static func pointStarts(_ samples: [TrajectorySample]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        var prev = 0.0
        for s in samples {
            if out[s.pointIndex] == nil { out[s.pointIndex] = prev }
            prev = s.time
        }
        return out
    }

    /// Texto da linha do programa (para a mensagem "comando executado").
    private func lineText(robot id: UUID, program: String, line: Int, cache: inout [String: [String]]) -> String? {
        let key = "\(id):\(program.uppercased())"
        if cache[key] == nil {
            guard let bk = robots.first(where: { $0.id == id })?.backup else { return nil }
            let chosen = simulationProgramURL(for: id)
            let projects = bk.projects.sorted { a, _ in a.programs.contains { $0.url == chosen } }
            guard var prog = projects.lazy.compactMap({ $0.programs.first { $0.name.caseInsensitiveCompare(program) == .orderedSame } }).first else { return nil }
            if let op = openProgram, op.url == prog.url { prog = op }
            cache[key] = EcoProgramEditor.rawLines(prog.source)
        }
        guard let lines = cache[key], lines.indices.contains(line - 1) else { return nil }
        return lines[line - 1].trimmingCharacters(in: .whitespaces)
    }

    /// Monta a fila de mensagens da execução (no relógio da estação, depois dos bits de colisão).
    func buildRunEvents(_ runs: [RobotSimulationRun]) {
        var ev: [SimEvent] = []
        var records: [KinematicIssueRecord] = []
        var cache: [String: [String]] = [:]
        for run in runs {
            let name = robots.first { $0.id == run.robotID }?.name ?? ""
            for n in run.notes { ev.append(SimEvent(time: 0, level: .simulation, text: n, robot: name, robotID: run.robotID)) }
            let starts = Self.pointStarts(run.samples)
            for (i, p) in run.program.points.enumerated() {
                let o = run.origin.indices.contains(i) ? run.origin[i] : (program: "", line: 0)
                let cmd = lineText(robot: run.robotID, program: o.program, line: o.line, cache: &cache) ?? "\(p.motion.rawValue)(\(p.name))"
                let place = o.program.isEmpty ? "" : "\(o.program):\(o.line) – "
                ev.append(SimEvent(time: starts[i] ?? 0, level: .simulation, text: place + cmd, robot: name, robotID: run.robotID,
                                   program: o.program, line: o.line))
            }
            for issue in run.issues {
                let o = run.origin.indices.contains(issue.pointIndex) ? run.origin[issue.pointIndex] : (program: "", line: 0)
                let rel = Swift.max(0, issue.time - (run.rawStarts[issue.pointIndex] ?? 0))
                let t = (starts[issue.pointIndex] ?? issue.time) + rel
                var rec = issue
                rec.time = t
                records.append(KinematicIssueRecord(robot: name, issue: rec, program: o.program, line: o.line))
                let place = o.program.isEmpty ? "" : "\(o.program):\(o.line) – "
                let code = issue.code > 0 ? " [MCU \(issue.code)]" : ""
                let level: MessageLevel = issue.severity == .error ? .error : (issue.severity == .warning ? .warning : .simulation)
                ev.append(SimEvent(time: t, level: level, text: place + issue.text + code, robot: name, robotID: run.robotID,
                                   isError: issue.severity == .error, program: o.program, line: o.line))
            }
        }
        for e in stationEvents {
            let id = robots.first { $0.name == e.robot }?.id
            ev.append(SimEvent(time: e.time, level: e.kind == .deadlock ? .warning : .simulation, text: e.text, robot: e.robot, robotID: id))
        }
        // ordem estável: no mesmo instante, o comando sai antes do erro que ele gerou
        simEvents = ev.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
        kinematicIssues = records
        postedEvents = 0
        runFinished = false
        clearRunErrors()
    }

    private func postRunBatch(_ batch: [AppMessage]) {
        guard !batch.isEmpty else { return }
        var list = messages
        list.append(contentsOf: batch)
        if list.count > 5000 { list.removeFirst(list.count - 5000) }
        messages = list
        runMessageIDs.formUnion(batch.map(\.id))
    }

    private func postRun(_ level: MessageLevel, _ text: String, robot: String?) {
        post(level, text, robot: robot)
        if let id = messages.last?.id { runMessageIDs.insert(id) }
    }

    func clearRunErrors() {
        scene.clearRobotErrors()
        simulationStop = nil
        editorErrorLine = nil
        runErrorCount = 0
    }

    /// Começo de uma execução (play a partir do início): limpa o registro anterior e o vermelho dos robôs.
    func beginRunLog() {
        messages.removeAll { runMessageIDs.contains($0.id) }
        runMessageIDs = []
        clearRunErrors()
        postedEvents = 0
        runFinished = false
        let names = simulateAllRobots
            ? simulationRuns.map { run in robots.first { $0.id == run.robotID }?.name ?? "" }.joined(separator: ", ")
            : robot.name
        postRun(.info, "Simulação iniciada – " + (simulateAllRobots ? "\(stationName): \(names)" : "\(names): \(program.name)"), robot: nil)
        advanceEvents(to: 0)
    }

    /// Solta as mensagens até o instante `t`. No primeiro erro (com "Parar no erro"), para a simulação naquele ponto.
    func advanceEvents(to t: Double) {
        var stopNow = false
        // todas as mensagens do quadro entram na lista de uma vez (cada inserção redesenha a tabela)
        var batch: [AppMessage] = []
        defer { postRunBatch(batch) }
        while postedEvents < simEvents.count, simEvents[postedEvents].time <= t + 1e-6 {
            let e = simEvents[postedEvents]
            postedEvents += 1
            batch.append(AppMessage(level: e.level, text: String(format: "%.2f s – ", e.time) + e.text, time: Date(),
                                    robot: e.robot.isEmpty ? (activeIndex.map { robots[$0].name } ?? "") : e.robot))
            guard e.isError else { continue }
            runErrorCount += 1
            if let id = e.robotID { scene.setRobotError(id, true) }
            if simulationStop == nil || isPlaying {
                let place = "\(e.program):\(e.line) – "
                let detail = e.text.hasPrefix(place) ? String(e.text.dropFirst(place.count)) : e.text
                simulationStop = SimulationStopInfo(robot: e.robot, program: e.program, line: e.line, text: detail, time: e.time)
                showErrorLine(e)
            }
            if stopOnError && isPlaying { stopNow = true; break }
        }
        if stopNow {
            postRunBatch(batch); batch = []
            stop()
            postRun(.error, "\(simulationStop?.robot ?? "Robô") parou com erro – simulação interrompida. ▶ continua a partir daqui.", robot: simulationStop?.robot)
        }
    }

    /// Mostra no editor a linha que deu erro (abre o programa se for outro e não houver edição pendente).
    private func showErrorLine(_ e: SimEvent) {
        guard !e.program.isEmpty, e.line > 0 else { return }
        if let p = openProgram, p.name.caseInsensitiveCompare(e.program) == .orderedSame,
           openProgramOwner?.name == e.robot || openProgramOwner == nil {
            editorErrorLine = e.line
            highlightedLine = e.line
            return
        }
        guard !openProgramDirty else { return }
        reveal(program: e.program, line: e.line, robot: e.robot)
        editorErrorLine = e.line
    }

    /// Ao arrastar o tempo para trás, as mensagens voltam a sair quando o tempo passar de novo por elas.
    func syncEvents(to t: Double) {
        if postedEvents > 0, postedEvents <= simEvents.count, simEvents[postedEvents - 1].time > t + 1e-6 {
            postedEvents = simEvents.firstIndex { $0.time > t + 1e-6 } ?? simEvents.count
            if let stopInfo = simulationStop, stopInfo.time > t + 1e-6 { clearRunErrors() }
            runFinished = false
        } else {
            advanceEvents(to: t)
        }
    }

    /// Fim da execução: resumo como o DXQ.
    func finishRun() {
        guard !runFinished else { return }
        advanceEvents(to: .infinity)
        runFinished = true
        let waits = stationWaitTime.filter { $0.value > 0.1 }.sorted { $0.key < $1.key }
            .map { String(format: "%@ %.1f s", $0.key, $0.value) }
        if !waits.isEmpty { postRun(.simulation, "Tempo parado esperando bits de colisão: " + waits.joined(separator: ", "), robot: nil) }
        if runErrorCount > 0 {
            postRun(.error, String(format: "Simulação concluída com erros (%d, %.1f s). Os pontos com erro estão em vermelho na trajetória.", runErrorCount, currentSimTime), robot: nil)
        } else {
            postRun(.info, String(format: "Simulação concluída com sucesso (%.1f s)", currentSimTime), robot: nil)
        }
    }
}
