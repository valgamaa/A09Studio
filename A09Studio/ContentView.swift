import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var document: EditorDocument

    @State private var isAssembling = false
    @State private var lastResult: AssemblerResult?
    @State private var selectedOutputTab: OutputTab = .listing
    @State private var showDiskImage = false
    // Kept alive here (not recreated per click) so re-clicking "Programmer…"
    // brings the same movable window back to front instead of opening a
    // second one -- see FloatingPanel.
    @State private var programmerWindow = FloatingPanel<ProgrammerPanel>()

    @StateObject private var programmerRunner = ProgrammerRunner()
    // Owned here (not by TerminalView) so the Disk Image panel can drive
    // the same already-open serial connection instead of opening a second
    // one to the same port.
    @StateObject private var port = SerialPortManager()

    private let assembler = AssemblerRunner()

    enum OutputTab: String, CaseIterable, Identifiable {
        case listing = "Listing"
        case diagnostics = "Errors/Warnings"
        var id: String { rawValue }
    }

    var body: some View {
        TabView {
            assemblerTab
                .tabItem { Label("Assembler", systemImage: "hammer") }
            TerminalView(port: port, sRecord: lastResult?.sRecord)
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var assemblerTab: some View {
        NavigationSplitView {
            EmptyView()
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                HSplitView {
                    CodeEditorView(text: $document.source)
                        .frame(minWidth: 420)
                    outputPane
                        .frame(minWidth: 360)
                }
            }
        }
        .navigationTitle(document.sourceFileURL?.lastPathComponent ?? "Untitled.asm")
        .sheet(isPresented: $showDiskImage) {
            DiskImagePanel(port: port)
                .frame(width: 560, height: 560)
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                document.openViaPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            Button {
                document.save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }

            Divider().frame(height: 20)

            Button {
                Task { await assemble() }
            } label: {
                if isAssembling {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Assemble", systemImage: "hammer")
                }
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(isAssembling)

            Spacer()

            Button {
                programmerWindow.show(title: "TL866 Programmer", defaultSize: CGSize(width: 640, height: 620)) {
                    ProgrammerPanel(runner: programmerRunner, assembledBinary: lastResult?.binary)
                }
            } label: {
                Label("Programmer…", systemImage: "cpu")
            }

            Button {
                showDiskImage = true
            } label: {
                Label("Disk Image…", systemImage: "opticaldiscdrive")
            }

            if let result = lastResult {
                statusBadge(for: result)
            }
        }
        .padding(8)
    }

    private func statusBadge(for result: AssemblerResult) -> some View {
        let errorCount = result.diagnostics.filter { $0.severity == .error }.count
        let warningCount = result.diagnostics.filter { $0.severity == .warning }.count
        return HStack(spacing: 6) {
            if result.succeeded {
                Label("Build OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Build failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            if errorCount > 0 {
                Text("\(errorCount) error\(errorCount == 1 ? "" : "s")").foregroundStyle(.red)
            }
            if warningCount > 0 {
                Text("\(warningCount) warning\(warningCount == 1 ? "" : "s")").foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private var outputPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedOutputTab) {
                ForEach(OutputTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch selectedOutputTab {
            case .listing:
                // SwiftUI's Text + ScrollView combination proved unable to
                // reliably suppress word-wrap for this content -- see
                // PlainTextDisplayView for why this uses the same
                // NSTextView-based approach as the source editor instead.
                PlainTextDisplayView(
                    text: Self.unwrapListingComments(lastResult?.listing ?? "Assemble (⌘B) to see the listing here."),
                    fontSize: 20
                )
            case .diagnostics:
                List(lastResult?.diagnostics ?? []) { diag in
                    HStack(alignment: .top) {
                        Image(systemName: diag.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(diag.severity == .error ? .red : .orange)
                        VStack(alignment: .leading) {
                            if let line = diag.line {
                                Text("Line \(line)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(diag.message).font(.system(.callout, design: .monospaced))
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    /// a09's own listing formatter wraps a source line's comment onto the
    /// very next physical row -- with no address/opcode columns, just the
    /// bare ";..." text -- whenever the code portion already fills the
    /// listing's fixed column width and leaves no room for it (an a09
    /// limitation; not something this view's layout controls). Heuristically
    /// stitching such a line back onto the row above makes the listing far
    /// more readable at a small risk of being wrong in rarer cases: a line
    /// that starts with ";" is appended to the previous line whenever that
    /// previous line doesn't already contain a comment of its own -- if it
    /// did, two consecutive standalone comment lines is more likely than a
    /// wrapped one.
    private static func unwrapListingComments(_ listing: String) -> String {
        var result: [String] = []
        for line in listing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";"), let previous = result.last, !previous.contains(";") {
                result[result.count - 1] = previous + " " + trimmed
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private func assemble() async {
        isAssembling = true
        defer { isAssembling = false }
        do {
            var result = try await assembler.assemble(source: document.source, sourceFileName: document.sourceFileURL?.lastPathComponent ?? "main.asm")
            saveIntelHexNextToSource(&result)
            lastResult = result
            selectedOutputTab = result.succeeded ? .listing : .diagnostics
        } catch {
            lastResult = AssemblerResult(succeeded: false, diagnostics: [
                AssemblerDiagnostic(severity: .error, line: nil, message: error.localizedDescription)
            ], listing: "", binary: nil, rawOutput: "")
            selectedOutputTab = .diagnostics
        }
    }

    /// Writes the just-built Intel Hex out next to the source file (same
    /// name, ".hex" extension) so it's somewhere natural to find afterward
    /// -- the assembler's own temp working directory is deleted the moment
    /// assemble() returns (see AssemblerRunner), so without this it only
    /// ever existed in memory. Intel Hex rather than the S-record: it's
    /// what the Programmer panel's srec_cat combine step handles most
    /// directly, since each byte's address is already embedded in the file
    /// rather than needing a separately-typed base address. Best-effort:
    /// appends a warning diagnostic rather than failing the whole build if
    /// it can't be written (source not yet saved to disk, or a permissions
    /// problem).
    private func saveIntelHexNextToSource(_ result: inout AssemblerResult) {
        guard let intelHex = result.intelHex else { return }
        guard let sourceURL = document.sourceFileURL else {
            result.diagnostics.append(AssemblerDiagnostic(
                severity: .warning, line: nil,
                message: "Intel Hex not saved to disk -- save the source file first to give it somewhere to go."
            ))
            return
        }
        let hexURL = sourceURL.deletingPathExtension().appendingPathExtension("hex")
        do {
            try intelHex.write(to: hexURL, atomically: true, encoding: .utf8)
        } catch {
            result.diagnostics.append(AssemblerDiagnostic(
                severity: .warning, line: nil,
                message: "Couldn't save Intel Hex to \(hexURL.lastPathComponent): \(error.localizedDescription)"
            ))
        }
    }

}

#Preview {
    ContentView(document: EditorDocument())
}
