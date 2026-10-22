import CellCore
import Foundation

/// Gerenciamento da estação como no DXQ (Projeto ▸ Estação ▸ Controle/robô):
/// - a estação é só um título (Nova estação / Renomear);
/// - robôs entram pelo backup do flash (Adicionar robô) e saem com Excluir da estação;
/// - "Remover da Vista 3D" tira a kinematic do 3D (DXQ "Remove robot from 3D"), mas o robô continua na estação.
extension AppState {
    var robotsIn3D: [RobotSlot] { robots.filter { !$0.hidden3D } }

    /// Mostra ou remove a kinematic da Vista 3D (some do 3D e da simulação conjunta; programas continuam no explorador).
    func setRobotIn3D(_ id: UUID, _ shown: Bool) {
        guard let i = robots.firstIndex(where: { $0.id == id }), robots[i].hidden3D == shown else { return }
        stop()
        robots[i].hidden3D = !shown
        scene.updateRobot(robots[i])
        if !shown, activeRobotID == id { activeRobotID = robotsIn3D.first?.id }
        scene.highlight(robot: activeRobotID)
        invalidateTrajectory()
        scene.showPaths([])
        info(shown ? "\(robots[i].name) carregado na Vista 3D" : "\(robots[i].name) removido da Vista 3D (continua na estação; não entra na simulação)")
    }

    func setAllRobotsIn3D(_ shown: Bool) {
        for r in robots where r.hidden3D == shown { setRobotIn3D(r.id, shown) }
    }

    /// Exclui o robô (controle) da estação. Os arquivos do backup não são apagados.
    func deleteRobot(_ id: UUID) {
        guard let i = robots.firstIndex(where: { $0.id == id }) else { return }
        let name = robots[i].name
        guard Dialogs.confirm("Excluir \(name) da estação?",
                              "O robô sai da estação e da Vista 3D. Os arquivos do backup no disco não são apagados; para voltar, use Adicionar robô.",
                              ok: "Excluir") else { return }
        stop()
        // módulos abertos desse robô fecham sem perguntar se não tiverem alteração
        for t in openTabs where t.robotID == id { closeTab(t.id) }
        if openTabs.contains(where: { $0.robotID == id }) { return }     // o usuário cancelou ao fechar um módulo alterado
        robots.remove(at: i)
        simulationProgramSelection[id] = nil
        if activeRobotID == id { activeRobotID = robotsIn3D.first?.id }
        if case .robot(let rid) = selection, rid == id { selection = .station }
        scene.syncRobots(robots)
        scene.highlight(robot: activeRobotID)
        invalidateTrajectory()
        scene.showPaths([])
        analysis = nil
        info("\(name) excluído da estação")
    }

    /// Nova estação vazia (só o título); os robôs entram depois por Adicionar robô.
    func newStation() {
        if !robots.isEmpty || !parts.isEmpty {
            guard Dialogs.confirm("Criar uma nova estação?",
                                  "Os robôs e objetos da estação atual saem da tela. Salve antes em Arquivo ▸ Salvar estação se quiser guardá-la.",
                                  ok: "Nova estação") else { return }
        }
        guard let name = askName(title: "Nova estação", message: "Nome da estação", value: "Estação") else { return }
        stop()
        for t in openTabs { closeTab(t.id) }
        guard openTabs.isEmpty else { return }
        for p in parts { removePart(p.id) }
        robots = []
        activeRobotID = nil
        simulationProgramSelection = [:]
        selectedTypeKey = nil
        analysis = nil
        program = RobotProgram(name: "programa")
        scene.syncRobots(robots)
        scene.showPaths([])
        stationName = name
        stationNameAuto = false
        selection = .station
        info("Estação \"\(name)\" criada. Adicione os robôs pelo backup do flash (botão direito na estação ▸ Adicionar robô).")
    }

    func renameStation() {
        guard let name = askName(title: "Renomear estação", message: "Novo nome", value: stationName) else { return }
        stationName = name
        stationNameAuto = false
    }

    /// Adicionar robô: escolhe uma ou mais pastas de backup do flash (como "Adicionar controle" do DXQ).
    func addRobotsFromBackup() {
        Dialogs.chooseFolders("Escolha a pasta do backup (flash) de cada robô", multiple: true).forEach { openBackup($0) }
    }

    private func askName(title: String, message: String, value: String) -> String? {
        Dialogs.prompt(title, message, value: value)
    }
}
