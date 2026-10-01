import Foundation

/// A single line of progress/log output streamed from minipro, e.g.
/// "Writing Code...  42.13%   0.31Sec"
struct ProgrammerLogLine: Identifiable {
    let id = UUID()
    let text: String
}

enum ProgrammerAction {
    case read
    case write
    case verify
    case erase
    case identify

    /// The single flag selecting this action. Kept separate from
    /// `extraFlags` below because minipro's getopt-style parser consumes
    /// whatever argv entry comes immediately after a flag that takes a
    /// value (like "-w <file>") -- it does not skip over another flag to
    /// find it. Putting "-u" right after "-w" (as a previous version of
    /// this code did) made minipro swallow "-u" itself as -w's filename
    /// argument, then choke on the real path as an unexpected "Extra
    /// argument". The filename has to land immediately after this flag;
    /// any modifier flags belong in extraFlags, added elsewhere in the
    /// argument list instead.
    var minitproFlag: String {
        switch self {
        case .read:     return "-r"
        case .write:    return "-w"
        case .verify:   return "-m"   // compare/verify against file
        case .erase:    return "-E"
        case .identify: return "-D"   // read_id -- just read the chip ID, no file needed.
                                    // ("-q" is --programmer, which forces a
                                    // programmer *version* and requires an
                                    // argument -- it was never the right flag
                                    // here and would have made minipro reject
                                    // the invocation outright.)
        }
    }

    /// Modifier flags that take no value of their own, safe to place
    /// anywhere else in the argument list (not between minitproFlag and
    /// the filename -- see its doc comment).
    var extraFlags: [String] {
        switch self {
        // "-u" disables the chip's own software data-protect (SDP) latch
        // before writing/erasing. Without it, a chip that has SDP enabled
        // from some earlier write (AT28C256 and similar EEPROMs ship with
        // -- or can end up with -- this on) silently ignores new data at
        // protected addresses: minipro still reports "Write...OK", but the
        // later verify pass reads back the chip's old/blank contents and
        // fails with "Verification failed... Device=0xFF. This chip may be
        // write-protected. Use -u and try again." -- which is minipro's own
        // suggested fix.
        case .write, .erase: return ["-u"]
        case .read, .verify, .identify: return []
        }
    }
}

enum ProgrammerRunnerError: LocalizedError {
    case miniproNotFound
    var errorDescription: String? {
        "minipro wasn't found. Install it with `brew install minipro`, then set its path in Settings if it's not on your PATH."
    }
}

/// Drives a TL866 II+/CS EPROM programmer via the open-source `minipro`
/// command-line tool (https://gitlab.com/DavidGriffith/minipro), which
/// already implements the (reverse-engineered, GPL-licensed) TL866 USB
/// protocol. This class only shells out to it -- it does not reimplement
/// any of that protocol itself.
@MainActor
final class ProgrammerRunner: ObservableObject {
    @Published var isBusy = false
    @Published var log: [ProgrammerLogLine] = []
    @Published var lastProgress: Double = 0 // 0...1
    /// The actual attached unit, read straight off minipro's own connect
    /// banner (e.g. "Found TL866II+ 04.2.111 (0x26f)") on any command that
    /// talks to the hardware -- Identify chief among them. This is a more
    /// reliable source of the exact "-q" value minipro expects than asking
    /// the user to pick one blind, since it comes from minipro itself
    /// naming the unit it's actually talking to.
    @Published var detectedProgrammerVersion: String?

    /// Accumulates every byte seen so far during the current run, so the
    /// "Found <model>..." banner can be matched even if the OS happens to
    /// deliver it to us split across two or more separate pipe reads
    /// (matching against each raw chunk independently, as the log-line
    /// splitting below does for display, can miss a token straddling a
    /// chunk boundary). Reset at the start of each run().
    private var rawOutputBuffer = ""

    /// Resolved lazily; a user-configured path from Settings takes priority,
    /// then common Homebrew locations, then PATH.
    func resolveMiniproPath() -> String? {
        let configured = AppSettings.shared.miniproExecutablePath
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        let candidates = [
            "/opt/homebrew/bin/minipro",  // Apple Silicon Homebrew
            "/usr/local/bin/minipro",      // Intel Homebrew
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to PATH via `which`, in case the user installed it another way.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "minipro"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// Runs a minipro invocation that just prints information to parse
    /// (device/programmer listings) rather than reading/writing a chip --
    /// kept separate from `run(action:...)` because it doesn't touch the
    /// published busy/log/progress state that drives the main action
    /// buttons, and can safely run concurrently with the UI just sitting
    /// there (e.g. while the user is still typing a search).
    private func queryLines(_ args: [String]) async throws -> [String] {
        guard let miniproPath = resolveMiniproPath() else {
            throw ProgrammerRunnerError.miniproNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: miniproPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // -l/-L/-Q's listing goes to stdout in
                                      // some minipro versions and stderr in
                                      // others -- merge both so this doesn't
                                      // depend on which.
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        // Queries (search/list) never otherwise show up anywhere visible --
        // unlike run(action:...), they don't touch `log`. Echo the raw
        // invocation and its output there too (clearly marked) purely for
        // diagnosis: if a search ever comes back with nonsense, the actual
        // minipro command and response are sitting right there in the same
        // panel instead of being invisible.
        log.append(ProgrammerLogLine(text: "[query] minipro \(args.joined(separator: " "))"))
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
            log.append(ProgrammerLogLine(text: "[query] \(line)"))
        }
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    }

    /// minipro's own device-list output (`-l` for everything, `-L <query>`
    /// filtered) is one device per line, name first, then descriptive
    /// columns -- take just the leading token and drop anything that isn't
    /// a plausible device name (blank lines, a header row, a "not found"
    /// message). There are 13,000+ devices in the unfiltered list, so
    /// callers doing live search-as-you-type should always pass a query
    /// rather than fetching everything.
    private static func parseListedNames(from lines: [String]) -> [String] {
        lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let first = trimmed.split(separator: " ").first else { return nil }
            let name = String(first)
            // Filter out obvious non-device lines (a usage/error message
            // starting with a capitalized sentence word, or minipro's own
            // "Found N devices" style summary line) -- device names in
            // minipro's database don't contain plain English words like this.
            let noise: Set<String> = ["Found", "No", "Usage:", "Error:", "Warning:"]
            guard !noise.contains(name) else { return nil }
            return name
        }
    }

    /// Devices matching `query` via minipro's own "-L" search (case-
    /// insensitive substring match against its ~13,000-device database).
    /// Pass a non-empty query -- this is meant for live search-as-you-type,
    /// not for fetching the entire list. `programmerVersion`, if non-empty,
    /// restricts the search to devices that model actually supports (e.g.
    /// "minipro -q TL866II+ -L 28C256") -- different XGecu hardware
    /// generations support different chip sets, so filtering by the
    /// programmer you're actually using avoids picking a device your unit
    /// can't program. Leave empty to search the full, unfiltered database.
    func searchDevices(matching query: String, programmerVersion: String = "") async throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var args: [String] = []
        if !programmerVersion.isEmpty {
            args += ["-q", programmerVersion]
        }
        args += ["-L", query]
        let lines = try await queryLines(args)
        return Self.parseListedNames(from: lines)
    }

    /// The programmer models minipro can target ("-Q"). Falls back to the
    /// fixed set minipro's own docs enumerate (TL866A, TL866II+, T48, T56)
    /// if the query fails or returns nothing usable -- these are compiled-in
    /// constants in minipro, not something that varies by install, so the
    /// fallback is never stale.
    func listProgrammerVersions() async -> [String] {
        let fallback = ["TL866A", "TL866II", "T48", "T56"]
        guard let lines = try? await queryLines(["-Q"]) else { return fallback }
        let parsed = Self.parseListedNames(from: lines)
        return parsed.isEmpty ? fallback : parsed
    }

    /// Runs a minipro action for the given device (e.g. "AT28C256").
    /// `fileURL` is required for .read/.write/.verify. `programmerVersion`
    /// is accepted for signature compatibility with the panel/search calls
    /// but deliberately NOT passed to minipro here -- its own man page is
    /// explicit that "-q/--programmer" only "forces a programmer version
    /// when *listing* devices" (i.e. alongside -L/-l/-d). Passing it on a
    /// real hardware action (-r/-w/-m/-E/-D) makes minipro respond "-L, -l
    /// or -d command is required for this action", since as far as minipro
    /// is concerned -q has nothing to do with here -- for actual hardware
    /// actions minipro identifies the connected programmer itself.
    /// `fileFormat`, if non-empty, is passed as "-f <format>" (e.g. "ihex")
    /// -- needed when `fileURL` is an Intel HEX file (as produced by
    /// combining several inputs via srec_cat) rather than a raw binary.
    func run(action: ProgrammerAction, device: String, programmerVersion: String = "", fileFormat: String = "", fileURL: URL?) async throws -> Bool {
        guard let miniproPath = resolveMiniproPath() else {
            throw ProgrammerRunnerError.miniproNotFound
        }

        isBusy = true
        lastProgress = 0
        log.removeAll()
        rawOutputBuffer = ""
        defer { isBusy = false }

        var args = ["-p", device]
        if !fileFormat.isEmpty {
            args += ["-f", fileFormat]
        }
        args.append(action.minitproFlag)
        if let fileURL, action != .identify, action != .erase {
            // Must come immediately after minitproFlag -- see its doc comment.
            args.append(fileURL.path)
        }
        args += action.extraFlags
        args += AppSettings.splitArguments(AppSettings.shared.programmerExtraArguments)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: miniproPath)
        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stderrPipe // minipro writes progress to stderr; merge both

        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendChunk(chunk)
            }
        }

        try process.run()
        process.waitUntilExit()

        // A fast failure (minipro prints one short error line and exits
        // immediately) races with the readabilityHandler above, which
        // delivers each chunk asynchronously via `Task { @MainActor in ... }`.
        // waitUntilExit() can return -- and the process can already be
        // reaped -- before that last callback has actually run, so tearing
        // down the handler and returning right away can silently drop the
        // only output minipro ever produced, leaving an empty log with no
        // clue why the action failed. Drain whatever's left on the pipe
        // directly (synchronously, since this function already runs on the
        // main actor) before clearing the handler, so a fast failure still
        // shows its error line.
        let remaining = handle.availableData
        handle.readabilityHandler = nil
        if !remaining.isEmpty, let chunk = String(data: remaining, encoding: .utf8) {
            appendChunk(chunk)
        }

        let succeeded = process.terminationStatus == 0
        if !succeeded {
            appendChunk("\n[exit code \(process.terminationStatus)]")
        }
        return succeeded
    }

    private func appendChunk(_ chunk: String) {
        // Match against the whole accumulated buffer, not just this one
        // chunk -- a pipe read can split "Found TL866II+..." partway
        // through the model name, and only the fully-accumulated text is
        // guaranteed to contain it as one contiguous substring. Recomputed
        // (not just checked once) on every chunk so swapping to a
        // different programmer between runs is picked up too -- cheap
        // enough, and @Published only actually notifies observers when the
        // value changes.
        rawOutputBuffer += chunk
        if let version = Self.parseProgrammerVersion(from: rawOutputBuffer) {
            detectedProgrammerVersion = version
        }

        // minipro rewrites a single progress line with \r; split on both.
        // (This splitting is only for what gets displayed in the log --
        // see rawOutputBuffer above for why banner detection can't use the
        // same per-piece chunks.)
        let pieces = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for piece in pieces {
            let text = String(piece)
            guard !text.isEmpty else { continue }
            log.append(ProgrammerLogLine(text: text))
            if let percent = Self.parsePercent(from: text) {
                lastProgress = percent
            }
        }
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }

    /// Pulls the model name out of minipro's own connect banner, e.g.
    /// "Found TL866II+ 04.2.111 (0x26f)" -> "TL866II+", *then* normalizes
    /// it to what "-q" actually accepts. minipro's man page is explicit:
    /// "Possible values (case insensitive): TL866A TL866II T48 T56" -- no
    /// "+"/"Plus" at all, despite the connect banner (and the box, and the
    /// product name everywhere else) always calling it "TL866II+". Passing
    /// the banner's own spelling back to "-q" is exactly what produced
    /// "Unknown programmer version".
    private static func parseProgrammerVersion(from text: String) -> String? {
        guard let range = text.range(of: #"Found (\S+)"#, options: .regularExpression) else { return nil }
        let matched = text[range]
        guard let raw = matched.split(separator: " ", maxSplits: 1).last.map(String.init) else { return nil }
        return normalizedForCLI(raw)
    }

    /// Maps a display-style model name (as minipro's banner or a person
    /// might write it) to the bare token "-q" actually accepts. Matches by
    /// prefix so "TL866II+", "TL866IIplus", "TL866II Plus" etc. all land on
    /// the same "TL866II", and "TL866CS" (a real, distinct unit) is grouped
    /// under "TL866A" per minipro's own docs ("currently supports the
    /// TL866A/CS...").
    private static func normalizedForCLI(_ raw: String) -> String {
        let upper = raw.uppercased()
        if upper.hasPrefix("TL866II") { return "TL866II" }
        if upper.hasPrefix("TL866CS") || upper.hasPrefix("TL866A") { return "TL866A" }
        if upper.hasPrefix("T48") { return "T48" }
        if upper.hasPrefix("T56") { return "T56" }
        return raw
    }

    private static func parsePercent(from line: String) -> Double? {
        guard let range = line.range(of: #"[\d.]+%"#, options: .regularExpression) else { return nil }
        let numeric = line[range].dropLast() // drop trailing %
        guard let value = Double(numeric) else { return nil }
        return min(max(value / 100.0, 0), 1)
    }
}
