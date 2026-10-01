import SwiftUI
import UniformTypeIdentifiers

/// One file to be programmed, and where its first byte should land in the
/// combined image. A single file with base address 0 needs no relocation
/// and is handed to minipro as-is; anything else (more than one file, or a
/// non-zero base) goes through srec_cat first to produce one combined
/// Intel HEX image.
struct ProgrammerInputFile: Identifiable {
    let id = UUID()
    var url: URL
    /// Extra per-file adjustment on top of the panel's single PROM base
    /// address (see ProgrammerPanel.promBaseAddressHex) -- almost always
    /// left at the "0000" default; only needed if this particular file
    /// needs relocating somewhere other than "its own real address minus
    /// the PROM base".
    var baseAddressHex: String = "0000"

    var baseAddress: Int32 {
        Self.parseSignedHex(baseAddressHex)
    }

    /// Parses text like "8000", "0x8000", or "-8000" -- with or without a
    /// leading "0x", and optionally a leading "-" -- into a signed value,
    /// defaulting to 0 for anything that doesn't parse. Signed because
    /// srec_cat's own "-offset" is signed: relocating an already-addressed
    /// hex/S-record file *downward* (e.g. shifting a09's "-x" output at
    /// $F800 down to $7800 for a 32K EEPROM's own local address space)
    /// needs a negative offset, exactly as it would typed on the command
    /// line ("-offset -0x8000"). Address fields are edited as free text,
    /// so this has to tolerate a momentarily-invalid/empty value while the
    /// user is still typing.
    static func parseSignedHex(_ text: String) -> Int32 {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if cleaned.hasPrefix("-") {
            negative = true
            cleaned.removeFirst()
        }
        cleaned = cleaned.replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
        guard let magnitude = UInt32(cleaned, radix: 16) else { return 0 }
        let value = Int32(bitPattern: magnitude)
        return negative ? -value : value
    }
}

/// Panel for programming an EPROM/EEPROM on the TL866 via minipro, using
/// the most recently assembled binary and/or one or more separately chosen
/// files, each optionally relocated to its own base address via srec_cat.
struct ProgrammerPanel: View {
    @ObservedObject var runner: ProgrammerRunner
    var assembledBinary: Data?

    @State private var device: String = AppSettings.shared.programmerDevice
    @State private var programmerVersion: String = AppSettings.shared.programmerVersion
    @State private var programmerVersions: [String] = []
    @State private var deviceSuggestions: [String] = []
    @State private var deviceSearchTask: Task<Void, Never>?
    @State private var showDeviceSuggestions = false
    @State private var files: [ProgrammerInputFile] = []
    @State private var promBaseAddressHex: String = AppSettings.shared.programmerPromBaseAddress
    @State private var srecordRunner = SrecordRunner()
    @State private var statusMessage: String = ""
    @State private var lastActionFailed = false
    // Kept alive here so a second "Read" reuses the same movable window
    // (updating its contents) instead of piling up copies -- see FloatingPanel.
    @State private var hexWindow = FloatingPanel<HexViewerView>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TL866 Programmer").font(.title2).bold()

            HStack {
                Text("Programmer:").font(.title3)
                Picker("", selection: $programmerVersion) {
                    Text("Auto-detect").tag("")
                    ForEach(programmerVersions, id: \.self) { version in
                        Text(version).tag(version)
                    }
                }
                .labelsHidden()
                .font(.title3)
                .frame(width: 200)
                .onChange(of: programmerVersion) { newValue in
                    AppSettings.shared.programmerVersion = newValue
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Chip:").font(.title3)
                    TextField("Type to search minipro's device list…", text: $device)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .onChange(of: device) { newValue in
                            AppSettings.shared.programmerDevice = newValue
                            searchDevices(for: newValue)
                        }
                }
                // Live results from minipro's own "-L <query>" search --
                // there are 13,000+ devices in its full database, so this
                // only ever fetches a filtered slice, never the whole list.
                if showDeviceSuggestions, !deviceSuggestions.isEmpty {
                    GroupBox {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(deviceSuggestions, id: \.self) { suggestion in
                                    Button {
                                        device = suggestion
                                        AppSettings.shared.programmerDevice = suggestion
                                        showDeviceSuggestions = false
                                    } label: {
                                        Text(suggestion)
                                            .font(.system(.title3, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Files:").font(.title3)
                    Spacer()
                    Button("Add Last Build") { addLastBuild() }
                        .font(.title3)
                        .disabled(assembledBinary == nil)
                    Button("Add Files…") { addFiles() }
                        .font(.title3)
                }

                // A single PROM base address, subtracted from every already-
                // addressed (.hex/.s19) file below via srec_cat -- e.g. "8000"
                // for a chip mapped at $8000 in the board's memory map, so a
                // file carrying the board's real addresses lands correctly in
                // the chip's own 0-based address space. Leave at 0 (the
                // default) if your files are already addressed the way the
                // chip expects, or if you're only burning raw binaries placed
                // via their own per-file Base field below.
                HStack {
                    Text("PROM Base 0x:").font(.title3)
                    TextField("0000", text: $promBaseAddressHex)
                        .font(.system(.title3, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: promBaseAddressHex) { newValue in
                            AppSettings.shared.programmerPromBaseAddress = newValue
                        }
                    Text("subtracted from every file's addresses below")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if files.isEmpty {
                    Text("No files added yet — Write/Verify need at least one.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    // One row per file: its name, an editable base address
                    // (where its first byte lands in the combined image --
                    // srec_cat's "-offset"), and a remove button. More than
                    // one file, or any non-zero base address, triggers the
                    // srec_cat combine step in perform(); a single file left
                    // at base 0 skips it and goes to minipro as a plain
                    // binary, same as before this feature existed.
                    VStack(spacing: 4) {
                        ForEach($files) { $file in
                            HStack {
                                Text(file.url.lastPathComponent)
                                    .font(.system(.title3, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("Base 0x").font(.title3).foregroundStyle(.secondary)
                                TextField("0000", text: $file.baseAddressHex)
                                    .font(.system(.title3, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                                Button {
                                    files.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if srecordRunner.resolveSrecCatPath() == nil {
                    Label("srec_cat not found — install with `brew install srecord` (only needed for multiple files or a non-zero base address)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.title3)
                }
            }

            HStack(spacing: 8) {
                actionButton("Identify", action: .identify, needsFile: false)
                actionButton("Read", action: .read, needsFile: false)
                actionButton("Write", action: .write, needsFile: true)
                actionButton("Verify", action: .verify, needsFile: true)
                actionButton("Erase", action: .erase, needsFile: false)
            }

            if runner.isBusy {
                ProgressView(value: runner.lastProgress)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundStyle(lastActionFailed ? .red : .green)
                    .font(.title3)
            }

            GroupBox("Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(runner.log) { line in
                            Text(line.text)
                                .font(.system(.title3, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140)
            }

            if runner.resolveMiniproPath() == nil {
                Label("minipro not found — install with `brew install minipro`", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.title3)
            }
        }
        .padding()
        .task {
            programmerVersions = await runner.listProgrammerVersions()
        }
        .onChange(of: runner.detectedProgrammerVersion) { detected in
            // minipro just told us (via its own connect banner, e.g. from
            // pressing Identify) exactly which unit is plugged in -- prefer
            // that over whatever was picked/left on Auto-detect, and
            // refresh the search filter to match.
            guard let detected else { return }
            programmerVersion = detected
            AppSettings.shared.programmerVersion = detected
            if !programmerVersions.contains(detected) {
                programmerVersions.append(detected)
            }
            searchDevices(for: device)
        }
    }

    private func actionButton(_ title: String, action: ProgrammerAction, needsFile: Bool) -> some View {
        Button(title) {
            Task { await perform(action, needsFile: needsFile) }
        }
        .font(.title2)
        .controlSize(.large)
        .disabled(runner.isBusy || (needsFile && !hasUsableFile))
    }

    private var hasUsableFile: Bool {
        !files.isEmpty
    }

    /// Debounced live search against minipro's own device database
    /// ("-L <query>"). Cancels any in-flight search first, so fast typing
    /// doesn't pile up overlapping minipro processes -- only the last
    /// keystroke's search actually runs.
    private func searchDevices(for query: String) {
        deviceSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            deviceSuggestions = []
            showDeviceSuggestions = false
            return
        }
        deviceSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms debounce
            guard !Task.isCancelled else { return }
            let results = (try? await runner.searchDevices(matching: trimmed, programmerVersion: programmerVersion)) ?? []
            guard !Task.isCancelled else { return }
            deviceSuggestions = Array(results.prefix(30)) // keep the popover short
            showDeviceSuggestions = !deviceSuggestions.isEmpty
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            files.append(ProgrammerInputFile(url: url))
        }
    }

    /// Spills the in-memory assembled binary to a temp file and adds it to
    /// the list, same as any other file -- its base address defaults to 0
    /// and is just as editable, in case it needs relocating alongside
    /// whatever else is in the list.
    private func addLastBuild() {
        guard let data = assembledBinary else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("a09studio-program-\(UUID().uuidString).bin")
        guard (try? data.write(to: tmp)) != nil else {
            statusMessage = "Couldn't write the last build to a temp file."
            lastActionFailed = true
            return
        }
        files.append(ProgrammerInputFile(url: tmp))
    }

    private func perform(_ action: ProgrammerAction, needsFile: Bool) async {
        statusMessage = ""
        do {
            var fileURL: URL?
            var fileFormat = ""

            if needsFile {
                guard !files.isEmpty else {
                    statusMessage = "Add at least one file first."
                    lastActionFailed = true
                    return
                }
                let promBase = ProgrammerInputFile.parseSignedHex(promBaseAddressHex)

                if files.count == 1, files[0].baseAddress == 0, promBase == 0 {
                    // No relocation needed -- skip srec_cat entirely and
                    // hand the file to minipro as-is, telling it the format
                    // explicitly for anything that isn't a plain binary
                    // (minipro doesn't reliably guess from the extension).
                    fileURL = files[0].url
                    switch SrecordRunner.InputKind.inferring(from: files[0].url) {
                    case .binary: fileFormat = ""
                    case .intelHex: fileFormat = "ihex"
                    case .motorolaSRecord: fileFormat = "srec"
                    }
                } else {
                    // More than one file, and/or a non-zero base address
                    // (per-file and/or the panel's single PROM base):
                    // combine via srec_cat into a single Motorola S-record
                    // image. Each file's actual offset is its own per-file
                    // Base (almost always left at 0) minus the shared PROM
                    // base address, so setting just the PROM base once
                    // shifts every already-addressed file down into the
                    // chip's own local address space without retyping
                    // "-8000" (with its sign) into each file individually.
                    // The combined output is S-record, not Intel Hex --
                    // minipro has proven unreliable reading Intel Hex here
                    // (a crash on a full-chip image, a bare non-zero exit
                    // on a much smaller one), while S-record has worked
                    // every time, so this sidesteps that entirely. See
                    // SrecordRunner.combine()'s doc comment.
                    let combined = FileManager.default.temporaryDirectory
                        .appendingPathComponent("a09studio-combined-\(UUID().uuidString).s19")
                    try srecordRunner.combine(
                        files.map { (url: $0.url, baseAddress: $0.baseAddress - promBase) },
                        outputURL: combined
                    )
                    fileURL = combined
                    fileFormat = "srec"
                }
            }

            // For a plain "read", pull the chip into a temp file first -- the
            // hex viewer (opened below on success) is what the user actually
            // saves from, rather than picking a destination up front before
            // there's anything to look at.
            if action == .read, fileURL == nil {
                fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("a09studio-read-\(UUID().uuidString).bin")
            }

            let ok = try await runner.run(action: action, device: device, programmerVersion: programmerVersion, fileFormat: fileFormat, fileURL: fileURL)
            lastActionFailed = !ok
            statusMessage = ok ? "\(actionVerb(action)) succeeded." : "\(actionVerb(action)) failed — see log."

            if ok, action == .read, let fileURL {
                if let data = try? Data(contentsOf: fileURL) {
                    let filename = "\(device.isEmpty ? "dump" : device).bin"
                    hexWindow.show(title: "Chip Read", defaultSize: CGSize(width: 980, height: 560)) {
                        HexViewerView(data: data, suggestedFilename: filename)
                    }
                } else {
                    statusMessage = "Read succeeded, but the dump file couldn't be loaded for viewing."
                    lastActionFailed = true
                }
            }
        } catch {
            lastActionFailed = true
            statusMessage = error.localizedDescription
        }
    }

    private func actionVerb(_ action: ProgrammerAction) -> String {
        switch action {
        case .read: return "Read"
        case .write: return "Write"
        case .verify: return "Verify"
        case .erase: return "Erase"
        case .identify: return "Identify"
        }
    }
}
