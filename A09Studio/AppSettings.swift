import Foundation

/// Persisted app configuration -- assembler tool path/options, programmer
/// tool path/options, and serial terminal defaults. Backed by UserDefaults
/// so settings survive relaunches. This is a plain ObservableObject (not
/// @AppStorage-in-a-View) so it can be read from non-View code too
/// (AssemblerRunner, ProgrammerRunner, SerialPortManager).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let assemblerExecutablePath = "assemblerExecutablePath"
        static let assemblerExtraArguments = "assemblerExtraArguments"
        static let programmerDevice = "programmerDevice"
        static let programmerVersion = "programmerVersion"
        static let programmerPromBaseAddress = "programmerPromBaseAddress"
        static let miniproExecutablePath = "miniproExecutablePath"
        static let programmerExtraArguments = "programmerExtraArguments"
        static let serialDefaultBaud = "serialDefaultBaud"
        static let serialLineEnding = "serialLineEnding"
        static let serialLocalEcho = "serialLocalEcho"
        static let serialDownloadLineDelayMs = "serialDownloadLineDelayMs"
        static let serialDownloadPrefix = "serialDownloadPrefix"
    }

    enum LineEnding: String, CaseIterable, Identifiable {
        case cr = "CR"
        case lf = "LF"
        case crlf = "CRLF"
        var id: String { rawValue }

        var bytes: [UInt8] {
            switch self {
            case .cr: return [0x0D]
            case .lf: return [0x0A]
            case .crlf: return [0x0D, 0x0A]
            }
        }
    }

    /// Path to a custom a09 binary. Empty string means "use the a09 tool
    /// bundled inside the app" (the normal case).
    @Published var assemblerExecutablePath: String {
        didSet { UserDefaults.standard.set(assemblerExecutablePath, forKey: Key.assemblerExecutablePath) }
    }

    /// Extra command-line arguments appended to every a09 invocation, e.g.
    /// "-OTSC -Dsymbol=1". Split on whitespace before being passed to Process.
    @Published var assemblerExtraArguments: String {
        didSet { UserDefaults.standard.set(assemblerExtraArguments, forKey: Key.assemblerExtraArguments) }
    }

    /// Default chip/device name passed to minipro, e.g. "AT28C256".
    @Published var programmerDevice: String {
        didSet { UserDefaults.standard.set(programmerDevice, forKey: Key.programmerDevice) }
    }

    /// Which programmer model to force via minipro's "-q" flag (TL866A,
    /// TL866II, T48, T56), or "" to let minipro auto-detect the attached
    /// unit -- the normal case with a single programmer plugged in.
    @Published var programmerVersion: String {
        didSet { UserDefaults.standard.set(programmerVersion, forKey: Key.programmerVersion) }
    }

    /// The EEPROM/EPROM's own base address within the target board's real
    /// memory map, e.g. "8000" for a 32K chip mapped at $8000-$FFFF. This
    /// is subtracted (via srec_cat's "-offset") from every already-
    /// addressed file in the Programmer panel's Files list, so an Intel
    /// Hex/S-record file carrying the board's real addresses gets shifted
    /// down into the chip's own local 0-based address space without
    /// having to type that offset (and its sign) into each file's own
    /// Base field by hand. Defaults to "0" (no shift), so it's a no-op
    /// until deliberately set.
    @Published var programmerPromBaseAddress: String {
        didSet { UserDefaults.standard.set(programmerPromBaseAddress, forKey: Key.programmerPromBaseAddress) }
    }

    /// Path to a custom minipro binary. Empty string means "auto-detect"
    /// (Homebrew locations, then PATH via `which`).
    @Published var miniproExecutablePath: String {
        didSet { UserDefaults.standard.set(miniproExecutablePath, forKey: Key.miniproExecutablePath) }
    }

    /// Extra command-line arguments appended to every minipro invocation.
    @Published var programmerExtraArguments: String {
        didSet { UserDefaults.standard.set(programmerExtraArguments, forKey: Key.programmerExtraArguments) }
    }

    /// Default baud rate offered when opening the Terminal tab. Defaults to
    /// 38400 to match the MC68681 UART setup already in the SBC's console
    /// driver (TINIT sets ClkSel for 38.4k).
    @Published var serialDefaultBaud: Int {
        didSet { UserDefaults.standard.set(serialDefaultBaud, forKey: Key.serialDefaultBaud) }
    }

    /// Line ending sent when you press Return in the terminal, and between
    /// lines during an S-record download. Defaults to CR-only, matching
    /// FLEX's own line convention (a bare CR ends a line) and the SBC's
    /// console driver, which does no CR/LF translation of its own.
    @Published var serialLineEndingRaw: String {
        didSet { UserDefaults.standard.set(serialLineEndingRaw, forKey: Key.serialLineEnding) }
    }
    var serialLineEnding: LineEnding {
        get { LineEnding(rawValue: serialLineEndingRaw) ?? .cr }
        set { serialLineEndingRaw = newValue.rawValue }
    }

    /// Whether typed characters are echoed locally in the terminal view.
    /// Defaults to off, since the SBC's own INCH routine already echoes
    /// received characters back to the sender -- local echo too would
    /// double every character on screen.
    @Published var serialLocalEcho: Bool {
        didSet { UserDefaults.standard.set(serialLocalEcho, forKey: Key.serialLocalEcho) }
    }

    /// Delay between lines while sending an S-record download. Many simple
    /// monitor firmwares (including hand-written ones with no interrupt-
    /// driven Rx buffering) can't keep up with back-to-back lines at higher
    /// baud rates, so a small per-line pacing delay avoids dropped bytes.
    /// Tune this in Settings if downloads fail partway through, or set to 0
    /// if your monitor buffers/flow-controls properly.
    @Published var serialDownloadLineDelayMs: Int {
        didSet { UserDefaults.standard.set(serialDownloadLineDelayMs, forKey: Key.serialDownloadLineDelayMs) }
    }

    /// Text sent (as a line, with the configured line ending) immediately
    /// before the S-record stream on Download -- e.g. whatever command your
    /// monitor ROM needs to put it into "load" mode first. Empty by default,
    /// since not every monitor needs one; the S-record stream then follows
    /// after the usual inter-line delay.
    @Published var serialDownloadPrefix: String {
        didSet { UserDefaults.standard.set(serialDownloadPrefix, forKey: Key.serialDownloadPrefix) }
    }

    private init() {
        let d = UserDefaults.standard
        assemblerExecutablePath = d.string(forKey: Key.assemblerExecutablePath) ?? ""
        assemblerExtraArguments = d.string(forKey: Key.assemblerExtraArguments) ?? ""
        programmerDevice = d.string(forKey: Key.programmerDevice) ?? "AT28C256"
        programmerPromBaseAddress = d.string(forKey: Key.programmerPromBaseAddress) ?? "0"
        programmerVersion = d.string(forKey: Key.programmerVersion) ?? ""
        miniproExecutablePath = d.string(forKey: Key.miniproExecutablePath) ?? ""
        programmerExtraArguments = d.string(forKey: Key.programmerExtraArguments) ?? ""
        let storedBaud = d.integer(forKey: Key.serialDefaultBaud)
        serialDefaultBaud = storedBaud == 0 ? 38400 : storedBaud
        serialLineEndingRaw = d.string(forKey: Key.serialLineEnding) ?? LineEnding.cr.rawValue
        serialLocalEcho = d.bool(forKey: Key.serialLocalEcho)
        let storedDelay = d.object(forKey: Key.serialDownloadLineDelayMs) as? Int
        serialDownloadLineDelayMs = storedDelay ?? 10
        serialDownloadPrefix = d.string(forKey: Key.serialDownloadPrefix) ?? ""
    }

    /// Splits the free-text extra-arguments field into an argv-style array.
    /// Simple whitespace split -- no quoting support, which matches how
    /// a09's and minipro's own options are normally passed (single tokens
    /// like -OTSC, -Dsym=1, -y).
    static func splitArguments(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}
