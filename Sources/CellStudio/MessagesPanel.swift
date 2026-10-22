import SwiftUI
import UniformTypeIdentifiers

struct MessagesPanel: View {
    var body: some View { DockPanel(title: "Mensagens") { MessagesContent() } }
}

struct MessagesContent: View {
    @EnvironmentObject var app: AppState

    private var visible: [AppMessage] { app.messages.filter { app.messageFilter.contains($0.level) }.reversed() }

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 6) {
                    toggle(.error, "xmark.circle.fill", .red)
                    toggle(.warning, "exclamationmark.triangle.fill", .orange)
                    toggle(.info, "info.circle.fill", .blue)
                    toggle(.simulation, "eye.fill", Color(white: 0.25))
                    Divider().frame(height: 18)
                    Button { app.messages.removeAll() } label: { Label("Limpar", systemImage: "eraser") }
                    Button { export() } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Text("\(visible.count) mensagens").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .font(DXQ.font)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .phoneHorizontalScroll()
                Rectangle().fill(DXQ.border).frame(height: 1)
                if Platform.isPhone {
                    List(visible) { m in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(m.level)).foregroundStyle(color(m.level)).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.text).font(DXQ.font).textSelection(.enabled)
                                HStack(spacing: 6) {
                                    Text(m.time, format: .dateTime.hour().minute().second())
                                    if !m.robot.isEmpty { Text(m.robot) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                } else {
                Table(visible) {
                    TableColumn("Nível") { m in
                        Image(systemName: icon(m.level)).foregroundStyle(color(m.level))
                    }.width(40)
                    TableColumn("Mensagem") { m in Text(m.text).font(DXQ.font).help(m.text) }
                    TableColumn("Tempo") { m in Text(m.time, format: .dateTime.hour().minute().second()).font(DXQ.font) }.width(70)
                    TableColumn("Robô") { m in Text(m.robot).font(DXQ.font) }.width(60)
                }
                .dxqTableStyle(alternating: false)
                }
        }
    }

    private func toggle(_ l: MessageLevel, _ icon: String, _ c: Color) -> some View {
        ToolbarToggle(title: l.rawValue, icon: icon, color: c, isOn: Binding(
            get: { app.messageFilter.contains(l) },
            set: { if $0 { app.messageFilter.insert(l) } else { app.messageFilter.remove(l) } }))
    }

    private func icon(_ l: MessageLevel) -> String {
        switch l {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .simulation: "eye.fill"
        }
    }

    private func color(_ l: MessageLevel) -> Color {
        switch l {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        case .simulation: Color(white: 0.3)
        }
    }

    private func export() {
        let f = ISO8601DateFormatter()
        let csv = "nivel;mensagem;tempo;robo\n" + app.messages.map { "\($0.level.rawValue);\($0.text.replacingOccurrences(of: ";", with: ","));\(f.string(from: $0.time));\($0.robot)" }.joined(separator: "\n")
        saveFile("mensagens.csv") { url in try? csv.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct StatusBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 10) {
            Text("Usuário atual: \(Platform.userName)")
            Image(systemName: "pencil")
            Divider().frame(height: 12).overlay(Color.white.opacity(0.5))
            Text("Robô ativo: \(app.robot.name)")
            if app.isPlaying { Text("▶ Simulação em execução") }
            Spacer()
            switch app.connectionState {
            case .connected: Label("Online", systemImage: "network")
            case .connecting: Label("Conectando…", systemImage: "network")
            default: Label("Offline", systemImage: "network.slash")
            }
            Divider().frame(height: 12).overlay(Color.white.opacity(0.5))
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date, format: .dateTime.day().month().year().hour().minute().second())
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(DXQ.blue)
    }
}
