import Foundation

// FlexDisk.swift
//
// Pure-Swift model layer for building FLEX .dsk images (no SwiftUI, so it
// can be unit-tested against reference images). Implements the "FLEX .dsk
// Image Builder -- Feature Spec": FlexGeometry, FlexImage, FlexDirectory,
// FlexFileConverter, FlexAllocator, FlexVerifier, plus FlexDiskBuilder for
// the one-step "image from folder" flow.
//
// Conventions (same as the spec): tracks count from 0, sectors from 1,
// sectors are 256 bytes, file offset = (track * spt + (sector - 1)) * 256.
// Every chained sector is: [0] next track, [1] next sector (00 00 = end),
// [2-3] record number (big-endian), [4-255] 252 data bytes.

// MARK: - Basic types

/// A track/sector address.
struct FlexTS: Hashable {
    var track: Int
    var sector: Int
    var isEnd: Bool { track == 0 && sector == 0 }
    static let end = FlexTS(track: 0, sector: 0)
}

/// FLEX's two-digit-year date.
struct FlexDate: Equatable {
    var month: Int
    var day: Int
    var year: Int   // two-digit, 0-99

    static var today: FlexDate {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return FlexDate(month: c.month ?? 1, day: c.day ?? 1, year: (c.year ?? 2000) % 100)
    }
}

enum FlexError: LocalizedError {
    case badGeometry(String)
    case notAFlexImage(String)
    case imageDamaged(String)
    case diskFull(needed: Int, free: Int)
    case directoryFull
    case duplicateName(String)
    case invalidName(String)
    case conversion(String)
    case needsTransferAddress

    var errorDescription: String? {
        switch self {
        case .badGeometry(let m): return "Bad geometry: \(m)"
        case .notAFlexImage(let m): return "Not a FLEX image: \(m)"
        case .imageDamaged(let m): return "Image failed verification: \(m)"
        case .diskFull(let needed, let free): return "Not enough free space (needs \(needed) sectors, \(free) free)"
        case .directoryFull: return "Directory is full (track 0 has no free slots)"
        case .duplicateName(let n): return "\(n) already exists on the disk"
        case .invalidName(let m): return "Invalid FLEX name: \(m)"
        case .conversion(let m): return "Conversion failed: \(m)"
        case .needsTransferAddress: return "S-record has no start address; enter one"
        }
    }
}

// MARK: - Geometry

struct FlexGeometry: Equatable, Hashable, Identifiable {
    let name: String
    let maxTrack: Int       // last track number, 1...255
    let spt: Int            // sectors per track (per cylinder), 5...255

    var id: String { name }
    var tracks: Int { maxTrack + 1 }
    var totalSectors: Int { tracks * spt }
    var byteCount: Int { totalSectors * 256 }
    /// Free sectors on a blank disk: tracks 1...maxTrack (track 0 is never free).
    var blankFreeSectors: Int { maxTrack * spt }
    /// Directory slots: sectors 5...spt of track 0, 10 entries each.
    var directorySlots: Int { (spt - 4) * 10 }
    var isValid: Bool { (1...255).contains(maxTrack) && (5...255).contains(spt) }

    init(name: String, tracks: Int, spt: Int) {
        self.name = name
        self.maxTrack = tracks - 1
        self.spt = spt
    }

    func offset(track: Int, sector: Int) -> Int {
        return (track * spt + (sector - 1)) * 256
    }

    func contains(_ ts: FlexTS) -> Bool {
        return ts.track >= 0 && ts.track <= maxTrack && ts.sector >= 1 && ts.sector <= spt
    }

    var sizeDescription: String {
        let kb = Double(byteCount) / 1024.0
        return kb == kb.rounded() ? "\(Int(kb)) KB" : String(format: "%.1f KB", kb)
    }

    static let presets: [FlexGeometry] = [
        FlexGeometry(name: "5.25\" SS SD, 35 tracks", tracks: 35, spt: 10),
        FlexGeometry(name: "5.25\" SS SD, 40 tracks", tracks: 40, spt: 10),
        FlexGeometry(name: "5.25\" DS DD, 40 tracks", tracks: 40, spt: 36),
        FlexGeometry(name: "3.5\" DS DD, 80 tracks", tracks: 80, spt: 36),
        FlexGeometry(name: "CF large (256 x 255)", tracks: 256, spt: 255),
    ]
    static let cfLarge = presets[presets.count - 1]
}

// MARK: - Image

struct FlexImage {
    let geometry: FlexGeometry
    var bytes: [UInt8]

    // SIR field offsets (within track 0, sector 3).
    static let sirSector = 3
    private static let sirLabel = 0x10
    private static let sirVolume = 0x1B
    private static let sirFirstFree = 0x1D
    private static let sirLastFree = 0x1F
    private static let sirFreeCount = 0x21
    private static let sirDate = 0x23
    private static let sirMaxTrack = 0x26
    private static let sirMaxSector = 0x27

    // MARK: Formatting a blank image

    /// Spec "Format a blank image".
    init(formatting g: FlexGeometry, label: String, volumeNumber: Int,
         date: FlexDate, bootSectors: Data? = nil) throws {
        guard g.isValid else {
            throw FlexError.badGeometry("tracks 2-256 and 5-255 sectors per track are supported")
        }
        geometry = g
        bytes = [UInt8](repeating: 0, count: g.byteCount)

        // Boot sectors (T0 S1-S2).
        if let boot = bootSectors {
            let n = min(boot.count, 512)
            let base = g.offset(track: 0, sector: 1)
            for i in 0..<n { bytes[base + i] = boot[boot.startIndex + i] }
        }

        // Directory chain: sectors 5...spt-1 link to the next; sector spt ends.
        if g.spt > 5 {
            for s in 5..<g.spt { setLink(FlexTS(track: 0, sector: s), to: FlexTS(track: 0, sector: s + 1)) }
        }
        setLink(FlexTS(track: 0, sector: g.spt), to: .end)

        // Free chain: (1,1) ... (maxTrack, spt), in order.
        for t in 1...g.maxTrack {
            for s in 1...g.spt {
                let next: FlexTS
                if t == g.maxTrack && s == g.spt {
                    next = .end
                } else if s == g.spt {
                    next = FlexTS(track: t + 1, sector: 1)
                } else {
                    next = FlexTS(track: t, sector: s + 1)
                }
                setLink(FlexTS(track: t, sector: s), to: next)
            }
        }

        // SIR.
        setLabel(label)
        volumeNumber16 = volumeNumber
        firstFree = FlexTS(track: 1, sector: 1)
        lastFree = FlexTS(track: g.maxTrack, sector: g.spt)
        freeCount = g.blankFreeSectors
        setSIR(Self.sirDate, [UInt8(clamping: date.month), UInt8(clamping: date.day), UInt8(clamping: date.year)])
        setSIR(Self.sirMaxTrack, [UInt8(g.maxTrack)])
        setSIR(Self.sirMaxSector, [UInt8(g.spt)])
    }

    // MARK: Loading an existing image

    /// Reads geometry from the image's own SIR (the same offsets the Disk
    /// Image panel uses) and checks the file size matches it exactly.
    init(data: Data, lenient: Bool = false) throws {
        guard data.count >= 768 else { throw FlexError.notAFlexImage("file is too short to contain a SIR") }
        var b = [UInt8](data)
        let maxTrack = Int(b[512 + Self.sirMaxTrack])
        let spt = Int(b[512 + Self.sirMaxSector])
        let g = FlexGeometry(name: "From image", tracks: maxTrack + 1, spt: spt)
        guard g.isValid else {
            throw FlexError.notAFlexImage("SIR reports max track \(maxTrack), sectors per track \(spt)")
        }
        // Browsing tolerates images with trailing padding; building does not.
        if lenient && b.count > g.byteCount { b = Array(b[0..<g.byteCount]) }
        guard b.count == g.byteCount else {
            throw FlexError.notAFlexImage("size is \(b.count) bytes but the SIR geometry (\(g.tracks) x \(g.spt)) needs \(g.byteCount)")
        }
        geometry = g
        bytes = b
    }

    // MARK: Sector access

    func offset(_ ts: FlexTS) -> Int { geometry.offset(track: ts.track, sector: ts.sector) }

    func link(_ ts: FlexTS) -> FlexTS {
        let o = offset(ts)
        return FlexTS(track: Int(bytes[o]), sector: Int(bytes[o + 1]))
    }

    mutating func setLink(_ ts: FlexTS, to next: FlexTS) {
        let o = offset(ts)
        bytes[o] = UInt8(next.track)
        bytes[o + 1] = UInt8(next.sector)
    }

    func recordNumber(_ ts: FlexTS) -> Int {
        let o = offset(ts)
        return (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
    }

    // MARK: SIR access

    private var sirBase: Int { geometry.offset(track: 0, sector: Self.sirSector) }

    private func getSIR(_ off: Int, _ n: Int) -> [UInt8] {
        return Array(bytes[(sirBase + off)..<(sirBase + off + n)])
    }

    private mutating func setSIR(_ off: Int, _ values: [UInt8]) {
        for (i, v) in values.enumerated() { bytes[sirBase + off + i] = v }
    }

    var firstFree: FlexTS {
        get { let v = getSIR(Self.sirFirstFree, 2); return FlexTS(track: Int(v[0]), sector: Int(v[1])) }
        set { setSIR(Self.sirFirstFree, [UInt8(newValue.track), UInt8(newValue.sector)]) }
    }

    var lastFree: FlexTS {
        get { let v = getSIR(Self.sirLastFree, 2); return FlexTS(track: Int(v[0]), sector: Int(v[1])) }
        set { setSIR(Self.sirLastFree, [UInt8(newValue.track), UInt8(newValue.sector)]) }
    }

    var freeCount: Int {
        get { let v = getSIR(Self.sirFreeCount, 2); return (Int(v[0]) << 8) | Int(v[1]) }
        set { setSIR(Self.sirFreeCount, [UInt8((newValue >> 8) & 0xFF), UInt8(newValue & 0xFF)]) }
    }

    var volumeNumber16: Int {
        get { let v = getSIR(Self.sirVolume, 2); return (Int(v[0]) << 8) | Int(v[1]) }
        set { setSIR(Self.sirVolume, [UInt8((newValue >> 8) & 0xFF), UInt8(newValue & 0xFF)]) }
    }

    /// Volume label: 11 bytes (8 name + 3 extension), zero padded.
    var label: String {
        let raw = getSIR(Self.sirLabel, 11).filter { $0 != 0 }
        return String(bytes: raw, encoding: .ascii) ?? ""
    }

    mutating func setLabel(_ text: String) {
        let clean = FlexNames.sanitizeLabel(text)
        var field = [UInt8](repeating: 0, count: 11)
        for (i, b) in Array(clean.utf8).prefix(11).enumerated() { field[i] = b }
        setSIR(Self.sirLabel, field)
    }

    var dateText: String {
        let v = getSIR(Self.sirDate, 3)
        return String(format: "%02d/%02d/%02d", Int(v[0]), Int(v[1]), Int(v[2]))
    }

    var data: Data { Data(bytes) }
}

// MARK: - Names

enum FlexNames {
    private static func isLetter(_ c: UInt8) -> Bool {
        return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
    private static func isDigit(_ c: UInt8) -> Bool { return c >= 0x30 && c <= 0x39 }
    private static func isNameChar(_ c: UInt8) -> Bool {
        return isLetter(c) || isDigit(c) || c == 0x2D || c == 0x5F   // - _
    }

    /// Spec name rules: 1-8 characters, first a letter, the rest letters,
    /// digits, '-' or '_'; extension up to 3 characters from the same set.
    /// Returns an error message, or nil when valid. Names are checked in
    /// upper case.
    static func validate(name: String, ext: String) -> String? {
        let n = Array(name.uppercased().utf8)
        let e = Array(ext.uppercased().utf8)
        if n.isEmpty { return "name is empty" }
        if n.count > 8 { return "name '\(name)' is longer than 8 characters" }
        if !isLetter(n[0]) { return "name '\(name)' must start with a letter" }
        if !n.allSatisfy(isNameChar) { return "name '\(name)' may only contain letters, digits, - and _" }
        if e.count > 3 { return "extension '\(ext)' is longer than 3 characters" }
        if !e.allSatisfy(isNameChar) { return "extension '\(ext)' may only contain letters, digits, - and _" }
        return nil
    }

    /// Volume label: upper case, only characters FLEX accepts, 8 maximum.
    static func sanitizeLabel(_ text: String) -> String {
        let kept = text.uppercased().utf8.filter { isNameChar($0) }
        let s = String(bytes: Array(kept).prefix(8), encoding: .ascii) ?? ""
        return s.isEmpty ? "FLEX" : s
    }

    /// Splits a host file name ("prog.s19", "hello.txt") into upper-case
    /// FLEX name and extension at the last dot.
    static func split(hostFileName: String) -> (name: String, ext: String) {
        let upper = hostFileName.uppercased()
        if let dot = upper.lastIndex(of: "."), dot != upper.startIndex {
            return (String(upper[upper.startIndex..<dot]), String(upper[upper.index(after: dot)...]))
        }
        return (upper, "")
    }
}

// MARK: - Directory

struct FlexDirEntry {
    var name: String
    var ext: String
    var attributes: UInt8
    var start: FlexTS
    var end: FlexTS
    var sectorCount: Int
    var random: Bool
    var date: FlexDate
    var dirSector: FlexTS
    var slot: Int

    var fullName: String { ext.isEmpty ? name : "\(name).\(ext)" }
}

enum FlexDirectory {
    static let entriesPerSector = 10
    static let entrySize = 24
    static let firstEntryOffset = 16

    /// Directory sectors in chain order, following links from T0 S5. Stops at
    /// the end marker or at a safety cap, and never leaves track 0.
    static func sectors(in image: FlexImage) -> [FlexTS] {
        var out: [FlexTS] = []
        var ts = FlexTS(track: 0, sector: 5)
        while !ts.isEnd && out.count <= image.geometry.spt {
            guard ts.track == 0, ts.sector >= 5, ts.sector <= image.geometry.spt else { break }
            out.append(ts)
            ts = image.link(ts)
        }
        return out
    }

    private static func entryBase(_ image: FlexImage, _ sector: FlexTS, _ slot: Int) -> Int {
        return image.offset(sector) + firstEntryOffset + slot * entrySize
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        let raw = bytes.filter { $0 != 0 }
        return String(bytes: raw, encoding: .ascii) ?? ""
    }

    /// Live (not deleted) entries, in directory order, up to the first
    /// never-used slot (FLEX stops searching there).
    static func entries(in image: FlexImage) -> [FlexDirEntry] {
        var result: [FlexDirEntry] = []
        for sector in sectors(in: image) {
            for slot in 0..<entriesPerSector {
                let e = entryBase(image, sector, slot)
                let b = image.bytes
                if b[e] == 0 { return result }
                if b[e] & 0x80 != 0 { continue }
                result.append(FlexDirEntry(
                    name: text(b[e..<(e + 8)]),
                    ext: text(b[(e + 8)..<(e + 11)]),
                    attributes: b[e + 11],
                    start: FlexTS(track: Int(b[e + 13]), sector: Int(b[e + 14])),
                    end: FlexTS(track: Int(b[e + 15]), sector: Int(b[e + 16])),
                    sectorCount: (Int(b[e + 17]) << 8) | Int(b[e + 18]),
                    random: b[e + 19] != 0,
                    date: FlexDate(month: Int(b[e + 21]), day: Int(b[e + 22]), year: Int(b[e + 23])),
                    dirSector: sector, slot: slot))
            }
        }
        return result
    }

    /// First slot whose byte 0 is $00 (never used) or has bit 7 set (deleted).
    static func firstFreeSlot(in image: FlexImage) -> (sector: FlexTS, slot: Int)? {
        for sector in sectors(in: image) {
            for slot in 0..<entriesPerSector {
                let first = image.bytes[entryBase(image, sector, slot)]
                if first == 0 || first & 0x80 != 0 { return (sector, slot) }
            }
        }
        return nil
    }

    /// Number of unused slots (never used or deleted).
    static func freeSlotCount(in image: FlexImage) -> Int {
        var n = 0
        for sector in sectors(in: image) {
            for slot in 0..<entriesPerSector {
                let first = image.bytes[entryBase(image, sector, slot)]
                if first == 0 || first & 0x80 != 0 { n += 1 }
            }
        }
        return n
    }

    static func contains(name: String, ext: String, in image: FlexImage) -> Bool {
        let n = name.uppercased(), e = ext.uppercased()
        return entries(in: image).contains { $0.name.uppercased() == n && $0.ext.uppercased() == e }
    }

    static func write(_ entry: FlexDirEntry, in image: inout FlexImage, sector: FlexTS, slot: Int) {
        let e = entryBase(image, sector, slot)
        for i in 0..<entrySize { image.bytes[e + i] = 0 }
        for (i, c) in Array(entry.name.uppercased().utf8).prefix(8).enumerated() { image.bytes[e + i] = c }
        for (i, c) in Array(entry.ext.uppercased().utf8).prefix(3).enumerated() { image.bytes[e + 8 + i] = c }
        image.bytes[e + 11] = entry.attributes
        image.bytes[e + 13] = UInt8(entry.start.track)
        image.bytes[e + 14] = UInt8(entry.start.sector)
        image.bytes[e + 15] = UInt8(entry.end.track)
        image.bytes[e + 16] = UInt8(entry.end.sector)
        image.bytes[e + 17] = UInt8((entry.sectorCount >> 8) & 0xFF)
        image.bytes[e + 18] = UInt8(entry.sectorCount & 0xFF)
        image.bytes[e + 19] = entry.random ? 1 : 0
        image.bytes[e + 21] = UInt8(clamping: entry.date.month)
        image.bytes[e + 22] = UInt8(clamping: entry.date.day)
        image.bytes[e + 23] = UInt8(clamping: entry.date.year)
    }
}

// MARK: - Host file conversion

enum FlexFileKind: String, CaseIterable, Identifiable {
    case binary = "Binary"
    case text = "Text"
    case srecord = "S-record / hex"
    var id: String { rawValue }
}

struct FlexConversion {
    var bytes: [UInt8]
    var warnings: [String] = []
}

enum FlexFileConverter {

    // MARK: Type detection

    /// Guesses a kind from the host extension, falling back to a content sniff.
    static func detectKind(fileName: String, data: Data) -> FlexFileKind {
        // Content wins over the extension: S-record / Intel hex text must be
        // converted even if it is named .CMD or .BIN, otherwise the text
        // would be stored as if it were machine code.
        if looksLikeHostCode(data) { return .srecord }
        let ext = FlexNames.split(hostFileName: fileName).ext
        switch ext {
        case "CMD", "BIN", "SYS", "DAT", "COR", "OUT":
            return .binary
        case "S19", "S09", "S1", "S9", "SREC", "HEX", "S28", "S37":
            return .srecord
        case "TXT", "ASM", "BAS", "TEXT", "DOC", "LST", "C", "H", "INC", "MD", "A09":
            return .text
        default:
            break
        }
        let sample = data.prefix(4096)
        if sample.isEmpty { return .text }
        for b in sample {
            if b == 0 { return .binary }
            if b > 0x7F { return .binary }
            if b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D && b != 0x1A { return .binary }
        }
        return .text
    }

    /// True when the first line is an S-record (S0-S9) or Intel hex (:) record.
    static func looksLikeHostCode(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(256))
        guard !head.isEmpty else { return false }
        var line: [UInt8] = []
        for b in head {
            if b == 0x0A || b == 0x0D {
                if line.isEmpty { continue }
                break
            }
            line.append(b)
        }
        guard line.count >= 10 else { return false }
        func isHex(_ c: UInt8) -> Bool {
            return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
        }
        if line[0] == 0x53 || line[0] == 0x73 {                    // S
            guard line[1] >= 0x30 && line[1] <= 0x39 else { return false }
            return line.dropFirst(2).allSatisfy(isHex)
        }
        if line[0] == 0x3A {                                         // :
            return line.dropFirst().allSatisfy(isHex)
        }
        return false
    }

    /// Walks a FLEX binary file's records and describes it: load range,
    /// transfer address, and anything that will not load or will crash FLEX.
    static func analyzeBinary(_ b: [UInt8]) -> [String] {
        var notes: [String] = []
        var i = 0
        var lowest = Int.max
        var highest = -1
        var transfer: Int? = nil
        var records = 0
        while i < b.count {
            let t = b[i]
            if t == 0x00 { i += 1; continue }                         // padding
            if t == 0x02 {
                guard i + 3 < b.count else { notes.append("WARNING: truncated data record at byte \(i)"); return notes }
                let addr = (Int(b[i + 1]) << 8) | Int(b[i + 2])
                let n = Int(b[i + 3])
                guard i + 4 + n <= b.count else {
                    notes.append("WARNING: data record at byte \(i) runs past the end of the file")
                    return notes
                }
                lowest = min(lowest, addr)
                highest = max(highest, addr + max(n, 1) - 1)
                records += 1
                i += 4 + n
            } else if t == 0x16 {
                guard i + 2 < b.count else { notes.append("WARNING: truncated transfer record"); return notes }
                transfer = (Int(b[i + 1]) << 8) | Int(b[i + 2])
                i += 3
            } else {
                notes.append(String(format: "WARNING: not a FLEX binary - unexpected byte $%02X at offset %d (expected a $02 data or $16 transfer record)", t, i))
                return notes
            }
        }
        if records == 0 {
            notes.append("WARNING: no data records found - not a FLEX binary?")
            return notes
        }
        var info = String(format: "loads $%04X-$%04X", lowest, highest)
        if let t = transfer { info += String(format: ", starts at $%04X", t) } else { info += ", no start address (returns to FLEX)" }
        notes.append(info)
        // 6809 FLEX layout: utility command space $C100-$C6FF, FLEX itself
        // $C700-$DFFF (and the FCB / line buffer in $C000-$C0FF).
        if highest >= 0xC700 {
            notes.append("WARNING: loads at or above $C700, where FLEX itself lives - running it will overwrite FLEX")
        }
        // 6800 FLEX uses $A100 for utility commands and its DOS entry points
        // are $AD00-$AD3F; 6809 FLEX uses $C100 and $CD00. A file like that
        // is 6800 machine code and will crash a 6809.
        var calls6800 = false
        var j = 0
        var scan = 0
        while scan < b.count {
            let t = b[scan]
            if t == 0x02, scan + 3 < b.count {
                let n = Int(b[scan + 3])
                let end = min(b.count, scan + 4 + n)
                j = scan + 4
                while j + 2 < end {
                    if (b[j] == 0xBD || b[j] == 0x7E) && b[j + 1] == 0xAD && b[j + 2] < 0x40 { calls6800 = true }
                    j += 1
                }
                scan = end
            } else if t == 0x16 {
                scan += 3
            } else {
                scan += 1
            }
        }
        if calls6800 || lowest == 0xA100 {
            notes.append("WARNING: looks like a 6800 FLEX program (loads at $A100 / calls $ADxx). 6809 FLEX programs load at $C100 and call $CDxx - this will not run on a 6809")
        }
        if let t = transfer, t < lowest || t > highest {
            notes.append("WARNING: start address is outside the code it loads")
        }
        return notes
    }

    /// The extension a converted file gets on the FLEX disk by default.
    static func defaultFlexExtension(hostExtension: String, kind: FlexFileKind) -> String {
        return kind == .srecord ? "CMD" : hostExtension
    }

    // MARK: Entry point

    /// Converts a host file's bytes into the FLEX byte stream for `kind`.
    /// `transferAddress` is used for S-record/hex input that has no usable
    /// start address; pass nil to get `FlexError.needsTransferAddress` in
    /// that case, or `allowNoTransfer` to just omit the transfer record.
    static func convert(data: Data, kind: FlexFileKind, compressSpaces: Bool = false,
                        transferAddress: UInt16? = nil, allowNoTransfer: Bool = false) throws -> FlexConversion {
        switch kind {
        case .binary:
            let bytes = [UInt8](data)
            return FlexConversion(bytes: bytes, warnings: analyzeBinary(bytes))
        case .text:
            return convertText([UInt8](data), compressSpaces: compressSpaces)
        case .srecord:
            let text = String(decoding: data, as: UTF8.self)
            return try convertSRecord(text, transferAddress: transferAddress, allowNoTransfer: allowNoTransfer)
        }
    }

    // MARK: Text

    /// "Already FLEX": contains CR, no LF, every byte <= $7F, no trailing
    /// Ctrl-Z, and every $09 is followed by a plausible count byte.
    static func looksLikeFlexText(_ b: [UInt8]) -> Bool {
        guard b.contains(0x0D), !b.contains(0x0A), b.last != 0x1A else { return false }
        var i = 0
        while i < b.count {
            let c = b[i]
            if c > 0x7F { return false }
            if c == 0x09 {
                guard i + 1 < b.count, b[i + 1] >= 1, b[i + 1] <= 127 else { return false }
                i += 1
            }
            i += 1
        }
        return true
    }

    static func convertText(_ input: [UInt8], compressSpaces: Bool) -> FlexConversion {
        if looksLikeFlexText(input) { return FlexConversion(bytes: input) }

        var warnings: [String] = []
        var data = input
        while let last = data.last, last == 0x1A { data.removeLast() }   // trailing Ctrl-Z

        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var column = 0
        var dropped = 0
        var i = 0
        while i < data.count {
            let c = data[i]
            switch c {
            case 0x0D:
                out.append(0x0D); column = 0
                if i + 1 < data.count && data[i + 1] == 0x0A { i += 1 }     // CRLF -> CR
            case 0x0A:
                out.append(0x0D); column = 0                                  // LF -> CR
            case 0x09:
                let n = 8 - (column % 8)                                      // tab -> spaces
                out.append(contentsOf: [UInt8](repeating: 0x20, count: n))
                column += n
            case 0x80...0xFF:
                dropped += 1                                                  // FLEX text is 7-bit
            default:
                out.append(c); column += 1
            }
            i += 1
        }
        if dropped > 0 { warnings.append("removed \(dropped) byte(s) above $7F") }
        if let last = out.last, last != 0x0D {
            out.append(0x0D)                                                  // terminate last line
        }

        if compressSpaces { out = compress(out) }
        return FlexConversion(bytes: out, warnings: warnings)
    }

    /// Runs of 2+ spaces become $09, count (count <= 127).
    private static func compress(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == 0x20 {
                var run = 0
                while i + run < b.count && b[i + run] == 0x20 { run += 1 }
                var left = run
                while left > 0 {
                    let n = min(left, 127)
                    if n >= 2 { out.append(0x09); out.append(UInt8(n)) }
                    else { out.append(0x20) }
                    left -= n
                }
                i += run
            } else {
                out.append(b[i]); i += 1
            }
        }
        return out
    }

    // MARK: S-record / Intel hex -> FLEX binary records

    struct ParsedImage {
        var memory: [Int: UInt8] = [:]
        var start: Int? = nil
    }

    private static func hexBytes(_ s: Substring) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = 0
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        while i < chars.count {
            guard let h = nib(chars[i]), let l = nib(chars[i + 1]) else { return nil }
            out.append((h << 4) | l)
            i += 2
        }
        return out
    }

    static func parseHostCode(_ text: String) throws -> ParsedImage {
        var img = ParsedImage()
        var extendedBase = 0
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("S") || line.hasPrefix("s") {
                guard line.count >= 4 else { throw FlexError.conversion("short S-record line") }
                let typeChar = Array(line.utf8)[1]
                guard let body = hexBytes(line.dropFirst(2)), body.count >= 3 else {
                    throw FlexError.conversion("bad S-record line: \(line)")
                }
                let count = Int(body[0])
                guard body.count == count + 1 else { throw FlexError.conversion("S-record length mismatch: \(line)") }
                let sum = body.reduce(0) { Int($0) + Int($1) }
                guard (sum & 0xFF) == 0xFF else { throw FlexError.conversion("S-record checksum error: \(line)") }
                let payload = Array(body[1..<(body.count - 1)])
                let addrLen: Int
                switch typeChar {
                case 0x30: continue                         // S0 header
                case 0x31, 0x39: addrLen = 2
                case 0x32, 0x38: addrLen = 3
                case 0x33, 0x37: addrLen = 4
                case 0x35, 0x36: continue                   // record counts
                default: throw FlexError.conversion("unsupported S-record type in: \(line)")
                }
                guard payload.count >= addrLen else { throw FlexError.conversion("S-record too short: \(line)") }
                var addr = 0
                for i in 0..<addrLen { addr = (addr << 8) | Int(payload[i]) }
                if typeChar == 0x31 || typeChar == 0x32 || typeChar == 0x33 {
                    guard addr + payload.count - addrLen <= 0x10000 else {
                        throw FlexError.conversion("address above $FFFF in: \(line)")
                    }
                    for (i, byte) in payload[addrLen...].enumerated() { img.memory[addr + i] = byte }
                } else {
                    img.start = addr
                }
            } else if line.hasPrefix(":") {
                guard let body = hexBytes(line.dropFirst()), body.count >= 5 else {
                    throw FlexError.conversion("bad hex line: \(line)")
                }
                let len = Int(body[0])
                guard body.count == len + 5 else { throw FlexError.conversion("hex length mismatch: \(line)") }
                guard body.reduce(0, { Int($0) + Int($1) }) & 0xFF == 0 else {
                    throw FlexError.conversion("hex checksum error: \(line)")
                }
                let addr = (Int(body[1]) << 8) | Int(body[2])
                let type = body[3]
                let payload = Array(body[4..<(4 + len)])
                switch type {
                case 0x00:
                    for (i, byte) in payload.enumerated() {
                        let a = extendedBase + addr + i
                        guard a <= 0xFFFF else { throw FlexError.conversion("address above $FFFF in: \(line)") }
                        img.memory[a] = byte
                    }
                case 0x01: break
                case 0x02:
                    guard payload.count >= 2 else { throw FlexError.conversion("bad hex line: \(line)") }
                    extendedBase = ((Int(payload[0]) << 8) | Int(payload[1])) << 4
                case 0x04:
                    guard payload.count >= 2 else { throw FlexError.conversion("bad hex line: \(line)") }
                    extendedBase = ((Int(payload[0]) << 8) | Int(payload[1])) << 16
                case 0x03, 0x05:
                    if payload.count >= 4 { img.start = (Int(payload[2]) << 8) | Int(payload[3]) }
                default: break
                }
            } else {
                throw FlexError.conversion("not an S-record or Intel hex line: \(line)")
            }
        }
        return img
    }

    /// The start address in an S-record/hex file, if it has a usable one.
    /// $0000 is treated as "none": assemblers write S9 0000 when the source
    /// has no END address, and jumping to $0000 after loading would crash.
    static func startAddress(inHostCode text: String) -> UInt16? {
        guard let parsed = try? parseHostCode(text), let s = parsed.start, s > 0, s <= 0xFFFF else { return nil }
        return UInt16(s)
    }

    static func convertSRecord(_ text: String, transferAddress: UInt16?, allowNoTransfer: Bool) throws -> FlexConversion {
        let parsed = try parseHostCode(text)
        guard !parsed.memory.isEmpty else { throw FlexError.conversion("no data records found") }

        var warnings: [String] = []
        var out: [UInt8] = []
        let addresses = parsed.memory.keys.sorted()

        // Group each contiguous run into $02 records of up to 255 bytes.
        var runStart = addresses[0]
        var run: [UInt8] = []
        func flush() {
            var offset = 0
            while offset < run.count {
                let n = min(255, run.count - offset)
                let a = runStart + offset
                out.append(0x02)
                out.append(UInt8((a >> 8) & 0xFF))
                out.append(UInt8(a & 0xFF))
                out.append(UInt8(n))
                out.append(contentsOf: run[offset..<(offset + n)])
                offset += n
            }
            run.removeAll()
        }
        var expected = addresses[0]
        for a in addresses {
            if a != expected { flush(); runStart = a }
            run.append(parsed.memory[a] ?? 0)
            expected = a + 1
        }
        flush()

        // Transfer record.
        var transfer: Int? = nil
        if let s = parsed.start, s > 0 { transfer = s }
        else if let t = transferAddress { transfer = Int(t) }
        if let t = transfer {
            out.append(0x16)
            out.append(UInt8((t >> 8) & 0xFF))
            out.append(UInt8(t & 0xFF))
        } else if allowNoTransfer {
            warnings.append("no start address in the file; no transfer record written (the program loads and returns to FLEX)")
        } else {
            throw FlexError.needsTransferAddress
        }
        return FlexConversion(bytes: out, warnings: warnings)
    }
}

// MARK: - Allocator

enum FlexAllocator {
    /// Spec "Add a file". Works on a copy and only commits when every step
    /// has succeeded, so a failure never leaves the image half-modified.
    /// Returns warnings (e.g. zero-length file).
    @discardableResult
    static func addFile(to image: inout FlexImage, name: String, ext: String, stream: [UInt8],
                        attributes: UInt8 = 0, date: FlexDate = .today) throws -> [String] {
        var warnings: [String] = []
        if let problem = FlexNames.validate(name: name, ext: ext) { throw FlexError.invalidName(problem) }

        var data = stream
        if data.isEmpty {
            data = [UInt8](repeating: 0, count: 252)
            warnings.append("empty file: stored as one zero-filled sector")
        }
        let needed = (data.count + 251) / 252

        var work = image
        guard work.freeCount >= needed else { throw FlexError.diskFull(needed: needed, free: work.freeCount) }
        guard let slot = FlexDirectory.firstFreeSlot(in: work) else { throw FlexError.directoryFull }
        if FlexDirectory.contains(name: name, ext: ext, in: work) {
            throw FlexError.duplicateName(ext.isEmpty ? name.uppercased() : "\(name.uppercased()).\(ext.uppercased())")
        }

        // Take sectors from the head of the free chain, following its links.
        let first = work.firstFree
        var current = first
        var last = first
        var oldLinkOfLast = FlexTS.end
        for n in 1...needed {
            guard work.geometry.contains(current), current.track >= 1 else {
                throw FlexError.imageDamaged("free chain leaves the disk before \(needed) sectors")
            }
            let o = work.offset(current)
            let next = work.link(current)
            work.bytes[o + 2] = UInt8((n >> 8) & 0xFF)
            work.bytes[o + 3] = UInt8(n & 0xFF)
            let chunkStart = (n - 1) * 252
            for i in 0..<252 {
                let idx = chunkStart + i
                work.bytes[o + 4 + i] = idx < data.count ? data[idx] : 0
            }
            last = current
            oldLinkOfLast = next
            if n == needed { work.setLink(current, to: .end) }
            current = next
        }

        // SIR.
        work.freeCount = work.freeCount - needed
        if work.freeCount == 0 {
            work.firstFree = .end
            work.lastFree = .end
        } else {
            work.firstFree = oldLinkOfLast
        }

        // Directory entry.
        let entry = FlexDirEntry(name: name.uppercased(), ext: ext.uppercased(), attributes: attributes,
                                 start: first, end: last, sectorCount: needed, random: false, date: date,
                                 dirSector: slot.sector, slot: slot.slot)
        FlexDirectory.write(entry, in: &work, sector: slot.sector, slot: slot.slot)

        image = work
        return warnings
    }
}

// MARK: - Verifier

struct FlexReport {
    var errors: [String] = []
    var warnings: [String] = []
    var fileCount = 0
    var fileSectors = 0
    var freeSectors = 0
    var orphanedSectors = 0
    var ok: Bool { errors.isEmpty }
}

enum FlexVerifier {
    private enum Owner { case system, directory, file(String), free }

    /// The checks from the spec's Verification section, with a per-sector
    /// owner map so overlaps show up immediately.
    static func verify(_ image: FlexImage) -> FlexReport {
        var report = FlexReport()
        let g = image.geometry
        var owner: [FlexTS: Owner] = [:]

        if image.bytes.count != g.byteCount {
            report.errors.append("image size \(image.bytes.count) is not \((g.maxTrack + 1)) x \(g.spt) x 256")
            return report
        }
        for s in 1...4 { owner[FlexTS(track: 0, sector: s)] = .system }

        // Directory chain.
        var dirSectors: [FlexTS] = []
        var ts = FlexTS(track: 0, sector: 5)
        var dirOK = true
        while true {
            if ts.track != 0 || ts.sector < 5 || ts.sector > g.spt {
                report.errors.append("directory chain leaves track 0 / sectors 5-\(g.spt) at T\(ts.track) S\(ts.sector)")
                dirOK = false
                break
            }
            if dirSectors.contains(ts) { report.errors.append("directory chain loops at S\(ts.sector)"); dirOK = false; break }
            dirSectors.append(ts)
            owner[ts] = .directory
            let next = image.link(ts)
            if next.isEnd { break }
            ts = next
        }
        if dirOK, dirSectors.last?.sector != g.spt {
            report.warnings.append("directory chain ends at sector \(dirSectors.last?.sector ?? 0), not \(g.spt)")
        }

        // Live files.
        for entry in FlexDirectory.entries(in: image) {
            report.fileCount += 1
            let label = entry.fullName
            var chain: [FlexTS] = []
            var cur = entry.start
            var broken = false
            while !cur.isEnd {
                if !g.contains(cur) || cur.track < 1 {
                    report.errors.append("\(label): link points outside the geometry (T\(cur.track) S\(cur.sector))")
                    broken = true; break
                }
                if chain.count >= g.totalSectors { report.errors.append("\(label): chain loops"); broken = true; break }
                if let existing = owner[cur] {
                    switch existing {
                    case .file(let other): report.errors.append("\(label): sector T\(cur.track) S\(cur.sector) also belongs to \(other)")
                    case .free: report.errors.append("\(label): sector T\(cur.track) S\(cur.sector) is also on the free chain")
                    default: report.errors.append("\(label): sector T\(cur.track) S\(cur.sector) overlaps system/directory")
                    }
                    broken = true; break
                }
                owner[cur] = .file(label)
                chain.append(cur)
                cur = image.link(cur)
            }
            if broken { continue }
            if chain.count != entry.sectorCount {
                report.errors.append("\(label): chain has \(chain.count) sectors, directory says \(entry.sectorCount)")
            }
            if chain.last != entry.end {
                report.errors.append("\(label): chain ends at a different sector than the directory's end T/S")
            }
            for (i, s) in chain.enumerated() where image.recordNumber(s) != i + 1 {
                report.errors.append("\(label): record number \(image.recordNumber(s)) at position \(i + 1)")
                break
            }
            report.fileSectors += chain.count
        }

        // Free chain.
        var freeChain: [FlexTS] = []
        var cur = image.firstFree
        var freeBroken = false
        while !cur.isEnd {
            if !g.contains(cur) || cur.track < 1 {
                report.errors.append("free chain link outside the geometry (T\(cur.track) S\(cur.sector))")
                freeBroken = true; break
            }
            if freeChain.count >= g.totalSectors { report.errors.append("free chain loops"); freeBroken = true; break }
            if let existing = owner[cur] {
                if case .file(let other) = existing {
                    report.errors.append("free chain sector T\(cur.track) S\(cur.sector) belongs to \(other)")
                } else {
                    report.errors.append("free chain sector T\(cur.track) S\(cur.sector) listed twice or overlaps")
                }
                freeBroken = true; break
            }
            owner[cur] = .free
            freeChain.append(cur)
            cur = image.link(cur)
        }
        if !freeBroken {
            if freeChain.count != image.freeCount {
                report.errors.append("free chain has \(freeChain.count) sectors, SIR says \(image.freeCount)")
            }
            if let lastFreeActual = freeChain.last, lastFreeActual != image.lastFree {
                report.errors.append("SIR last-free T/S does not match the end of the free chain")
            }
            if freeChain.isEmpty && !(image.firstFree.isEnd && image.lastFree.isEnd) {
                report.errors.append("free count is 0 but SIR first/last free are not 00 00")
            }
        }
        report.freeSectors = freeChain.count

        // Accounting.
        var orphans = 0
        for t in 0...g.maxTrack {
            for s in 1...g.spt where owner[FlexTS(track: t, sector: s)] == nil { orphans += 1 }
        }
        report.orphanedSectors = orphans
        if orphans > 0 { report.warnings.append("\(orphans) orphaned sector(s) belong to no chain") }
        return report
    }
}

// MARK: - High-level builder

struct FlexBuildSummary {
    var added: [String] = []
    var skipped: [(name: String, reason: String)] = []
    var warnings: [String] = []
    var geometry: FlexGeometry?
    var freeAfter = 0
}

enum FlexDiskBuilder {
    /// Spec "Build from folder": smallest preset that fits the sectors and
    /// directory slots with at least 10% of free sectors to spare; CF large
    /// as the fallback; nil if even that is too small.
    static func chooseGeometry(sectorsNeeded: Int, entriesNeeded: Int) -> FlexGeometry? {
        let sorted = FlexGeometry.presets.sorted { $0.blankFreeSectors < $1.blankFreeSectors }
        for g in sorted {
            let spare = Double(g.blankFreeSectors - sectorsNeeded) / Double(g.blankFreeSectors)
            if sectorsNeeded <= g.blankFreeSectors && spare >= 0.10 && entriesNeeded <= g.directorySlots { return g }
        }
        let cf = FlexGeometry.cfLarge
        if sectorsNeeded <= cf.blankFreeSectors && entriesNeeded <= cf.directorySlots { return cf }
        return nil
    }

    private struct Candidate {
        var name: String
        var ext: String
        var stream: [UInt8]
        var warnings: [String]
    }

    /// Whole folder -> one image. Files that fail conversion or naming are
    /// skipped and listed; the rest still go on the disk. Returns nil image
    /// if nothing could be added or the result fails verification (the
    /// summary says why).
    static func buildFromFolder(_ folder: URL, date: FlexDate = .today) -> (image: FlexImage?, summary: FlexBuildSummary) {
        var summary = FlexBuildSummary()
        let fm = FileManager.default
        let contents = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])) ?? [])
            .sorted { $0.lastPathComponent.uppercased() < $1.lastPathComponent.uppercased() }

        var candidates: [Candidate] = []
        var seen = Set<String>()
        for url in contents {
            let fileName = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }       // skip subfolders
            if fileName.hasPrefix(".") { continue }                       // .DS_Store etc.

            guard let data = try? Data(contentsOf: url) else {
                summary.skipped.append((fileName, "could not read the file")); continue
            }
            let kind = FlexFileConverter.detectKind(fileName: fileName, data: data)
            let parts = FlexNames.split(hostFileName: fileName)
            let ext = FlexFileConverter.defaultFlexExtension(hostExtension: parts.ext, kind: kind)
            if let problem = FlexNames.validate(name: parts.name, ext: ext) {
                summary.skipped.append((fileName, problem)); continue
            }
            let key = "\(parts.name).\(ext)"
            if seen.contains(key) { summary.skipped.append((fileName, "would duplicate \(key)")); continue }
            do {
                let conv = try FlexFileConverter.convert(data: data, kind: kind, allowNoTransfer: true)
                candidates.append(Candidate(name: parts.name, ext: ext, stream: conv.bytes,
                                            warnings: conv.warnings.map { "\(fileName): \($0)" }))
                seen.insert(key)
            } catch {
                summary.skipped.append((fileName, error.localizedDescription))
            }
        }

        guard !candidates.isEmpty else {
            summary.warnings.append("no usable files in \(folder.lastPathComponent)")
            return (nil, summary)
        }
        candidates.sort { "\($0.name).\($0.ext)" < "\($1.name).\($1.ext)" }

        let sectorsNeeded = candidates.reduce(0) { $0 + max(1, ($1.stream.count + 251) / 252) }
        guard let geometry = chooseGeometry(sectorsNeeded: sectorsNeeded, entriesNeeded: candidates.count) else {
            summary.warnings.append("\(sectorsNeeded) sectors / \(candidates.count) files do not fit even the CF large preset")
            return (nil, summary)
        }
        summary.geometry = geometry

        guard var image = try? FlexImage(formatting: geometry, label: folder.lastPathComponent,
                                         volumeNumber: 1, date: date) else {
            summary.warnings.append("could not format an image")
            return (nil, summary)
        }
        for c in candidates {
            do {
                let w = try FlexAllocator.addFile(to: &image, name: c.name, ext: c.ext, stream: c.stream, date: date)
                summary.added.append(c.ext.isEmpty ? c.name : "\(c.name).\(c.ext)")
                summary.warnings.append(contentsOf: c.warnings)
                summary.warnings.append(contentsOf: w.map { "\(c.name): \($0)" })
            } catch {
                summary.skipped.append(("\(c.name).\(c.ext)", error.localizedDescription))
            }
        }

        let report = FlexVerifier.verify(image)
        summary.warnings.append(contentsOf: report.warnings)
        guard report.ok else {
            summary.warnings.append(contentsOf: report.errors.map { "verification: \($0)" })
            return (nil, summary)
        }
        summary.freeAfter = image.freeCount
        return (image, summary)
    }
}

// MARK: - Extraction (reading files back out of an image)

struct FlexExtracted {
    var bytes: [UInt8]
    var warnings: [String] = []
}

/// What a file looks like, for the browser's middle panel.
struct FlexFileInfo {
    enum Kind: String { case binary = "Binary", text = "Text", data = "Data", random = "Random" }
    var kind: Kind
    var notes: [String] = []
    var preview: String = ""
    var byteCount: Int = 0
    /// True when the notes say this is 6800 code (it will not run on a 6809).
    var is6800: Bool { notes.contains { $0.contains("6800 FLEX program") } }
    var hasWarning: Bool { notes.contains { $0.hasPrefix("WARNING") } }
}

enum FlexExtractor {
    /// The stored bytes of a sequential file: the 252 data bytes of every
    /// sector on its chain, in order. Zero padding in the last sector is
    /// kept, so copying the stream to another disk reproduces the file
    /// exactly (same sector count). Random-access files are refused: their
    /// sector map holds track/sector addresses that would have to be rebuilt.
    static func stream(of entry: FlexDirEntry, in image: FlexImage) throws -> FlexExtracted {
        if entry.random {
            throw FlexError.conversion("\(entry.fullName) is a random-access file; copying those is not supported")
        }
        var out: [UInt8] = []
        var visited = Set<FlexTS>()
        var warnings: [String] = []
        var ts = entry.start
        while !ts.isEnd {
            guard image.geometry.contains(ts), visited.insert(ts).inserted else {
                throw FlexError.imageDamaged("\(entry.fullName): sector chain is broken or loops at T\(ts.track) S\(ts.sector)")
            }
            let o = image.offset(ts)
            out.append(contentsOf: image.bytes[(o + 4)..<(o + 256)])
            ts = image.link(ts)
        }
        if visited.count != entry.sectorCount {
            warnings.append("directory says \(entry.sectorCount) sectors but the chain has \(visited.count)")
        }
        return FlexExtracted(bytes: out, warnings: warnings)
    }

    /// Classify a file's bytes and prepare a short preview.
    static func describe(_ bytes: [UInt8]) -> FlexFileInfo {
        let first = bytes.first(where: { $0 != 0 })
        if first == 0x02 {
            var info = FlexFileInfo(kind: .binary, byteCount: bytes.count)
            info.notes = FlexFileConverter.analyzeBinary(bytes)
            info.preview = hexDump(bytes, limit: 256)
            return info
        }
        if first != nil, FlexFileConverter.looksLikeFlexText(bytes) {
            var info = FlexFileInfo(kind: .text, byteCount: bytes.count)
            info.preview = textPreview(bytes, limit: 6000)
            return info
        }
        var info = FlexFileInfo(kind: .data, byteCount: bytes.count)
        info.preview = hexDump(bytes, limit: 256)
        return info
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// CRC-32 (8 hex digits) of a file's bytes with trailing zero padding
    /// removed, so two copies of the same file match even if one has more
    /// padding in its last sector.
    static func checksum(_ b: [UInt8]) -> String {
        var end = b.count
        while end > 0 && b[end - 1] == 0 { end -= 1 }
        var crc: UInt32 = 0xFFFFFFFF
        for i in 0..<end { crc = crcTable[Int((crc ^ UInt32(b[i])) & 0xFF)] ^ (crc >> 8) }
        return String(format: "%08X", crc ^ 0xFFFFFFFF)
    }

    /// FLEX text as a Mac text file: CR becomes LF, $09 nn expands to nn
    /// spaces, zero padding and the $04 end marker are dropped. No length limit.
    static func hostText(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x0D: out.append(0x0A)
            case 0x09:
                if i + 1 < b.count {
                    out.append(contentsOf: [UInt8](repeating: 0x20, count: Int(b[i + 1])))
                    i += 1
                }
            case 0x00, 0x04: break
            default: out.append(c)
            }
            i += 1
        }
        return out
    }

    /// FLEX text to plain text: CR becomes a newline, $09 nn expands to nn
    /// spaces, zero padding and the $04 end marker are dropped.
    static func textPreview(_ b: [UInt8], limit: Int) -> String {
        var out = ""
        var i = 0
        while i < b.count && out.count < limit {
            let c = b[i]
            switch c {
            case 0x0D: out.append("\n")
            case 0x09:
                if i + 1 < b.count { out.append(String(repeating: " ", count: Int(b[i + 1]))); i += 1 }
            case 0x20...0x7E: out.append(Character(UnicodeScalar(c)))
            default: break
            }
            i += 1
        }
        if i < b.count && out.count >= limit { out += "\n…" }
        return out
    }

    static func hexDump(_ b: [UInt8], limit: Int) -> String {
        var lines: [String] = []
        var i = 0
        while i < min(b.count, limit) {
            let row = b[i..<min(b.count, i + 16)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let asc = row.map { ($0 >= 0x20 && $0 < 0x7F) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%04X  ", i) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + asc)
            i += 16
        }
        if b.count > limit { lines.append("…") }
        return lines.joined(separator: "\n")
    }
}
