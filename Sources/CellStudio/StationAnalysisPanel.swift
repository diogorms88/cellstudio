import CellCore
import SwiftUI
import simd

/// Resultado da análise da estação: tempo de ciclo por robô, regiões de risco e sugestões.
struct AnalysisReport {
    var createdAt = Date()
    var breakdowns: [CycleBreakdown]
    var suggestions: [AnalysisSuggestion]
    var conflicts: [ConflictRegion]
    var bodyLoaded: Bool
    var duration: Double
}

/// Efeito de uma sugestão na estação inteira (todos os robôs, bits de colisão reescalonados).
struct StationEffect {
    var before: [String: Double]
    var after: [String: Double]
    var stationBefore: Double
    var stationAfter: Double
    var collisionsBefore: Int
    var collisionsAfter: Int
    var newErrors: Int
    var stationGain: Double { stationBefore - stationAfter }
    var createsCollision: Bool { collisionsAfter > collisionsBefore }
}

/// O que é preciso para re-simular a estação fora da thread principal.
struct StationSimInput {
    var name: String
    var model: RobotModel
    var start: JointState
    var warnings: SimulationWarningSettings
    var systemData: [EcoTalkDeclaration]
    var project: EcoTalkProject?
    var programName: String
    var program: RobotProgram
    var origin: [(program: String, line: Int)]
    var raw: [TrajectorySample]
    var actions: [EcoTalkSyncAction]
    var errors: Int

    /// Estação com as alterações aplicadas (só os robôs alterados são re-simulados).
    static func evaluate(_ inputs: [StationSimInput], edits: [SourceEdit]) -> (totals: [String: Double], collisions: Int, newErrors: Int) {
        var sched: [StationScheduler.Input] = []
        var tracks: [RobotTrack] = []
        var newErrors = 0
        for inp in inputs {
            let mine = edits.filter { $0.robot == inp.name }
            var program = inp.program, origin = inp.origin, raw = inp.raw, actions = inp.actions
            if !mine.isEmpty, var proj = inp.project {
                for (name, es) in Dictionary(grouping: mine, by: { $0.program.uppercased() }) {
                    if let gi = proj.programs.firstIndex(where: { $0.name.uppercased() == name }) {
                        var p = proj.programs[gi]
                        EcoProgramEditor.apply(es, to: &p)
                        proj.programs[gi] = p
                    }
                }
                let res = EcoTalkInterpreter(project: proj, systemData: inp.systemData, robot: inp.model).run(inp.programName)
                let smp = Trajectory.sample(program: res.program, robot: inp.model, start: inp.start, warnings: inp.warnings)
                program = res.program; origin = res.origin; raw = smp.samples; actions = res.actions
                newErrors += Swift.max(0, smp.issues.filter { $0.severity == .error }.count - inp.errors)
            }
            sched.append(StationScheduler.Input(robot: inp.name, samples: raw, actions: actions, pointCount: program.points.count, start: inp.start))
            tracks.append(RobotTrack(name: inp.name, robot: inp.model, program: program, samples: [], origin: origin, actions: actions, start: inp.start))
        }
        let out = StationScheduler.run(sched)
        for i in tracks.indices { tracks[i].samples = out.samples[tracks[i].name] ?? [] }
        let collisions = StationAnalysis.conflicts(tracks, zones: out.zones).filter { $0.simultaneous && $0.protectedBy == nil }.count
        var totals: [String: Double] = [:]
        for t in tracks { totals[t.name] = t.samples.last?.time ?? 0 }
        return (totals, collisions, newErrors)
    }
}

extension AppState {
    func stationSimInputs() -> [StationSimInput] {
        simulationRuns.compactMap { run in
            guard let slot = robots.first(where: { $0.id == run.robotID }) else { return nil }
            var project: EcoTalkProject?
            var programName = run.program.name
            if let bk = slot.backup, let url = simulationProgramURL(for: slot.id),
               var proj = bk.projects.first(where: { $0.programs.contains { $0.url == url } }) {
                if let op = openProgram, let gi = proj.programs.firstIndex(where: { $0.url == op.url }) { proj.programs[gi] = op }
                project = proj
                programName = proj.programs.first { $0.url == url }?.name ?? programName
            }
            return StationSimInput(name: slot.name, model: slot.model, start: run.start, warnings: slot.warnings,
                                   systemData: slot.backup?.systemData ?? [], project: project, programName: programName,
                                   program: run.program, origin: run.origin, raw: run.rawSamples, actions: run.actions,
                                   errors: run.issues.filter { $0.severity == .error }.count)
        }
    }

    /// Avalia em segundo plano o efeito de cada sugestão aplicável na estação inteira.
    func evaluateStationEffects() {
        effectsTask?.cancel()
        stationEffects = [:]
        guard let a = analysis else { return }
        let inputs = stationSimInputs()
        let todo = a.suggestions.filter { $0.applicable }
        guard !todo.isEmpty, !inputs.isEmpty else { return }
        effectsTask = Task.detached(priority: .utility) {
            let base = StationSimInput.evaluate(inputs, edits: [])
            let stationBefore = base.totals.values.max() ?? 0
            for s in todo {
                // não disputa a CPU com a reprodução: espera o play parar
                while await MainActor.run(body: { AppState.shared?.isPlaying ?? false }) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                }
                if Task.isCancelled { return }
                let r = StationSimInput.evaluate(inputs, edits: s.edits)
                let eff = StationEffect(before: base.totals, after: r.totals, stationBefore: stationBefore,
                                        stationAfter: r.totals.values.max() ?? 0, collisionsBefore: base.collisions,
                                        collisionsAfter: r.collisions, newErrors: r.newErrors)
                await MainActor.run { AppState.shared?.stationEffects[s.id] = eff }
            }
        }
    }

    /// Trajetórias da simulação conjunta, no formato da análise.
    func analysisTracks() -> [RobotTrack] {
        simulationRuns.compactMap { run in
            guard let slot = robots.first(where: { $0.id == run.robotID }) else { return nil }
            return RobotTrack(name: slot.name, robot: slot.model, program: run.program, samples: run.samples,
                              origin: run.origin, actions: run.actions, start: run.start, chains: run.callChains)
        }
    }

    /// Programa de um robô pelo nome (do projeto que a estação usa), com as edições abertas no editor.
    func stationProgram(robot name: String, program: String) -> (robotIndex: Int, project: Int, program: Int, value: EcoTalkProgram)? {
        guard let ri = robots.firstIndex(where: { $0.name == name }), let bk = robots[ri].backup else { return nil }
        let chosen = simulationProgramURL(for: robots[ri].id)
        let order = bk.projects.indices.sorted { a, _ in bk.projects[a].programs.contains { $0.url == chosen } }
        for pi in order {
            if let gi = bk.projects[pi].programs.firstIndex(where: { $0.name.caseInsensitiveCompare(program) == .orderedSame }) {
                var p = bk.projects[pi].programs[gi]
                if let op = openProgram, op.url == p.url { p = op }
                return (ri, pi, gi, p)
            }
        }
        return nil
    }

    /// Carroceria/peças carregadas como obstáculo (grade cacheada enquanto as peças não mudam).
    private func bodyMesh() -> (key: String, mesh: Mesh)? {
        guard !parts.isEmpty else { return nil }
        let key = parts.map { "\($0.id)\($0.offset.x)\($0.offset.y)\($0.offset.z)\($0.offset.a)\($0.offset.b)\($0.offset.c)" }.joined()
        var P: [SIMD3<Float>] = [], I: [UInt32] = []
        for part in parts {
            let m = part.offset.matrix
            let base = UInt32(P.count)
            P += part.mesh.positions.map { v in
                let w = m * SIMD4<Double>(Double(v.x), Double(v.y), Double(v.z), 1)
                return SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
            }
            I += part.mesh.indices.map { $0 + base }
        }
        return (key, Mesh(positions: P, indices: I))
    }

    /// Projetos que existem em pelo menos um robô (para escolher o programa da análise).
    var stationProjects: [String] {
        var names = Set<String>()
        for r in robots { for p in r.backup?.projects ?? [] where !p.programs.isEmpty { names.insert(p.name) } }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Todos os robôs rodam o Main (ou o primeiro programa) do projeto.
    func applyProject(_ name: String) {
        selectedTypeKey = nil
        var used: [String] = [], missing: [String] = []
        for slot in robots {
            guard let proj = slot.backup?.projects.first(where: { $0.name == name }),
                  let prog = proj.programs.first(where: { $0.name.caseInsensitiveCompare("Main") == .orderedSame }) ?? proj.programs.first else {
                missing.append(slot.name); continue
            }
            simulationProgramSelection[slot.id] = prog.url.path
            used.append("\(slot.name): \(proj.name)/\(prog.name)")
        }
        stop(); invalidateTrajectory()
        info("Programa da estação: " + used.joined(separator: ", "))
        if !missing.isEmpty { warn("Sem o projeto \(name): " + missing.joined(separator: ", ") + " (ficam parados)") }
    }

    /// Chave do programa escolhido para a análise: "type:N", "proj:Nome" ou "" (o que está em Programas da estação).
    var analysisProgramKey: String {
        get { selectedTypeKey.map { "type:\($0)" } ?? analysisProjectKey }
        set {
            if newValue.hasPrefix("type:") { analysisProjectKey = ""; applyType(String(newValue.dropFirst(5))) }
            else if newValue.hasPrefix("proj:") { analysisProjectKey = newValue; applyProject(String(newValue.dropFirst(5))) }
            else { analysisProjectKey = ""; selectedTypeKey = nil }
        }
    }

    /// Analisar: gera a simulação da estação desde HOME (com os programas escolhidos) e depois a análise.
    func simulateAndAnalyze() {
        guard !analyzing else { return }
        stop()
        scene.clearAnalysisHighlight()
        for i in robots.indices { robots[i].joints = homeState(for: robots[i]); scene.updateRobot(robots[i]) }
        simulateAllRobots = true
        computeTrajectory()
        guard !simulationRuns.isEmpty else { warn("Análise: nenhum robô com programa na estação"); return }
        let names = simulationRuns.compactMap { run in robots.first { $0.id == run.robotID }.map { r in
            "\(r.name): \(simulationProgramURL(for: r.id).map { $0.deletingLastPathComponent().deletingPathExtension().lastPathComponent + "/" + $0.deletingPathExtension().lastPathComponent } ?? "-")" } }
        info(String(format: "Simulação gerada para a análise (%.1f s): ", simulationTimeline.last ?? 0) + names.joined(separator: ", "))
        runAnalysis()
    }

    func runAnalysis() {
        guard !analyzing else { return }
        if !simulateAllRobots { simulateAllRobots = true }
        if simulationRuns.isEmpty { computeTrajectory() }
        guard !simulationRuns.isEmpty else { warn("Análise: nenhum robô com programa na estação"); return }
        stop()
        let tracks = analysisTracks()
        let zones = stationZones, waits = stationWaits
        var sources: [String: [String: EcoTalkProgram]] = [:]
        for t in tracks {
            for name in Set(t.origin.map(\.program)) {
                if let p = stationProgram(robot: t.name, program: name)?.value { sources[t.name, default: [:]][name.uppercased()] = p }
            }
        }
        let body = bodyMesh()
        let cached = bodyGridCache.flatMap { c in c.key == body?.key ? c.grid : nil }
        analyzing = true
        bottomTab = 2
        post(.info, "Análise da estação iniciada: \(tracks.map(\.name).joined(separator: ", "))" + (body == nil ? " – sem carroceria carregada" : ""))
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let grid = cached ?? body.map { ObstacleGrid(mesh: $0.mesh, transform: matrix_identity_double4x4) }
            let conflicts = StationAnalysis.conflicts(tracks, zones: zones)
            var suggestions: [AnalysisSuggestion] = []
            for t in tracks {
                let src = sources[t.name] ?? [:]
                suggestions += CycleAnalysis.cycleSuggestions(t, body: grid, source: { src[$0.uppercased()] })
            }
            suggestions += CycleAnalysis.collisionSuggestions(tracks, conflicts: conflicts, zones: zones, waits: waits)
            // um aviso de "carregue a carroceria" basta
            var seenNotice = false
            suggestions = suggestions.filter { s in
                guard s.kind == .notice else { return true }
                defer { seenNotice = true }
                return !seenNotice
            }
            suggestions.sort { ($0.severity, -($0.gain ?? 0)) < ($1.severity, -($1.gain ?? 0)) }
            let breakdowns = tracks.map { CycleAnalysis.breakdown($0, waits: waits) }
            let elapsed = Date().timeIntervalSince(t0)
            let result = suggestions
            await MainActor.run {
                let suggestions = result
                if let body, let grid { self.bodyGridCache = (body.key, grid) }
                self.analysis = AnalysisReport(breakdowns: breakdowns, suggestions: suggestions, conflicts: conflicts,
                                               bodyLoaded: body != nil, duration: elapsed)
                self.analyzing = false
                self.evaluateStationEffects()
                let crit = suggestions.filter { $0.severity == .critical }.count, risk = suggestions.filter { $0.severity == .risk }.count
                let gain = suggestions.compactMap { $0.kind == .notice ? nil : $0.gain }.reduce(0, +)
                self.post(crit > 0 ? .error : (risk > 0 ? .warning : .info),
                          String(format: "Análise concluída em %.1f s: %d colisão(ões) na simulação, %d risco(s) < 100 mm, %d melhoria(s) de ciclo (até %.1f s somadas)",
                                 elapsed, crit, risk, suggestions.filter { $0.severity == .improvement }.count, gain))
            }
        }
    }

    /// Leva a simulação ao instante da sugestão, abre a linha e mostra o caminho na Vista 3D.
    func focus(_ s: AnalysisSuggestion) {
        selectedSuggestionID = s.id
        scrub(toTime: s.time)
        let robot = s.edits.first?.robot ?? s.robot.components(separatedBy: " × ").first ?? s.robot
        if !s.program.isEmpty, s.line > 0 { reveal(program: s.program, line: s.line, robot: robot) }
        let marker = (s.kind == .protectRegion || s.kind == .adjustBit) ? s.currentPath.first : nil
        scene.showAnalysisHighlight(current: marker == nil ? s.currentPath : [], proposed: s.proposedPath, marker: marker)
        // risco: começa mostrando onde os robôs estão de verdade nesse instante
        if let first = s.riskPoints.first { showRealPositions(s, at: first.robot) }
    }

    /// Distância real entre os robôs do risco num instante (mm).
    private func pairDistance(_ s: AnalysisSuggestion, at t: Double) -> Double? {
        let names = s.riskPoints.map(\.robot)
        let tracks = analysisTracks().filter { names.contains($0.name) }
        guard tracks.count == 2 else { return nil }
        return RobotGeometry.clearance(RobotGeometry.capsules(tracks[0].robot, tracks[0].state(at: t).state),
                                       RobotGeometry.capsules(tracks[1].robot, tracks[1].state(at: t).state)).distance
    }

    /// Posição real: a estação inteira no instante em que `robot` passa pelo ponto de risco (sem colisão, se o tempo for diferente).
    func showRealPositions(_ s: AnalysisSuggestion, at robot: String) {
        guard let rp = s.riskPoints.first(where: { $0.robot == robot }) else { return }
        scrub(toTime: rp.time)
        let others = s.riskPoints.filter { $0.robot != robot }.map { o -> String in
            guard let t = analysisTracks().first(where: { $0.name == o.robot }) else { return o.robot }
            let p = t.state(at: rp.time).point
            let pl = t.place(p)
            return "\(o.robot) está em \(pl.program):\(pl.line) (\(t.program.points.indices.contains(p) ? t.program.points[p].name : "?"))"
        }
        let d = pairDistance(s, at: rp.time).map { String(format: " – distância real %.0f mm", $0) } ?? ""
        info(String(format: "Posição real em %.1f s: %@ no ponto de risco %@ (%@:%d); ", rp.time, robot, rp.point, rp.program, rp.line) + others.joined(separator: ", ") + d)
    }

    /// Colisão se atrasar: cada robô na posição em que fica mais perto do outro (instantes diferentes).
    func showDelayedCollision(_ s: AnalysisSuggestion) {
        stop()
        var shown: [String] = []
        for rp in s.riskPoints {
            guard let i = robots.firstIndex(where: { $0.name == rp.robot }),
                  let track = analysisTracks().first(where: { $0.name == rp.robot }) else { continue }
            robots[i].joints = track.state(at: rp.time).state
            scene.updateRobot(robots[i])
            shown.append(String(format: "%@ em %.1f s (%@)", rp.robot, rp.time, rp.point))
        }
        let times = s.riskPoints.map(\.time)
        let gap = (times.max() ?? 0) - (times.min() ?? 0)
        info("Colisão se atrasar: " + shown.joined(separator: " × ") + String(format: " – acontece se um robô atrasar %.1f s em relação ao outro", gap))
    }

    /// Botão direito ▸ ir para o ponto de risco de um robô: abre a linha no editor e põe o robô nessa posição.
    func goToRiskPoint(_ s: AnalysisSuggestion, _ rp: RiskPoint) {
        selectedSuggestionID = s.id
        showRealPositions(s, at: rp.robot)
        guard !rp.program.isEmpty, rp.line > 0 else { return }
        reveal(program: rp.program, line: rp.line, robot: rp.robot)
        editorTab = 0
        editorSelection = [rp.line - 1]
        highlightedLine = rp.line
    }

    /// Aplica a sugestão nos programas (em memória, com desfazer); recalcula a simulação e a análise.
    func apply(_ s: AnalysisSuggestion) {
        guard s.applicable else { warn("Esta sugestão precisa ser feita à mão: \(s.manualReason ?? "")"); return }
        var snapshot: [(robot: UUID, program: EcoTalkProgram)] = []
        for (robot, byRobot) in Dictionary(grouping: s.edits, by: \.robot) {
            for (name, edits) in Dictionary(grouping: byRobot, by: { $0.program.uppercased() }) {
                guard let found = stationProgram(robot: robot, program: name), var bk = robots[found.robotIndex].backup else {
                    warn("Não achei o programa \(name) de \(robot)"); continue
                }
                var prog = found.value
                snapshot.append((robots[found.robotIndex].id, prog))
                EcoProgramEditor.apply(edits, to: &prog)
                bk.projects[found.project].programs[found.program] = prog
                robots[found.robotIndex].backup = bk
                if openProgram?.url == prog.url { openProgram = prog; openProgramDirty = true }
                if let ti = openTabs.firstIndex(where: { $0.id == prog.url }) { openTabs[ti].program = prog; openTabs[ti].dirty = true }
                aiModifiedPrograms.insert(prog.url)
            }
        }
        guard !snapshot.isEmpty else { return }
        aiUndo.append(snapshot)
        info("Sugestão aplicada (\(s.kind.rawValue)): \(s.title). Salve com \"Salvar alterações\" na aba Análise.")
        scene.clearAnalysisHighlight()
        scrub(to: 0)        // robôs na posição inicial da simulação antes de recalcular
        computeTrajectory()
        runAnalysis()
    }

    func undoLastApply() {
        guard let snap = aiUndo.popLast() else { return }
        for item in snap {
            guard let ri = robots.firstIndex(where: { $0.id == item.robot }), var bk = robots[ri].backup else { continue }
            for pi in bk.projects.indices {
                if let gi = bk.projects[pi].programs.firstIndex(where: { $0.url == item.program.url }) { bk.projects[pi].programs[gi] = item.program }
            }
            robots[ri].backup = bk
            if openProgram?.url == item.program.url { openProgram = item.program }
            if let ti = openTabs.firstIndex(where: { $0.id == item.program.url }) { openTabs[ti].program = item.program }
        }
        info("Última sugestão desfeita")
        scene.clearAnalysisHighlight()
        scrub(to: 0)
        computeTrajectory()
        runAnalysis()
    }

    /// Grava nos .tip/.tid os programas alterados pelas sugestões.
    func saveAnalysisChanges() {
        var saved: [String] = []
        for slot in robots {
            for proj in slot.backup?.projects ?? [] {
                for p in proj.programs where aiModifiedPrograms.contains(p.url) {
                    let value = openProgram?.url == p.url ? openProgram! : p
                    do { try value.save(); saved.append("\(slot.name)/\(p.name)") } catch { self.error("Erro ao salvar \(p.name): \(error.localizedDescription)") }
                    if openProgram?.url == p.url { openProgramDirty = false }
                    if let ti = openTabs.firstIndex(where: { $0.id == p.url }) { openTabs[ti].program = value; openTabs[ti].dirty = false }
                }
            }
        }
        aiModifiedPrograms = []
        aiUndo = []
        info(saved.isEmpty ? "Nada para salvar" : "Salvo: " + saved.joined(separator: ", "))
    }
}

// MARK: - Painel

struct StationAnalysisPanel: View {
    @EnvironmentObject var app: AppState
    @State private var filter = 0      // 0 todas, 1 colisão, 2 tempo de ciclo
    @State private var showPhoneDetail = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(DXQ.border).frame(height: 1)
            if app.analyzing {
                VStack(spacing: 8) { ProgressView(); Text("Analisando trajetórias, distâncias entre robôs e carroceria…").font(DXQ.font) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let a = app.analysis {
                if Platform.isPhone {
                    // iPhone: ciclo em cima, sugestões embaixo; o detalhe abre em folha
                    VStack(spacing: 0) {
                        cycleSummary(a).frame(maxHeight: 190)
                        Rectangle().fill(DXQ.border).frame(height: 1)
                        suggestionList(a)
                    }
                } else {
                HStack(spacing: 0) {
                    cycleSummary(a).frame(width: 300)
                    Rectangle().fill(DXQ.border).frame(width: 1)
                    suggestionList(a)
                }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Análise da estação").font(.headline)
                    Text("Carregue a carroceria (Objetos 3D), escolha os programas da estação e clique em Analisar. A análise procura colisão entre todos os robôs (< 100 mm) e onde o tempo de ciclo pode cair sem mexer em velocidade e aceleração.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                    if Platform.isPhone {
                        VStack(spacing: 10) { AnalysisProgramPicker(width: 260); Button("Simular e analisar") { app.simulateAndAnalyze() }.buttonStyle(.borderedProminent) }
                    } else {
                        HStack { AnalysisProgramPicker(width: 260); Button("Simular e analisar") { app.simulateAndAnalyze() }.buttonStyle(.borderedProminent) }
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            AnalysisProgramPicker(width: 230)
            Button { app.simulateAndAnalyze() } label: { Label("Simular e analisar", systemImage: "sparkles") }.disabled(app.analyzing)
            Divider().frame(height: 14)
            Text("Ciclo ideal HOME-to-HOME")
            TextField("", value: $app.idealCycleTime, format: .number.precision(.fractionLength(1))).frame(width: 56).textFieldStyle(.roundedBorder)
            Text("s").foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Text("Variação ±").help("Atraso que a célula real pode ter. Riscos em instantes diferentes acima disso aparecem como informação.")
            TextField("", value: $app.timingTolerance, format: .number.precision(.fractionLength(0...1))).frame(width: 40).textFieldStyle(.roundedBorder)
            Text("s").foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Picker("", selection: $filter) {
                Text("Todas").tag(0); Text("Colisão").tag(1); Text("Tempo de ciclo").tag(2)
            }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
            Spacer()
            if !app.aiUndo.isEmpty { Button { app.undoLastApply() } label: { Label("Desfazer", systemImage: "arrow.uturn.backward") } }
            if !app.aiModifiedPrograms.isEmpty {
                Button { app.saveAnalysisChanges() } label: { Label("Salvar alterações (\(app.aiModifiedPrograms.count))", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: Platform.isPhone ? 40 : 28)
        .phoneHorizontalScroll()
    }

    private func cycleSummary(_ a: AnalysisReport) -> some View {
        let ideal = app.idealCycleTime
        let maxT = Swift.max(a.breakdowns.map(\.total).max() ?? 1, ideal, 1)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tempo de ciclo (simulado)").font(.system(size: 11, weight: .semibold))
                ForEach(a.breakdowns, id: \.robot) { b in
                    let gain = a.suggestions.filter { $0.robot == b.robot && $0.severity == .improvement }.compactMap(\.gain).reduce(0, +)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(b.robot).font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text(String(format: "%.1f s", b.total)).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ideal > 0 && b.total > ideal ? .red : .primary)
                        }
                        GeometryReader { g in
                            let w = g.size.width / maxT
                            ZStack(alignment: .leading) {
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color.orange).frame(width: b.application * w)
                                    Rectangle().fill(Color(red: 0.3, green: 0.55, blue: 0.85)).frame(width: b.air * w)
                                    Rectangle().fill(Color.red.opacity(0.6)).frame(width: b.waiting * w)
                                    Rectangle().fill(Color.gray.opacity(0.4)).frame(width: b.delays * w)
                                }
                                if ideal > 0 { Rectangle().fill(Color.green).frame(width: 2, height: 16).offset(x: ideal * w) }
                            }
                        }
                        .frame(height: 12)
                        Text(String(format: "aplicação %.1f · ar %.1f · espera %.1f · parado %.1f%@", b.application, b.air, b.waiting, b.delays,
                                    gain > 0 ? String(format: " · sugestões −%.1f s", gain) : ""))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        if ideal > 0 {
                            Text(b.total <= ideal ? "Dentro da meta" : String(format: "%.1f s acima da meta%@", b.total - ideal, gain >= b.total - ideal ? " – as sugestões cobrem" : ""))
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(b.total <= ideal ? .green : .red)
                        }
                    }
                }
                HStack(spacing: 6) {
                    legend(.orange, "aplicação"); legend(Color(red: 0.3, green: 0.55, blue: 0.85), "ar"); legend(.red.opacity(0.6), "espera"); legend(.gray.opacity(0.4), "parado")
                }
                if !a.bodyLoaded {
                    Label("Sem carroceria: sugestões de caminho desligadas", systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Text(String(format: "Análise de %@ (%.1f s)", a.createdAt.formatted(date: .omitted, time: .shortened), a.duration)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 2) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 8); Text(t).font(.system(size: 9)) }
    }

    private func visible(_ a: AnalysisReport) -> [AnalysisSuggestion] {
        a.suggestions.filter { s in
            switch filter {
            case 1: return [.protectRegion, .adjustBit].contains(s.kind)
            case 2: return ![.protectRegion, .adjustBit].contains(s.kind)
            default: return true
            }
        }
    }

    private func suggestionList(_ a: AnalysisReport) -> some View {
        let items = visible(a)
        let selected = items.first { $0.id == app.selectedSuggestionID }
        return HStack(spacing: 0) {
            List(items, selection: Binding(get: { app.selectedSuggestionID }, set: { id in
                // só reage a uma escolha nova (evita o ciclo seleção → focus → seleção)
                guard id != app.selectedSuggestionID, let s = items.first(where: { $0.id == id }) else { return }
                DispatchQueue.main.async { app.focus(s) }
            })) { s in
                SuggestionRow(s: s, effect: app.stationEffects[s.id], evaluating: app.effectsTask != nil && s.applicable && app.stationEffects[s.id] == nil).tag(s.id)
                    .contextMenu {
                        ForEach(s.riskPoints) { rp in
                            Button("Ir para o ponto de risco do \(rp.robot) – \(rp.program):\(rp.line) (\(rp.point), \(String(format: "%.1f", rp.time)) s)") { app.goToRiskPoint(s, rp) }
                        }
                        if !s.riskPoints.isEmpty {
                            Divider()
                            ForEach(s.riskPoints) { rp in Button("Posição real (instante do \(rp.robot))") { app.selectedSuggestionID = s.id; app.showRealPositions(s, at: rp.robot) } }
                            Button("Mostrar colisão se um robô atrasar") { app.selectedSuggestionID = s.id; app.showDelayedCollision(s) }
                        }
                        if s.applicable { Divider(); Button("Aplicar sugestão") { app.apply(s) } }
                    }
            }
            .listStyle(.plain)
            .sheet(isPresented: Binding(get: { Platform.isPhone && selected != nil && showPhoneDetail },
                                        set: { if !$0 { showPhoneDetail = false } })) {
                if let s = selected {
                    NavigationStack { ScrollView { SuggestionDetail(s: s) }.navigationTitle(s.title).navigationBarTitleDisplayModeInline() }
                        .presentationDetents([.medium, .large])
                }
            }
            .onChange(of: app.selectedSuggestionID) { _, id in if id != nil { showPhoneDetail = true } }
            if let s = selected, !Platform.isPhone {
                Rectangle().fill(DXQ.border).frame(width: 1)
                SuggestionDetail(s: s).frame(width: 340)
            }
        }
    }
}

struct SuggestionRow: View {
    let s: AnalysisSuggestion
    var effect: StationEffect?
    var evaluating = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("\(s.robot) · \(s.kind.rawValue)" + (s.program.isEmpty ? "" : " · \(s.program):\(s.line)"))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let g = s.gain, s.kind != .notice {
                Text(String(format: "robô −%.2f s", g)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let e = effect {
                // efeito real na estação (mais lento dos robôs), com os bits reescalonados
                Text(String(format: "estação %@%.1f s", e.stationGain >= 0 ? "−" : "+", abs(e.stationGain)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(e.createsCollision || e.newErrors > 0 ? .red : (e.stationGain > 0.05 ? .green : .secondary))
                if e.createsCollision || e.newErrors > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 10))
                        .help(e.createsCollision ? "Cria colisão na simulação" : "Gera erro de cinemática")
                }
            } else if evaluating {
                ProgressView().controlSize(.mini)
            }
            if !s.applicable && s.kind != .notice { Image(systemName: "hand.raised").font(.system(size: 9)).foregroundStyle(.secondary).help(s.manualReason ?? "") }
        }
        .padding(.vertical, 1)
    }
    private var icon: String {
        switch s.severity { case .critical: "xmark.octagon.fill"; case .risk: "exclamationmark.triangle.fill"; case .improvement: "bolt.fill"; case .info: "info.circle" }
    }
    private var color: Color {
        switch s.severity { case .critical: .red; case .risk: .orange; case .improvement: .green; case .info: .blue }
    }
}

struct SuggestionDetail: View {
    @EnvironmentObject var app: AppState
    let s: AnalysisSuggestion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.system(size: 12, weight: .bold))
                if !s.riskPoints.isEmpty {
                    Text("Ver o risco").font(.system(size: 10, weight: .semibold))
                    HStack {
                        ForEach(s.riskPoints) { rp in
                            Button("Posição real (\(rp.robot))") { app.showRealPositions(s, at: rp.robot) }
                                .help(String(format: "Estação inteira em %.1f s: onde os robôs estão de verdade", rp.time))
                        }
                    }
                    Button("Mostrar colisão se um robô atrasar") { app.showDelayedCollision(s) }
                        .help("Cada robô na posição em que chega mais perto do outro")
                    HStack {
                        ForEach(s.riskPoints) { rp in
                            Button("Abrir \(rp.robot) \(rp.program):\(rp.line)") { app.goToRiskPoint(s, rp) }
                                .help("Abre o ponto \(rp.point) no editor de programa")
                        }
                    }
                }
                Text(s.detail).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let c = s.bodyClearance { Text(String(format: "Folga à carroceria: %.0f mm", c)).font(.system(size: 10)).foregroundStyle(.secondary) }
                if let e = app.stationEffects[s.id] {
                    Text("Efeito na estação (simulada com os bits)").font(.system(size: 10, weight: .semibold))
                    ForEach(e.before.keys.sorted(), id: \.self) { r in
                        let b = e.before[r] ?? 0, a = e.after[r] ?? 0
                        HStack {
                            Text(r).frame(width: 40, alignment: .leading)
                            Text(String(format: "%.1f → %.1f s", b, a)).font(.system(size: 10, design: .monospaced))
                            Text(String(format: "(%@%.1f)", a <= b ? "−" : "+", abs(a - b))).foregroundStyle(a < b - 0.05 ? .green : (a > b + 0.05 ? .red : .secondary))
                        }
                        .font(.system(size: 10))
                    }
                    Text(String(format: "Ciclo da estação: %.1f → %.1f s", e.stationBefore, e.stationAfter)).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(e.stationGain > 0.05 ? .green : (e.stationGain < -0.05 ? .red : .primary))
                    if e.createsCollision {
                        Label("Com o novo tempo, os robôs ficam a menos de 100 mm ao mesmo tempo (\(e.collisionsBefore) → \(e.collisionsAfter)). Precisa de bit de colisão.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }
                    if e.newErrors > 0 { Label("Gera \(e.newErrors) erro(s) de cinemática novo(s)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red) }
                } else if s.applicable {
                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Avaliando o efeito na estação…").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if !s.edits.isEmpty {
                    Text("Alterações").font(.system(size: 10, weight: .semibold))
                    ForEach(Array(s.edits.enumerated()), id: \.offset) { _, e in
                        Text("\(e.robot) \(e.program):\(e.line) – \(describe(e.op))").font(.system(size: 10, design: .monospaced)).lineLimit(3)
                    }
                }
                if let r = s.manualReason { Label(r, systemImage: "hand.raised").font(.system(size: 10)).foregroundStyle(.orange) }
                HStack {
                    Button("Ver na simulação") { app.focus(s) }
                    if s.applicable { Button("Aplicar") { app.apply(s) }.buttonStyle(.borderedProminent) }
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }
    private func describe(_ op: SourceEdit.Op) -> String {
        switch op {
        case .replace(let t): "trocar por \(t.trimmingCharacters(in: .whitespaces))"
        case .insertBefore(let ts): "inserir antes: " + ts.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
        case .insertAfter(let ts): "inserir depois: " + ts.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
        case .delete: "remover a linha"
        case .disable: "desativar (##)"
        }
    }
}


/// Escolha do programa que a análise simula: tipo do typelist.ini, projeto (Main) ou o que está na estação.
struct AnalysisProgramPicker: View {
    @EnvironmentObject var app: AppState
    var width: CGFloat = 230
    var body: some View {
        Picker("", selection: Binding(get: { app.analysisProgramKey }, set: { app.analysisProgramKey = $0 })) {
            Text("Programas da estação (atual)").tag("")
            if !app.typeListOptions.isEmpty {
                Section("Tipos em produção (typelist.ini)") {
                    ForEach(app.typeListOptions) { t in Text(t.label).tag("type:\(t.section)") }
                }
            }
            Section("Projetos (Main)") {
                ForEach(app.stationProjects, id: \.self) { p in Text(p).tag("proj:\(p)") }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: width)
        .help("Programa que cada robô roda na simulação da análise")
    }
}
