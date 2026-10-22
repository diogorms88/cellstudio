import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Camada fina entre macOS (AppKit) e iPhone (UIKit): cores, imagens, área de transferência,
// diálogos e seletores de arquivo. O resto do app usa só estes nomes.

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
#else
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont

extension UIColor {
    convenience init(calibratedWhite white: CGFloat, alpha: CGFloat) { self.init(white: white, alpha: alpha) }
    convenience init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

#if os(iOS)
// Estilos e comandos que só existem no macOS: no iPhone viram equivalentes de toque.

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}

extension View {
    /// Teclas Delete/⌘C não existem no iPhone; as mesmas ações ficam no menu de contexto e na barra do editor.
    func onDeleteCommand(perform action: (() -> Void)?) -> some View { self }
    func onCopyCommand(perform payloadAction: (() -> [NSItemProvider])?) -> some View { self }
    func onCutCommand(perform payloadAction: (() -> [NSItemProvider])?) -> some View { self }
    func onPasteCommand(of supportedContentTypes: [UTType], perform payloadAction: @escaping ([NSItemProvider]) -> Void) -> some View { self }
}
#endif

extension View {
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Barras de ferramentas largas: no iPhone rolam na horizontal em vez de cortar.
    @ViewBuilder func phoneHorizontalScroll() -> some View {
        if Platform.isPhone {
            ScrollView(.horizontal, showsIndicators: false) { fixedSize(horizontal: true, vertical: false) }
        } else {
            self
        }
    }

    /// Largura fixa das folhas no Mac; no iPhone a folha ocupa a tela e rola.
    @ViewBuilder func sheetFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        NavigationStack {
            ScrollView { self.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .presentationDragIndicator(.visible)
        #endif
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

extension FileManager {
    /// Manda para a Lixeira no Mac. O iOS não tem Lixeira acessível, então o item vai para
    /// Documentos/Lixeira do app (aparece no app Arquivos e pode ser recuperado).
    func discard(_ url: URL) throws {
        #if os(macOS)
        try trashItem(at: url, resultingItemURL: nil)
        #else
        let bin = Platform.documents.appendingPathComponent("Lixeira", isDirectory: true)
        try createDirectory(at: bin, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try moveItem(at: url, to: bin.appendingPathComponent("\(stamp) \(url.lastPathComponent)"))
        #endif
    }
}

enum Platform {
    /// Layout de iPhone (tela estreita, toque). A versão Mac Catalyst só existe para testar o app do iPhone,
    /// então usa o mesmo layout.
    static let isPhone: Bool = {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone || ProcessInfo.processInfo.isMacCatalystApp
        #else
        false
        #endif
    }()

    /// Pasta do usuário: no Mac a home; no iPhone os Documentos do app (visíveis no app Arquivos).
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var userName: String {
        #if os(macOS)
        NSUserName()
        #else
        UIDevice.current.name
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static var revealTitle: String { isMac ? "Mostrar no Finder" : "Compartilhar…" }

    /// "Mostrar no Finder" no Mac; no iPhone abre a folha de compartilhamento do item.
    @MainActor static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        guard let top = Dialogs.topController else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
        #endif
    }

    @MainActor static func printImage(_ img: PlatformImage) {
        #if os(macOS)
        let iv = NSImageView(frame: NSRect(origin: .zero, size: img.size))
        iv.image = img
        let info = NSPrintInfo.shared
        info.orientation = img.size.width > img.size.height ? .landscape : .portrait
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        NSPrintOperation(view: iv, printInfo: info).run()
        #else
        let pc = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .photo
        info.orientation = img.size.width > img.size.height ? .landscape : .portrait
        pc.printInfo = info
        pc.printingItem = img
        pc.present(animated: true)
        #endif
    }
}

// MARK: - Diálogos

/// Diálogos síncronos, como o NSAlert.runModal do Mac. No iPhone o alerta/seletor é apresentado
/// e o laço principal roda até a resposta, para o código que pergunta continuar igual nas duas plataformas.
@MainActor
enum Dialogs {
    /// Índice do botão escolhido; o último botão é o de cancelar.
    static func ask(_ title: String, _ message: String, buttons: [String]) -> Int {
        #if os(macOS)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        buttons.forEach { a.addButton(withTitle: $0) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        #else
        var answer = buttons.count - 1
        runModal { done in
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for (i, b) in buttons.enumerated() {
                a.addAction(UIAlertAction(title: b, style: i == buttons.count - 1 ? .cancel : .default) { _ in answer = i; done() })
            }
            guard present(a) else { done(); return }
        }
        return answer
        #endif
    }

    static func confirm(_ title: String, _ message: String, ok: String) -> Bool {
        ask(title, message, buttons: [ok, "Cancelar"]) == 0
    }

    /// Texto digitado (sem espaços nas pontas) ou nil se cancelar/vazio.
    static func prompt(_ title: String, _ message: String, value: String = "", ok: String = "OK") -> String? {
        #if os(macOS)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancelar")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespaces)
        #else
        var result: String?
        runModal { done in
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            a.addTextField { $0.text = value; $0.clearButtonMode = .whileEditing; $0.autocapitalizationType = .none }
            a.addAction(UIAlertAction(title: ok, style: .default) { _ in result = a.textFields?.first?.text; done() })
            a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in done() })
            guard present(a) else { done(); return }
        }
        let t = (result ?? "").trimmingCharacters(in: .whitespaces)
        #endif
        return t.isEmpty ? nil : t
    }

    /// Pastas escolhidas (backup do flash, 3DObjects, destino de exportação).
    static func chooseFolders(_ message: String, multiple: Bool = false, prompt: String? = nil) -> [URL] {
        #if os(macOS)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.allowsMultipleSelection = multiple
        p.message = message
        if let prompt { p.prompt = prompt }
        return p.runModal() == .OK ? p.urls : []
        #else
        return pick(UIDocumentPickerViewController(forOpeningContentTypes: [.folder]), multiple: multiple, extensions: [])
        #endif
    }

    /// Arquivos com uma das extensões (vazio = qualquer arquivo).
    static func chooseFiles(_ exts: [String], multiple: Bool = false, message: String = "") -> [URL] {
        #if os(macOS)
        let p = NSOpenPanel()
        p.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = multiple; p.canChooseFiles = true
        if !message.isEmpty { p.message = message }
        return p.runModal() == .OK ? p.urls : []
        #else
        // extensões da Dürr (.tip, .hsf, .src…) não têm tipo registrado no iOS: aceita qualquer item e filtra depois
        let types = exts.compactMap { UTType(filenameExtension: $0) }
        let known = !types.isEmpty && types.allSatisfy { !$0.isDynamic }
        return pick(UIDocumentPickerViewController(forOpeningContentTypes: known ? types : [.item]), multiple: multiple, extensions: exts)
        #endif
    }

    /// Escolhe onde salvar e chama `write`. No iPhone grava num arquivo temporário e oferece a exportação (Arquivos, AirDrop…).
    static func save(_ name: String, _ write: @escaping (URL) -> Void) {
        #if os(macOS)
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        if p.runModal() == .OK, let u = p.url { write(u) }
        #else
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exportar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        write(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = present(UIDocumentPickerViewController(forExporting: [url], asCopy: true))
        #endif
    }

    #if os(iOS)
    static var topController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }

    @discardableResult private static func present(_ vc: UIViewController) -> Bool {
        guard let top = topController else { return false }
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(vc, animated: true)
        return true
    }

    /// Roda o laço principal até `done` ser chamado (equivale ao runModal do AppKit).
    private static func runModal(_ start: (@escaping () -> Void) -> Void) {
        var finished = false
        start { finished = true }
        while !finished { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }

    private static func pick(_ picker: UIDocumentPickerViewController, multiple: Bool, extensions: [String]) -> [URL] {
        var urls: [URL] = []
        let delegate = PickerDelegate()
        runModal { done in
            delegate.finish = { urls = $0; done() }
            picker.allowsMultipleSelection = multiple
            picker.delegate = delegate
            guard present(picker) else { done(); return }
        }
        let wanted = Set(extensions.map { $0.lowercased() })
        urls = urls.filter { wanted.isEmpty || wanted.contains($0.pathExtension.lowercased()) }
        urls.forEach(ScopedAccess.remember)
        return urls
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        var finish: (([URL]) -> Void)?
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish?(urls); finish = nil }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish?([]); finish = nil }
    }
    #endif
}

/// Acesso às pastas de fora do app (backups, 3DObjects) escolhidas no seletor do iOS.
/// O iOS só deixa ler com o acesso aberto; o favorito (bookmark) reabre o acesso no próximo início,
/// para a última estação e a pasta de modelos voltarem sozinhas.
enum ScopedAccess {
    private static let key = "scopedBookmarks"

    static func remember(_ url: URL) {
        #if os(iOS)
        _ = url.startAccessingSecurityScopedResource()
        guard let data = try? url.bookmarkData() else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(all, forKey: key)
        #endif
    }

    /// Reabre o acesso a todas as pastas guardadas (chamar no início do app).
    private static var restored = false

    static func restoreAll() {
        #if os(iOS)
        guard !restored else { return }
        restored = true
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        var kept: [String: Data] = [:]
        for (_, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            kept[url.standardizedFileURL.path] = stale ? ((try? url.bookmarkData()) ?? data) : data
        }
        UserDefaults.standard.set(kept, forKey: key)
        #endif
    }
}

/// Ação de menu (menu de contexto ou Menu) que pode abrir diálogo ou seletor. No iPhone o diálogo
/// não pode abrir enquanto o menu ainda está fechando (a tela trava esperando um toque que nunca chega),
/// então a ação roda logo depois que o menu termina de sumir. No Mac roda na hora.
@MainActor func afterMenu(_ action: @escaping @MainActor () -> Void) {
    #if os(iOS)
    Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in MainActor.assumeIsolated { action() } }
    #else
    action()
    #endif
}

// Nomes usados no app inteiro (antes eram funções com NSOpenPanel/NSSavePanel).
@MainActor func openFile(_ exts: [String], _ action: @escaping (URL) -> Void) {
    if let u = Dialogs.chooseFiles(exts).first { action(u) }
}

@MainActor func saveFile(_ name: String, _ action: @escaping (URL) -> Void) {
    Dialogs.save(name, action)
}

extension View {
    /// Tabela com bordas e linhas alternadas no Mac (como o DXQ); no iPhone o estilo padrão.
    @ViewBuilder func dxqTableStyle(alternating: Bool = true) -> some View {
        #if os(macOS)
        tableStyle(.bordered(alternatesRowBackgrounds: alternating))
        #else
        self
        #endif
    }
}
