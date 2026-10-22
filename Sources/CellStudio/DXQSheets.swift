import CellCore
import SwiftUI
import simd

struct DXQSheetView: View {
    @EnvironmentObject var app: AppState
    let sheet: DXQSheet
    var body: some View {
        switch sheet {
        case .frameTransfer(let k): FrameTransferSheet(kind: k)
        case .correctZero: CorrectZeroSheet()
        case .mirrorTransfer: MirrorTransferSheet()
        case .smoothOrientation: SmoothOrientationSheet()
        case .replaceText(let u, let r): ReplaceTextSheet(project: u, robot: r)
        case .compare(let u, let r): CompareSheet(url: u, robot: r)
        case .unusedPrograms(let r): UnusedProgramsSheet(robot: r)
        case .objectPlacement(let p): ObjectPlacementSheet(part: p)
        case .rotateObject(let p): RotateObjectSheet(part: p)
        case .rename, .newItem: EmptyView()
        }
    }
}

private func field(_ label: String, _ v: Binding<Double>, _ unit: String, width: CGFloat = 80) -> some View {
    HStack(spacing: 4) {
        Text(label).frame(width: 34, alignment: .trailing)
        TextField("", value: v, format: .number.precision(.fractionLength(0...3))).frame(width: width).textFieldStyle(.roundedBorder)
        Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
    }
    .font(.system(size: 12))
}

private struct PoseFields: View {
    @Binding var v: [Double]
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) { field("X", $v[0], "mm"); field("Y", $v[1], "mm"); field("Z", $v[2], "mm") }
            VStack(alignment: .leading, spacing: 4) { field("A", $v[3], "°"); field("B", $v[4], "°"); field("C", $v[5], "°") }
        }
    }
}

private struct SheetButtons: View {
    let ok: String
    var disabled = false
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Spacer()
            Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(ok) { action(); dismiss() }.keyboardShortcut(.defaultAction).disabled(disabled)
        }
    }
}

/// TransferFrameView do DXQ: Objeto-Objeto / Ferramenta-Ferramenta.
struct FrameTransferSheet: View {
    @EnvironmentObject var app: AppState
    let kind: String
    @State private var old = ""
    @State private var new = ""
    @State private var createNew = false
    @State private var newName = ""
    @State private var values = Array(repeating: 0.0, count: 6)

    var body: some View {
        let isTool = kind == "TOOL"
        let existing = app.visibleDeclarations(type: kind).map(\.decl.name)
        VStack(alignment: .leading, spacing: 10) {
            Text(isTool ? "Ferramenta-Ferramenta" : "Objeto-Objeto").font(.headline)
            Text(isTool ? "Troca o SETTOOL do módulo e recalcula os pontos World/Object para que o robô faça exatamente o mesmo movimento com a ferramenta nova (P' = P · Tvelha⁻¹ · Tnova)."
                        : "Troca o SETOBJECT do módulo e recalcula os pontos Object para que fiquem no mesmo lugar no mundo, escritos no objeto novo (P' = Onovo⁻¹ · Ovelho · P).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(isTool ? "Ferramenta atual" : "Objeto atual", selection: $old) {
                ForEach(app.framesUsed(kind: kind), id: \.self) { Text($0).tag($0) }
            }
            Toggle("Criar \(isTool ? "ferramenta" : "objeto") novo no programa", isOn: $createNew)
            if createNew {
                HStack { Text("Nome"); TextField("", text: $newName).frame(width: 180).textFieldStyle(.roundedBorder) }
                PoseFields(v: $values)
            } else {
                Picker(isTool ? "Ferramenta nova" : "Objeto novo", selection: $new) {
                    ForEach(existing, id: \.self) { Text($0).tag($0) }
                }
                if let p = app.framePose(type: kind, name: new) {
                    Text(String(format: "X %.1f  Y %.1f  Z %.1f  A %.2f  B %.2f  C %.2f", p.x, p.y, p.z, p.a, p.b, p.c))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            SheetButtons(ok: "Transformar", disabled: old.isEmpty || (createNew ? newName.isEmpty : (new.isEmpty || new == old))) {
                let pose = createNew ? Pose(x: values[0], y: values[1], z: values[2], a: values[3], b: values[4], c: values[5]) : nil
                app.transferFrame(kind: kind, old: old, new: createNew ? newName : new, newValues: pose)
            }
        }
        .padding(16).sheetFrame(width: 480)
        .onAppear {
            old = app.framesUsed(kind: kind).first ?? ""
            new = existing.first { $0 != old } ?? ""
            if let p = app.framePose(type: kind, name: old) { values = [p.x, p.y, p.z, p.a, p.b, p.c] }
            newName = old + "_NOVO"
        }
    }
}

/// CorrectZeroPositionView do DXQ.
struct CorrectZeroSheet: View {
    @EnvironmentObject var app: AppState
    @State private var v = Array(repeating: 0.0, count: 6)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Correção da posição zero").font(.headline)
            Text("Desloca todos os pontos Object do módulo pelo delta abaixo (no sistema do objeto): P' = D · P. Pontos World e Axis não mudam.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PoseFields(v: $v)
            SheetButtons(ok: "Corrigir", disabled: v.allSatisfy { $0 == 0 }) {
                app.correctZeroPosition(Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5]))
            }
        }
        .padding(16).sheetFrame(width: 420)
    }
}

/// ProgramMirrorTransferView do DXQ (espelhar no lado oposto e/ou transferir para outro robô).
struct MirrorTransferSheet: View {
    @EnvironmentObject var app: AppState
    @State private var plane: MirrorPlane = .xz
    @State private var offset = 0.0
    @State private var target: UUID?
    var body: some View {
        let others = app.robots.filter { $0.id != app.openProgramOwner?.id && $0.backup != nil }
        VStack(alignment: .leading, spacing: 10) {
            Text("Espelhar/Transferir \(app.openProgram?.name ?? "")").font(.headline)
            Text("Espelha todos os pontos do módulo num plano do objeto. XZ com 0 troca o lado da carroceria (Y → −Y). Para transferir, o módulo espelhado é gravado no projeto de mesmo nome do outro robô; o original não muda.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Plano", selection: $plane) { ForEach(MirrorPlane.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            field(plane == .xy ? "Z =" : (plane == .xz ? "Y =" : "X ="), $offset, "mm")
            Picker("Destino", selection: $target) {
                Text("Este módulo (espelhar aqui)").tag(UUID?.none)
                ForEach(others) { r in Text("Transferir para \(r.name)").tag(UUID?.some(r.id)) }
            }
            SheetButtons(ok: target == nil ? "Espelhar" : "Transferir") { app.mirrorTransfer(plane: plane, offset: offset, target: target) }
        }
        .padding(16).sheetFrame(width: 460)
    }
}

/// SmoothOrientationView do DXQ (modo linear).
struct SmoothOrientationSheet: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let names = app.selectedPointTargets.map(\.decl.name)
        VStack(alignment: .leading, spacing: 10) {
            Text("Suavizar orientação").font(.headline)
            Text("O primeiro e o último ponto selecionados mantêm a orientação; os do meio passam a girar de forma contínua entre eles, proporcional à distância percorrida. A posição dos pontos não muda. Pontos Axis não mudam.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(names.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).lineLimit(4)
            SheetButtons(ok: "Suavizar", disabled: names.count < 3) { app.smoothSelectedOrientation() }
        }
        .padding(16).sheetFrame(width: 440)
    }
}

struct ReplaceTextSheet: View {
    @EnvironmentObject var app: AppState
    let project: URL
    let robot: UUID
    @State private var find = ""
    @State private var repl = ""
    var body: some View {
        let progs = app.project(project, robot: robot)?.programs ?? []
        let hits = progs.filter { !find.isEmpty && $0.name.contains(find) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Substituir texto no nome").font(.headline)
            HStack { Text("Procurar").frame(width: 80, alignment: .trailing); TextField("", text: $find).textFieldStyle(.roundedBorder) }
            HStack { Text("Substituir por").frame(width: 80, alignment: .trailing); TextField("", text: $repl).textFieldStyle(.roundedBorder) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hits) { g in Text("\(g.name) → \(g.name.replacingOccurrences(of: find, with: repl))").font(.system(size: 11, design: .monospaced)) }
                }
            }
            .frame(height: 120)
            SheetButtons(ok: "Renomear \(hits.count)", disabled: hits.isEmpty) { app.replaceTextInNames(project: project, robot: robot, find: find, with: repl) }
        }
        .padding(16).sheetFrame(width: 440)
    }
}

/// Comparador (ProgramCompare): diferença linha a linha entre dois programas (código e dados).
struct CompareSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let robot: UUID
    @State private var other: URL?
    @State private var showData = false

    private var all: [(label: String, prog: EcoTalkProgram)] {
        app.robots.flatMap { r in (r.backup?.projects ?? []).flatMap { p in p.programs.map { ("\(r.name) : \(p.name) : \($0.name)", $0) } } }
    }

    var body: some View {
        let a = all.first { $0.prog.url == url }?.prog
        let b = all.first { $0.prog.url == other }?.prog
        VStack(alignment: .leading, spacing: 8) {
            Text("Comparador – \(a?.name ?? "")").font(.headline)
            HStack {
                Picker("Comparar com", selection: $other) {
                    ForEach(all.filter { $0.prog.url != url }, id: \.prog.url) { Text($0.label).tag(URL?.some($0.prog.url)) }
                }
                Picker("", selection: $showData) { Text("Código (.tip)").tag(false); Text("Dados (.tid)").tag(true) }.pickerStyle(.segmented).frame(width: 200)
            }
            if let a, let b {
                let d = AppState.diff(showData ? a.data : a.source, showData ? b.data : b.source)
                let changes = d.filter { $0.kind != " " }.count
                Text(changes == 0 ? "Iguais" : "\(changes) linha(s) diferentes (− só em \(a.name), + só no outro)").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(d.enumerated()), id: \.offset) { _, l in
                            Text("\(String(l.kind)) \(l.text)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(l.kind == "-" ? Color.red.opacity(0.15) : (l.kind == "+" ? Color.green.opacity(0.18) : .clear))
                        }
                    }
                }
                .border(DXQ.border)
            }
            HStack { Spacer(); Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16).sheetFrame(width: 760, height: 560)
        .onAppear {
            // padrão: mesmo programa em outro robô, senão o próximo do projeto
            let name = all.first { $0.prog.url == url }?.prog.name ?? ""
            other = all.first { $0.prog.url != url && $0.prog.name.caseInsensitiveCompare(name) == .orderedSame }?.prog.url
                ?? all.first { $0.prog.url != url }?.prog.url
        }
    }
}

/// CleanupControl do DXQ: programas de teach que nenhum Main/tipo usa.
struct UnusedProgramsSheet: View {
    @EnvironmentObject var app: AppState
    let robot: UUID
    @State private var list: [EcoTalkProgram] = []
    @State private var chosen = Set<URL>()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Excluir programas de teach não usados – \(app.slot(robot)?.name ?? "")").font(.headline)
            Text("Programas que nenhum Main e nenhum tipo do typelist.ini chamam (seguindo os CALLs). Os marcados vão para a Lixeira do Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if list.isEmpty {
                Text("Nenhum programa sem uso.").foregroundStyle(.secondary).frame(height: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(list) { g in
                            Toggle(isOn: Binding(get: { chosen.contains(g.url) }, set: { if $0 { chosen.insert(g.url) } else { chosen.remove(g.url) } })) {
                                Text("\(g.url.deletingLastPathComponent().deletingPathExtension().lastPathComponent) / \(g.name)").font(.system(size: 12))
                            }
                        }
                    }
                }
                .frame(height: 260)
                HStack {
                    Button("Marcar todos") { chosen = Set(list.map(\.url)) }
                    Button("Desmarcar todos") { chosen = [] }
                }
            }
            SheetButtons(ok: "Excluir \(chosen.count)", disabled: chosen.isEmpty) { app.trashPrograms(Array(chosen), robot: robot) }
        }
        .padding(16).sheetFrame(width: 520)
        .onAppear { list = app.unusedPrograms(robot: robot) }
    }
}

/// "Editar posição do objeto" / "Ajustar" (PlacementView do DXQ).
struct ObjectPlacementSheet: View {
    @EnvironmentObject var app: AppState
    let part: UUID
    @State private var v = Array(repeating: 0.0, count: 6)
    var body: some View {
        let p = app.parts.first { $0.id == part }
        VStack(alignment: .leading, spacing: 10) {
            Text("Posição de \(p?.name ?? "")").font(.headline)
            Text("Posição e orientação do objeto na estação (X, Y, Z em mm; A, B, C em graus).").font(.caption).foregroundStyle(.secondary)
            PoseFields(v: $v)
            SheetButtons(ok: "Aplicar") { app.updatePartOffset(part, Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5])) }
        }
        .padding(16).sheetFrame(width: 420)
        .onAppear { if let o = p?.offset { v = [o.x, o.y, o.z, o.a, o.b, o.c] } }
    }
}

/// "Girar objeto em torno de vetor".
struct RotateObjectSheet: View {
    @EnvironmentObject var app: AppState
    let part: UUID
    @State private var s = [0.0, 0, 0]
    @State private var e = [0.0, 0, 1000]
    @State private var angle = 90.0
    var body: some View {
        let p = app.parts.first { $0.id == part }
        VStack(alignment: .leading, spacing: 10) {
            Text("Girar \(p?.name ?? "") em torno de vetor").font(.headline)
            Text("Eixo do Início ao Fim (coordenadas da estação, mm); ângulo pela regra da mão direita.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) { Text("Início").font(.caption.bold()); field("X", $s[0], "mm"); field("Y", $s[1], "mm"); field("Z", $s[2], "mm") }
                VStack(alignment: .leading, spacing: 4) { Text("Fim").font(.caption.bold()); field("X", $e[0], "mm"); field("Y", $e[1], "mm"); field("Z", $e[2], "mm") }
            }
            field("Âng.", $angle, "°")
            SheetButtons(ok: "Girar", disabled: angle == 0 || s == e) {
                guard let o = p?.offset else { return }
                let a = Vec3(s[0], s[1], s[2]), b = Vec3(e[0], e[1], e[2])
                let r = Mat4(simd_quatd(angle: rad(angle), axis: simd_normalize(b - a)))
                app.updatePartOffset(part, Pose(matrix: Mat4.translation(a) * r * Mat4.translation(-a) * o.matrix))
            }
        }
        .padding(16).sheetFrame(width: 420)
        .onAppear { if let o = p?.offset { s = [o.x, o.y, o.z]; e = [o.x, o.y, o.z + 1000] } }
    }
}
