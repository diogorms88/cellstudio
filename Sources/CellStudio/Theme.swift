#if os(macOS)
import AppKit
#endif
import CellCore
import SwiftUI

/// Paleta do DXQ3D.onsite: tema Office 2013 do Infragistics (Shell/app.baml: Themes.Office2013),
/// cores medidas nas telas do DXQ e nos recursos BAML do Shell.
enum DXQ {
    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static let blue = hex(0x0072C6)          // aba Arquivo, barra de status (destaque Office 2013)
    static let blueText = hex(0x0072C6)      // aba selecionada, título da aba de documento
    static let border = hex(0xD4D4D4)
    static let borderStrong = hex(0xABABAB)
    static let groupLine = hex(0xE2E2E2)
    static let panelHeader = hex(0x444444)
    static let text = hex(0x444444)
    static let groupTitle = hex(0x777777)
    static let ribbonBG = Color.white
    static let windowBG = hex(0xF0F0F0)
    static let selection = hex(0xCDE6F7)     // linha/item selecionado
    static let hover = hex(0xE6F0FA)
    static let hoverBorder = hex(0x99CCFF)
    static let categoryBG = hex(0xF5F5F5)
    static let comment = Color(red: 0.0, green: 0.55, blue: 0.0)
    static let font = Font.system(size: Platform.isPhone ? 14 : 12)
    /// altura das linhas de árvore/lista: no iPhone maior, para o dedo
    static let rowHeight: CGFloat = Platform.isPhone ? 34 : 20
}

// MARK: - Ribbon

struct RibbonTabBar: View {
    let tabs: [String]
    @Binding var selected: String
    var onFile: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onFile) {
                Text("Arquivo")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 24)
                    .background(DXQ.blue)
            }
            .buttonStyle(.plain)
            ForEach(tabs, id: \.self) { t in
                Button { selected = t } label: {
                    Text(t)
                        .font(.system(size: 12))
                        .foregroundStyle(selected == t ? DXQ.blueText : DXQ.text)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(selected == t ? DXQ.ribbonBG : Color.clear)
                        .overlay(Rectangle().stroke(selected == t ? DXQ.border : .clear, lineWidth: 1).padding(.bottom, -1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .background(Color.white)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 4) { content }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
                .padding(.horizontal, 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DXQ.groupTitle)
                .padding(.bottom, 3)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(DXQ.groupLine).frame(width: 1).padding(.vertical, 4) }
    }
}

/// Botão grande (ícone 32 pt + rótulo em até duas linhas).
struct RibbonLargeButton: View {
    let title: String
    let icon: String
    var tint: Color = Color(red: 0.2, green: 0.35, blue: 0.6)
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RibbonIcon(title: title, symbol: icon, size: 32, tint: tint, enabled: enabled)
                    .frame(height: 32)
                Text(title)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(enabled ? DXQ.text : Color.gray)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 46, maxWidth: 74)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(hover && enabled ? DXQ.hover : .clear)
            .overlay(RoundedRectangle(cornerRadius: 0).stroke(hover && enabled ? DXQ.hoverBorder : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Botão pequeno (ícone 16 pt + rótulo à direita), empilhado em colunas de três.
struct RibbonSmallButton: View {
    let title: String
    let icon: String
    var tint: Color = Color(red: 0.2, green: 0.35, blue: 0.6)
    var enabled = true
    var checked = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RibbonIcon(title: title, symbol: icon, size: 16, tint: tint, enabled: enabled)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(enabled ? DXQ.text : Color.gray)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 3)
            .frame(height: 22, alignment: .leading)
            .background(checked ? DXQ.selection : (hover && enabled ? DXQ.hover : .clear))
            .overlay(Rectangle().stroke(checked || (hover && enabled) ? DXQ.hoverBorder : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

struct RibbonColumn<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 1) { content } }
}

// MARK: - Painéis acopláveis

struct DockPanel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(DXQ.panelHeader).lineLimit(1)
                Spacer()
                accessory
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                Image(systemName: "pin").font(.system(size: 9)).rotationEffect(.degrees(45))
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color(white: 0.45))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.white)
            Rectangle().fill(DXQ.border).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .overlay(Rectangle().stroke(DXQ.border, lineWidth: 1))
    }
}

extension DockPanel where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Aba de documento (como "3D view" e "R11 : fixpos : home" no DXQ).
struct DocumentTab: View {
    let title: String
    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(DXQ.blueText)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Color.white)
                .overlay(alignment: .top) { Rectangle().fill(DXQ.blue).frame(height: 2) }
            Spacer()
        }
        .background(Color(white: 0.97))
    }
}

struct ToolbarToggle: View {
    let title: String
    let icon: String
    let color: Color
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.15))
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(isOn ? DXQ.selection : Color.clear)
            .overlay(Rectangle().stroke(isOn ? Color(red: 0.4, green: 0.65, blue: 0.95) : DXQ.border))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Campos

struct NumberField: View {
    let label: String
    @Binding var value: Double
    var width: CGFloat = 70
    var body: some View {
        HStack(spacing: 4) {
            if !label.isEmpty { Text(label).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing) }
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
        .font(DXQ.font)
    }
}

struct PoseEditor: View {
    @Binding var pose: Pose
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            GridRow { NumberField(label: "X", value: $pose.x, width: 62); NumberField(label: "Y", value: $pose.y, width: 62); NumberField(label: "Z", value: $pose.z, width: 62) }
            GridRow { NumberField(label: "A", value: $pose.a, width: 62); NumberField(label: "B", value: $pose.b, width: 62); NumberField(label: "C", value: $pose.c, width: 62) }
        }
    }
}


/// Divisão entre dois painéis com divisória arrastável que grava o tamanho (UserDefaults, chave "split.<key>").
/// `side` diz qual lado tem o tamanho gravado; o outro ocupa o resto da janela.
struct PersistentSplit<First: View, Second: View>: View {
    enum Side { case first, second }
    let axis: Axis
    let side: Side
    let minFirst: CGFloat
    let minSecond: CGFloat
    let first: First
    let second: Second
    @AppStorage private var size: Double
    @State private var dragStart: Double?
    private let thickness: CGFloat = 5

    init(_ axis: Axis, key: String, defaultSize: Double, side: Side, minFirst: CGFloat, minSecond: CGFloat,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis; self.side = side; self.minFirst = minFirst; self.minSecond = minSecond
        self.first = first(); self.second = second()
        _size = AppStorage(wrappedValue: defaultSize, "split." + key)
    }

    private func clamp(_ v: Double, total: CGFloat) -> CGFloat {
        let minOwn = side == .first ? minFirst : minSecond
        let minOther = side == .first ? minSecond : minFirst
        let upper = Swift.max(minOwn, total - thickness - minOther)
        return Swift.min(Swift.max(CGFloat(v), minOwn), upper)
    }

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let s = clamp(size, total: total)
            let firstLen = side == .first ? s : Swift.max(total - thickness - s, 0)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: firstLen)
                    divider(total: total)
                    second.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: firstLen)
                    divider(total: total)
                    second.frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(DXQ.windowBG)
            .frame(width: axis == .horizontal ? thickness : nil, height: axis == .vertical ? thickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                #if os(macOS)
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                #endif
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if dragStart == nil { dragStart = Double(clamp(size, total: total)) }
                    let delta = Double(axis == .horizontal ? g.translation.width : g.translation.height)
                    size = Double(clamp((dragStart ?? size) + (side == .first ? delta : -delta), total: total))
                }
                .onEnded { _ in dragStart = nil })
    }
}

// MARK: - Ícones do DXQ (images/*.png das DLLs do DXQ3D.onsite, em Resources/dxq)

enum DXQIcons {
    /// Botão do ribbon (título, ou "título|símbolo" quando o título se repete) → ícone do DXQ (sem _16x16/_32x32).
    static let byTitle: [String: String] = [
        // Editor de programa
        "Abrir backup": "3dgraphic_open", "Salvar": "general_saveas", "Simular programa": "programeditorcommon_simulatemodule",
        "Carregar na simulação": "programeditor_loadmodule", "Recarregar do disco": "programeditor_refresh",
        "Copiar posição do TCP": "3dgraphic_tcp", "Ir para posição inicial": "programeditor_currentposition",
        "Importar .src": "general_import", "Exportar .src": "general_export",
        // Transformação
        "Mover robô até o ponto": "3dgraphic_currentposition", "Valores…": "programeditorcommon_modifycommand",
        "Restaurar coordenadas": "general_undo", "Copiar orientação": "3dgraphic_copyorientation",
        "Colar orientação": "3dgraphic_pasteorientation", "Copiar E1": "3dgraphic_copyrail", "Colar E1": "3dgraphic_pasterail",
        "Girar em torno de vetor…": "3dgraphic_rotatearoundvector", "Espelhar em plano…": "3dgraphic_mirroronplane",
        "Distância entre pontos": "3dgraphic_showdistanceselectedpoints", "Converter tipo": "3dgraphic_convertcoordinatesystem",
        // Vista 3D
        "Enquadrar tudo": "3dgraphic_navigatezoomtofit", "Isométrica": "3dgraphic_viewfixediso", "Frente": "3dgraphic_viewfixedfront",
        "Lateral": "3dgraphic_viewfixedleft", "Topo": "3dgraphic_viewfixedtop", "Grade": "3dgraphic_showhidefloor",
        "Trajetória": "3dgraphic_showhidepoints", "Sistemas de coord.": "3dgraphic_transformcoordsysworld",
        "Modelos 3D…": "3dgraphic_load", "Espelhar na vista 3D": "3dgraphic_mirroronplane",
        "Todos os robôs": "3dgraphic_multikin", "Todos para home": "3dgraphic_viewhome", "Tipo do catálogo…": "catalogviewer_configuration",
        // Objetos 3D
        "Importar carroceria": "3dgraphic_carbody", "Importar peça": "3dgraphic_cellload", "Painel demo": "3dgraphic_cell",
        "Remover": "general_delete", "Usar como alvo": "3dgraphic_placement", "Zigue-zague na peça": "3dgraphic_createpath",
        "Pincéis…": "brusheditor", "Pintar durante": "3dgraphic_showbrushcolors", "Simular espessura": "3dgraphic_processsimulation",
        "Limpar tinta": "hidepaintfilm",
        // Simulação
        "Iniciar": "3dgraphic_start", "Parar": "3dgraphic_stop", "Ao início": "3dgraphic_viewbackward",
        "Recalcular trajetória": "3dgraphic_simpath", "Parar no erro": "3dgraphic_emergencystop",
        // Análise IA
        "Simular e\nanalisar": "3dgraphic_simresults", "Analisando…": "3dgraphic_simresults", "Ver sugestões": "general_listview",
        "Desfazer sugestão": "general_undo", "Salvar alterações": "general_saveas",
        // Online
        "Conectar|cpu": "general_control", "Conectar|network": "system_sync", "Desconectar": "system_logout",
    ]

    /// Ícones fora do ribbon (explorador, barras de ferramentas), pelo símbolo usado antes.
    static let bySymbol: [String: String] = [
        "building.2.fill": "general_station", "square.stack.3d.up.fill": "general_folder", "gearshape.2.fill": "dirobjects_robotrs",
        "car.side.fill": "general_teachproject", "doc.text": "general_teachprogram", "folder.fill": "general_folder",
        "cube.transparent": "3dgraphic_cell", "cube": "3dgraphic_cell", "paintbrush.fill": "3dgraphic_carbody",
        "pencil": "programeditorcommon_modifycommand", "scope": "programeditor_modify", "location.viewfinder": "programeditor_currentposition",
        "trash": "programeditorcommon_removecommand", "text.bubble": "programeditorcommon_commentout", "nosign": "programeditorcommon_disable",
        "arrow.uturn.backward": "general_undo", "arrow.uturn.forward": "general_redo", "plus.rectangle.on.rectangle": "programeditorcommon_insertcommand",
        "arrow.clockwise": "general_refresh", "rectangle.expand.vertical": "general_expandall", "rectangle.compress.vertical": "general_collapseall",
    ]

    static func name(title: String, symbol: String) -> String? {
        if symbol.hasPrefix("dxq:") { return String(symbol.dropFirst(4)) }
        return byTitle["\(title)|\(symbol)"] ?? byTitle[title]
    }

    private static var cache: [String: PlatformImage] = [:]

    /// PNG do DXQ no tamanho pedido (16 ou 32); sem o tamanho, usa o outro.
    static func image(_ name: String, size: Int) -> PlatformImage? {
        let key = "\(name)@\(size)"
        if let i = cache[key] { return i }
        let other = size == 32 ? 16 : 32
        for s in [size, other] {
            if let url = Bundle.main.url(forResource: "\(name)_\(s)x\(s)", withExtension: "png", subdirectory: "dxq"),
               let img = PlatformImage(contentsOfFile: url.path) {
                #if os(macOS)
                img.size = NSSize(width: size, height: size)
                #endif
                cache[key] = img
                return img
            }
        }
        return nil
    }
}

/// Ícone do DXQ se houver, senão o símbolo do sistema. Desativado fica cinza como no DXQ.
struct RibbonIcon: View {
    let title: String
    let symbol: String
    let size: Int
    var tint: Color
    var enabled: Bool
    var body: some View {
        if let n = DXQIcons.name(title: title, symbol: symbol), let img = DXQIcons.image(n, size: size) {
            Image(platformImage: img).resizable().interpolation(.high)
                .frame(width: CGFloat(size), height: CGFloat(size))
                .saturation(enabled ? 1 : 0).opacity(enabled ? 1 : 0.45)
        } else {
            Image(systemName: symbol.hasPrefix("dxq:") ? "questionmark.square.dashed" : symbol)
                .font(.system(size: size == 32 ? 24 : 13))
                .foregroundStyle(enabled ? tint : Color.gray.opacity(0.5))
        }
    }
}

/// Símbolo do sistema trocado pelo ícone do DXQ equivalente (explorador e barras), se houver.
struct DXQSymbol: View {
    let symbol: String
    var size: CGFloat = 16
    var tint: Color = DXQ.text
    var body: some View {
        if let n = DXQIcons.bySymbol[symbol], let img = DXQIcons.image(n, size: 16) {
            Image(platformImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: symbol).font(.system(size: size * 0.75)).foregroundStyle(tint)
        }
    }
}

// MARK: - Botões com menu e só-ícone (ribbon do DXQ)

/// Botão grande com menu (▾), como "Inserir comando", "Modo de renderização".
struct RibbonMenuLarge<Content: View>: View {
    let title: String
    let icon: String
    var enabled = true
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            VStack(spacing: 2) {
                RibbonIcon(title: title, symbol: icon, size: 32, tint: .accentColor, enabled: enabled).frame(height: 32)
                Text(title + " ▾").font(.system(size: 11)).multilineTextAlignment(.center)
                    .foregroundStyle(enabled ? DXQ.text : Color.gray).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 46, maxWidth: 80)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!enabled)
    }
}

/// Botão pequeno com menu (▾).
struct RibbonMenuSmall<Content: View>: View {
    let title: String
    let icon: String
    var enabled = true
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            HStack(spacing: 4) {
                RibbonIcon(title: title, symbol: icon, size: 16, tint: .accentColor, enabled: enabled).frame(width: 18)
                Text(title + " ▾").font(.system(size: 12)).foregroundStyle(enabled ? DXQ.text : Color.gray).fixedSize()
            }
            .frame(height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!enabled)
    }
}

/// Botão só com ícone de 16 px (grupo Vista / Navegar / Programa ativo do DXQ).
struct RibbonIconButton: View {
    let icon: String
    let help: String
    var enabled = true
    var checked = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            RibbonIcon(title: help, symbol: icon, size: 16, tint: .accentColor, enabled: enabled)
                .frame(width: 22, height: 22)
                .background(checked ? DXQ.selection : (hover && enabled ? DXQ.hover : .clear))
                .overlay(Rectangle().stroke(checked || (hover && enabled) ? DXQ.hoverBorder : .clear))
        }
        .buttonStyle(.plain).disabled(!enabled).help(help).onHover { hover = $0 }
    }
}

/// Ícone só (com menu) de 16 px.
struct RibbonIconMenu<Content: View>: View {
    let icon: String
    let help: String
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            HStack(spacing: 1) {
                RibbonIcon(title: help, symbol: icon, size: 16, tint: .accentColor, enabled: true)
                Text("▾").font(.system(size: 8)).foregroundStyle(DXQ.text)
            }
            .frame(height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(help)
    }
}
