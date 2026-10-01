import SwiftUI
import UniformTypeIdentifiers

/// Clones a whole vintage FLEX .DSK disk image onto a physical CF-card
/// "drive" over the serial link, sector by sector, driving the on-device
/// Flex_BIOS_DiskLoader.asm receiver program (see that file's header for
/// the wire protocol: [SOH][DRIVE][TRACK][SECTOR][256 data bytes][checksum]
/// -> ACK, or NAK + one error byte). This talks to the CF card's real
/// DRIVE_T/WRITE_T driver entries -- the same ones Flex_BIOS.asm's disk
/// vector table exposes to FLEX itself -- so what lands on the card is
/// exactly what FLEX would see reading its own disk.
///
/// Geometry (how many 256-byte sectors make up one track) is auto-detected
/// from the image's own System Information Record (SIR) -- confirmed
/// against Phil's own FlexExtractor.m/DSKviewer.m Octave tools, which read
/// real FLEX disk images this way: the SIR is the disk's 3rd sector (Track
/// 0, Sector 3 -- file byte offset 512, since sectors are 256 bytes and
/// FLEX numbers them 1-based within a track), and within it byte offset
/// $26 (0-indexed within the sector) is "Max Track" and $27 is "Max
/// Sector" (i.e. sectors per track). Number of tracks is Max Track + 1
/// (tracks are 0-indexed); sectors per track is Max Sector directly. This
/// is still shown as an editable field rather than a silent guess: it's
/// pre-filled from the SIR when detection succeeds, but the user can
/// override it, and a mismatch against the image's total sector count is
/// flagged either way.
///
/// Assumes Flex_BIOS_DiskLoader.asm is already running on the target
/// (the 'U' command from Assist09, after downloading Flex_BIOS.asm and this
/// receiver program) before "Start Transfer" is pressed. Deliberately
/// does NOT wait for the receiver's initial ready ACK: that byte is sent
/// the moment the receiver starts, which is almost always before this
/// panel is even opened, so waiting for it here would usually just time
/// out having missed it -- the receiver's main loop doesn't need the
/// host to have seen it anyway, it only needs well-formed packets.
struct DiskImagePanel: View {
    @ObservedObject var port: SerialPortManager

    @State private var imageURL: URL?
    @State private var imageData: Data?
    @State private var drive: Int = 0
    @State private var sectorsPerTrack: Int = 18
    @State private var geometrySource: GeometrySource = .manual

    private enum GeometrySource {
        case manual
        case detected(tracks: Int)
    }
    @State private var isTransferring = false
    @State private var progress: Double = 0
    @State private var statusMessage: String = ""
    @State private var lastActionFailed = false
    @State private var log: [LogLine] = []
    @State private var cancelRequested = false

    private struct LogLine: Identifiable {
        let id = UUID()
        let text: String
    }

    private let sectorSize = 256
    private let maxRetries = 5

    // Protocol constants -- must match Flex_BIOS_DiskLoader.asm exactly.
    private let soh: UInt8 = 0x01
    private let eot: UInt8 = 0x04
    private let ack: UInt8 = 0x06
    private let nak: UInt8 = 0x15

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disk Image → CF Card").font(.headline)

            HStack {
                Text("Image:")
                Text(imageURL?.lastPathComponent ?? "(no file selected)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseImage() }
                    .disabled(isTransferring)
            }

            if let imageData {
                let totalSectors = imageData.count / sectorSize
                let remainder = imageData.count % sectorSize
                VStack(alignment: .leading, spacing: 6) {
                    Text(sizeSummary(totalSectors: totalSectors, remainder: remainder))
                        .font(.callout)
                        .foregroundStyle(remainder == 0 ? Color.secondary : Color.orange)

                    HStack {
                        Text("Sectors per track:")
                        TextField("", value: $sectorsPerTrack, formatter: NumberFormatter())
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isTransferring)
                            .onChange(of: sectorsPerTrack) { _ in
                                geometrySource = .manual
                            }
                        if sectorsPerTrack > 0, case .mismatch = Self.geometryFit(totalSectors: totalSectors, sectorsPerTrack: sectorsPerTrack) {
                            Label("Doesn't divide evenly into \(totalSectors) sectors -- double-check this against the image's real geometry", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        } else if sectorsPerTrack > 0, case .singleDensityFirstTrack = Self.geometryFit(totalSectors: totalSectors, sectorsPerTrack: sectorsPerTrack) {
                            Label("Sector count matches \(sectorsPerTrack) sectors/track with a half-size (single-density) first track -- normal for a FLEX double-density disk.", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    switch geometrySource {
                    case .detected(let tracks):
                        Label("Detected from the image's own SIR: \(tracks) tracks × \(sectorsPerTrack) sectors/track", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    case .manual:
                        Label("Geometry not detected from this image -- confirm sectors-per-track yourself before transferring", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }

            HStack {
                Text("Target drive:")
                Picker("", selection: $drive) {
                    ForEach(0..<4) { d in
                        Text("\(d)").tag(d)
                    }
                }
                .frame(width: 80)
                .labelsHidden()
                .disabled(isTransferring)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await startTransfer() }
                } label: {
                    Label("Start Transfer", systemImage: "arrow.up.doc")
                }
                .disabled(!canStart)

                if isTransferring {
                    Button("Cancel") { cancelRequested = true }
                }
            }

            if isTransferring {
                ProgressView(value: progress)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundStyle(lastActionFailed ? .red : .green)
                    .font(.callout)
            }

            if !port.isConnected {
                Label("Not connected -- connect to the target on the Terminal tab first", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Text("Make sure Flex_BIOS_DiskLoader is already running on the target (the 'U' command from Assist09) before starting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(log) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140)
            }
        }
        .padding()
    }

    /// How a transferred image's total sector count relates to its
    /// declared sectors-per-track. FLEX disks conventionally write track 0
    /// in single density even on an otherwise double-density disk, which
    /// halves track 0's own sector count (e.g. 9 sectors instead of 18) --
    /// so a perfectly normal double-density .DSK image is `sectorsPerTrack`
    /// sectors short of dividing evenly: its real total is
    /// `(tracks - 1) * sectorsPerTrack + sectorsPerTrack / 2`. Checking for
    /// that shape specifically (rather than just flagging any remainder)
    /// means a correctly-formed image no longer trips the "doesn't divide
    /// evenly" warning. This only affects the on-screen check -- the actual
    /// transfer already sends whatever sectors the file contains and writes
    /// fine either way.
    private enum GeometryFit {
        case exact
        case singleDensityFirstTrack
        case mismatch
    }

    private static func geometryFit(totalSectors: Int, sectorsPerTrack: Int) -> GeometryFit {
        guard sectorsPerTrack > 0 else { return .mismatch }
        if totalSectors % sectorsPerTrack == 0 { return .exact }
        let halfTrack = sectorsPerTrack / 2
        if halfTrack > 0, totalSectors >= halfTrack, (totalSectors - halfTrack) % sectorsPerTrack == 0 {
            return .singleDensityFirstTrack
        }
        return .mismatch
    }

    private func sizeSummary(totalSectors: Int, remainder: Int) -> String {
        var text = "\(imageData?.count ?? 0) bytes -- \(totalSectors) sector\(totalSectors == 1 ? "" : "s") of \(sectorSize) bytes"
        if remainder != 0 {
            text += " (⚠️ \(remainder) leftover byte\(remainder == 1 ? "" : "s") -- not a whole number of sectors)"
        }
        return text
    }

    private var canStart: Bool {
        guard let imageData, !imageData.isEmpty else { return false }
        return port.isConnected && !isTransferring && sectorsPerTrack > 0 && imageData.count % sectorSize == 0
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            imageURL = url
            imageData = data
            statusMessage = ""
            log = []

            if let geometry = Self.detectGeometry(from: data) {
                sectorsPerTrack = geometry.sectorsPerTrack
                geometrySource = .detected(tracks: geometry.tracks)
                appendLog("Detected geometry from SIR: \(geometry.tracks) tracks, \(geometry.sectorsPerTrack) sectors/track.")
            } else {
                geometrySource = .manual
                appendLog("Couldn't read a SIR from this image (too short, or not at the expected offset) -- set sectors-per-track manually.")
            }
        } catch {
            statusMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            lastActionFailed = true
        }
    }

    /// Reads FLEX's disk geometry straight out of the image's own System
    /// Information Record, the same way Phil's FlexExtractor.m/DSKviewer.m
    /// Octave tools do: the SIR is the disk's 3rd 256-byte sector (Track 0,
    /// Sector 3), which is file byte offset 512 in a raw sequential image.
    /// Within the SIR, 0-indexed byte 38 (hex $26) is "Max Track" and byte
    /// 39 (hex $27) is "Max Sector" -- sectors per track, since FLEX
    /// sectors are numbered 1-based within a track. Tracks are 0-indexed,
    /// so the track count is Max Track + 1.
    private static func detectGeometry(from data: Data) -> (tracks: Int, sectorsPerTrack: Int)? {
        let sirOffset = 512
        let maxTrackOffset = sirOffset + 0x26
        let maxSectorOffset = sirOffset + 0x27
        guard data.count > maxSectorOffset else { return nil }

        let maxTrack = Int(data[data.startIndex + maxTrackOffset])
        let maxSector = Int(data[data.startIndex + maxSectorOffset])
        guard maxSector > 0 else { return nil }

        return (tracks: maxTrack + 1, sectorsPerTrack: maxSector)
    }

    private func appendLog(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 500 {
            log.removeFirst(log.count - 400)
        }
    }

    private func startTransfer() async {
        guard let imageData else { return }
        isTransferring = true
        cancelRequested = false
        progress = 0
        lastActionFailed = false
        statusMessage = "Transferring…"
        appendLog("--- Starting transfer of \(imageURL?.lastPathComponent ?? "image") to drive \(drive) ---")
        defer { isTransferring = false }

        let totalSectors = imageData.count / sectorSize
        var index = 0

        while index < totalSectors {
            if cancelRequested {
                statusMessage = "Cancelled after \(index) of \(totalSectors) sectors."
                lastActionFailed = true
                appendLog("--- Cancelled by user after \(index) of \(totalSectors) sectors ---")
                return
            }

            let track = UInt8(index / sectorsPerTrack)
            let sector = UInt8((index % sectorsPerTrack) + 1) // FLEX sectors are 1-based within a track
            let start = index * sectorSize
            let sectorData = imageData.subdata(in: start..<(start + sectorSize))

            var packet = Data([soh, UInt8(drive), track, sector])
            packet.append(sectorData)
            var checksum: UInt8 = 0
            for byte in sectorData {
                checksum = checksum &+ byte
            }
            packet.append(checksum)

            var succeeded = false
            var attempt = 0
            while attempt < maxRetries && !succeeded {
                attempt += 1
                let response = await port.sendAndAwaitRaw(packet, timeout: 3.0) { data in
                    guard let first = data.first else { return false }
                    if first == ack { return true }
                    if first == nak { return data.count >= 2 }
                    return false
                }
                switch response.first {
                case ack:
                    succeeded = true
                case nak:
                    let errCode = response.count >= 2 ? response[1] : 0xFF
                    appendLog("Track \(track) sector \(sector): NAK (error \(String(format: "$%02X", errCode))), attempt \(attempt)/\(maxRetries)")
                default:
                    appendLog("Track \(track) sector \(sector): no response, attempt \(attempt)/\(maxRetries)")
                }
            }

            if !succeeded {
                statusMessage = "Failed at track \(track) sector \(sector) after \(maxRetries) attempts -- stopped."
                lastActionFailed = true
                appendLog("--- Stopped: track \(track) sector \(sector) never succeeded ---")
                return
            }

            index += 1
            progress = Double(index) / Double(totalSectors)
        }

        // Tell the receiver we're done, so it returns to Assist09.
        let eotResponse = await port.sendAndAwaitRaw(Data([eot]), timeout: 3.0) { $0.count >= 1 }
        if eotResponse.first == ack {
            appendLog("Receiver acknowledged end-of-transfer and returned to the monitor.")
        } else {
            appendLog("No acknowledgment for end-of-transfer -- the receiver may not have returned to the monitor cleanly.")
        }

        statusMessage = "Transfer complete -- \(totalSectors) sectors written to drive \(drive)."
        lastActionFailed = false
        appendLog("--- Transfer complete: \(totalSectors) sectors ---")
    }
}

#Preview {
    DiskImagePanel(port: SerialPortManager())
        .frame(width: 560, height: 560)
}
