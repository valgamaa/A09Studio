import SwiftUI
import AppKit

/// A monospaced, line-numbered, lightly syntax-highlighted text editor for
/// 6809 assembly source. Built on NSTextView because SwiftUI's TextEditor
/// has no styling hooks for per-token coloring.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var errorLines: Set<Int> = []

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 26, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.allowsUndo = true
        textView.string = text

        let ruler = LineNumberRulerView(textView: textView)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        // Assembly source relies on comments lining up in a column well past
        // the visible width -- wrapping those lines makes the code unreadable.
        // A horizontal scroller plus a non-wrapping text container (below)
        // keeps every line on one row, like a real code editor.
        scrollView.hasHorizontalScroller = true
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
        scrollView.autoresizingMask = [.width, .height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        // Deliberately not [.width] here: NSTextView's own auto-grow (from
        // isHorizontallyResizable) only fires on text/layout changes, not
        // when the enclosing scroll view's visible width changes (e.g.
        // dragging the HSplitView divider), so it's not enough on its own --
        // resizeToFitContent(_:) below drives the frame width explicitly on
        // every update instead.
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        context.coordinator.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
            if selectedRange.location <= (textView.string as NSString).length {
                textView.setSelectedRange(selectedRange)
            }
        }
        // Re-fit on every update, not just text changes -- this is what
        // actually catches the pane being resized (see the comment on
        // resizeToFitContent).
        context.coordinator.resizeToFitContent(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        /// Deliberately simple: colors comments, string literals, hex/decimal
        /// numbers, and known 6809 mnemonics/pseudo-ops. Good enough to read
        /// code by; not a full tokenizer.
        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)

            // Belt-and-suspenders against wrapping: lines mixing literal
            // spaces with tabs for comment alignment (e.g. "EQU     0
            // <tab>; comment") were still wrapping at a space even with an
            // effectively-infinite container width, while tab-only lines
            // weren't -- ordinary word-wrap breaking at the space runs.
            // Setting the paragraph's lineBreakMode to .byClipping forbids
            // wrapping outright, regardless of width, tabs, or spaces.
            let noWrap = NSMutableParagraphStyle()
            noWrap.lineBreakMode = .byClipping
            noWrap.tabStops = []
            noWrap.defaultTabInterval = 32

            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: noWrap], range: fullRange)

            let text = storage.string as NSString

            func colorize(pattern: String, color: NSColor, bold: Bool = false) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
                regex.enumerateMatches(in: storage.string, range: fullRange) { match, _, _ in
                    guard let match else { return }
                    var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                    if bold {
                        attrs[.font] = NSFont.monospacedSystemFont(ofSize: 26, weight: .semibold)
                    }
                    storage.addAttributes(attrs, range: match.range)
                }
            }
            _ = text

            // Order matters: comments last so they override token coloring
            // inside a commented-out line.
            colorize(pattern: #"\b(0x[0-9a-f]+|\$[0-9a-f]+|%[01]+|#\$?[0-9a-f]+|\b\d+)\b"#, color: .systemPurple)
            colorize(pattern: Mnemonics.pattern, color: .systemBlue, bold: true)
            colorize(pattern: Pseudos.pattern, color: .systemTeal, bold: true)
            colorize(pattern: #""[^"]*""#, color: .systemGreen)
            colorize(pattern: #";.*$"#, color: .secondaryLabelColor)

            storage.endEditing()
            resizeToFitContent(textView)
        }

        /// NSTextView's own auto-grow (from isHorizontallyResizable) only
        /// fires right when text/layout changes; dragging the HSplitView
        /// divider wider, with the text unchanged, never triggers it, which
        /// is why the view kept wrapping at the old width no matter how
        /// wide the pane got. This measures the actual unwrapped width from
        /// the layout manager directly and sets the frame explicitly, so
        /// it's always at least as wide as both the longest line and the
        /// currently visible pane.
        func resizeToFitContent(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let usedWidth = layoutManager.usedRect(for: container).width
            let visibleWidth = textView.enclosingScrollView?.contentView.bounds.width ?? 0
            let targetWidth = max(usedWidth + textView.textContainerInset.width * 2 + 4, visibleWidth)
            if abs(textView.frame.width - targetWidth) > 0.5 {
                textView.setFrameSize(NSSize(width: targetWidth, height: textView.frame.height))
            }
        }
    }
}

private enum Mnemonics {
    static let list = [
        "ABX","ADCA","ADCB","ADDA","ADDB","ADDD","ANDA","ANDB","ANDCC","ASL","ASLA","ASLB",
        "ASR","ASRA","ASRB","BCC","BCS","BEQ","BGE","BGT","BHI","BHS","BITA","BITB","BLE",
        "BLO","BLS","BLT","BMI","BNE","BPL","BRA","BRN","BSR","BVC","BVS","CLR","CLRA","CLRB",
        "CMPA","CMPB","CMPD","CMPS","CMPU","CMPX","CMPY","COM","COMA","COMB","CWAI","DAA",
        "DEC","DECA","DECB","EORA","EORB","EXG","INC","INCA","INCB","JMP","JSR","LBCC","LBCS",
        "LBEQ","LBGE","LBGT","LBHI","LBHS","LBLE","LBLO","LBLS","LBLT","LBMI","LBNE","LBPL",
        "LBRA","LBRN","LBSR","LBVC","LBVS","LDA","LDB","LDD","LDS","LDU","LDX","LDY","LEAS",
        "LEAU","LEAX","LEAY","LSL","LSLA","LSLB","LSR","LSRA","LSRB","MUL","NEG","NEGA","NEGB",
        "NOP","ORA","ORB","ORCC","PSHS","PSHU","PULS","PULU","ROL","ROLA","ROLB","ROR","RORA",
        "RORB","RTI","RTS","SBCA","SBCB","SEX","STA","STB","STD","STS","STU","STX","STY",
        "SUBA","SUBB","SUBD","SWI","SWI2","SWI3","SYNC","TFR","TST","TSTA","TSTB"
    ]
    static let pattern = "\\b(" + list.joined(separator: "|") + ")\\b"
}

private enum Pseudos {
    static let list = [
        "ORG","EQU","SET","RMB","FCB","FDB","FCC","FCW","END","INCLUDE","MACRO","ENDM",
        "IF","ELSE","ENDIF","SETDP","OPT","NAM","TTL","EXITM","DUP","ENDD","REG","ERR",
        "TEXT","RZB","PUBLIC","EXTERN","BIN","BINARY"
    ]
    static let pattern = "\\b(" + list.joined(separator: "|") + ")\\b"
}

/// Simple line-number gutter for NSTextView.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 56
        NotificationCenter.default.addObserver(self, selector: #selector(contentDidChange),
                                                 name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func contentDidChange() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let text = textView.string as NSString
        var lineNumber = 1
        var index = 0

        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let y = lineRect.minY + textView.textContainerInset.height - visibleRect.minY

            if y + lineRect.height >= 0 && y <= visibleRect.height {
                let numberString = "\(lineNumber)" as NSString
                let size = numberString.size(withAttributes: attrs)
                numberString.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attrs)
            }
            index = lineRange.location + lineRange.length
            lineNumber += 1
            if lineRange.length == 0 { break }
        }
    }
}
