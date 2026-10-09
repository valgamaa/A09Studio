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

    private var freeSectors: Int {
        if mode == .existing { return baseImage?.freeCount ?? 0 }
        return geometry?.blankFreeSectors ?? 0
    }

    private var freeSlots: Int {
        if mode == .existing, let img = baseImage { return FlexDirectory.freeSlotCount(in: img) }
        return geometry?.directorySlots ?? 0
    }

    private var queuedSectors: Int { files.filter { $0.error == nil && $0.nameProblem == nil }.reduce(0) { $0 + $1.sectors } }
    private var queuedFiles: Int { files.filter { $0.error == nil && $0.nameProblem == nil }.count }

    private var canBuild: Bool {
        guard geometry != nil, queuedFiles > 0 else { return false }
        if mode == .existing && baseImage == nil { return false }
        return queuedSectors <= freeSectors && queuedFiles <= freeSlots
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Disk Builder → FLEX .dsk").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }

            imageSection
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
                    .font(.callout)
            }

            GroupBox("Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 110)
            }
        }
        .padding()
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
            .frame(maxWidth: 360)

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
                    .frame(maxWidth: 330)
                }
                if presetID == Self.customID {
                    HStack {
                        Text("Tracks:")
                        TextField("", value: $customTracks, formatter: NumberFormatter())
                            .frame(width: 60).textFieldStyle(.roundedBorder)
                        Text("Sectors/track:")
                        TextField("", value: $customSpt, formatter: NumberFormatter())
                            .frame(width: 60).textFieldStyle(.roundedBorder)
                        if geometry == nil {
                            Label("tracks 2–256, sectors/track 5–255", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    }
                }
                HStack {
                    Text("Volume label:")
                    TextField("", text: $volumeLabel)
                        .frame(width: 110).textFieldStyle(.roundedBorder)
                    Text("Volume number:")
                    TextField("", value: $volumeNumber, formatter: NumberFormatter())
                        .frame(width: 60).textFieldStyle(.roundedBorder)
                }
                if let g = geometry {
                    Text("\(g.tracks) tracks × \(g.spt) sectors – \(g.sizeDescription), \(g.blankFreeSectors) free sectors, \(g.directorySlots) directory slots")
                        .font(.caption).foregroundStyle(.secondary)
                    if g.byteCount > 4_000_000 {
                        Text("Cloning this size over serial is slow; a smaller geometry is much quicker if your files fit.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                HStack {
                    Text(baseURL?.lastPathComponent ?? "(no image selected)")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseExistingImage() }
                }
                if let img = baseImage {
                    Text("\(img.geometry.tracks) tracks × \(img.geometry.spt) sectors, volume \(img.label.isEmpty ? "(none)" : img.label), \(FlexDirectory.entries(in: img).count) file(s), \(img.freeCount) free sectors – verified OK")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.subheadline.bold())
                Text("(drop files or a folder here)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Files…") { chooseHostFiles() }
                Button("Add Assembled Output") { addAssembled() }
                    .disabled(assembledSRecord == nil)
                Button("Clear") { files.removeAll() }
                    .disabled(files.isEmpty)
            }

            if files.isEmpty {
                Text("No files yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                HStack(spacing: 6) {
                    Text("Name").frame(width: 90, alignment: .leading)
                    Text("Ext").frame(width: 44, alignment: .leading)
                    Text("Type").frame(width: 130, alignment: .leading)
                    Text("Sectors").frame(width: 55, alignment: .trailing)
                    Text("Attr").frame(width: 50, alignment: .leading)
                    Text("Notes").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)

                List {
                    ForEach($files) { $file in
                        fileRow($file)
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
    }

    private func fileRow(_ file: Binding<BuilderFile>) -> some View {
        HStack(spacing: 6) {
            TextField("", text: file.name)
                .textFieldStyle(.roundedBorder).frame(width: 90)
                .onChange(of: file.wrappedValue.name) { new in
                    let up = new.uppercased()
                    if up != new { file.wrappedValue.name = up }
                }
            TextField("", text: file.ext)
                .textFieldStyle(.roundedBorder).frame(width: 44)
                .onChange(of: file.wrappedValue.ext) { new in
                    let up = new.uppercased()
                    if up != new { file.wrappedValue.ext = up }
                }
            Picker("", selection: file.kind) {
                ForEach(FlexFileKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 130)
            .onChange(of: file.wrappedValue.kind) { _ in recompute(file.wrappedValue.id) }

            Text("\(file.wrappedValue.sectors)").frame(width: 55, alignment: .trailing)

            Menu {
                Toggle("Write protect (W)", isOn: attrBinding(file, 0x80))
                Toggle("Delete protect (D)", isOn: attrBinding(file, 0x40))
                Toggle("Read protect (R)", isOn: attrBinding(file, 0x20))
                Toggle("Catalog protect (C)", isOn: attrBinding(file, 0x10))
            } label: {
                Text(attrText(file.wrappedValue.attributes))
            }
            .frame(width: 50)

            VStack(alignment: .leading, spacing: 1) {
                if let problem = file.wrappedValue.nameProblem {
                    Text(problem).foregroundStyle(.red)
                } else if let error = file.wrappedValue.error {
                    Text(error).foregroundStyle(.red)
                }
                if file.wrappedValue.kind == .srecord, !file.wrappedValue.hostHasStart {
                    HStack(spacing: 4) {
                        Text("Start $").font(.caption)
                        TextField("hex", text: file.startText)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                            .onChange(of: file.wrappedValue.startText) { _ in recompute(file.wrappedValue.id) }
                    }
                }
                ForEach(file.wrappedValue.messages, id: \.self) { Text($0).foregroundStyle(.orange) }
            }
            .font(.caption)
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
                .font(.caption)
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
            appendLog("Opened \(url.lastPathComponent): \(image.geometry.tracks) × \(image.geometry.spt), \(report.fileCount) file(s), \(report.freeSectors) free sectors.")
            report.warnings.forEach { appendLog("warning: \($0)") }
        } catch {
            baseImage = nil
            baseURL = url
            statusMessage = error.localizedDescription
            lastActionFailed = true
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
        for f in files {
            if let p = f.nameProblem { appendLog("Skipped \(f.hostName): \(p)"); continue }
            if let e = f.error { appendLog("Skipped \(f.hostName): \(e)"); continue }
            do {
                let w = try FlexAllocator.addFile(to: &image, name: f.name, ext: f.ext, stream: f.stream,
                                                  attributes: f.attributes, date: .today)
                added += 1
                appendLog("Added \(f.name).\(f.ext) (\(f.sectors) sectors)")
                f.messages.forEach { appendLog("  note: \($0)") }
                w.forEach { appendLog("  note: \($0)") }
            } catch {
                appendLog("Skipped \(f.hostName): \(error.localizedDescription)")
            }
        }
        guard added > 0 else { fail("Nothing was added."); return }

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
            statusMessage = "Saved \(url.lastPathComponent): \(added) file(s), \(image.freeCount) free sectors left."
            appendLog("Saved \(url.path) (\(image.bytes.count) bytes). Verified OK.")
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
        .frame(width: 820, height: 700)
}
