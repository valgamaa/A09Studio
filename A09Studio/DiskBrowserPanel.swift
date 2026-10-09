import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Search-box matcher. Plain text matches anywhere (substring); if the text
/// contains `*` (any run of characters) or `?` (any one character) it is a
/// wildcard pattern that must match the whole name, e.g. `*.CMD`, `XB?.*`.
struct SearchMatcher {
    let query: String          // upper-cased, trimmed
    private let pattern: [Character]
    let isWildcard: Bool

    init(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces).uppercased()
        pattern = Array(query)
        isWildcard = query.contains("*") || query.contains("?")
    }

    var isEmpty: Bool { query.isEmpty }

    /// `text` must already be upper-case.
    func matches(_ text: String) -> Bool {
        if query.isEmpty { return true }
        if !isWildcard { return text.contains(query) }
        let t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < pattern.count && (pattern[pi] == "?" || pattern[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < pattern.count && pattern[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < pattern.count && pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }
}


// MARK: - Background loading (no SwiftUI, no actor isolation)

/// What the left panel remembers about each image in the chosen folder, so
/// the search box can look inside every disk without re-reading it.
struct BrowserImageInfo {
    var names: [String] = []        // upper-case NAME.EXT of every live file
    var label = ""
    var geometry = ""
    var error: String? = nil
}

/// One directory entry of the open image, with its bytes already read.
struct BrowserRow: Identifiable {
    let id: String
    let entry: FlexDirEntry
    var info: FlexFileInfo
    var bytes: [UInt8]
    var warnings: [String]
    var error: String?
    var crc: String = ""
}

struct BrowserLoad {
    var rows: [BrowserRow] = []
    var summary = ""
    var problems: [String] = []
    var error: String? = nil
}

enum DiskBrowserLoader {
    static let imageExtensions: Set<String> = ["dsk", "img", "flx", "flex"]

    /// Every disk image under `root`, sorted by path.
    static func findImages(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        while let item = walker.nextObject() as? URL {
            if imageExtensions.contains(item.pathExtension.lowercased()) { found.append(item) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Cheap pass for the search index: directory names only.
    static func indexImage(_ url: URL) -> BrowserImageInfo {
        var info = BrowserImageInfo()
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let image = try FlexImage(data: data, lenient: true)
            info.names = FlexDirectory.entries(in: image).map { $0.fullName.uppercased() }
            info.label = image.label
            info.geometry = "\(image.geometry.tracks)×\(image.geometry.spt)"
        } catch {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            info.error = "\(error.localizedDescription) (\(size) bytes)"
        }
        return info
    }

    /// Full read of one image: every file's bytes, kind and notes.
    static func loadRows(_ url: URL) -> BrowserLoad {
        var load = BrowserLoad()
        do {
            let data = try Data(contentsOf: url)
            let image = try FlexImage(data: data, lenient: true)
            let report = FlexVerifier.verify(image, forBrowsing: true)
            load.problems = report.errors
            for e in FlexDirectory.entries(in: image) {
                let id = "\(e.dirSector.track)-\(e.dirSector.sector)-\(e.slot)"
                do {
                    let x = try FlexExtractor.stream(of: e, in: image)
                    load.rows.append(BrowserRow(id: id, entry: e, info: FlexExtractor.describe(x.bytes),
                                                bytes: x.bytes, warnings: x.warnings, error: nil,
                                                crc: FlexExtractor.checksum(x.bytes)))
                } catch {
                    load.rows.append(BrowserRow(id: id, entry: e,
                                                info: FlexFileInfo(kind: e.random ? .random : .data),
                                                bytes: [], warnings: [], error: error.localizedDescription))
                }
            }
            let g = image.geometry
            let firstTrack = image.track0Sectors < g.spt ? " (track 0: \(image.track0Sectors))" : ""
            load.summary = "\(g.tracks) tracks × \(g.spt) sectors\(firstTrack), volume \(image.label.isEmpty ? "(none)" : image.label), \(load.rows.count) file(s), \(image.freeCount) free sectors"
        } catch {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            load.error = "\(error.localizedDescription) (file is \(size) bytes)"
        }
        return load
    }
}

// MARK: - View

/// "DSK Browser": point it at a folder of FLEX disk images, look inside any
/// of them, and collect the files you want onto a new (or existing) image.
///
///   [ disk images ] [ files on the selected image ] [Add] [ files to copy ]
struct DiskBrowserPanel: View {
    /// Called with the saved image's URL when "Send to CF…" is pressed.
    var onSendToCF: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    private static let rootKey = "DiskBrowserRoot"
    private static let autoID = "Automatic"

    // Left panel
    @State private var rootURL: URL?
    @State private var imageURLs: [URL] = []
    @State private var index: [URL: BrowserImageInfo] = [:]
    @State private var scanTask: Task<Void, Never>?
    @State private var scanProgress = ""
    @State private var search = ""
    @State private var hideUnreadable = true
    @State private var filterFiles = true
    @State private var selectedImage: URL?
    private enum ListFocus { case images, files }
    @FocusState private var focusedList: ListFocus?

    // Middle panel
    @State private var loadTask: Task<Void, Never>?
    @State private var rows: [BrowserRow] = []
    @State private var openSummary = ""
    @State private var openProblems: [String] = []
    @State private var openError: String?
    @State private var selectedRows = Set<String>()

    // Right panel
    private struct BasketItem: Identifiable {
        let id = UUID()
        var sourceName: String
        var sourceURL: URL?
        var originalName: String
        var name: String
        var ext: String
        var attributes: UInt8
        var date: FlexDate
        var stream: [UInt8]
        var notes: [String]
        var kind: FlexFileInfo.Kind = .data
        var crc: String = ""

        var sectors: Int { max(1, (stream.count + 251) / 252) }
        var nameProblem: String? { FlexNames.validate(name: name, ext: ext) }
    }

    private enum TargetMode: String, CaseIterable, Identifiable {
        case new = "New image"
        case existing = "Add to existing .dsk"
        var id: String { rawValue }
    }

    @State private var basket: [BasketItem] = []
    @State private var mode: TargetMode = .new
    @State private var presetID = DiskBrowserPanel.autoID
    @State private var volumeLabel = "FLEXDISK"
    @State private var volumeNumber = 1
    @State private var baseURL: URL?
    @State private var baseImage: FlexImage?

    // Output
    @State private var log: [String] = []
    @State private var statusMessage = ""
    @State private var lastActionFailed = false
    @State private var builtURL: URL?
    @State private var convertTextOnSave = true

    // MARK: Derived

    private var filteredImages: [URL] {
        let m = SearchMatcher(search)
        let base = hideUnreadable ? imageURLs.filter { index[$0]?.error == nil } : imageURLs
        if m.isEmpty { return base }
        return base.filter { url in
            if m.isWildcard {
                if m.matches(url.lastPathComponent.uppercased()) { return true }
            } else if m.matches(relativePath(url).uppercased()) { return true }
            return index[url]?.names.contains(where: { m.matches($0) }) ?? false
        }
    }

    /// Files shown in the middle panel: optionally narrowed by the search box.
    private var visibleRows: [BrowserRow] {
        let m = SearchMatcher(search)
        if !filterFiles || m.isEmpty { return rows }
        return rows.filter { m.matches($0.entry.fullName.uppercased()) }
    }

    private var unreadableCount: Int { index.values.filter { $0.error != nil }.count }

    private var focusRow: BrowserRow? {
        guard selectedRows.count == 1, let id = selectedRows.first else { return nil }
        return visibleRows.first { $0.id == id }
    }

    private var validItems: [BasketItem] {
        basket.filter { $0.nameProblem == nil && !isDuplicate($0) }
    }
    private var queuedSectors: Int { validItems.reduce(0) { $0 + $1.sectors } }
    private var queuedFiles: Int { validItems.count }

    private var chosenGeometry: FlexGeometry? {
        if mode == .existing { return baseImage?.geometry }
        if presetID == Self.autoID {
            return FlexDiskBuilder.chooseGeometry(sectorsNeeded: queuedSectors, entriesNeeded: queuedFiles)
        }
        return FlexGeometry.presets.first { $0.name == presetID }
    }

    private var freeSectors: Int {
        if mode == .existing { return baseImage?.freeCount ?? 0 }
        return chosenGeometry?.blankFreeSectors ?? 0
    }

    private var freeSlots: Int {
        if mode == .existing, let img = baseImage { return FlexDirectory.freeSlotCount(in: img) }
        return chosenGeometry?.directorySlots ?? 0
    }

    private var canBuild: Bool {
        guard queuedFiles > 0, chosenGeometry != nil else { return false }
        if mode == .existing && baseImage == nil { return false }
        return queuedSectors <= freeSectors && queuedFiles <= freeSlots
    }

    private func isDuplicate(_ item: BasketItem) -> Bool {
        let n = item.name.uppercased(), e = item.ext.uppercased()
        if basket.filter({ $0.name.uppercased() == n && $0.ext.uppercased() == e }).count > 1 { return true }
        if mode == .existing, let img = baseImage, FlexDirectory.contains(name: n, ext: e, in: img) { return true }
        return false
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = rootURL else { return url.lastPathComponent }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("DSK Browser").font(.title.bold())
                Text(rootURL?.path ?? "(no folder chosen)")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { chooseFolder() }
                Button("Close") { dismiss() }
            }

            HStack(alignment: .top, spacing: 8) {
                leftPanel.frame(minWidth: 220, idealWidth: 300, maxWidth: 340)
                middlePanel.frame(minWidth: 610, maxWidth: .infinity)
                addColumn.frame(width: 90)
                rightPanel.frame(minWidth: 420, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundStyle(lastActionFailed ? .red : .green)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.title3, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 80)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .padding()
        .onAppear {
            if rootURL == nil, let saved = UserDefaults.standard.string(forKey: Self.rootKey),
               FileManager.default.fileExists(atPath: saved) {
                startScan(URL(fileURLWithPath: saved, isDirectory: true))
            }
        }
        .onChange(of: selectedImage) { url in
            openImage(url)
            keepImageListFocus()
        }
    }

    // MARK: Left panel – disk images

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Disk images").font(.title3.bold())
                Spacer()
                Text(scanProgress).font(.body).foregroundStyle(.secondary)
            }
            TextField("Search disks or files (wildcards * ? allowed)", text: $search)
                .textFieldStyle(.roundedBorder)
            Toggle("Also filter the file list", isOn: $filterFiles)
                .font(.body)
            if imageURLs.isEmpty {
                Text(rootURL == nil ? "Choose a folder that contains .dsk files."
                                    : "No .dsk, .img or .flx files found here (or the folder is not accessible – choose it again).")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                Spacer()
            } else {
                List(selection: $selectedImage) {
                    ForEach(filteredImages, id: \.self) { url in
                        imageRow(url).tag(url)
                    }
                }
                .focused($focusedList, equals: .images)
                Text("\(filteredImages.count) of \(imageURLs.count) disk(s)")
                    .font(.body).foregroundStyle(.secondary)
                if unreadableCount > 0 {
                    Toggle("Hide \(unreadableCount) unreadable", isOn: $hideUnreadable)
                        .font(.body)
                }
            }
        }
    }

    private func imageRow(_ url: URL) -> some View {
        let info = index[url]
        let m = SearchMatcher(search)
        let hits: [String] = m.isEmpty ? [] : (info?.names.filter { m.matches($0) } ?? [])
        return VStack(alignment: .leading, spacing: 1) {
            Text(url.lastPathComponent)
                .font(.system(.title2, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            let rel = relativePath(url)
            if rel != url.lastPathComponent {
                Text((rel as NSString).deletingLastPathComponent)
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            if !hits.isEmpty {
                Text(hits.prefix(3).joined(separator: ", ") + (hits.count > 3 ? " +\(hits.count - 3)" : ""))
                    .font(.body).foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else if let err = info?.error {
                Text(err).font(.body).foregroundStyle(.red).lineLimit(1)
            } else if let info = info {
                Text("\(info.names.count) file(s)\(info.label.isEmpty ? "" : " · " + info.label)")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Middle panel – files on the selected image

    private var middlePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedImage?.lastPathComponent ?? "Contents").font(.title3.bold())
                .lineLimit(1).truncationMode(.middle)
            if let err = openError {
                Text(err).font(.title3).foregroundStyle(.red)
                Spacer()
            } else if selectedImage == nil {
                Text("Select a disk image on the left.")
                    .font(.title3).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(openSummary).font(.body).foregroundStyle(.secondary)
                if !openProblems.isEmpty {
                    Text("Image has structural problems (\(openProblems[0])) – files may be damaged.")
                        .font(.body).foregroundStyle(.orange)
                }
                HStack(spacing: 6) {
                    Text("").frame(width: 20)
                    Text("File").frame(width: 150, alignment: .leading)
                    Text("Type").frame(width: 70, alignment: .leading)
                    Text("Sect").frame(width: 52, alignment: .trailing)
                    Text("Date").frame(width: 100, alignment: .leading)
                    Text("Attr").frame(width: 52, alignment: .leading)
                    Text("CRC32").frame(width: 110, alignment: .leading)
                }
                .font(.body).foregroundStyle(.secondary)

                List(selection: $selectedRows) {
                    ForEach(visibleRows) { r in
                        fileRow(r)
                            .tag(r.id)
                            .contextMenu {
                                Button("Add to list") { addRows(visibleRows.filter { selectedRows.contains($0.id) || $0.id == r.id }) }
                            }
                    }
                }
                .focused($focusedList, equals: .files)
                if visibleRows.count != rows.count {
                    Text("\(visibleRows.count) of \(rows.count) file(s) shown")
                        .font(.body).foregroundStyle(.secondary)
                }
                detailBox
            }
        }
    }

    private func fileRow(_ r: BrowserRow) -> some View {
        HStack(spacing: 6) {
            Group {
                if r.error != nil {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                } else if r.info.is6800 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("Looks like a 6800 program – it will not run on 6809 FLEX")
                } else if r.info.hasWarning {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                } else {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            Text(r.entry.fullName)
                .font(.system(.title2, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(r.info.kind.rawValue).frame(width: 70, alignment: .leading)
            Text("\(r.entry.sectorCount)").frame(width: 52, alignment: .trailing)
            Text(dateText(r.entry.date)).frame(width: 100, alignment: .leading)
            Text(attrText(r.entry.attributes)).frame(width: 52, alignment: .leading)
            Text(r.crc).font(.system(.title3, design: .monospaced)).frame(width: 110, alignment: .leading)
        }
        .font(.title3)
    }

    private var detailBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let r = focusRow {
                if let e = r.error {
                    Text(e).foregroundStyle(.red).font(.body)
                } else {
                    Text("\(r.entry.fullName) – \(r.info.kind.rawValue), \(r.bytes.count) bytes stored")
                        .font(.title3.bold())
                    ForEach(r.info.notes + r.warnings, id: \.self) { n in
                        Text(n).font(.body)
                            .foregroundStyle(n.hasPrefix("WARNING") || n.hasPrefix("directory says") ? Color.orange : Color.secondary)
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(r.info.preview)
                            .font(.system(size: 16, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            } else {
                Text(selectedRows.isEmpty ? "Select a file to see its details, then press Add. Command- or Shift-click selects several."
                                          : "\(selectedRows.count) files selected.")
                    .font(.body).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 240, alignment: .topLeading)
    }

    // MARK: Add column

    private var addColumn: some View {
        VStack(spacing: 10) {
            Spacer()
            Button { addRows(visibleRows.filter { selectedRows.contains($0.id) }) } label: {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.right.circle.fill").font(.title)
                    Text("Add")
                }
            }
            .disabled(selectedRows.isEmpty)
            Button { addRows(visibleRows) } label: {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.right.to.line")
                    Text("Add all").font(.body)
                }
            }
            .disabled(visibleRows.isEmpty)
            Spacer()
        }
        .buttonStyle(.bordered)
    }

    // MARK: Right panel – files to copy

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files to copy").font(.title3.bold())
                Spacer()
                Button("Clear") { basket.removeAll() }.disabled(basket.isEmpty)
            }

            if basket.isEmpty {
                Text("Nothing selected yet.")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                Spacer()
            } else {
                List {
                    ForEach($basket) { $item in
                        basketRow($item)
                    }
                }
            }

            targetSection
            capacitySection

            HStack(spacing: 8) {
                Button { build() } label: { Label("Build .dsk…", systemImage: "hammer") }
                    .disabled(!canBuild)
                Button { if let u = builtURL { onSendToCF(u) } } label: { Label("Send to CF…", systemImage: "arrow.up.doc") }
                    .disabled(builtURL == nil)
                Spacer()
                Button { saveBasketToMac() } label: { Label("Save to Mac…", systemImage: "square.and.arrow.down") }
                    .disabled(basket.isEmpty)
                Toggle("Text → Mac text", isOn: $convertTextOnSave).font(.body)
            }
        }
    }

    private func basketRow(_ item: Binding<BasketItem>) -> some View {
        let v = item.wrappedValue
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("", text: item.name)
                    .textFieldStyle(.roundedBorder).frame(width: 130)
                    .onChange(of: item.wrappedValue.name) { new in
                        let up = new.uppercased()
                        if up != new { item.wrappedValue.name = up }
                    }
                TextField("", text: item.ext)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                    .onChange(of: item.wrappedValue.ext) { new in
                        let up = new.uppercased()
                        if up != new { item.wrappedValue.ext = up }
                    }
                Text("\(v.sectors) sect").font(.body).frame(width: 76, alignment: .trailing)
                Text(attrText(v.attributes)).font(.body).frame(width: 44)
                Text("from \(v.sourceName) · \(v.crc)")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    basket.removeAll { $0.id == v.id }
                } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
            }
            if let problem = v.nameProblem {
                Text(problem).font(.body).foregroundStyle(.red)
            } else if isDuplicate(v) {
                Text("Same name as another file in the list – rename it before building a disk").font(.body).foregroundStyle(.red)
            }
            ForEach(v.notes, id: \.self) { Text($0).font(.body).foregroundStyle(.orange) }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $mode) {
                ForEach(TargetMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if mode == .new {
                HStack {
                    Text("Size:")
                    Picker("", selection: $presetID) {
                        Text("Automatic (smallest that fits)").tag(Self.autoID)
                        ForEach(FlexGeometry.presets) { g in
                            Text("\(g.name) – \(g.sizeDescription)").tag(g.name)
                        }
                    }
                    .labelsHidden()
                }
                HStack {
                    Text("Label:")
                    TextField("", text: $volumeLabel).frame(width: 150).textFieldStyle(.roundedBorder)
                    Text("Volume #:")
                    TextField("", value: $volumeNumber, formatter: NumberFormatter())
                        .frame(width: 62).textFieldStyle(.roundedBorder)
                }
            } else {
                HStack {
                    Text(baseURL?.lastPathComponent ?? "(no image selected)")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseExistingImage() }
                }
            }
        }
    }

    private var capacitySection: some View {
        let sectorsAfter = freeSectors - queuedSectors
        let slotsAfter = freeSlots - queuedFiles
        let bad = chosenGeometry == nil || sectorsAfter < 0 || slotsAfter < 0
        var text = "\(queuedFiles) file(s), \(queuedSectors) sectors"
        if let g = chosenGeometry {
            text += " → \(g.name), \(max(sectorsAfter, 0)) sectors and \(max(slotsAfter, 0)) directory slots left"
            if sectorsAfter < 0 || slotsAfter < 0 { text += " (does not fit)" }
        } else if mode == .existing {
            text += " – choose an image to add to"
        } else if queuedFiles > 0 {
            text += " – too large for any supported size"
        }
        return VStack(alignment: .leading, spacing: 3) {
            if freeSectors > 0 {
                ProgressView(value: min(1.0, Double(queuedSectors) / Double(freeSectors)))
            }
            Text(text).font(.body).foregroundStyle(bad && queuedFiles > 0 ? Color.red : Color.secondary)
        }
    }

    // MARK: Helpers

    private func attrText(_ a: UInt8) -> String {
        var s = ""
        if a & 0x80 != 0 { s += "W" }
        if a & 0x40 != 0 { s += "D" }
        if a & 0x20 != 0 { s += "R" }
        if a & 0x10 != 0 { s += "C" }
        return s.isEmpty ? "–" : s
    }

    private func dateText(_ d: FlexDate) -> String {
        return String(format: "%02d/%02d/%02d", d.month, d.day, d.year)
    }

    private func appendLog(_ text: String) {
        log.append(text)
        if log.count > 400 { log.removeFirst(log.count - 300) }
    }

    private func fail(_ message: String) {
        statusMessage = message
        lastActionFailed = true
        appendLog(message)
    }

    // MARK: Folder scan and index

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        startScan(url)
    }

    private func startScan(_ root: URL) {
        scanTask?.cancel()
        rootURL = root
        imageURLs = []
        index = [:]
        selectedImage = nil
        scanProgress = "scanning…"
        scanTask = Task {
            let urls = await Task.detached(priority: .userInitiated) { DiskBrowserLoader.findImages(in: root) }.value
            if Task.isCancelled { return }
            await MainActor.run {
                imageURLs = urls
                scanProgress = urls.isEmpty ? "" : "indexing 0/\(urls.count)"
            }
            var batch: [URL: BrowserImageInfo] = [:]
            var done = 0
            for url in urls {
                if Task.isCancelled { return }
                let info = await Task.detached(priority: .utility) { DiskBrowserLoader.indexImage(url) }.value
                batch[url] = info
                done += 1
                if batch.count >= 20 || done == urls.count {
                    let chunk = batch
                    batch = [:]
                    let progress = done
                    await MainActor.run {
                        for (k, v) in chunk { index[k] = v }
                        scanProgress = progress == urls.count ? "" : "indexing \(progress)/\(urls.count)"
                    }
                }
            }
        }
    }

    // MARK: Open an image

    private func openImage(_ url: URL?) {
        loadTask?.cancel()
        rows = []
        selectedRows = []
        openSummary = ""
        openProblems = []
        openError = nil
        guard let url else { return }
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) { DiskBrowserLoader.loadRows(url) }.value
            if Task.isCancelled { return }
            await MainActor.run {
                guard selectedImage == url else { return }
                rows = result.rows
                openSummary = result.summary
                openProblems = result.problems
                openError = result.error
                keepImageListFocus()
            }
        }
    }

    /// Loading a disk rebuilds the file list, which can take the keyboard
    /// focus away from the disk list, so the cursor keys stop working there.
    /// Put the focus back, unless the user has moved to the file list.
    private func keepImageListFocus() {
        guard focusedList != .files else { return }
        DispatchQueue.main.async { focusedList = .images }
    }

    // MARK: Basket

    private func addRows(_ list: [BrowserRow]) {
        guard let source = selectedImage else { return }
        var added = 0
        for r in list {
            if let err = r.error {
                appendLog("Skipped \(r.entry.fullName): \(err)")
                continue
            }
            if basket.contains(where: { $0.sourceURL == source && $0.originalName == r.entry.fullName }) {
                appendLog("\(r.entry.fullName) from \(source.lastPathComponent) is already in the list")
                continue
            }
            let notes = r.info.notes.filter { $0.hasPrefix("WARNING") } + r.warnings
            basket.append(BasketItem(sourceName: source.lastPathComponent, sourceURL: source,
                                     originalName: r.entry.fullName, name: r.entry.name, ext: r.entry.ext,
                                     attributes: r.entry.attributes, date: r.entry.date,
                                     stream: r.bytes, notes: notes, kind: r.info.kind, crc: r.crc))
            added += 1
        }
        if added > 0 { statusMessage = "" }
    }

    // MARK: Save to Mac

    /// Writes every file in the list to a folder on the Mac. Binaries are
    /// written byte for byte (still valid FLEX files). Files that share a
    /// name with another file in the list get the source disk's name added,
    /// so copies from different disks never overwrite each other.
    private func saveBasketToMac() {
        guard !basket.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var saved = 0
        for item in basket {
            let dup = basket.filter {
                $0.name.uppercased() == item.name.uppercased() && $0.ext.uppercased() == item.ext.uppercased()
            }.count > 1
            var base = item.name.uppercased()
            if dup {
                let stem = (item.sourceName as NSString).deletingPathExtension
                base += "-" + String(stem.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            }
            func fileName(_ b: String) -> String { item.ext.isEmpty ? b : "\(b).\(item.ext.uppercased())" }
            var url = folder.appendingPathComponent(fileName(base))
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent(fileName("\(base)-\(n)"))
                n += 1
            }
            let bytes: [UInt8] = (convertTextOnSave && item.kind == .text) ? FlexExtractor.hostText(item.stream) : item.stream
            do {
                try Data(bytes).write(to: url)
                saved += 1
                appendLog("Saved \(url.lastPathComponent) (\(bytes.count) bytes, CRC32 \(item.crc)) from \(item.sourceName)")
            } catch {
                appendLog("Could not save \(fileName(base)): \(error.localizedDescription)")
            }
        }
        lastActionFailed = saved == 0
        statusMessage = "Saved \(saved) of \(basket.count) file(s) to \(folder.lastPathComponent)."
    }

    // MARK: Existing target

    private func chooseExistingImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let image = try FlexImage(data: try Data(contentsOf: url))
            let report = FlexVerifier.verify(image)
            guard report.ok else {
                baseImage = nil
                baseURL = url
                fail("\(url.lastPathComponent) failed verification – not safe to add files to.")
                report.errors.forEach { appendLog("verification: \($0)") }
                return
            }
            baseImage = image
            baseURL = url
            statusMessage = ""
            appendLog("Target \(url.lastPathComponent): \(image.freeCount) free sectors, \(FlexDirectory.freeSlotCount(in: image)) free directory slots.")
        } catch {
            baseImage = nil
            baseURL = url
            fail(error.localizedDescription)
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
                guard let g = chosenGeometry else { throw FlexError.badGeometry("nothing fits the chosen size") }
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
        for item in basket {
            let label = "\(item.name).\(item.ext)"
            if let p = item.nameProblem { appendLog("Skipped \(label): \(p)"); continue }
            if isDuplicate(item) {
                appendLog("Skipped \(label): duplicate name")
                continue
            }
            let date = (1...12).contains(item.date.month) ? item.date : FlexDate.today
            do {
                try FlexAllocator.addFile(to: &image, name: item.name, ext: item.ext, stream: item.stream,
                                          attributes: item.attributes, date: date)
                added += 1
                appendLog("Added \(label) (\(item.sectors) sectors) from \(item.sourceName)")
            } catch {
                appendLog("Skipped \(label): \(error.localizedDescription)")
            }
        }
        guard added > 0 else { fail("Nothing was added."); return }

        let report = FlexVerifier.verify(image)
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
            if let root = rootURL { panel.directoryURL = root }
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
}

#Preview {
    DiskBrowserPanel(onSendToCF: { _ in })
        .frame(width: 1400, height: 900)
}
