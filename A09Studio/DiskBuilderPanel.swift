import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// "Disk Builder": pick individual FLEX program files on the Mac, choose a
/// geometry, and get a valid FLEX .dsk image the Disk Image panel can clone
/// to the CF card. All the format work lives in FlexDisk.swift (no SwiftUI);
/// this view only collects input and shows results. See "FLEX .dsk Image
/// Builder -- Feature Spec".
struct DiskBuilderPanel: View {
    /// The Assembler tab's current S19 text, and a suggested FLEX name for it.
    var assembledSRecord: String?
    var assembledName: String?
    /// Called with the saved image's URL when "Send to CF…" is pressed.
    var onSendToCF: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: Text size

    /// Scale for this panel's text and column widths. 1.0 = standard macOS
    /// sizes; 2.0 doubles them. Change this one value to adjust.
    static let scale: CGFloat = 2.0

    /// A system font at `base` standard points, scaled.
    private static func F(_ base: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: base * scale, weight: weight, design: mono ? .monospaced : .default)
    }
    /// A width or height in standard points, scaled.
    private static func W(_ x: CGFloat) -> CGFloat { x * scale }

    // MARK: Image source

    private enum ImageMode: String, CaseIterable, Identifiable {
        case new = "New image"
        case existing = "Open existing .dsk"
        var id: String { rawValue }
    }

    private static let customID = "Custom"

    @State private var mode: ImageMode = .new
    @State private var presetID: String = FlexGeometry.presets[3].name
    @State private var customTracks: Int = 40
    @State private var customSpt: Int = 18
    @State private var volumeLabel: String = "FLEXDISK"
    @State private var volumeNumber: Int = 1

    @State private var baseURL: URL?
    @State private var baseImage: FlexImage?
    /// True once files have been deleted from `baseImage` in memory.
    @State private var imageModified = false
    /// Queued files whose name matches a file on the disk replace it.
    @State private var replaceExisting = true
    @State private var pendingDelete: FlexDirEntry?
    @State private var showProtectedConfirm = false

    // MARK: Files and results

    private struct BuilderFile: Identifiable {
        let id = UUID()
        var hostName: String
        var data: Data
        var name: String
        var ext: String
        var kind: FlexFileKind
        var compress = false
        var startText = ""
        var hostHasStart = true
        var attributes: UInt8 = 0
        var stream: [UInt8] = []
        var messages: [String] = []
        var error: String? = nil

        var sectors: Int { stream.isEmpty ? 1 : (stream.count + 251) / 252 }
        var nameProblem: String? { FlexNames.validate(name: name, ext: ext) }
    }

    @State private var files: [BuilderFile] = []
    @State private var log: [String] = []
    @State private var statusMessage = ""
    @State private var lastActionFailed = false
    @State private var builtURL: URL?

    // MARK: Derived

    private var geometry: FlexGeometry? {
        if mode == .existing { return baseImage?.geometry }
        if presetID == Self.customID {
            let g = FlexGeometry(name: "Custom", tracks: customTracks, spt: customSpt)
            return g.isValid ? g : nil
        }
        return FlexGeometry.presets.first { $0.name == presetID }
    }

    private static func key(_ name: String, _ ext: String) -> String { "\(name.uppercased()).\(ext.uppercased())" }

    /// Live directory entries of the opened image.
    private var diskEntries: [FlexDirEntry] {
        guard mode == .existing, let img = baseImage else { return [] }
        return FlexDirectory.entries(in: img)
    }

    /// The disk file a queued file would clash with, if any.
    private func clash(_ f: BuilderFile) -> FlexDirEntry? {
        let k = Self.key(f.name, f.ext)
        return diskEntries.first { Self.key($0.name, $0.ext) == k }
    }

    /// True when a clash can be resolved by replacing the disk file.
    private func canReplace(_ e: FlexDirEntry) -> Bool { replaceExisting && e.attributes & 0xC0 == 0 }

    /// Queued files that will actually be written.
    private var validFiles: [BuilderFile] {
        files.filter { f in
            guard f.error == nil, f.nameProblem == nil else { return false }
            if let e = clash(f) { return canReplace(e) }
            return true
        }
    }

    /// Disk files that will be replaced, freeing their sectors and slots.
    private var replacedEntries: [FlexDirEntry] {
        let queued = Set(validFiles.map { Self.key($0.name, $0.ext) })
        return diskEntries.filter { queued.contains(Self.key($0.name, $0.ext)) }
    }

    private var freeSectors: Int {
        if mode == .existing {
            return (baseImage?.freeCount ?? 0) + replacedEntries.reduce(0) { $0 + $1.sectorCount }
        }
        return geometry?.blankFreeSectors ?? 0
    }

    private var freeSlots: Int {
        if mode == .existing, let img = baseImage {
            return FlexDirectory.freeSlotCount(in: img) + replacedEntries.count
        }
        return geometry?.directorySlots ?? 0
    }

    private var queuedSectors: Int { validFiles.reduce(0) { $0 + $1.sectors } }
    private var queuedFiles: Int { validFiles.count }

    private var canBuild: Bool {
        guard geometry != nil else { return false }
        if mode == .existing && baseImage == nil { return false }
        guard queuedFiles > 0 || (mode == .existing && imageModified) else { return false }
        return queuedSectors <= freeSectors && queuedFiles <= freeSlots
    }

    // MARK: View

    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Disk Builder → FLEX .dsk").font(Self.F(15, .bold))
                Spacer()
                Button("Close") { dismiss() }
            }

            imageSection
            if mode == .existing, baseImage != nil {
                Divider()
                diskFilesSection
            }
            Divider()
            fileSection
            capacitySection

            HStack(spacing: 8) {
                Button { build() } label: { Label("Build .dsk…", systemImage: "hammer") }
                    .disabled(!canBuild)
                Button { sendToCF() } label: { Label("Send to CF…", systemImage: "arrow.up.doc") }
                    .disabled(builtURL == nil)
                Spacer()
                Button { newImageFromFolder() } label: { Label("New Image from Folder…", systemImage: "folder.badge.gearshape") }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundStyle(lastActionFailed ? .red : .green)
                    .font(Self.F(12))
            }

            GroupBox("Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Self.F(10, mono: true)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Self.W(110), maxHeight: Self.W(160))
            }
        }
        .padding()
        }
        .font(Self.F(13))
        .controlSize(.large)
        .alert("Delete protected file?", isPresented: $showProtectedConfirm, presenting: pendingDelete) { e in
            Button("Delete", role: .destructive) { performDelete(e, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { e in
            Text("\(e.fullName) is marked \(attrText(e.attributes)). Delete it anyway?")
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { addHostURLs([url]) } }
                }
            }
            return true
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mode) {
                ForEach(ImageMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: Self.W(360))

            if mode == .new {
                HStack {
                    Text("Geometry:")
                    Picker("", selection: $presetID) {
                        ForEach(FlexGeometry.presets) { g in
                            Text("\(g.name) – \(g.sizeDescription)").tag(g.name)
                        }
                        Text("Custom…").tag(Self.customID)
                    }
                    .labelsHidden()
                    .frame(maxWidth: Self.W(330))
                }
                if presetID == Self.customID {
                    HStack {
                        Text("Tracks:")
                        TextField("", value: $customTracks, formatter: NumberFormatter())
                            .frame(width: Self.W(60)).textFieldStyle(.roundedBorder)
                        Text("Sectors/track:")
                        TextField("", value: $customSpt, formatter: NumberFormatter())
                            .frame(width: Self.W(60)).textFieldStyle(.roundedBorder)
                        if geometry == nil {
                            Label("tracks 2–256, sectors/track 5–255", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(Self.F(10))
                        }
                    }
                }
                HStack {
                    Text("Volume label:")
                    TextField("", text: $volumeLabel)
                        .frame(width: Self.W(110)).textFieldStyle(.roundedBorder)
                    Text("Volume number:")
                    TextField("", value: $volumeNumber, formatter: NumberFormatter())
                        .frame(width: Self.W(60)).textFieldStyle(.roundedBorder)
                }
                if let g = geometry {
                    Text("\(g.tracks) tracks × \(g.spt) sectors – \(g.sizeDescription), \(g.blankFreeSectors) free sectors, \(g.directorySlots) directory slots")
                        .font(Self.F(10)).foregroundStyle(.secondary)
                    if g.byteCount > 4_000_000 {
                        Text("Cloning this size over serial is slow; a smaller geometry is much quicker if your files fit.")
                            .font(Self.F(10)).foregroundStyle(.orange)
                    }
                }
            } else {
                HStack {
                    Text(baseURL?.lastPathComponent ?? "(no image selected)")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Revert") { if let u = baseURL { loadExisting(u) } }
                        .disabled(!imageModified)
                    Button("Choose…") { chooseExistingImage() }
                }
                if let img = baseImage {
                    Text("\(img.geometry.tracks) tracks × \(img.geometry.spt) sectors, volume \(img.label.isEmpty ? "(none)" : img.label), \(FlexDirectory.entries(in: img).count) file(s), \(img.freeCount) free sectors" + (imageModified ? " – changed, not saved yet" : " – verified OK"))
                        .font(Self.F(10)).foregroundStyle(imageModified ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private var diskFilesSection: some View {
        let replacing = Set(replacedEntries.map { Self.key($0.name, $0.ext) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files on disk").font(Self.F(11, .bold))
                Text("(\(diskEntries.count))").font(Self.F(10)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Replace files with the same name", isOn: $replaceExisting)
            }
            if diskEntries.isEmpty {
                Text("The disk has no files.")
                    .font(Self.F(12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("Name").frame(width: Self.W(120), alignment: .leading)
                    Text("Sectors").frame(width: Self.W(55), alignment: .trailing)
                    Text("Attr").frame(width: Self.W(44), alignment: .leading)
                    Text("Date").frame(width: Self.W(70), alignment: .leading)
                    Text("Start").frame(width: Self.W(70), alignment: .leading)
                    Spacer()
                }
                .font(Self.F(10)).foregroundStyle(.secondary)

                List {
                    ForEach(diskEntries, id: \.fullName) { e in
                        HStack(spacing: 6) {
                            Text(e.fullName).font(Self.F(13, mono: true))
                                .frame(width: Self.W(120), alignment: .leading)
                            Text("\(e.sectorCount)").frame(width: Self.W(55), alignment: .trailing)
                            Text(attrText(e.attributes)).frame(width: Self.W(44), alignment: .leading)
                            Text(String(format: "%02d-%02d-%02d", e.date.month, e.date.day, e.date.year))
                                .frame(width: Self.W(70), alignment: .leading)
                            Text(String(format: "T%02X S%02X", e.start.track, e.start.sector))
                                .font(Self.F(12, mono: true))
                                .frame(width: Self.W(70), alignment: .leading)
                            if replacing.contains(Self.key(e.name, e.ext)) {
                                Text("will be replaced").font(Self.F(10)).foregroundStyle(.orange)
                            }
                            if e.random {
                                Text("random").font(Self.F(10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { requestDelete(e) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete \(e.fullName) from the image")
                        }
                    }
                }
                .frame(minHeight: Self.W(100), maxHeight: Self.W(200))
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files to add").font(Self.F(11, .bold))
                Text("(drop files or a folder here)").font(Self.F(10)).foregroundStyle(.secondary)
                Spacer()
                Button("Add Files…") { chooseHostFiles() }
                Button("Add Assembled Output") { addAssembled() }
                    .disabled(assembledSRecord == nil)
                Button("Clear") { files.removeAll() }
                    .disabled(files.isEmpty)
            }

            if files.isEmpty {
                Text("No files yet.")
                    .font(Self.F(12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.W(60))
            } else {
                HStack(spacing: 6) {
                    Text("Name").frame(width: Self.W(90), alignment: .leading)
                    Text("Ext").frame(width: Self.W(44), alignment: .leading)
                    Text("Type").frame(width: Self.W(130), alignment: .leading)
                    Text("Sectors").frame(width: Self.W(55), alignment: .trailing)
                    Text("Attr").frame(width: Self.W(50), alignment: .leading)
                    Text("Notes").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Self.F(10)).foregroundStyle(.secondary)

                List {
                    ForEach($files) { $file in
                        fileRow($file)
                    }
                }
                .frame(minHeight: Self.W(120), maxHeight: Self.W(220))
            }
        }
    }

    private func fileRow(_ file: Binding<BuilderFile>) -> some View {
        HStack(spacing: 6) {
            TextField("", text: file.name)
                .textFieldStyle(.roundedBorder).frame(width: Self.W(90))
                .onChange(of: file.wrappedValue.name) { new in
                    let up = new.uppercased()
                    if up != new { file.wrappedValue.name = up }
                }
            TextField("", text: file.ext)
                .textFieldStyle(.roundedBorder).frame(width: Self.W(44))
                .onChange(of: file.wrappedValue.ext) { new in
                    let up = new.uppercased()
                    if up != new { file.wrappedValue.ext = up }
                }
            Picker("", selection: file.kind) {
                ForEach(FlexFileKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: Self.W(130))
            .onChange(of: file.wrappedValue.kind) { _ in recompute(file.wrappedValue.id) }

            Text("\(file.wrappedValue.sectors)").frame(width: Self.W(55), alignment: .trailing)

            Menu {
                Toggle("Write protect (W)", isOn: attrBinding(file, 0x80))
                Toggle("Delete protect (D)", isOn: attrBinding(file, 0x40))
                Toggle("Read protect (R)", isOn: attrBinding(file, 0x20))
                Toggle("Catalog protect (C)", isOn: attrBinding(file, 0x10))
            } label: {
                Text(attrText(file.wrappedValue.attributes))
            }
            .frame(width: Self.W(50))

            VStack(alignment: .leading, spacing: 1) {
                if let problem = file.wrappedValue.nameProblem {
                    Text(problem).foregroundStyle(.red)
                } else if let error = file.wrappedValue.error {
                    Text(error).foregroundStyle(.red)
                } else if let e = clash(file.wrappedValue) {
                    if canReplace(e) {
                        Text("replaces \(e.fullName) on the disk").foregroundStyle(.orange)
                    } else if e.attributes & 0xC0 != 0 {
                        Text("\(e.fullName) on the disk is protected – delete it above first").foregroundStyle(.red)
                    } else {
                        Text("\(e.fullName) already on the disk – turn on Replace").foregroundStyle(.red)
                    }
                }
                if file.wrappedValue.kind == .srecord, !file.wrappedValue.hostHasStart {
                    HStack(spacing: 4) {
                        Text("Start $")
                        TextField("hex", text: file.startText)
                            .textFieldStyle(.roundedBorder).frame(width: Self.W(60))
                            .onChange(of: file.wrappedValue.startText) { _ in recompute(file.wrappedValue.id) }
                    }
                }
                ForEach(file.wrappedValue.messages, id: \.self) { Text($0).foregroundStyle(.orange) }
            }
            .font(Self.F(10))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                files.removeAll { $0.id == file.wrappedValue.id }
            } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.borderless)
        }
    }

    private var capacitySection: some View {
        let sectorsAfter = freeSectors - queuedSectors
        let slotsAfter = freeSlots - queuedFiles
        let bad = sectorsAfter < 0 || slotsAfter < 0
        return VStack(alignment: .leading, spacing: 3) {
            if freeSectors > 0 {
                ProgressView(value: min(1.0, Double(queuedSectors) / Double(freeSectors)))
            }
            Text("\(queuedFiles) file(s), \(queuedSectors) sectors queued – \(sectorsAfter) of \(freeSectors) free sectors and \(slotsAfter) of \(freeSlots) directory slots left after build")
                .font(Self.F(10))
                .foregroundStyle(bad ? Color.red : Color.secondary)
        }
    }

    // MARK: Attribute helpers

    private func attrText(_ a: UInt8) -> String {
        var s = ""
        if a & 0x80 != 0 { s += "W" }
        if a & 0x40 != 0 { s += "D" }
        if a & 0x20 != 0 { s += "R" }
        if a & 0x10 != 0 { s += "C" }
        return s.isEmpty ? "–" : s
    }

    private func attrBinding(_ file: Binding<BuilderFile>, _ mask: UInt8) -> Binding<Bool> {
        Binding(
            get: { file.wrappedValue.attributes & mask != 0 },
            set: { on in
                if on { file.wrappedValue.attributes |= mask } else { file.wrappedValue.attributes &= ~mask }
            })
    }

    // MARK: Adding files

    private func appendLog(_ text: String) {
        log.append(text)
        if log.count > 600 { log.removeFirst(log.count - 500) }
    }

    private func chooseHostFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data, .folder]
        guard panel.runModal() == .OK else { return }
        addHostURLs(panel.urls)
    }

    private func addHostURLs(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let inside = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") }
                    .sorted { $0.lastPathComponent.uppercased() < $1.lastPathComponent.uppercased() }
                for item in inside {
                    let v = try? item.resourceValues(forKeys: [.isRegularFileKey])
                    if v?.isRegularFile == true { addHostFile(item) }
                }
            } else {
                addHostFile(url)
            }
        }
    }

    private func addHostFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            appendLog("Could not read \(url.lastPathComponent)")
            return
        }
        let kind = FlexFileConverter.detectKind(fileName: url.lastPathComponent, data: data)
        let parts = FlexNames.split(hostFileName: url.lastPathComponent)
        let ext = FlexFileConverter.defaultFlexExtension(hostExtension: parts.ext, kind: kind)
        let file = BuilderFile(hostName: url.lastPathComponent, data: data, name: parts.name, ext: ext, kind: kind)
        files.append(file)
        recompute(file.id)
    }

    private func addAssembled() {
        guard let text = assembledSRecord else { return }
        let suggested = FlexNames.sanitizeLabel(assembledName ?? "PROGRAM")
        let file = BuilderFile(hostName: "assembled.s19", data: Data(text.utf8),
                               name: suggested, ext: "CMD", kind: .srecord)
        files.append(file)
        recompute(file.id)
    }

    private func recompute(_ id: UUID) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        var f = files[i]
        f.messages = []
        f.error = nil
        var transfer: UInt16? = nil
        if f.kind == .srecord {
            f.hostHasStart = FlexFileConverter.startAddress(inHostCode: String(decoding: f.data, as: UTF8.self)) != nil
            let trimmed = f.startText.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$", with: "")
            if !trimmed.isEmpty { transfer = UInt16(trimmed, radix: 16) }
        }
        do {
            let conv = try FlexFileConverter.convert(data: f.data, kind: f.kind, compressSpaces: f.compress,
                                                     transferAddress: transfer)
            f.stream = conv.bytes
            f.messages = conv.warnings
        } catch FlexError.needsTransferAddress {
            f.stream = []
            f.error = "needs a start address"
        } catch {
            f.stream = []
            f.error = error.localizedDescription
        }
        if f.stream.isEmpty && f.error == nil { f.messages.append("empty file: one zero sector") }
        files[i] = f
    }

    // MARK: Existing image

    private func chooseExistingImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadExisting(url)
    }

    /// Loads (or reloads, for Revert) an image, discarding in-memory deletes.
    private func loadExisting(_ url: URL) {
        imageModified = false
        lastActionFailed = false
        do {
            let data = try Data(contentsOf: url)
            let image = try FlexImage(data: data)
            let report = FlexVerifier.verify(image)
            guard report.ok else {
                baseImage = nil
                baseURL = url
                statusMessage = "\(url.lastPathComponent) failed verification – not safe to add files to."
                lastActionFailed = true
                report.errors.forEach { appendLog("verification: \($0)") }
                return
            }
            baseImage = image
            baseURL = url
            statusMessage = ""
            builtURL = nil
            appendLog("Opened \(url.lastPathComponent): \(image.geometry.tracks) × \(image.geometry.spt), \(report.fileCount) file(s), \(report.freeSectors) free sectors.")
            report.warnings.forEach { appendLog("warning: \($0)") }
        } catch {
            baseImage = nil
            baseURL = url
            statusMessage = error.localizedDescription
            lastActionFailed = true
        }
    }

    private func requestDelete(_ e: FlexDirEntry) {
        if e.attributes & 0xC0 != 0 {
            pendingDelete = e
            showProtectedConfirm = true
        } else {
            performDelete(e, force: false)
        }
    }

    /// Deletes in memory only; the original .dsk is untouched until Build saves.
    private func performDelete(_ e: FlexDirEntry, force: Bool) {
        guard var img = baseImage else { return }
        do {
            let freed = try FlexAllocator.deleteFile(from: &img, name: e.name, ext: e.ext, ignoreProtection: force)
            baseImage = img
            imageModified = true
            builtURL = nil
            lastActionFailed = false
            statusMessage = "Deleted \(e.fullName) – press Build to save the changed image."
            appendLog("Deleted \(e.fullName) (\(freed) sectors freed, not saved yet)")
        } catch {
            fail("Could not delete \(e.fullName): \(error.localizedDescription)")
        }
    }

    // MARK: Build

    private func build() {
        lastActionFailed = false
        statusMessage = ""
        builtURL = nil
        var image: FlexImage
        do {
            switch mode {
            case .new:
                guard let g = geometry else { throw FlexError.badGeometry("choose a valid geometry") }
                image = try FlexImage(formatting: g, label: volumeLabel, volumeNumber: volumeNumber, date: .today)
            case .existing:
                guard let base = baseImage else { throw FlexError.notAFlexImage("no image selected") }
                image = base
            }
        } catch {
            fail(error.localizedDescription)
            return
        }

        appendLog("--- Building ---")
        var added = 0
        var addedKeys = Set<String>()
        for f in files {
            if let p = f.nameProblem { appendLog("Skipped \(f.hostName): \(p)"); continue }
            if let e = f.error { appendLog("Skipped \(f.hostName): \(e)"); continue }
            let k = Self.key(f.name, f.ext)
            let shown = f.ext.isEmpty ? f.name.uppercased() : k
            if addedKeys.contains(k) { appendLog("Skipped \(f.hostName): \(shown) is queued twice"); continue }
            do {
                // Work on a copy so a failed add never loses the file it replaces.
                var trial = image
                if mode == .existing, FlexDirectory.contains(name: f.name, ext: f.ext, in: trial) {
                    guard replaceExisting else { throw FlexError.duplicateName(shown) }
                    let freed = try FlexAllocator.deleteFile(from: &trial, name: f.name, ext: f.ext)
                    appendLog("Replacing \(shown) (\(freed) old sectors freed)")
                }
                let w = try FlexAllocator.addFile(to: &trial, name: f.name, ext: f.ext, stream: f.stream,
                                                  attributes: f.attributes, date: .today)
                image = trial
                addedKeys.insert(k)
                added += 1
                appendLog("Added \(f.name).\(f.ext) (\(f.sectors) sectors)")
                f.messages.forEach { appendLog("  note: \($0)") }
                w.forEach { appendLog("  note: \($0)") }
            } catch {
                appendLog("Skipped \(f.hostName): \(error.localizedDescription)")
            }
        }
        let changedOnly = mode == .existing && imageModified
        guard added > 0 || changedOnly else { fail("Nothing was added."); return }

        let report = FlexVerifier.verify(image)
        report.warnings.forEach { appendLog("warning: \($0)") }
        guard report.ok else {
            report.errors.forEach { appendLog("verification: \($0)") }
            fail("Verification failed – the image was not saved.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dsk") ?? .data]
        if mode == .existing, let base = baseURL {
            panel.directoryURL = base.deletingLastPathComponent()
            panel.nameFieldStringValue = base.deletingPathExtension().lastPathComponent + "-new.dsk"
        } else {
            panel.nameFieldStringValue = FlexNames.sanitizeLabel(volumeLabel) + ".dsk"
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            appendLog("Save cancelled.")
            return
        }
        do {
            try image.data.write(to: url)
            builtURL = url
            statusMessage = "Saved \(url.lastPathComponent): \(added) file(s) added, \(image.freeCount) free sectors left."
            appendLog("Saved \(url.path) (\(image.bytes.count) bytes). Verified OK.")
            if mode == .existing {
                // Carry on from the saved image so the list shows what is on it now.
                baseImage = image
                baseURL = url
                imageModified = false
                files.removeAll()
            }
        } catch {
            fail("Could not save: \(error.localizedDescription)")
        }
    }

    private func newImageFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Build"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        lastActionFailed = false
        builtURL = nil
        appendLog("--- Image from folder \(folder.lastPathComponent) ---")
        let result = FlexDiskBuilder.buildFromFolder(folder)
        result.summary.skipped.forEach { appendLog("Skipped \($0.name): \($0.reason)") }
        result.summary.warnings.forEach { appendLog("note: \($0)") }
        guard let image = result.image, let g = result.summary.geometry else {
            fail("Could not build an image from \(folder.lastPathComponent) – see the log.")
            return
        }
        let url = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".dsk")
        do {
            try image.data.write(to: url)
            builtURL = url
            appendLog("Added \(result.summary.added.count) file(s): \(result.summary.added.joined(separator: ", "))")
            appendLog("Geometry: \(g.name) (\(g.tracks) × \(g.spt)); \(result.summary.freeAfter) free sectors left.")
            appendLog("Saved \(url.path)")
            statusMessage = "Built \(url.lastPathComponent): \(result.summary.added.count) file(s), \(result.summary.skipped.count) skipped."
        } catch {
            fail("Could not save: \(error.localizedDescription)")
        }
    }

    private func sendToCF() {
        guard let url = builtURL else { return }
        onSendToCF(url)
    }

    private func fail(_ message: String) {
        statusMessage = message
        lastActionFailed = true
        appendLog(message)
    }
}

#Preview {
    DiskBuilderPanel(assembledSRecord: nil, assembledName: nil, onSendToCF: { _ in })
        .frame(width: 1600, height: 1300)
}
