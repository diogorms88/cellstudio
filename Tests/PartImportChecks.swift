import AppKit
import CellCore
import Foundation
import simd

@main
struct PartImportChecks {
    @MainActor static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ text: String) {
            print("\(value ? "✓" : "✗") \(text)")
            if !value { failures += 1 }
        }
        let app = AppState(restoreSession: false)
        app.addDemoPanel()
        let base = URL(fileURLWithPath: "..", isDirectory: true)
        let r11 = try RobotBackup.load(base.appendingPathComponent("R11"))
        let r22 = try RobotBackup.load(base.appendingPathComponent("R22"))
        let slot = RobotSlot(model: r11.robot, joints: .home(for: r11.robot), backup: r11)
        app.robots = [slot, RobotSlot(model: r22.robot, joints: .home(for: r22.robot), backup: r22)]
        app.activeRobotID = slot.id
        let program = r11.projects.flatMap(\.programs).first { $0.name.lowercased() == "under" }!
        app.openProgram = program
        if let r22Program = r22.projects.flatMap(\.programs).first(where: { $0.name.lowercased() == "main" }) {
            app.simulationProgramSelection[app.robots[1].id] = r22Program.url.path
        }
        app.simulateAllRobots = true
        app.loadOpenProgramForSimulation()
        check(app.simulationRuns.count == 2, "Simulação multi-kin prepara um programa por robô")
        check(app.simulationTimeline.count > 1 && app.samples.count > 1, "Simulação multi-kin cria relógio comum")
        app.scrub(to: app.simulationTimeline.count / 2)
        check(app.robots.allSatisfy { $0.joints.q.count == 6 }, "Reprodução conjunta atualiza os eixos de todos os robôs")
        app.simulateAllRobots = false
        let selected = app.partObjects.first { $0.id == app.defaultPartObjectID }!
        check(selected.name == "S202" && selected.robotID == slot.id, "SETOBJECT seleciona S202 do robô ativo")
        check(app.partObjects.contains { $0.robotID == app.robots[1].id } && Set(app.partObjects.map(\.id)).count == app.partObjects.count, "OBJECTs de R11 e R22 possuem identificação distinta")
        check(abs(selected.pose.z - 2373.535) < 0.001 && abs(selected.pose.c + 179.775) < 0.001, "Pose S202 em mm e convenção Dürr")
        let id = app.parts[0].id
        app.assignPartObject(id, objectID: selected.id)
        check(app.parts[0].objectName == selected.id && abs(app.parts[0].offset.z - selected.pose.z) < 0.001, "Troca do OBJECT atualiza posição e vínculo")
        app.assignPartObject(id, objectID: "station")
        check(app.parts[0].offset.z == 0, "Origem da estação")
        app.assignPartObject(id, objectID: "manual")
        check(app.parts[0].objectName == nil, "Posicionamento manual remove o vínculo")
        let ref = StationFile.PartRef(name: "Carroceria", path: "carroceria.hsf", offset: selected.pose, isPaintTarget: true, objectName: selected.id)
        let encoded = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(StationFile.PartRef.self, from: encoded)
        check(decoded.objectName == ref.objectName && decoded.offset.z == ref.offset.z, "Arquivo de estação preserva OBJECT e pose")
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        old.removeValue(forKey: "objectName")
        let legacy = try JSONDecoder().decode(StationFile.PartRef.self, from: JSONSerialization.data(withJSONObject: old))
        check(legacy.objectName == nil, "Compatibilidade com estações antigas")
        let files = FileManager.default.enumerator(at: base.appendingPathComponent("_analise/inst/3DObjects/Tools"), includingPropertiesForKeys: nil)!
        let fixture = (files.allObjects as! [URL]).first { $0.pathExtension.lowercased() == "hsf" }!
        let raw = try AppState.readHSF(fixture).parts
        let mesh = try AppState.loadMesh(fixture)
        check(!mesh.indices.isEmpty && mesh.indices.count == raw.reduce(0) { $0 + $1.indices.count }, "HSF mantém todos os triângulos")
        var vertex = 0, index = 0, correct = true
        for part in raw {
            for (i, p) in part.positions.enumerated() { if simd_distance(mesh.positions[vertex + i], p * 1000) > 0.001 { correct = false } }
            for (i, n) in part.indices.enumerated() { if mesh.indices[index + i] != n + UInt32(vertex) { correct = false } }
            vertex += part.positions.count; index += part.indices.count
        }
        check(correct, "Conversão metros → mm e índices entre múltiplas partes")
        check(mesh.normals.count == mesh.positions.count, "Normais calculadas para a malha importada")
        app.importPart(fixture)
        check(app.partImportRequest != nil && app.importObjectID == selected.id, "Importar HSF abre seleção com OBJECT padrão")
        app.partImportRequest = nil
        app.importPart(URL(fileURLWithPath: "carroceria.stl"), asBody: true)
        check(app.partImportRequest != nil, "Importar carroceria STL também permite escolher OBJECT")
        app.addDemoPanel()
        if let removable = app.parts.last?.id {
            app.selection = .part(removable)
            app.removePart(removable)
            check(!app.parts.contains { $0.id == removable } && app.selection == .station, "Remover objeto selecionado limpa a seleção")
        } else {
            check(false, "Remover objeto selecionado limpa a seleção")
        }
        print(failures == 0 ? "TODOS OS TESTES DE IMPORTAÇÃO PASSARAM" : "FALHAS: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
