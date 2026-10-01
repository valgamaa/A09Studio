import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Holds the single open source file and the actions the File menu and the
/// toolbar both need (Open, Open Recent, Save). A09Studio edits one file at
/// a time with no NSDocument/multi-window architecture, so this is a plain
/// shared model -- owned once by the App and handed to ContentView -- rather
/// than a full document class. Keeping it here (instead of local @State in
/// ContentView) is what lets the app's main-menu Commands act on the same
/// state as the toolbar's Open/Save buttons.
final class EditorDocument: ObservableObject {
    private static let recentPathsKey = "recentDocumentPaths"
    private static let maxRecents = 10

    @Published var source: String = EditorDocument.sampleSource
    @Published var sourceFileURL: URL?
    @Published private(set) var recentURLs: [URL] = []

    init() {
        let savedPaths = UserDefaults.standard.stringArray(forKey: Self.recentPathsKey) ?? []
        recentURLs = savedPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func openViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "asm") ?? .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// Opens a specific file directly -- used by the Open Recent submenu.
    func open(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        source = contents
        sourceFileURL = url
        addRecent(url)
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "asm") ?? .plainText]
        panel.nameFieldStringValue = sourceFileURL?.lastPathComponent ?? "main.asm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? source.write(to: url, atomically: true, encoding: .utf8)
        sourceFileURL = url
        addRecent(url)
    }

    func clearRecents() {
        recentURLs = []
        UserDefaults.standard.removeObject(forKey: Self.recentPathsKey)
    }

    private func addRecent(_ url: URL) {
        var updated = recentURLs.filter { $0 != url }
        updated.insert(url, at: 0)
        if updated.count > Self.maxRecents {
            updated.removeLast(updated.count - Self.maxRecents)
        }
        recentURLs = updated
        UserDefaults.standard.set(updated.map(\.path), forKey: Self.recentPathsKey)
    }

    static let sampleSource = """
            ORG $1000
    START   LDA #$41
            STA $2000
            LDX #MSG
    LOOP    LDB ,X+
            BEQ DONE
            BRA LOOP
    DONE    RTS
    MSG     FCC "HELLO"
            FCB 0
            END START
    """
}
