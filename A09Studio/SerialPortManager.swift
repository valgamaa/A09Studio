import Foundation
import Darwin

/// Opens a raw 8-N-1 connection to a USB-serial adapter's /dev/cu.* device
/// using POSIX termios directly (no third-party serial library), and
/// streams bytes in both directions. This is deliberately a plain byte
/// pipe -- no XMODEM/Kermit framing, no flow control beyond what the wire
/// itself provides -- matching how a simple monitor-ROM console (like the
/// SBC's MC68681-based one) actually talks: raw characters in, raw
/// characters out.
///
/// Only standard termios baud constants are used (300...230400), which
/// covers every rate a 6850/6821/68681-era UART setup is likely to use.
@MainActor
final class SerialPortManager: ObservableObject {
    @Published var availablePorts: [String] = []
    @Published var isConnected = false
    @Published var receivedText = ""
    @Published var lastError: String?

    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?

    /// When set, every incoming byte is delivered here as raw `Data`
    /// *instead of* being decoded as text and appended to `receivedText`.
    /// Used by the disk-image transfer (see `sendAndAwaitRaw`), which needs
    /// to read exact ACK/NAK protocol bytes without the text-mode
    /// normalization (Latin-1 decoding, CR/LF collapsing) mangling binary
    /// data. Always cleared again once a raw exchange finishes, restoring
    /// normal terminal display. Only ever set/read/cleared on the main
    /// queue, matching how `readAvailableBytes` already hands off to it.
    private var rawByteHandler: ((Data) -> Void)?

    /// Which line-ending byte (if any) was processed last, so its pairing
    /// half -- CR after LF, or LF after CR, in either order -- can be
    /// swallowed even if it arrives in the *next* read (a USB-serial read
    /// can split a two-byte line ending across two chunks). Only ever
    /// touched from the read source's own serial dispatch queue, so no
    /// locking is needed.
    private enum PendingNewline { case none, cr, lf }
    private var pendingNewline: PendingNewline = .none

    /// /dev/cu.* is preferred over /dev/tty.* for outgoing connections: a
    /// cu. device doesn't wait for the modem-control (DCD) line to go
    /// active before open() succeeds, which most USB-serial adapters used
    /// with a bare UART on a homebrew SBC never assert anyway.
    func refreshPorts() {
        let devDir = "/dev"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: devDir) else {
            availablePorts = []
            return
        }
        availablePorts = entries
            .filter { $0.hasPrefix("cu.") }
            .map { "\(devDir)/\($0)" }
            .sorted()
    }

    func connect(path: String, baud: Int) {
        disconnect()
        lastError = nil

        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            lastError = "Couldn't open \(path): \(String(cString: strerror(errno)))"
            return
        }

        var settings = termios()
        tcgetattr(fd, &settings)
        cfmakeraw(&settings)

        guard let speed = Self.speedConstant(for: baud) else {
            lastError = "Unsupported baud rate: \(baud)"
            close(fd)
            return
        }
        cfsetispeed(&settings, speed)
        cfsetospeed(&settings, speed)

        // 8 data bits, no parity, 1 stop bit -- standard for every monitor
        // ROM / DOS-era console this app is likely to talk to.
        settings.c_cflag &= ~tcflag_t(CSIZE)
        settings.c_cflag |= tcflag_t(CS8)
        settings.c_cflag &= ~tcflag_t(PARENB)
        settings.c_cflag &= ~tcflag_t(CSTOPB)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)

        // Hardware RTS/CTS flow control -- the SBC's MC68681 console UART
        // has this enabled on its end (MR2 bits 4/5, set in Flex_BIOS.asm's
        // TINIT), so without asking macOS to manage RTS/CTS here too, the
        // DUART's transmitter can stall waiting for a CTS it's never
        // getting matched flow control for. CRTSCTS on Darwin is just
        // (CCTS_OFLOW | CRTS_IFLOW), so this one flag covers both
        // directions.
        settings.c_cflag |= tcflag_t(CRTSCTS)

        if tcsetattr(fd, TCSANOW, &settings) != 0 {
            lastError = "Couldn't configure \(path): \(String(cString: strerror(errno)))"
            close(fd)
            return
        }

        // Clear O_NONBLOCK now that the port is configured -- we want
        // blocking reads on the background dispatch source, not a busy poll.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        fileDescriptor = fd
        isConnected = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        readSource = source
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
        fileDescriptor = -1
        isConnected = false
        pendingNewline = .none
    }

    /// Sends raw text as-is (no line-ending translation) -- used for the
    /// S-record download, which needs full control over line endings itself.
    func sendRaw(_ data: Data) {
        guard fileDescriptor >= 0 else { return }
        data.withUnsafeBytes { buf in
            _ = write(fileDescriptor, buf.baseAddress, buf.count)
        }
    }

    /// Sends typed input, appending the configured line ending. Used by the
    /// terminal's own input field.
    func sendLine(_ text: String) {
        var data = Data(text.utf8)
        data.append(contentsOf: AppSettings.shared.serialLineEnding.bytes)
        sendRaw(data)
    }

    /// Sends `data`, then collects raw response bytes until `isComplete`
    /// says enough have arrived or `timeout` elapses -- whichever comes
    /// first. Returns whatever was collected (possibly a partial/empty
    /// `Data` on timeout, which the caller should treat as "no response").
    ///
    /// This is the primitive the disk-image loader's simple ACK/NAK
    /// protocol is built on: unlike the S-record download (a blind,
    /// fixed-delay blast with no acknowledgment), each disk-image sector
    /// needs a real reply before the next one is safe to send, and that
    /// reply's length varies (one byte for ACK, two for NAK + error code)
    /// -- hence a predicate instead of a fixed byte count.
    ///
    /// Not reentrant: only one call should be in flight at a time (true by
    /// construction, since sectors are sent strictly one at a time). While
    /// a call is in flight, incoming bytes are diverted away from
    /// `receivedText` via `rawByteHandler`; normal terminal display resumes
    /// as soon as it returns.
    func sendAndAwaitRaw(_ data: Data, timeout: TimeInterval = 3.0, isComplete: @escaping (Data) -> Bool) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            var collected = Data()
            var resumed = false

            // `finish` is captured by two @escaping closures below (the
            // rawByteHandler callback and the timeout handler), and once a
            // local function is captured that way the compiler no longer
            // treats it as inheriting whatever actor context it happened to
            // be declared in -- it has to prove its own isolation at the
            // point it actually touches actor-isolated state. Every call
            // site here only ever runs on the main thread in practice (this
            // continuation body runs synchronously on the main actor; the
            // other two only ever fire via DispatchQueue.main), so
            // MainActor.assumeIsolated is a safe assertion, not a real hop.
            func finish() {
                let shouldResume = MainActor.assumeIsolated { () -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    self.rawByteHandler = nil
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: collected)
                }
            }

            MainActor.assumeIsolated {
                self.rawByteHandler = { chunk in
                    guard !resumed else { return }
                    collected.append(chunk)
                    if isComplete(collected) {
                        finish()
                    }
                }
                self.sendRaw(data)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish()
            }
        }
    }

    private func readAvailableBytes() {
        guard fileDescriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fileDescriptor, &buffer, buffer.count)
        guard n > 0 else { return }

        if let handler = rawByteHandler {
            let chunk = Data(buffer[0..<n])
            DispatchQueue.main.async {
                handler(chunk)
            }
            return
        }

        // Normalize line endings to a single "\n" -- CR, LF, CRLF *and*
        // LFCR (some hand-written monitor consoles use the reverse order)
        // all collapse to one line break. A CR/LF pair only collapses when
        // the two bytes are of *different* kinds; two of the same kind in a
        // row (CRCR or LFLF) still produce two line breaks, so a genuine
        // blank line the target sends on purpose is preserved.
        var normalized = [UInt8]()
        normalized.reserveCapacity(n)
        for byte in buffer[0..<n] {
            switch byte {
            case 0x0D: // CR
                if pendingNewline == .lf {
                    pendingNewline = .none // completes an LF+CR pair -- already emitted for the LF
                } else {
                    normalized.append(0x0A)
                    pendingNewline = .cr
                }
            case 0x0A: // LF
                if pendingNewline == .cr {
                    pendingNewline = .none // completes a CR+LF pair -- already emitted for the CR
                } else {
                    normalized.append(0x0A)
                    pendingNewline = .lf
                }
            default:
                pendingNewline = .none
                normalized.append(byte)
            }
        }

        // Treat bytes as Latin-1/ISO-8859-1: every byte value 0-255 maps to
        // a valid Unicode scalar, so this never fails to decode the way
        // UTF-8 would on a stray high-bit byte from an old 8-bit monitor.
        let text = String(bytes: normalized, encoding: .isoLatin1) ?? ""
        DispatchQueue.main.async { [weak self] in
            self?.receivedText.append(text)
            // Cap the scrollback so a long session doesn't grow without
            // bound; keep the most recent ~200KB of text.
            if let self, self.receivedText.utf8.count > 200_000 {
                self.receivedText.removeFirst(self.receivedText.count - 150_000)
            }
        }
    }

    private static func speedConstant(for baud: Int) -> speed_t? {
        switch baud {
        case 300: return speed_t(B300)
        case 1200: return speed_t(B1200)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }

    deinit {
        readSource?.cancel()
    }
}
