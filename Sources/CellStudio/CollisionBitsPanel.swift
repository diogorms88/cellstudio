import CellCore
import SwiftUI

/// Painel inferior com abas: Mensagens e Bits de colisão.
struct BottomDock: View {
    @EnvironmentObject var app: AppState
    private var tab: Int { app.bottomTab }

    var body: some View {
        DockPanel(title: ["Mensagens", "Bits de colisão", "Análise da estação", "Claude"][min(tab, 3)]) {
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case 1: CollisionBitsPanel()
                    case 2: StationAnalysisPanel()
                    case 3: ClaudeChatPanel(chat: app.claude)
                    default: MessagesContent()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(DXQ.border).frame(height: 1)
                HStack(spacing: 0) {
                    tabButton("Mensagens", "text.bubble", 0, badge: nil)
                    tabButton("Bits de colisão", "lock.rectangle.stack", 1,
                              badge: app.stationWaits.isEmpty ? nil : "\(app.stationWaits.count)")
                    tabButton("Análise da estação", "sparkles", 2,
                              badge: app.analysis.map { a in a.suggestions.filter { $0.severity <= .risk }.count }.flatMap { $0 > 0 ? "\($0)" : nil })
                    tabButton("Claude", "bubble.left.and.text.bubble.right", 3, badge: nil)
                    Spacer()
                }
                .frame(height: 22)
                .background(DXQ.windowBG)
            }
        }
    }

    private func tabButton(_ title: String, _ icon: String, _ i: Int, badge: String?) -> some View {
        Button { app.bottomTab = i } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11))
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).background(Capsule().fill(Color.orange))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .foregroundStyle(tab == i ? DXQ.blue : Color(white: 0.35))
            .background(tab == i ? Color.white : Color.clear)
            .overlay(alignment: .top) { if tab == i { Rectangle().fill(DXQ.blue).frame(height: 2) } }
        }
        .buttonStyle(.plain)
    }
}

/// Linha do tempo dos bits de colisão da estação (como um Gantt):
/// uma faixa por bit mostrando o robô dono da zona, e uma faixa por robô com as esperas em RECEIVE.
struct CollisionBitsPanel: View {
    @EnvironmentObject var app: AppState
    @State private var zoom = 1.0
    @State private var onlyContended = false

    private let labelWidth: CGFloat = 170
    private let rowHeight: CGFloat = 20
    private let axisHeight: CGFloat = 18

    static let palette: [Color] = [
        Color(red: 0.16, green: 0.45, blue: 0.80), Color(red: 0.90, green: 0.49, blue: 0.13),
        Color(red: 0.20, green: 0.62, blue: 0.30), Color(red: 0.56, green: 0.33, blue: 0.70),
        Color(red: 0.80, green: 0.22, blue: 0.25), Color(red: 0.10, green: 0.60, blue: 0.62),
        Color(red: 0.55, green: 0.40, blue: 0.25), Color(red: 0.85, green: 0.40, blue: 0.65),
    ]

    private func color(_ robot: String) -> Color {
        let i = app.robots.firstIndex { $0.name == robot } ?? abs(robot.hashValue)
        return Self.palette[i % Self.palette.count]
    }

    private var pins: [String] {
        let contended = Set(app.stationWaits.map(\.pin))
        let all = Set(app.stationZones.map(\.pin)).union(contended)
        return all.filter { !onlyContended || contended.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var waitingRobots: [String] {
        Array(Set(app.stationWaits.map(\.robot))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var duration: Double { max(app.stationDuration, app.simulationTimeline.last ?? 0, app.samples.last?.time ?? 0, 0.1) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(DXQ.border).frame(height: 1)
            if app.stationZones.isEmpty && app.stationWaits.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "lock.open").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("Nenhum bit de colisão na simulação atual.").font(DXQ.font)
                    Text("Os programas precisam de SET/RECEIVE(CollisionN, High/Low). Ative \"Todos os robôs\" e recalcule a trajetória.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
    }

    // MARK: Barra

    private var toolbar: some View {
        let totalWait = app.stationWaits.reduce(0) { $0 + ($1.end - $1.start) }
        return HStack(spacing: 10) {
            ForEach(app.robots.map(\.name), id: \.self) { name in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(color(name)).frame(width: 12, height: 10)
                    Text(name)
                }
            }
            Divider().frame(height: 14)
            Text("\(pins.count) bits · \(app.stationWaits.count) esperas · \(String(format: "%.1f s", totalWait)) parado")
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Só bits com espera", isOn: $onlyContended).toggleStyle(.checkbox)
            HStack(spacing: 2) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...12).frame(width: 90).controlSize(.mini)
                Image(systemName: "plus.magnifyingglass")
            }
            Text(String(format: "t = %.2f s", app.currentSimTime)).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    // MARK: Gráfico

    private var chart: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                labels.frame(width: labelWidth)
                Rectangle().fill(DXQ.border).frame(width: 1)
                GeometryReader { geo in
                    ScrollView(.horizontal) {
                        timeline(width: max(geo.size.width * zoom, 100))
                    }
                }
                .frame(height: chartHeight)
            }
        }
    }

    private var chartHeight: CGFloat {
        axisHeight + CGFloat(pins.count) * rowHeight + (waitingRobots.isEmpty ? 0 : rowHeight + CGFloat(waitingRobots.count) * rowHeight)
    }

    private var labels: some View {
        let now = app.currentSimTime
        return VStack(alignment: .leading, spacing: 0) {
            Text("Bit / zona").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(height: axisHeight).padding(.leading, 6)
            ForEach(Array(pins.enumerated()), id: \.element) { i, pin in
                let owner = app.stationZones.first { $0.pin == pin && $0.start <= now && now < $0.end }?.owner
                HStack(spacing: 4) {
                    Image(systemName: owner == nil ? "lock.open" : "lock.fill").font(.system(size: 9))
                        .foregroundStyle(owner.map(color) ?? Color.secondary)
                    Text(pin).font(DXQ.font)
                    Spacer()
                    Text(owner ?? "livre").font(.system(size: 10, weight: owner == nil ? .regular : .semibold))
                        .foregroundStyle(owner.map(color) ?? Color.secondary)
                }
                .padding(.horizontal, 6)
                .frame(height: rowHeight)
                .background(i % 2 == 0 ? Color.clear : Color(white: 0.97))
            }
            if !waitingRobots.isEmpty {
                Text("Esperas em RECEIVE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(height: rowHeight).padding(.leading, 6)
                ForEach(waitingRobots, id: \.self) { r in
                    let total = app.stationWaits.filter { $0.robot == r }.reduce(0) { $0 + $1.end - $1.start }
                    let waitingNow = app.stationWaits.contains { $0.robot == r && $0.start <= now && now < $0.end }
                    HStack(spacing: 4) {
                        Image(systemName: waitingNow ? "hand.raised.fill" : "hourglass").font(.system(size: 9))
                            .foregroundStyle(waitingNow ? Color.red : color(r))
                        Text(r).font(DXQ.font)
                        Spacer()
                        Text(String(format: "%.1f s", total)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: rowHeight)
                }
            }
        }
    }

    private func timeline(width: CGFloat) -> some View {
        let scale = width / duration
        let x = { (t: Double) in CGFloat(t) * scale }
        return ZStack(alignment: .topLeading) {
            // fundo das linhas + grade de tempo
            VStack(spacing: 0) {
                Color.clear.frame(height: axisHeight)
                ForEach(Array(pins.enumerated()), id: \.element) { i, _ in
                    (i % 2 == 0 ? Color.clear : Color(white: 0.97)).frame(height: rowHeight)
                }
            }
            axis(width: width, scale: scale)

            ForEach(Array(pins.enumerated()), id: \.element) { i, pin in
                ForEach(app.stationZones.filter { $0.pin == pin }, id: \.self) { z in
                    segment(x: x(z.start), w: max(x(z.end) - x(z.start), 2), y: axisHeight + CGFloat(i) * rowHeight,
                            fill: color(z.owner).opacity(0.85), text: z.owner,
                            help: String(format: "%@: zona de %@ de %.2f a %.2f s (%.2f s)", pin, z.owner, z.start, z.end, z.end - z.start))
                        .onTapGesture { app.scrub(toTime: z.start) }
                }
                // marca onde alguém ficou esperando este bit
                ForEach(app.stationWaits.filter { $0.pin == pin }, id: \.self) { w in
                    Rectangle().fill(color(w.robot)).frame(width: max(x(w.end) - x(w.start), 2), height: 3)
                        .offset(x: x(w.start), y: axisHeight + CGFloat(i + 1) * rowHeight - 4)
                        .allowsHitTesting(false)
                }
            }

            let waitTop = axisHeight + CGFloat(pins.count + 1) * rowHeight
            ForEach(Array(waitingRobots.enumerated()), id: \.element) { i, r in
                ForEach(app.stationWaits.filter { $0.robot == r }, id: \.self) { w in
                    let who = w.blockedBy.map { " – zona com \($0)" } ?? ""
                    segment(x: x(w.start), w: max(x(w.end) - x(w.start), 2), y: waitTop + CGFloat(i) * rowHeight,
                            fill: w.forced ? Color.red.opacity(0.75) : color(r).opacity(0.35), stroke: color(r),
                            text: "\(w.pin) \(w.high ? "High" : "Low")",
                            help: String(format: "%@ parado em RECEIVE(%@, %@) de %.2f a %.2f s (%.2f s)%@\n%@:%d%@\nClique para abrir a linha no editor",
                                         r, w.pin, w.high ? "High" : "Low", w.start, w.end, w.end - w.start, who,
                                         w.program, w.line, w.forced ? "\nImpasse: passagem forçada pelo simulador" : ""))
                        .onTapGesture {
                            app.scrub(toTime: w.start)
                            app.reveal(program: w.program, line: w.line, robot: r)
                        }
                }
            }

            // cursor de tempo
            Rectangle().fill(Color.red).frame(width: 1.5, height: chartHeight)
                .offset(x: x(app.currentSimTime))
                .allowsHitTesting(false)
        }
        .frame(width: width, height: chartHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            app.scrub(toTime: max(0, min(duration, Double(g.location.x / scale))))
        })
    }

    private func segment(x: CGFloat, w: CGFloat, y: CGFloat, fill: Color, stroke: Color? = nil, text: String, help: String) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(stroke ?? .clear, lineWidth: 1))
            .overlay(alignment: .leading) {
                if w > 44 {
                    Text(text).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(stroke == nil ? Color.white : Color(white: 0.15))
                        .lineLimit(1).padding(.leading, 4)
                }
            }
            .frame(width: w, height: rowHeight - 6)
            .offset(x: x, y: y + 3)
            .help(help)
    }

    private func axis(width: CGFloat, scale: CGFloat) -> some View {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { CGFloat($0) * scale >= 60 } ?? 600
        let ticks = Array(stride(from: 0.0, through: duration, by: step))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(DXQ.border).frame(width: width, height: 1).offset(y: axisHeight - 1)
            ForEach(ticks, id: \.self) { t in
                Rectangle().fill(Color(white: 0.9)).frame(width: 1, height: chartHeight - axisHeight)
                    .offset(x: CGFloat(t) * scale, y: axisHeight)
                Text(t >= 60 && step >= 60 ? String(format: "%.0f min", t / 60) : String(format: step < 1 ? "%.1f s" : "%.0f s", t))
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
                    .offset(x: CGFloat(t) * scale + 2, y: 3)
            }
        }
        .allowsHitTesting(false)
    }
}
