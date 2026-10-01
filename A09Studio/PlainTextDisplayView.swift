import SwiftUI
import AppKit

/// A read-only, non-wrapping monospaced text view for output the user reads
/// and copies but never edits -- currently the assembler's Listing tab.
///
/// SwiftUI's own Text + .fixedSize + ScrollView combination proved
/// unreliable at actually preventing word-wrap for this content (the same
/// symptom CodeEditorView hit before switching to NSTextView), so this
/// reuses that same proven recipe instead: widthTracksTextView disabled, a
/// large-but-finite container (CGFloat.greatestFiniteMagnitude itself
/// caused inconsistent wrap behavior -- see CodeEditorView), a paragraph
/// style that forbids wrapping outright (.byClipping) rather than relying
/// on width alone, and an explicit resize-to-fit-content pass since
/// NSTextView's automatic auto-grow only fires on text changes, not when
/// the enclosing pane is resized.
struct PlainTextDisplayView: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat = 20

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 1_000_000, height: 1_000_000)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        // Deliberately empty, not [.width]: see CodeEditorView's identical
        // note -- NSTextView's own auto-grow doesn't fire on pane resizes
        // with unchanged text, so resizeToFitContent drives this instead.
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        textView.textContainer?.widthTracksTextView = false

        applyStyle(to: textView)
        resizeToFitContent(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            applyStyle(to: textView)
        }
        resizeToFitContent(textView)
    }

    private func applyStyle(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let noWrap = NSMutableParagraphStyle()
        noWrap.lineBreakMode = .byClipping
        noWrap.tabStops = []
        noWrap.defaultTabInterval = 32
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        storage.setAttributes(
            [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: noWrap],
            range: NSRange(location: 0, length: storage.length)
        )
    }

    private func resizeToFitContent(_ textView: NSTextView) {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let visibleSize = textView.enclosingScrollView?.contentView.bounds.size ?? .zero
        let targetWidth = max(used.width + textView.textContainerInset.width * 2 + 4, visibleSize.width)
        let targetHeight = max(used.height + textView.textContainerInset.height * 2 + 4, visibleSize.height)
        if abs(textView.frame.width - targetWidth) > 0.5 || abs(textView.frame.height - targetHeight) > 0.5 {
            textView.setFrameSize(NSSize(width: targetWidth, height: targetHeight))
        }
    }
}
