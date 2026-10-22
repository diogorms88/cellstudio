import CellCore
import SwiftUI
import simd

/// Itens do menu do botão direito do editor.
struct PointTransformMenu: View {
    @EnvironmentObject var app: AppState
    /// seleciona as linhas clicadas antes de agir (como os outros itens do menu)
    var run: (@escaping () -> Void) -> () -> Void = { $0 }
    var body: some View {
        Button("Valores (deslocar/girar)…", action: run { app.pointSheet = .values })
        Button("Restaurar coordenadas", action: run(app.resetPointCoordinates)).disabled(!app.canResetPoints)
        Menu("Converter tipo") { ForEach(["Object", "World", "Axis"], id: \.self) { m in Button(m, action: run { app.convertSelectedPoints(to: m) }) } }
        Divider()
        Button("Copiar orientação", action: run(app.copyPointOrientation))
        Button("Colar orientação", action: run(app.pastePointOrientation)).disabled(app.orientationClipboard == nil)
        Button("Copiar E1", action: run(app.copyPointRail))
        Button("Colar E1", action: run(app.pastePointRail)).disabled(app.railClipboard == nil)
        Divider()
        Button("Girar em torno de vetor…", action: run { app.pointSheet = .rotate })
        Button("Espelhar em plano…", action: run { app.pointSheet = .mirror })
        Button("Distância entre pontos", action: run { app.pointSheet = .distance })
    }
}

struct PointToolSheetView: View {
    @EnvironmentObject var app: AppState
    let kind: PointToolSheet
    var body: some View {
        switch kind {
        case .values: PointValuesSheet()
        case .rotate: RotateAroundVectorSheet()
        case .mirror: MirrorPlaneSheet()
        case .distance: PointDistanceSheet()
        }
    }
}

private func numberField(_ label: String, _ value: Binding<Double>, unit: String) -> some View {
    HStack(spacing: 4) {
        Text(label).frame(width: 26, alignment: .trailing)
        TextField("", value: value, format: .number.precision(.fractionLength(0...3))).frame(width: 80).textFieldStyle(.roundedBorder)
        Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
    }
    .font(.system(size: 12))
}

/// "Modify selected commands": deslocamento informado no sistema escolhido.
struct PointValuesSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sys: PointCoordSystem = .world
    @State private var v = Array(repeating: 0.0, count: 7)

    var body: some View {
        let names = sys == .joint ? ["A1", "A2", "A3", "A4", "A5", "A6"] : ["X", "Y", "Z", "A", "B", "C"]
        VStack(alignment: .leading, spacing: 10) {
            Text("Modificar pontos selecionados").font(.headline)
            Text("Os valores são somados a cada ponto selecionado no sistema escolhido. Em Mundo e Objeto a orientação gira em torno dos eixos do sistema, no próprio ponto; em Ferramenta, em torno dos eixos da pistola. O tipo do ponto (Axis/World/Object) é mantido.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Sistema", selection: $sys) { ForEach(PointCoordSystem.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in numberField(names[i], $v[i], unit: sys == .joint ? "°" : "mm") }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(3..<6, id: \.self) { i in numberField(names[i], $v[i], unit: "°") }
                }
            }
            numberField("E1", $v[6], unit: "mm")
            HStack {
                Text(app.selectedPointTargets.map(\.decl.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    var off = PointOffset(rail: v[6])
                    if sys == .joint { off.joints = Array(v[0..<6]) } else { off.pose = Pose(x: v[0], y: v[1], z: v[2], a: v[3], b: v[4], c: v[5]) }
                    app.applyPointOffset(off, in: sys)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(v.allSatisfy { $0 == 0 })
            }
        }
        .padding(16).sheetFrame(width: 460)
        .onAppear { sys = app.pointSystem }
    }
}

/// "Rotate around vector": eixo definido por dois pontos nas coordenadas do objeto.
struct RotateAroundVectorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var s = [0.0, 0, 0]
    @State private var e = [0.0, 0, 100]
    @State private var angle = 10.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Girar pontos em torno de um vetor").font(.headline)
            Text("O eixo vai do Início ao Fim (coordenadas do objeto, mm). Ângulo positivo gira pela regra da mão direita. Só pontos World/Object (como no DXQ). Por padrão o eixo é vertical e passa pelo centro dos pontos selecionados.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Início").font(.caption.bold())
                    numberField("X", $s[0], unit: "mm"); numberField("Y", $s[1], unit: "mm"); numberField("Z", $s[2], unit: "mm")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fim").font(.caption.bold())
                    numberField("X", $e[0], unit: "mm"); numberField("Y", $e[1], unit: "mm"); numberField("Z", $e[2], unit: "mm")
                }
            }
            numberField("Âng.", $angle, unit: "°")
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Girar") {
                    app.rotateSelectedPoints(start: Vec3(s[0], s[1], s[2]), end: Vec3(e[0], e[1], e[2]), angle: angle)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(angle == 0 || (s == e))
            }
        }
        .padding(16).sheetFrame(width: 420)
        .onAppear {
            let pts = app.selectedPointPositions()
            guard !pts.isEmpty else { return }
            let c = pts.reduce(Vec3.zero) { $0 + $1.object } / Double(pts.count)
            let r = { (x: Double) in (x * 10).rounded() / 10 }
            s = [r(c.x), r(c.y), r(c.z)]
            e = [r(c.x), r(c.y), r(c.z) + 100]
        }
    }
}

/// "Mirror on plane": espelha nas coordenadas do objeto (XZ com 0 = lado esquerdo ↔ direito da carroceria).
struct MirrorPlaneSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var plane: MirrorPlane = .xz
    @State private var offset = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Espelhar pontos em um plano").font(.headline)
            Text("Plano nas coordenadas do objeto. XZ com deslocamento 0 troca o lado da carroceria (Y → −Y). A posição e a direção da pistola são espelhadas. Só pontos World/Object (como no DXQ).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Plano", selection: $plane) { ForEach(MirrorPlane.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            numberField(plane == .xy ? "Z =" : (plane == .xz ? "Y =" : "X ="), $offset, unit: "mm")
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Espelhar") { app.mirrorSelectedPoints(plane: plane, offset: offset); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).sheetFrame(width: 400)
    }
}

/// "Show distance of selected points": distância entre pontos seguidos, total e do primeiro ao último.
struct PointDistanceSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pts = app.selectedPointPositions()
        let steps = zip(pts, pts.dropFirst()).map { (a, b) in (a.name, b.name, simd_distance(a.world, b.world)) }
        let total = steps.reduce(0) { $0 + $1.2 }
        VStack(alignment: .leading, spacing: 8) {
            Text("Distância entre pontos selecionados").font(.headline)
            if pts.count < 2 {
                Text("Selecione comandos com pelo menos dois pontos.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                            HStack { Text("\(s.0) → \(s.1)"); Spacer(); Text(String(format: "%.1f mm", s.2)).monospacedDigit() }
                        }
                    }
                    .font(.system(size: 12))
                }
                .frame(maxHeight: 260)
                Divider()
                HStack { Text("Total do caminho").bold(); Spacer(); Text(String(format: "%.1f mm", total)).monospacedDigit() }
                HStack {
                    Text("\(pts.first!.name) → \(pts.last!.name) (reta)"); Spacer()
                    Text(String(format: "%.1f mm", simd_distance(pts.first!.world, pts.last!.world))).monospacedDigit()
                }
            }
            HStack { Spacer(); Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .font(.system(size: 12))
        .padding(16).sheetFrame(width: 380)
    }
}
