import Foundation

enum SrecordError: LocalizedError {
    case srecCatNotFound
    case combineFailed(String)

    var errorDescription: String? {
        switch self {
        case .srecCatNotFound:
            return "srec_cat wasn't found. Install it with `brew install srecord`."
        case .combineFailed(let detail):
            return "srec_cat failed: \(detail)"
        }
    }
}

/// Drives the open-source `srec_cat` tool (part of the SRecord package,
/// http://srecord.sourceforge.net/) to combine one or more raw binary
/// files -- each placed at its own base address -- into a single Intel HEX
/// file minipro can program. This is exactly the job srec_cat exists for:
/// this class only shells out to it, same as ProgrammerRunner does for
/// minipro itself.
@MainActor
final class SrecordRunner {
    func resolveSrecCatPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/srec_cat",  // Apple Silicon Homebrew
            "/usr/local/bin/srec_cat",      // Intel Homebrew
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "srec_cat"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// One input file's format, as srec_cat needs to be told explicitly --
    /// it doesn't guess. A ".hex"/".ihx" file already carries each byte's
    /// real address (a09's own "-x" output, for instance), so it needs no
    /// offset unless deliberately relocating it further; a ".s19"/".s09"
    /// Motorola S-record is the same idea in a different encoding. Anything
    /// else is treated as a raw binary, which srec_cat can only place
    /// correctly if told the base address itself.
    enum InputKind {
        case binary
        case intelHex
        case motorolaSRecord

        static func inferring(from url: URL) -> InputKind {
            switch url.pathExtension.lowercased() {
            case "hex", "ihx": return .intelHex
            case "s19", "s09", "srec", "mot": return .motorolaSRecord
            default: return .binary
            }
        }

        var srecCatFlag: String {
            switch self {
            case .binary: return "-binary"
            case .intelHex: return "-intel"
            case .motorolaSRecord: return "-Motorola"
            }
        }
    }

    /// Combines `files` -- each with its own base address/offset (0 for an
    /// already-addressed hex/S-record file that needs no relocation) --
    /// into a single Motorola S-record file at `outputURL`. Built as
    /// "srec_cat f1 <-binary|-intel|-Motorola> [-offset 0xNNNN|-offset -0xNNNN] f2 ... -o out.s19 -Motorola".
    /// Output is deliberately S-record, not Intel Hex: minipro on at least
    /// one real-world install has proven unreliable reading Intel Hex here
    /// (a full-chip composite crashed it outright with SIGBUS, and even a
    /// much smaller single relocated file made it exit non-zero with no
    /// useful error), while the exact same data as S-record has worked
    /// every time -- so this sidesteps minipro's Intel Hex path entirely
    /// rather than chasing further bugs in it.
    /// baseAddress is signed because relocating an already-addressed file
    /// (as opposed to placing an unaddressed raw binary) is a *delta*, and
    /// that delta can be negative -- e.g. shifting a09's Intel Hex output
    /// at $F800 down to $7800 for a 32K EEPROM's own local address space is
    /// "-offset -0x8000".
    func combine(_ files: [(url: URL, baseAddress: Int32)], outputURL: URL) throws {
        guard let srecCatPath = resolveSrecCatPath() else {
            throw SrecordError.srecCatNotFound
        }
        guard !files.isEmpty else {
            throw SrecordError.combineFailed("No input files given.")
        }

        var args: [String] = []
        for file in files {
            let kind = InputKind.inferring(from: file.url)
            args += [file.url.path, kind.srecCatFlag]
            if file.baseAddress != 0 {
                let magnitude = String(format: "0x%X", abs(file.baseAddress))
                args += ["-offset", file.baseAddress < 0 ? "-\(magnitude)" : magnitude]
            }
        }
        // srec_cat's own defaults for a -Motorola output add two records
        // the user's known-good, hand-assembled S-records (e.g. a09's own
        // SortedFlex.s09) never have: an S0 "header" comment record, and an
        // S5 "record count" record as the file's last line. A plain S1...S9
        // file -- data records terminated by a single S9 execution-start-
        // address record, S9's address value unused by minipro and so left
        // at 0000 -- is what every file that has actually programmed
        // correctly looked like. Matching that exact shape (no S0, no S5,
        // a real S9 footer) is what finally made a combined file minipro
        // would accept, after S0/S5-bearing output kept exiting non-zero.
        args += [
            "-o", outputURL.path, "-Motorola",
            "-Disable=header",
            "-Disable=data_count",
            "-Enable=footer",
            "-Execution_Start_Address=0",
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: srecCatPath)
        process.arguments = args

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SrecordError.combineFailed(message?.isEmpty == false ? message! : "exit code \(process.terminationStatus)")
        }
    }
}
