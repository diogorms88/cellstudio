import CellCore
import SwiftUI
#if os(macOS)
import AppKit


/// Editor de código EcoTalk no estilo do DXQ: números de linha, comentários em verde,
/// instruções de movimento em azul e a linha em execução destacada durante a simulação.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightedLine: Int?
    var isData: Bool
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = Self.font
        tv.textColor = Self.textColor
        tv.backgroundColor = .white
        tv.insertionPointColor = .black
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = .white
        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.string = text
        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight(tv)
        }
        if context.coordinator.shownLine != highlightedLine {
            context.coordinator.shownLine = highlightedLine
            context.coordinator.markLine(tv, highlightedLine)
        }
        (scroll.verticalRulerView as? LineNumberRuler)?.currentLine = highlightedLine
        scroll.verticalRulerView?.needsDisplay = true
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let textColor = NSColor(calibratedWhite: 0.2, alpha: 1)
    static let commentColor = NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
    static let motionColor = NSColor(calibratedRed: 0.0, green: 0.25, blue: 0.75, alpha: 1)
    static let processColor = NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.0, alpha: 1)
    static let keywordColor = NSColor(calibratedRed: 0.5, green: 0.0, blue: 0.55, alpha: 1)
    static let numberColor = NSColor(calibratedRed: 0.6, green: 0.1, blue: 0.1, alpha: 1)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var shownLine: Int?
        init(_ p: CodeEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onChange()
            highlight(tv)
        }

        private static let motion = try! NSRegularExpression(pattern: #"^\s*(PTP|LIN|CIRC|PTP_REL|LIN_REL)\b"#, options: [.anchorsMatchLines, .caseInsensitive])
        private static let process = try! NSRegularExpression(pattern: #"^\s*(GUN|GUN_DIRECT|SETBRUSH|SETBRUSH_DIRECT|SETTOOL|SETOBJECT|VEL|ACC|OVERLAP)\b"#, options: [.anchorsMatchLines, .caseInsensitive])
        private static let keyword = try! NSRegularExpression(pattern: #"\b(CALL|IF|ELSIF|ELSE|END_IF|GOTO|LABEL|WHILE|END_WHILE|LOOP|END_LOOP|RSELECT|RDESELECT|WAIT|RETURN|SET|RECEIVE|DELAY)\b"#, options: [])
        private static let comment = try! NSRegularExpression(pattern: #"//.*$"#, options: [.anchorsMatchLines])
        private static let number = try! NSRegularExpression(pattern: #"(?<![\w.])-?\d+(\.\d+)?"#, options: [])
        private static let type = try! NSRegularExpression(pattern: #":\s*([A-Z_]+)\s*:="#, options: [])

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let s = storage.string
            storage.beginEditing()
            storage.setAttributes([.font: CodeEditor.font, .foregroundColor: CodeEditor.textColor], range: full)
            if parent.isData {
                Self.number.enumerateMatches(in: s, range: full) { m, _, _ in if let r = m?.range { storage.addAttribute(.foregroundColor, value: CodeEditor.numberColor, range: r) } }
                Self.type.enumerateMatches(in: s, range: full) { m, _, _ in if let r = m?.range(at: 1) { storage.addAttribute(.foregroundColor, value: CodeEditor.motionColor, range: r) } }
            } else {
                Self.keyword.enumerateMatches(in: s, range: full) { m, _, _ in if let r = m?.range { storage.addAttribute(.foregroundColor, value: CodeEditor.keywordColor, range: r) } }
                Self.motion.enumerateMatches(in: s, range: full) { m, _, _ in if let r = m?.range(at: 1) { storage.addAttribute(.foregroundColor, value: CodeEditor.motionColor, range: r) } }
                Self.process.enumerateMatches(in: s, range: full) { m, _, _ in if let r = m?.range(at: 1) { storage.addAttribute(.foregroundColor, value: CodeEditor.processColor, range: r) } }
            }
            Self.comment.enumerateMatches(in: s, range: full) { m, _, _ in if let r = m?.range { storage.addAttribute(.foregroundColor, value: CodeEditor.commentColor, range: r) } }
            storage.endEditing()
            markLine(tv, shownLine)
        }

        func markLine(_ tv: NSTextView, _ line: Int?) {
            guard let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            guard let line, line > 0 else { return }
            let ns = tv.string as NSString
            var start = 0, n = 1
            while n < line && start < ns.length {
                let r = ns.lineRange(for: NSRange(location: start, length: 0))
                start = NSMaxRange(r); n += 1
            }
            guard start <= ns.length else { return }
            let r = ns.lineRange(for: NSRange(location: start, length: 0))
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor(calibratedRed: 1, green: 0.93, blue: 0.55, alpha: 1), forCharacterRange: r)
            tv.scrollRangeToVisible(r)
        }
    }
}

/// Régua com números de linha (verde, como no editor do DXQ).
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var currentLine: Int?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // número da primeira linha visível
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                     .foregroundColor: NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.1, alpha: 1)]
        var idx = chars.location
        let yOffset = convert(NSPoint.zero, from: tv).y + tv.textContainerInset.height
        while idx <= NSMaxRange(chars) && idx < max(ns.length, 1) {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let g = lm.glyphRange(forCharacterRange: NSRange(location: lr.location, length: 0), actualCharacterRange: nil)
            let r = lm.lineFragmentRect(forGlyphAt: min(g.location, max(lm.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            let y = r.minY + yOffset
            if line == currentLine {
                NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: ruleThickness - 1, height: r.height).fill()
            }
            let s = "\(line)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (r.height - size.height) / 2), withAttributes: attrs)
            line += 1
            let next = NSMaxRange(lr)
            if next <= idx { break }
            idx = next
        }
    }
}

#endif

struct ProgramEditorPanel: View {
    @EnvironmentObject var app: AppState

    var title: String {
        guard let p = app.openProgram else { return "Editor do programa" }
        let proj = p.url.deletingLastPathComponent().deletingPathExtension().lastPathComponent
        let owner = app.robots.first { $0.backup?.projects.contains { $0.programs.contains { $0.url == p.url } } ?? false }?.name ?? app.robot.name
        return "\(owner) : \(proj) : \(p.name)\(app.openProgramDirty ? " *" : "")"
    }

    var body: some View {
        DockPanel(title: title) {
            VStack(spacing: 0) {
                ProgramTabsBar()
                HStack(spacing: 0) {
                    tab("Código fonte", 0)
                    tab("Dados", 1)
                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.top, 3)
                .background(Color(white: 0.97))
                .overlay(alignment: .bottom) { Rectangle().fill(DXQ.border).frame(height: 1) }
                if app.openProgram != nil {
                    if app.editorTab == 0 {
                        ProgramCommandList()
                    } else {
                        ProgramDataGrid()
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text("Selecione um programa no explorador de projeto").font(DXQ.font).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func tab(_ title: String, _ i: Int) -> some View {
        Button { app.editorTab = i } label: {
            Text(title)
                .font(DXQ.font)
                .foregroundStyle(Color(white: 0.1))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(app.editorTab == i ? Color.white : Color(white: 0.9))
                .overlay(Rectangle().stroke(DXQ.border))
        }
        .buttonStyle(.plain)
    }
}
