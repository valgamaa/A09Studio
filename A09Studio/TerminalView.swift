import SwiftUI
import AppKit

/// A minimal serial terminal: pick a /dev/cu.* port and baud, connect, and
/// exchange raw text with whatever's on the other end -- the SBC's own
/// console UART in this case. Also offers a one-button "Download (S9)"
/// that streams a Motorola S-record image to the target, line by line, so
/// Assemble -> Program or Assemble -> Download both become a single click
/// once the port is open. By default that's the most recently assembled
/// build's own S-record output, but "Load File..." can point Download at
/// any other .s19/.s09/.srec/.mot file instead -- e.g. a pre-built image
/// (like a stock FLEX binary) you don't have the source for, so it can be
/// tried out over serial without burning it to ROM first.
///
/// Keystrokes go straight to the serial port as you type, like a real
/// terminal app (Terminal.app, screen, minicom) -- there's no separate
/// input line to type into and press Return on. A transparent
/// KeyCaptureView sits behind the scrolling console and forwards raw key
/// presses to the port; what you see echoed back is whatever the target
/// sends (the SBC's own console driver already echoes typed characters).
struct TerminalView: View {
    /// Owned by ContentView (not this view) and passed in, so the Disk
    /// Image panel can drive the same already-open connection instead of
    /// opening a second, competing one to the same port.
    @ObservedObject var port: SerialPortManager
    @ObservedObject private var settings = AppSettings.shared

    /// The S-record text from the most recent successful build, supplied
    /// by ContentView (which owns the AssemblerResult). Nil until a build
    /// has produced one.
    var sRecord: String?

    @State private var selectedPort: String = ""
    @State private var baud: Int = AppSettings.shared.serialDefaultBaud
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = ""
    @State private var keyCaptureRef = KeyCaptureRef()
    /// An explicitly-loaded S-record file that overrides `sRecord` (the
    /// last build) for Download -- nil means "use the last build", the
    /// normal case.
    @State private var loadedFile: (name: String, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Port", selection: $selectedPort) {
                    Text("Select…").tag("")
                    ForEach(port.availablePorts, id: \.self) { path in
                        Text((path as NSString).lastPathComponent).tag(path)
                    }
                }
                .frame(minWidth: 220)
                Button {
                    port.refreshPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh port list")

                Picker("Baud", selection: $baud) {
                    ForEach([300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400], id: \.self) { rate in
                        Text("\(rate)").tag(rate)
                    }
                }
                .frame(width: 140)

                if port.isConnected {
                    Button("Disconnect") { port.disconnect() }
                } else {
                    Button("Connect") {
                        guard !selectedPort.isEmpty else { return }
                        port.connect(path: selectedPort, baud: baud)
                        keyCaptureRef.focus()
                    }
                    .disabled(selectedPort.isEmpty)
                }

                Spacer()

                Button {
                    copyConsoleToPasteboard()
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }
                .disabled(port.receivedText.isEmpty)
                .help("Copy the console contents to the clipboard")

                Button {
                    Task { await downloadSRecord() }
                } label: {
                    if isDownloading {
                        ProgressView(value: downloadProgress).frame(width: 100)
                    } else {
                        Label("Download (S9)", systemImage: "arrow.down.doc")
                    }
                }
                .disabled(!port.isConnected || effectiveSRecord == nil || isDownloading)
                .help(downloadHelpText)

                Button {
                    loadFile()
                } label: {
                    Label("Load File…", systemImage: "doc.badge.plus")
                }
                .help("Load a .s19/.s09/.srec/.mot file to Download instead of the last build -- e.g. a pre-built image you don't have the source for")

                if let loadedFile {
                    Text(loadedFile.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140)
                    Button {
                        self.loadedFile = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear the loaded file -- Download will use the last build again")
                }
            }

            if let error = port.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if !downloadStatus.isEmpty {
                Text(downloadStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    Text(consoleText)
                        .font(.system(size: 20, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                // KeyCaptureView only ever receives key-down events -- it's
                // mouse-transparent (see KeyCaptureNSView.hitTest), so it
                // can sit right on top of the ScrollView without stealing
                // the scroll wheel or the scrollbar from it. Click-to-focus
                // is handled separately below via a plain SwiftUI tap
                // gesture, which (unlike an NSView catching mouseDown)
                // doesn't interfere with ScrollView's own scroll gesture.
                .overlay(KeyCaptureView(ref: keyCaptureRef, onKeyDown: handleKeyDown))
                .contentShape(Rectangle())
                .onTapGesture { keyCaptureRef.focus() }
                .onChange(of: port.receivedText) { _ in
                    scrollProxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: port.isConnected) { connected in
                    if connected { keyCaptureRef.focus() }
                }
            }

            Text(port.isConnected ? "Connected -- click the console and type. Return sends \(settings.serialLineEnding.rawValue)." : "Not connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            port.refreshPorts()
            baud = settings.serialDefaultBaud
        }
    }

    private var consoleText: String {
        port.receivedText.isEmpty ? "Not connected." : port.receivedText
    }

    /// What Download actually sends: an explicitly-loaded file if there is
    /// one, otherwise the last build's own S-record output.
    private var effectiveSRecord: String? {
        loadedFile?.text ?? sRecord
    }

    private var downloadHelpText: String {
        if let loadedFile {
            return "Send the loaded file (\(loadedFile.name)) to the target"
        }
        return sRecord == nil
            ? "Assemble successfully first to produce an S-record image, or use Load File… to pick one"
            : "Send the last build's S-record output to the target"
    }

    /// Lets Download send an S-record file that didn't come from this app's
    /// own assembler -- e.g. a pre-built binary (a stock FLEX image, say)
    /// you only have as a .s19/.s09 dump with no source to reassemble.
    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            downloadStatus = "Couldn't read \(url.lastPathComponent) as text."
            return
        }
        loadedFile = (name: url.lastPathComponent, text: text)
        downloadStatus = ""
    }

    /// Copies the raw console contents to the clipboard. A dedicated button
    /// instead of `.textSelection(.enabled)` on the console `Text` -- making
    /// that view participate in AppKit's native text-interaction system
    /// competed with KeyCaptureNSView for keyboard focus/click handling and
    /// made typing into the terminal unreliable.
    private func copyConsoleToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(port.receivedText, forType: .string)
    }

    /// Forwards a raw key press to the serial port, the way a real terminal
    /// emulator would -- no line buffering, no separate input field.
    ///
    /// A handful of keys are pinned to their physical keyCode rather than
    /// trusting NSEvent.characters for them: Return needs the *configured*
    /// line ending (Settings > Terminal), not whatever raw byte AppKit
    /// happens to report, and pinning Space/Tab/Delete to their well-known
    /// ASCII bytes sidesteps any surprises from `characters` under unusual
    /// keyboard layouts or input sources. Everything else falls through to
    /// `characters`, decoded as Latin-1 to match how received bytes are
    /// decoded; arrow keys and other multi-byte escape sequences aren't
    /// translated, since the SBC's simple monitor console has no use for
    /// them.
    private func handleKeyDown(_ event: NSEvent) {
        guard port.isConnected else { return }

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            if settings.serialLocalEcho {
                port.receivedText.append("\n")
            }
            port.sendRaw(Data(settings.serialLineEnding.bytes))
            return
        case 51, 117: // Delete (Backspace) / Forward Delete
            sendAndMaybeEcho(Data([0x7F]))
            return
        case 48: // Tab
            sendAndMaybeEcho(Data([0x09]))
            return
        case 49: // Space
            sendAndMaybeEcho(Data([0x20]))
            return
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty else { return }
        var data = Data()
        for scalar in characters.unicodeScalars where scalar.value < 256 {
            data.append(UInt8(scalar.value))
        }
        guard !data.isEmpty else { return }
        sendAndMaybeEcho(data)
    }

    private func sendAndMaybeEcho(_ data: Data) {
        if settings.serialLocalEcho, let echoText = String(data: data, encoding: .isoLatin1) {
            port.receivedText.append(echoText)
        }
        port.sendRaw(data)
    }

    /// Streams the S-record text to the target one line at a time, with a
    /// configurable inter-line delay (Settings > Terminal) since many
    /// simple monitor firmwares have no flow control and can drop bytes
    /// sent back-to-back at speed. If a download prefix is configured
    /// (Settings > Terminal > S-Record Download), it's sent first as its
    /// own line -- e.g. whatever command puts your monitor into load mode
    /// -- with the same inter-line delay before the S-record stream starts.
    private func downloadSRecord() async {
        guard let effectiveSRecord, port.isConnected else { return }
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "Downloading…"
        defer {
            isDownloading = false
        }

        let lines = effectiveSRecord.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            downloadStatus = "Nothing to send -- S-record output was empty."
            return
        }

        let delayNanoseconds = UInt64(AppSettings.shared.serialDownloadLineDelayMs) * 1_000_000

        let prefix = AppSettings.shared.serialDownloadPrefix
        if !prefix.isEmpty {
            var prefixData = Data(prefix.utf8)
            prefixData.append(contentsOf: AppSettings.shared.serialLineEnding.bytes)
            port.sendRaw(prefixData)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        for (index, line) in lines.enumerated() {
            var data = Data(line.utf8)
            data.append(contentsOf: AppSettings.shared.serialLineEnding.bytes)
            port.sendRaw(data)
            downloadProgress = Double(index + 1) / Double(lines.count)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        downloadStatus = "Download complete -- sent \(lines.count) S-record line\(lines.count == 1 ? "" : "s")."
    }
}

/// Holds a weak reference to the live KeyCaptureNSView so SwiftUI code
/// (the Connect button, an onChange handler, a tap gesture) can explicitly
/// ask it to become first responder, instead of relying on an implicit
/// side-effect buried in a view update -- SwiftUI can restore focus to a
/// button after its action runs, which raced with and beat an automatic
/// focus grab in an earlier version of this view.
final class KeyCaptureRef {
    weak var view: KeyCaptureNSView?

    func focus() {
        // Dispatch async, and slightly deferred, so this runs after
        // SwiftUI's own post-action focus handling (e.g. restoring focus to
        // the button that was just clicked) rather than racing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let view = self?.view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// An NSView that grabs raw key-down events and forwards them, rather than
/// accumulating them into an editable text field. It's overlaid on top of
/// the console, but `hitTest` makes it invisible to the mouse -- clicks,
/// the scroll wheel, and scrollbar dragging all pass straight through to
/// whatever's underneath (the ScrollView). Focus is granted purely
/// programmatically (via KeyCaptureRef), never by this view intercepting a
/// click itself.
private struct KeyCaptureView: NSViewRepresentable {
    var ref: KeyCaptureRef
    var onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        ref.view = view
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        ref.view = nsView
    }
}

final class KeyCaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Mouse-transparent: returning nil tells AppKit "nothing here", so hit
    /// testing (mouseDown, scrollWheel, scrollbar dragging -- anything
    /// mouse-driven) falls through to the real view underneath this one in
    /// the stack. Only makeFirstResponder (called explicitly elsewhere)
    /// gives this view keyboard focus; it never grabs the mouse itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }
}

#Preview {
    TerminalView(port: SerialPortManager(), sRecord: nil)
}
