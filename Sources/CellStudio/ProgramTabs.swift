import CellCore
import SwiftUI

/// Um módulo aberto no editor (aba), com as alterações e o desfazer próprios.
struct ProgramTab: Identifiable {
    var id: URL { program.url }
    var robotID: UUID
    var program: EcoTalkProgram
    var dirty = false
    var undo: [EcoTalkProgram] = []
    var redo: [EcoTalkProgram] = []
}

extension AppState {
    /// Guarda o estado do módulo atual na aba dele.
    private func stashCurrentTab() {
        guard let op = openProgram, let i = openTabs.firstIndex(where: { $0.id == op.url }) else { return }
        openTabs[i].program = op
        openTabs[i].dirty = openProgramDirty
        openTabs[i].undo = editUndo
        openTabs[i].redo = editRedo
    }

    /// Mostra (abrindo se preciso) a aba de um módulo.
    func showTab(_ p: EcoTalkProgram, robot id: UUID) {
        stashCurrentTab()
        if let t = openTabs.first(where: { $0.id == p.url }) {
            openProgram = t.program
            openProgramDirty = t.dirty
            editUndo = t.undo; editRedo = t.redo
        } else {
            openTabs.append(ProgramTab(robotID: id, program: p))
            openProgram = p
            openProgramDirty = false
        }
    }

    /// Troca para outra aba: o 3D passa a mostrar só a trajetória daquele módulo.
    func selectTab(_ url: URL) {
        guard url != openProgram?.url, let t = openTabs.first(where: { $0.id == url }) else { return }
        if t.robotID != activeRobotID { activate(t.robotID) }
        showTab(t.program, robot: t.robotID)
        if let slot = robots.first(where: { $0.id == t.robotID }) { selection = .program(slot.id, url.path) }
        highlightedLine = nil
        previewModule()
    }

    func closeTab(_ url: URL) {
        guard let i = openTabs.firstIndex(where: { $0.id == url }) else { return }
        let isCurrent = openProgram?.url == url
        let dirty = isCurrent ? openProgramDirty : openTabs[i].dirty
        if dirty {
            switch Dialogs.ask("Salvar as alterações em \(openTabs[i].program.name)?",
                               "O módulo tem alterações que ainda não foram gravadas no .tip/.tid.",
                               buttons: ["Salvar", "Descartar", "Cancelar"]) {
            case 0:
                if isCurrent { saveOpenProgram() } else { try? openTabs[i].program.save() }
            case 1: break
            default: return
            }
        }
        openTabs.remove(at: i)
        guard isCurrent else { return }
        if let next = openTabs.last {
            openProgram = nil
            selectTab(next.id)
        } else {
            openProgram = nil
            openProgramDirty = false
            program = RobotProgram(name: "programa")
            scene.showPaths([])
        }
    }

    /// Ferramenta e objeto em vigor quando o programa da estação chama o módulo (para pontos Object no lugar certo).
    func moduleEntryFrames(module: String, robot slot: RobotSlot) -> EcoFrameContext? {
        // projeto do módulo (o aberto no editor, senão o da estação)
        guard let bk = slot.backup else { return nil }
        let moduleURL = openProgram.flatMap { op in op.name.caseInsensitiveCompare(module) == .orderedSame ? op.url : nil }
        let stationURL = simulationProgramURL(for: slot.id)
        guard var proj = bk.projects.first(where: { p in p.programs.contains { $0.url == moduleURL } })
                ?? bk.projects.first(where: { p in p.programs.contains { $0.url == stationURL } }) else { return nil }
        // quem chama o módulo: o programa da estação, se for deste projeto; senão o Main do projeto
        guard let main = proj.programs.first(where: { $0.url == stationURL })
                ?? proj.programs.first(where: { $0.name.caseInsensitiveCompare("Main") == .orderedSame }),
              main.name.caseInsensitiveCompare(module) != .orderedSame else { return nil }
        if let op = openProgram, let gi = proj.programs.firstIndex(where: { $0.url == op.url }) { proj.programs[gi] = op }
        let res = EcoTalkInterpreter(project: proj, systemData: bk.systemData, robot: slot.model).run(main.name)
        let prefix = module.uppercased() + ":"
        return res.frames.filter { $0.key.hasPrefix(prefix) }
            .min { (Int($0.key.dropFirst(prefix.count)) ?? .max) < (Int($1.key.dropFirst(prefix.count)) ?? .max) }?.value
    }

    /// Trajetória só do módulo aberto (não do programa inteiro da estação).
    func previewModule() {
        guard let p = openProgram, let owner = openProgramOwner, let bk = owner.backup, let proj = openProject else { return }
        var interp = EcoTalkInterpreter(project: proj, systemData: bk.systemData, robot: owner.model)
        interp.initialFrames = moduleEntryFrames(module: p.name, robot: owner)
        let res = interp.run(p.name)
        programNotes = res.messages
        setProgramActions(res.program.name, res.actions)
        origin = res.origin
        if let first = res.program.points.first { activeTool = first.tool ?? Pose() }
        program = res.program          // mostra o caminho do módulo e invalida a simulação anterior
    }

    // MARK: typelist.ini

    /// Tipos de todos os robôs, pela seção do typelist.ini (nome/descrição do primeiro robô que tiver).
    var typeListOptions: [TypeListEntry] {
        var bySection: [String: TypeListEntry] = [:]
        for slot in robots {
            for e in slot.backup?.typeList ?? [] where !e.isEmpty && bySection[e.section] == nil { bySection[e.section] = e }
        }
        return bySection.values.sorted { a, b in
            a.number != b.number ? a.number < b.number : a.section.localizedStandardCompare(b.section) == .orderedAscending
        }
    }

    /// Todos os robôs passam a rodar o Proj/Prog do tipo (cada um pelo próprio typelist.ini:
    /// mesma seção; senão mesmo TypNo e nome; senão mesmo TypNo).
    func applyType(_ key: String?) {
        selectedTypeKey = key
        guard let key, let opt = typeListOptions.first(where: { $0.section == key }) else { return }
        var used: [String] = [], missing: [String] = []
        for slot in robots {
            guard let bk = slot.backup else { continue }
            let list = bk.typeList.filter { !$0.isEmpty }
            let e = list.first { $0.section == key && $0.number == opt.number }
                ?? list.first { $0.number == opt.number && $0.name == opt.name }
                ?? list.first { $0.number == opt.number } ?? opt
            guard let proj = bk.projects.first(where: { $0.name.caseInsensitiveCompare(e.project) == .orderedSame }),
                  let prog = proj.programs.first(where: { $0.name.caseInsensitiveCompare(e.program) == .orderedSame }) else {
                missing.append(slot.name); continue
            }
            simulationProgramSelection[slot.id] = prog.url.path
            used.append("\(slot.name): \(proj.name)/\(prog.name)")
        }
        stop()
        invalidateTrajectory()
        info("Tipo \(opt.label) – " + used.joined(separator: ", "))
        if !missing.isEmpty { warn("Sem o projeto/programa do tipo \(opt.number) no backup: " + missing.joined(separator: ", ")) }
    }
}

/// Abas dos módulos abertos (como os documentos do DXQ).
struct ProgramTabsBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if !app.openTabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(app.openTabs) { t in
                        let current = t.id == app.openProgram?.url
                        let robot = app.robots.first { $0.id == t.robotID }?.name ?? "?"
                        let project = t.id.deletingLastPathComponent().deletingPathExtension().lastPathComponent
                        let dirty = current ? app.openProgramDirty : t.dirty
                        HStack(spacing: 4) {
                            Text("\(robot) · \(project) · \(t.program.name)\(dirty ? " *" : "")")
                                .font(.system(size: 11, weight: current ? .semibold : .regular))
                                .foregroundStyle(current ? DXQ.blue : Color(white: 0.3))
                                .lineLimit(1)
                            Button { app.closeTab(t.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.borderless).help("Fechar módulo")
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(current ? Color.white : Color(white: 0.92))
                        .overlay(alignment: .top) { if current { Rectangle().fill(DXQ.blue).frame(height: 2) } }
                        .overlay(alignment: .trailing) { Rectangle().fill(DXQ.border).frame(width: 1) }
                        .contentShape(Rectangle())
                        .onTapGesture { app.selectTab(t.id) }
                        .help("\(robot): \(project)/\(t.program.name) – clique para ver só a trajetória deste módulo")
                    }
                }
            }
            .frame(height: 22)
            .background(Color(white: 0.92))
            .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
        }
    }
}
