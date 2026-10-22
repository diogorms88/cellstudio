import CellCore
import SwiftUI
import simd

// Guias do ribbon no layout do DXQ3D.onsite (ProgramEditor / Hoops3DGraphic: StartTab…, Models3DTab…),
// com os ícones originais. Grupos marcados "CellStudio" são recursos próprios mantidos no fim de cada guia.

/// "Editor de programa" (Program editor).
struct DXQProgramEditorTab: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let sel = !app.editorSelection.isEmpty
        let open = app.openProgram != nil
        let lines = app.selectedLines
        Group {
            RibbonGroup(title: "Área de transferência") {
                RibbonLargeButton(title: "Colar", icon: "dxq:general_paste", enabled: open && !app.editClipboard.lines.isEmpty) { app.pasteCommands() }
                RibbonColumn {
                    RibbonSmallButton(title: "Copiar", icon: "dxq:general_copy", enabled: sel) { app.copyCommands() }
                    RibbonSmallButton(title: "Recortar", icon: "dxq:general_cut", enabled: sel) { app.cutCommands() }
                }
            }
            RibbonGroup(title: "Vista") {
                RibbonLargeButton(title: "Quadriculado", icon: "dxq:programeditor_table", enabled: open) { app.editorTab = 1 }
                RibbonLargeButton(title: "Programa", icon: "dxq:programeditor_code", enabled: open) { app.editorTab = 0 }
                RibbonLargeButton(title: "Ler novamente", icon: "dxq:programeditor_refresh", enabled: open) { reload() }
                RibbonLargeButton(title: "Editor de pincéis", icon: "dxq:brusheditor") { app.showBrushSheet = true }
                RibbonColumn {
                    RibbonSmallButton(title: "Abrir subprograma", icon: "dxq:programeditor_loadmodule",
                                      enabled: lines.count == 1 && lines.first?.name == "CALL") { app.openSelectedSubprogram() }
                    RibbonSmallButton(title: "Abrir todos os subprogramas", icon: "dxq:programeditor_loadallmodule", enabled: open) { app.openAllSubmodules() }
                    RibbonSmallButton(title: "Abrir programa de válvulas", icon: "dxq:ecopaintjet_valvepattern", enabled: false) {}
                        .help("EcoPaintJet: ainda não disponível no CellStudio")
                }
                RibbonColumn {
                    RibbonSmallButton(title: "Expandir todas as seções", icon: "dxq:general_expandall", enabled: false) {}
                        .help("O editor do CellStudio não agrupa seções")
                    RibbonSmallButton(title: "Recolher todas as seções", icon: "dxq:general_collapseall", enabled: false) {}
                        .help("O editor do CellStudio não agrupa seções")
                }
            }
            DXQModifyProgramGroup(large: true)
            RibbonGroup(title: "Comentários") {
                RibbonLargeButton(title: "Comentar", icon: "dxq:programeditorcommon_commentout", enabled: app.canCommentOut) { app.commentOutCommands() }
                RibbonColumn {
                    RibbonSmallButton(title: "Retirar comentário", icon: "dxq:programeditorcommon_commentin",
                                      enabled: lines.contains { $0.kind == .comment }) { app.commentInCommands() }
                    RibbonSmallButton(title: "Desativar comando", icon: "dxq:programeditorcommon_disable", enabled: app.canDisable) { app.setCommandsDisabled(true) }
                    RibbonSmallButton(title: "Ativar comando", icon: "dxq:programeditorcommon_enable", enabled: app.canEnable) { app.setCommandsDisabled(false) }
                }
            }
            RibbonGroup(title: "Programa (CellStudio)") {
                RibbonColumn {
                    RibbonSmallButton(title: "Simular programa", icon: "dxq:programeditorcommon_simulatemodule", enabled: open) { app.loadOpenProgramForSimulation(); app.play() }
                    RibbonSmallButton(title: "Carregar na simulação", icon: "dxq:programeditor_loadmodule", enabled: open) { app.loadOpenProgramForSimulation() }
                }
            }
        }
    }

    private func reload() {
        guard let p = app.openProgram else { return }
        if app.openProgramDirty, !app.confirm("Ler \(p.name) novamente?", "As alterações não salvas serão descartadas.", ok: "Ler novamente") { return }
        app.openProgram = EcoTalkProgram.load(p.url)
        app.openProgramDirty = false
        app.previewModule()
    }
}

/// Grupo "Modificar programa" (está no Editor de programa e na Vista 3D).
struct DXQModifyProgramGroup: View {
    @EnvironmentObject var app: AppState
    let large: Bool
    var body: some View {
        let sel = !app.editorSelection.isEmpty
        RibbonGroup(title: "Modificar programa") {
            if large {
                RibbonLargeButton(title: "Excluir comando selecionado", icon: "dxq:programeditorcommon_removecommand", enabled: sel) { app.deleteCommands() }
                RibbonLargeButton(title: "Modificar", icon: "dxq:programeditor_modify", enabled: app.canModify) { app.modifyPoints() }
                RibbonMenuLarge(title: "Inserir comando", icon: "dxq:programeditorcommon_insertcommand", enabled: app.openProgram != nil) { InsertCommandMenu() }
            } else {
                RibbonColumn {
                    RibbonSmallButton(title: "Excluir comando selecionado", icon: "dxq:programeditorcommon_removecommand", enabled: sel) { app.deleteCommands() }
                    RibbonSmallButton(title: "Modificar", icon: "dxq:programeditor_modify", enabled: app.canModify) { app.modifyPoints() }
                    RibbonMenuSmall(title: "Inserir comando", icon: "dxq:programeditorcommon_insertcommand", enabled: app.openProgram != nil) { InsertCommandMenu() }
                }
            }
        }
    }
}

/// "Ferramentas do editor" (Program editor tools).
struct DXQProgramToolsTab: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let open = app.openProgram != nil
        Group {
            RibbonGroup(title: "Ferramentas") {
                RibbonLargeButton(title: "Inverter sequência do programa", icon: "dxq:programeditor_reversesequence",
                                  enabled: app.editorSelection.count >= 2) { app.reverseCommands() }
                RibbonLargeButton(title: "Renomear e renumerar todos os pontos", icon: "dxq:programeditor_reorder", enabled: open) { app.renumberAllPoints() }
                RibbonColumn {
                    RibbonSmallButton(title: "Verificar", icon: "dxq:general_validate", enabled: open) { app.checkOpenProgram() }
                    RibbonSmallButton(title: "Verificar todos", icon: "dxq:general_validate", enabled: open) { app.checkAllProgramsOfProject() }
                    RibbonSmallButton(title: "Arrumar", icon: "dxq:tool_cleanup", enabled: open) { app.cleanupDeclarations() }
                }
            }
            RibbonGroup(title: "Transformação") {
                RibbonLargeButton(title: "Espelhar/Transferir", icon: "dxq:tool_mirrortransfer", enabled: open) { app.dxqSheet = .mirrorTransfer }
                RibbonLargeButton(title: "Ajustar ao robô", icon: "dxq:tool_adjusttorobot", enabled: false) {}
                    .help("Precisa do simulador nativo do DXQ (rcsdb01.dll) – não disponível no Mac")
                RibbonColumn {
                    RibbonSmallButton(title: "Ferramenta-Ferramenta", icon: "dxq:tool_transformtooltool", enabled: open) { app.dxqSheet = .frameTransfer(kind: "TOOL") }
                    RibbonSmallButton(title: "Objeto-Objeto", icon: "dxq:tool_transformobjectobject", enabled: open) { app.dxqSheet = .frameTransfer(kind: "OBJECT") }
                    RibbonSmallButton(title: "Correção da posição zero", icon: "dxq:tool_changeorigin", enabled: open) { app.dxqSheet = .correctZero }
                }
            }
            RibbonGroup(title: "KUKA KRL (CellStudio)") {
                RibbonColumn {
                    RibbonSmallButton(title: "Importar .src", icon: "dxq:general_import") { openFile(["src"]) { app.importProgram($0) } }
                    RibbonSmallButton(title: "Exportar .src", icon: "dxq:general_export") { saveFile("\(app.program.name).src") { app.exportProgram(to: $0) } }
                }
            }
        }
    }
}

/// "Vista 3D" (3D view): vista, navegar, seleção, programa ativo (transformar pontos), modificar, orientação, imprimir.
struct DXQView3DTab: View {
    @EnvironmentObject var app: AppState
    @Binding var showCatalog: Bool
    @State private var jogIndex = 0
    @State private var compactJogStep = 10.0

    var body: some View {
        let targets = app.selectedPointTargets
        let has = !targets.isEmpty
        Group {
            RibbonGroup(title: "Vista") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 1) {
                        RibbonIconButton(icon: "dxq:3dgraphic_viewbackward", help: "Vista anterior") { app.scene.stepCameraHistory(-1) }
                        RibbonIconButton(icon: "dxq:3dgraphic_viewforward", help: "Próxima vista") { app.scene.stepCameraHistory(1) }
                        RibbonIconMenu(icon: "dxq:3dgraphic_setcameraview", help: "Vistas fixas") { fixedViews }
                        RibbonIconMenu(icon: "dxq:3dgraphic_viewhome", help: "Home") {
                            Button("Ir para a vista home") { app.scene.goHome() }
                            Button("Salvar vista atual como home") { app.scene.saveHomeView() }
                            Button("Enquadrar tudo") { app.scene.frameAll() }
                        }
                    }
                    HStack(spacing: 1) {
                        RibbonIconMenu(icon: "dxq:3dgraphic_rendermodegouraudshaded", help: "Modo de renderização (tudo)") {
                            ForEach(RenderMode.allCases) { m in Button(m.rawValue) { app.setRenderMode("all", m) } }
                        }
                        RibbonIconMenu(icon: app.scene.isOrthographic ? "dxq:3dgraphic_viewprojectionmodeorthographic" : "dxq:3dgraphic_viewprojectionmodeperspective",
                                       help: "Projeção") {
                            Button("Perspectiva") { app.scene.setOrthographic(false); app.objectWillChange.send() }
                            Button("Ortográfica") { app.scene.setOrthographic(true); app.objectWillChange.send() }
                        }
                        RibbonIconButton(icon: "dxq:3dgraphic_showhidefloor", help: "Grade", checked: app.showGrid) { app.showGrid.toggle() }
                    }
                }
            }
            RibbonGroup(title: "Navegar") {
                RibbonColumn {
                    RibbonSmallButton(title: "Orbitar", icon: "dxq:3dgraphic_navigateorbit", checked: app.navigateMode == .orbit) { app.navigateMode = .orbit }
                    RibbonSmallButton(title: "Deslocar", icon: "dxq:3dgraphic_navigatepan", checked: app.navigateMode == .pan) { app.navigateMode = .pan }
                    RibbonSmallButton(title: "Zoom", icon: "dxq:3dgraphic_navigatezoom", checked: app.navigateMode == .zoom) { app.navigateMode = .zoom }
                }
                VStack(spacing: 1) {
                    RibbonIconButton(icon: "dxq:3dgraphic_navigatezoomtofit", help: "Enquadrar tudo") { app.scene.frameAll() }
                    RibbonIconButton(icon: "dxq:3dgraphic_viewfixediso", help: "Isométrica") { app.scene.setView(.iso) }
                    RibbonIconButton(icon: "dxq:3dgraphic_viewfixedtop", help: "Topo") { app.scene.setView(.top) }
                }
            }
            RibbonGroup(title: "Seleção") {
                RibbonColumn {
                    RibbonSmallButton(title: "Selecionar", icon: "dxq:3dgraphic_select", checked: !app.measuring) { app.measuring = false }
                    RibbonSmallButton(title: "Medir distância", icon: "dxq:3dgraphic_measuredistance", checked: app.measuring) { app.measuring.toggle() }
                }
            }
            activeProgramGroup(has: has)
            // A impressão ficava no extremo direito da faixa e era cortada em janelas menores.
            // Mantê-la junto ao programa ativo deixa o comando inteiro sempre visível.
            RibbonGroup(title: "Imprimir") {
                RibbonLargeButton(title: "Imprimir", icon: "dxq:general_printer") { app.printView() }
            }
            DXQModifyProgramGroup(large: false)
            RibbonGroup(title: "Ferramentas") {
                RibbonColumn {
                    RibbonSmallButton(title: "Comentar", icon: "dxq:programeditorcommon_commentout", enabled: app.canCommentOut) { app.commentOutCommands() }
                    RibbonSmallButton(title: "Desativar comando", icon: "dxq:programeditorcommon_disable", enabled: app.canDisable) { app.setCommandsDisabled(true) }
                    RibbonSmallButton(title: "Editor de pincéis", icon: "dxq:brusheditor") { app.showBrushSheet = true }
                }
            }
            RibbonGroup(title: "Orientação") {
                RibbonColumn {
                    RibbonMenuSmall(title: "Copiar", icon: "dxq:3dgraphic_copyorientation", enabled: has) {
                        Button("Copiar orientação") { app.copyPointOrientation() }
                        Button("Copiar diferença de orientação") { app.copyOrientationDelta() }
                        Button("Copiar E1 (trilho)") { app.copyPointRail() }
                    }
                    RibbonMenuSmall(title: "Colar", icon: "dxq:3dgraphic_pasteorientation", enabled: has) {
                        Button("Colar orientação") { app.pastePointOrientation() }.disabled(app.orientationClipboard == nil)
                        Button("Colar diferença de orientação") { app.pasteOrientationDelta() }.disabled(app.orientationDeltaClipboard == nil)
                        Button("Colar E1 (trilho)") { app.pastePointRail() }.disabled(app.railClipboard == nil)
                    }
                    RibbonSmallButton(title: "Suavizar orientação…", icon: "dxq:programeditorcommon_smoothorientation", enabled: targets.count > 2) {
                        app.dxqSheet = .smoothOrientation
                    }
                }
            }
            RibbonGroup(title: "Copiar/colar") {
                RibbonColumn {
                    RibbonSmallButton(title: "Orientação", icon: "dxq:3dgraphic_copyorientation", checked: !app.copyPasteRail) { app.copyPasteRail = false }
                    RibbonSmallButton(title: "Trilho", icon: "dxq:3dgraphic_copyrail", checked: app.copyPasteRail) { app.copyPasteRail = true }
                    HStack(spacing: 1) {
                        RibbonIconButton(icon: "dxq:general_copy", help: "Copiar \(app.copyPasteRail ? "E1" : "orientação") do último ponto", enabled: has) {
                            app.copyPasteRail ? app.copyPointRail() : app.copyPointOrientation()
                        }
                        RibbonIconButton(icon: "dxq:general_paste", help: "Colar \(app.copyPasteRail ? "E1" : "orientação") nos pontos selecionados",
                                         enabled: has && (app.copyPasteRail ? app.railClipboard != nil : app.orientationClipboard != nil)) {
                            app.copyPasteRail ? app.pastePointRail() : app.pastePointOrientation()
                        }
                    }
                }
            }
            RibbonGroup(title: "CellStudio") {
                RibbonMenuSmall(title: "Ferramentas", icon: "gearshape.2", enabled: !app.robots.isEmpty || has) {
                    Menu("Pontos") {
                        Button("Valores…") { app.pointSheet = .values }
                        Menu("Converter para") {
                            ForEach(["Object", "World", "Axis"], id: \.self) { mode in
                                Button(mode) { app.convertSelectedPoints(to: mode) }
                            }
                        }
                        Button("Mover robô até o ponto") { app.moveRobotToSelectedPoint() }
                        Button("Girar em torno de vetor…") { app.pointSheet = .rotate }
                        Button("Espelhar em plano…") { app.pointSheet = .mirror }
                        Button("Distância entre pontos") { app.pointSheet = .distance }
                    }
                    Menu("Robô e vista") {
                        Section("Robô ativo") {
                            ForEach(app.robots) { robot in
                                Button {
                                    app.activate(robot.id)
                                } label: {
                                    if app.activeRobotID == robot.id { Label(robot.name, systemImage: "checkmark") }
                                    else { Text(robot.name) }
                                }
                            }
                        }
                        Section("Exibição") {
                            Toggle("Trajetória", isOn: $app.showPath)
                            Toggle("Sistemas de coordenadas", isOn: $app.showFrames)
                            ForEach(app.robots) { robot in
                                Toggle(robot.name, isOn: Binding(get: { !robot.hidden3D }, set: { app.setRobotIn3D(robot.id, $0) }))
                            }
                        }
                        Button("Tipo do catálogo…") { showCatalog = true }
                        Button("Modelos 3D…") {
                            if let url = Dialogs.chooseFolders("Selecione a pasta 3DObjects do DXQ3D.onsite (contém Robots/, Tools/…)").first { app.modelsRoot = url }
                        }
                    }
                    Menu("Mover TCP") {
                        Section("Passo") {
                            ForEach([1.0, 10.0, 50.0, 100.0], id: \.self) { step in
                                Button("\(Int(step)) mm\(compactJogStep == step ? " ✓" : "")") { compactJogStep = step }
                            }
                        }
                        Section("Deslocar") {
                            ForEach(Array(["X", "Y", "Z", "A", "B", "C"].enumerated()), id: \.offset) { axis, name in
                                Button("+\(name)") { app.jog(axis: axis, by: axis < 3 ? compactJogStep : compactJogStep / 10) }
                                Button("−\(name)") { app.jog(axis: axis, by: axis < 3 ? -compactJogStep : -compactJogStep / 10) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var fixedViews: some View {
        Button("Isométrica") { app.scene.setView(.iso) }
        Button("Topo") { app.scene.setView(.top) }
        Button("Baixo") { app.scene.setView(.bottom) }
        Button("Frente") { app.scene.setView(.front) }
        Button("Trás") { app.scene.setView(.back) }
        Button("Esquerda") { app.scene.setView(.left) }
        Button("Direita") { app.scene.setView(.side) }
    }

    /// "Programa ativo": módulo, sistema de coordenadas, passo, eixo e ◀ ▶ (como o DXQ), Repor e camadas do caminho.
    @ViewBuilder private func activeProgramGroup(has: Bool) -> some View {
        let joint = app.pointSystem == .joint
        let axes: [(String, String)] = joint
            ? [("A1", "programeditorcommon_transformjoint1"), ("A2", "programeditorcommon_transformjoint2"), ("A3", "programeditorcommon_transformjoint3"),
               ("A4", "programeditorcommon_transformjoint4"), ("A5", "programeditorcommon_transformjoint5"), ("A6", "programeditorcommon_transformjoint6"),
               ("E1", "programeditorcommon_transformauxjoint1")]
            : [("X", "3dgraphic_transformtranslatex"), ("Y", "3dgraphic_transformtranslatey"), ("Z", "3dgraphic_transformtranslatez"),
               ("A", "3dgraphic_transformrotatex"), ("B", "3dgraphic_transformrotatey"), ("C", "3dgraphic_transformrotatez"),
               ("E1", "programeditorcommon_transformauxjoint1")]
        RibbonGroup(title: "Programa ativo") {
            VStack(alignment: .leading, spacing: 2) {
                Picker("", selection: Binding(get: { app.openProgram?.url }, set: { if let u = $0 { app.selectTab(u) } })) {
                    if app.openTabs.isEmpty { Text("Nenhum módulo aberto").tag(URL?.none) }
                    ForEach(app.openTabs) { t in
                        Text("\(app.robots.first { $0.id == t.robotID }?.name ?? "") : \(t.id.deletingLastPathComponent().deletingPathExtension().lastPathComponent) : \(t.program.name)")
                            .tag(URL?.some(t.id))
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 200)
                HStack(spacing: 1) {
                    ForEach([(PointCoordSystem.world, "3dgraphic_transformcoordsysworld"), (.object, "3dgraphic_transformcoordsysobject"),
                             (.tool, "3dgraphic_transformcoordsystool"), (.joint, "3dgraphic_transformcoordsysjoint")], id: \.0) { s, icon in
                        RibbonIconButton(icon: "dxq:" + icon, help: "Sistema: \(s.rawValue)", checked: app.pointSystem == s) { app.pointSystem = s }
                    }
                    RibbonIconButton(icon: "chevron.left", help: "Deslocar −", enabled: has) { app.jogSelectedPoints(index: jogIndex, sign: -1) }
                    RibbonIconButton(icon: "chevron.right", help: "Deslocar +", enabled: has) { app.jogSelectedPoints(index: jogIndex, sign: 1) }
                    Picker("", selection: $app.pointStepMm) {
                        ForEach([0.1, 0.5, 1, 5, 10, 50, 100], id: \.self) { Text("\(EcoProgramEditor.formatNumber($0)) mm").tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 78)
                    Picker("", selection: $app.pointStepDeg) {
                        ForEach([0.1, 0.5, 1, 5, 10, 45, 90], id: \.self) { Text("\(EcoProgramEditor.formatNumber($0))°").tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 62)
                    RibbonIconButton(icon: "dxq:3dgraphic_showhidepoints", help: "Mostrar/ocultar pontos", checked: app.scene.pathLayers.points) {
                        app.scene.pathLayers.points.toggle(); app.objectWillChange.send()
                    }
                    RibbonIconButton(icon: "dxq:3dgraphic_showhidetriggers", help: "Mostrar/ocultar gatilhos (pistola ligada)", checked: app.scene.pathLayers.triggers) {
                        app.scene.pathLayers.triggers.toggle(); app.objectWillChange.send()
                    }
                    RibbonIconButton(icon: "dxq:3dgraphic_showhidedirectioncones", help: "Mostrar/ocultar cones de direção", checked: app.scene.pathLayers.cones) {
                        app.scene.pathLayers.cones.toggle(); app.objectWillChange.send()
                    }
                }
                HStack(spacing: 1) {
                    ForEach(Array(axes.enumerated()), id: \.offset) { i, a in
                        RibbonIconButton(icon: "dxq:" + a.1, help: a.0, enabled: has, checked: jogIndex == i) { jogIndex = i }
                    }
                    Button("Repor") { app.resetPointCoordinates() }
                        .controlSize(.small).disabled(!app.canResetPoints).padding(.leading, 6)
                        .help("Volta os pontos ao que eram antes das transformações desta seleção")
                    Text(has ? "\(targets(has)) ponto(s)" : "selecione pontos (clique no 3D ou no editor)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
        }
    }

    private func targets(_ has: Bool) -> Int { app.selectedPointTargets.count }
}

/// "Objetos 3D" (3D objects): peças de trabalho (carroceria), célula, modos de renderização do robô e ferramentas.
struct DXQObjects3DTab: View {
    @EnvironmentObject var app: AppState
    private var workpieces: [Part] { app.parts.filter(\.isPaintTarget) }
    private var cellParts: [Part] { app.parts.filter { !$0.isPaintTarget } }
    private var selectedPart: UUID? { if case .part(let id) = app.selection { return id }; return nil }

    var body: some View {
        Group {
            RibbonGroup(title: "Peça de trabalho") {
                RibbonLargeButton(title: "Carregar", icon: "dxq:3dgraphic_load") { openFile(["hsf", "stl"]) { app.importPart($0, asBody: true) } }
                RibbonMenuLarge(title: "Ajustar", icon: "dxq:3dgraphic_placement", enabled: !workpieces.isEmpty) { partMenu(workpieces) }
                RibbonMenuLarge(title: "Modo de renderização", icon: "dxq:3dgraphic_rendermodegouraudshaded", enabled: !workpieces.isEmpty) { modes("workpiece") }
                RibbonLargeButton(title: "Salvar todas as peças num único arquivo", icon: "dxq:3dgraphic_carbodysaveas", enabled: !workpieces.isEmpty) { savePartsSTL(workpieces, "pecas") }
            }
            RibbonGroup(title: "Célula") {
                RibbonLargeButton(title: "Carregar", icon: "dxq:3dgraphic_cellload") { openFile(["hsf", "stl", "obj", "usdz", "usd", "ply"]) { app.importPart($0) } }
                RibbonMenuLarge(title: "Ajustar", icon: "dxq:3dgraphic_placement", enabled: !cellParts.isEmpty) { partMenu(cellParts) }
                RibbonMenuLarge(title: "Modo de renderização", icon: "dxq:3dgraphic_rendermodegouraudshaded", enabled: !cellParts.isEmpty) { modes("cell") }
                RibbonColumn {
                    RibbonSmallButton(title: "Mostrar/ocultar chão", icon: "dxq:3dgraphic_showhidefloor", checked: app.showFloor) { app.showFloor.toggle() }
                }
                RibbonLargeButton(title: "Salvar todos os elementos da célula num único arquivo", icon: "dxq:3dgraphic_cellsaveas", enabled: !cellParts.isEmpty) { savePartsSTL(cellParts, "celula") }
            }
            RibbonGroup(title: "Robô") {
                RibbonMenuLarge(title: "Modo de renderização robô", icon: "dxq:3dgraphic_robotrendermodegouraudshaded", enabled: !app.robots.isEmpty) { modes("robot") }
                RibbonMenuLarge(title: "Modo de renderização trilho", icon: "dxq:3dgraphic_railrendermodegouraudshaded", enabled: !app.robots.isEmpty) { modes("rail") }
                RibbonMenuLarge(title: "Modo de renderização ferramenta", icon: "dxq:3dgraphic_toolrendermodegouraudshaded", enabled: !app.robots.isEmpty) { modes("tool") }
            }
            RibbonGroup(title: "Ferramenta") {
                RibbonColumn {
                    RibbonSmallButton(title: "Salvar cena 3D", icon: "dxq:cellsaveas") { saveScene() }
                    RibbonSmallButton(title: "Editar posição do objeto", icon: "dxq:3dgraphic_placement", enabled: currentPart != nil) {
                        if let id = currentPart { app.dxqSheet = .objectPlacement(part: id) }
                    }
                    RibbonSmallButton(title: "Editar modelo do objeto", icon: "dxq:3dgraphic_editmodel", enabled: false) {}
                        .help("Ainda não disponível no CellStudio")
                }
                RibbonColumn {
                    RibbonSmallButton(title: "Editar estrutura do objeto", icon: "dxq:3dgraphic_editmodel", enabled: false) {}
                        .help("Ainda não disponível no CellStudio")
                    RibbonSmallButton(title: "Girar objeto em torno de vetor", icon: "dxq:3dgraphic_rotatearoundvector", enabled: currentPart != nil) {
                        if let id = currentPart { app.dxqSheet = .rotateObject(part: id) }
                    }
                }
            }
            RibbonGroup(title: "Objeto (CellStudio)") {
                RibbonLargeButton(title: "Painel demo", icon: "rectangle.3.group") { app.addDemoPanel() }
                RibbonColumn {
                    RibbonSmallButton(title: "Usar como alvo", icon: "scope", enabled: selectedPart != nil) { if let id = selectedPart { app.setPaintTarget(id) } }
                    RibbonSmallButton(title: "Remover", icon: "trash", tint: .red, enabled: selectedPart != nil) { if let id = selectedPart { app.removePart(id) } }
                }
            }
        }
    }

    /// objeto selecionado no explorador, senão a primeira peça
    private var currentPart: UUID? { selectedPart ?? app.parts.first?.id }

    @ViewBuilder private func partMenu(_ list: [Part]) -> some View {
        ForEach(list) { p in Button("Posição de \(p.name)…") { app.dxqSheet = .objectPlacement(part: p.id) } }
        Divider()
        ForEach(list) { p in Button("Girar \(p.name) em torno de vetor…") { app.dxqSheet = .rotateObject(part: p.id) } }
    }

    @ViewBuilder private func modes(_ key: String) -> some View {
        ForEach(RenderMode.allCases) { m in
            Button((app.renderModes[key] ?? .shaded) == m ? "✓ \(m.rawValue)" : m.rawValue) { app.setRenderMode(key, m) }
        }
    }

    private func savePartsSTL(_ list: [Part], _ name: String) {
        saveFile("\(name).stl") { url in
            let meshes = list.map { p -> (positions: [SIMD3<Float>], indices: [UInt32]) in
                let m = simd_float4x4(p.offset.matrix)
                return (p.mesh.positions.map { v in let w = m * SIMD4<Float>(v, 1); return SIMD3(w.x, w.y, w.z) }, p.mesh.indices)
            }
            do { try STL.writeBinary(meshes, to: url); app.info("\(list.count) objeto(s) salvos em \(url.lastPathComponent)") }
            catch { app.error("Salvar STL: \(error.localizedDescription)") }
        }
    }

    private func saveScene() {
        saveFile("cena.usdz") { url in
            let ok = app.scene.scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
            ok ? app.info("Cena 3D salva em \(url.lastPathComponent)") : app.error("Não foi possível salvar a cena 3D")
        }
    }
}
