import Foundation

/// One assembler diagnostic line, parsed from a09's stderr/listing output.
struct AssemblerDiagnostic: Identifiable {
    enum Severity { case error, warning }
    let id = UUID()
    let severity: Severity
    let line: Int?
    let message: String
}

struct AssemblerResult {
    var succeeded: Bool
    var diagnostics: [AssemblerDiagnostic]
    var listing: String
    var binary: Data?
    var rawOutput: String
    /// Motorola S-record (S1/S9) text generated alongside the binary output,
    /// for the Terminal tab's "Download (S9)" button. Nil if the build
    /// failed before a09 could produce output.
    var sRecord: String? = nil
    /// Intel Hex text, generated the same way as sRecord (a09's own "-x"
    /// output flag, confirmed in a09.c). This is what gets saved next to
    /// the source file -- srec_cat (used by the Programmer panel to combine
    /// multiple files) reads Intel Hex more directly than a raw binary,
    /// since the hex file already carries each byte's real address instead
    /// of needing a separately-typed base address.
    var intelHex: String? = nil
}

enum AssemblerRunnerError: LocalizedError {
    case toolNotFound
    case processFailedToLaunch(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "The a09 assembler tool isn't bundled with the app. Check the 'Copy a09 Tool' build phase."
        case .processFailedToLaunch(let reason):
            return "Couldn't launch a09: \(reason)"
        }
    }
}

/// Runs the bundled `a09` command-line assembler as a subprocess and
/// collects its listing, binary output, and diagnostics.
///
/// a09 is invoked exactly as it would be from a Terminal:
///   a09 -b<bin> -l<lst> <source>
/// so nothing about the original assembler's behavior is reimplemented --
/// this class only shells out to it and parses plain text it already prints.
final class AssemblerRunner {

    /// Locates the bundled a09 executable. Add it to the app target via a
    /// "Copy Files" build phase (Destination: Executables) as described in
    /// README.md.
    static func bundledToolURL() -> URL? {
        Bundle.main.url(forResource: "a09", withExtension: nil)
    }

    /// Resolves which a09 to run: a user-configured path from Settings
    /// (Settings > Assembler > Assembler Executable) if set, otherwise the
    /// tool bundled inside the app.
    private func resolveToolURL() -> URL? {
        let configured = AppSettings.shared.assemblerExecutablePath
        if !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return Self.bundledToolURL()
    }

    /// Assembles `source`. Runs synchronously on a background queue via the
    /// async signature; call from a Task { } in the UI layer.
    func assemble(source: String, sourceFileName: String = "main.asm") async throws -> AssemblerResult {
        guard let toolURL = resolveToolURL() else {
            throw AssemblerRunnerError.toolNotFound
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("A09Studio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let srcURL = workDir.appendingPathComponent(sourceFileName)
        let binURL = workDir.appendingPathComponent("out.bin")
        let lstURL = workDir.appendingPathComponent("out.lst")
        let s19URL = workDir.appendingPathComponent("out.s19")
        let hexURL = workDir.appendingPathComponent("out.hex")

        try source.write(to: srcURL, atomically: true, encoding: .utf8)

        let extraArgs = AppSettings.splitArguments(AppSettings.shared.assemblerExtraArguments)

        // a09's -B/-F/-R/-S/-X output-format flags turn out NOT to be
        // independent/combinable despite each taking its own filename --
        // they appear to be mutually exclusive (last one wins), so asking
        // for -b and -s together silently dropped the binary output. To
        // avoid any risk of regressing the binary/listing build (which
        // worked fine before S-record support was added), this is run
        // exactly as before, unchanged, in its own invocation.
        let process = Process()
        process.executableURL = toolURL
        process.currentDirectoryURL = workDir
        process.arguments = [
            "-b\(binURL.path)",
            "-l\(lstURL.path)"
        ] + extraArgs + [
            srcURL.path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AssemblerRunnerError.processFailedToLaunch(error.localizedDescription)
        }

        // Drain pipes concurrently with waitUntilExit to avoid deadlock on
        // large listings.
        async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(stderrPipe.fileHandleForReading)
        let (outData, errData) = await (stdoutData, stderrData)

        process.waitUntilExit()

        let stdoutText = String(data: outData, encoding: .utf8) ?? ""
        let stderrText = String(data: errData, encoding: .utf8) ?? ""
        let combined = stdoutText + stderrText

        let listing = (try? String(contentsOf: lstURL, encoding: .utf8)) ?? ""
        let binaryData = try? Data(contentsOf: binURL)

        let diagnostics = Self.parseDiagnostics(from: combined + "\n" + listing)

        // Second, separate, best-effort pass purely to produce the
        // S-record for the Terminal tab's Download button. It reuses the
        // same source and extra arguments but never influences
        // succeeded/diagnostics -- if it fails for any reason, sRecord is
        // simply nil and the Download button stays disabled.
        var sRecordText: String? = nil
        var intelHexText: String? = nil
        if binaryData != nil {
            let sProcess = Process()
            sProcess.executableURL = toolURL
            sProcess.currentDirectoryURL = workDir
            sProcess.arguments = ["-s\(s19URL.path)"] + extraArgs + [srcURL.path]
            sProcess.standardOutput = Pipe()
            sProcess.standardError = Pipe()
            if (try? sProcess.run()) != nil {
                sProcess.waitUntilExit()
                sRecordText = try? String(contentsOf: s19URL, encoding: .utf8)
            }

            let xProcess = Process()
            xProcess.executableURL = toolURL
            xProcess.currentDirectoryURL = workDir
            xProcess.arguments = ["-x\(hexURL.path)"] + extraArgs + [srcURL.path]
            xProcess.standardOutput = Pipe()
            xProcess.standardError = Pipe()
            if (try? xProcess.run()) != nil {
                xProcess.waitUntilExit()
                intelHexText = try? String(contentsOf: hexURL, encoding: .utf8)
            }
        }
        // a09's own exit code turns out not to be a reliable success signal
        // -- it can come back non-zero on a perfectly clean assemble (e.g.
        // if it exits non-zero whenever there's any diagnostic at all, even
        // just a warning), so it's deliberately not used here. Success is
        // instead judged from what actually happened: a binary was written,
        // and parseDiagnostics -- which now skips a09's own tally line --
        // found no genuine error.
        let hasRealErrors = diagnostics.contains { $0.severity == .error }
        let succeeded = binaryData != nil && !hasRealErrors

        return AssemblerResult(
            succeeded: succeeded,
            diagnostics: diagnostics,
            listing: listing,
            binary: binaryData,
            rawOutput: combined,
            sRecord: sRecordText,
            intelHex: intelHexText
        )
    }

    private func readAll(_ handle: FileHandle) async -> Data {
        handle.readDataToEndOfFile()
    }

    /// a09 prints per-line diagnostics like:
    ///   "*** Error 12 in line 5 of main.asm: Undefined symbol"
    ///   "*** warning 3: ..."
    /// always prefixed with three literal asterisks (confirmed against
    /// a09's own source -- every putlist() call that emits a diagnostic
    /// starts the line with "*** Error" or "*** warning"), and finishes
    /// every run (success or failure) with a tally line such as "0
    /// error(s), 0 warning(s)".
    ///
    /// Matching is anchored to that "***" prefix rather than a bare
    /// substring search for "error"/"warning" -- the listing also echoes
    /// the original source verbatim, and assembly source routinely has
    /// comments that legitimately contain those words (e.g. a doc comment
    /// describing a routine's exit conditions: "* (B) = Error condition"),
    /// which a bare substring match misfiled as real diagnostics.
    static func parseDiagnostics(from text: String) -> [AssemblerDiagnostic] {
        var results: [AssemblerDiagnostic] = []
        let lineRegex = try? NSRegularExpression(pattern: #"line (\d+)"#)
        let summaryRegex = try? NSRegularExpression(pattern: #"^\d+\s+(error|warning)"#, options: [.caseInsensitive])
        let diagnosticRegex = try? NSRegularExpression(pattern: #"^\*\*\*\s+(error|warning)\b"#, options: [.caseInsensitive])

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let summaryRegex, summaryRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                continue
            }
            guard let diagnosticRegex,
                  diagnosticRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else {
                continue
            }

            let lower = line.lowercased()
            var lineNumber: Int? = nil
            if let regex = lineRegex,
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                lineNumber = Int(line[range])
            }

            let severity: AssemblerDiagnostic.Severity = lower.contains("error") ? .error : .warning
            results.append(AssemblerDiagnostic(severity: severity, line: lineNumber, message: line))
        }
        return results
    }
}
