import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A read-only hex dump of a chip read, one row per 16 bytes (offset, hex
/// bytes, ASCII gutter), with its own Save. Rows are rendered by a `List`
/// so only the visible slice is ever laid out -- a full 32KB EEPROM read is
/// 2048 rows, which would be sluggish in a plain ScrollView/LazyVStack on
/// first layout but is fine here.
struct HexViewerView: View {
    let data: Data
    let suggestedFilename: String

    @State private var saveError: String?

    private static let bytesPerRow = 16

    private var rowCount: Int {
        (data.count + Self.bytesPerRow - 1) / Self.bytesPerRow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chip Read").font(.title2).bold()
                Spacer()
                Text("\(data.count) bytes")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if let saveError {
                Text(saveError)
                    .font(.title3)
                    .foregroundStyle(.red)
            }

            List(0..<rowCount, id: \.self) { row in
                hexRow(row)
            }
            .listStyle(.plain)

            HStack {
                Spacer()
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .font(.title3)
                Button("Save…") { save() }
                    .font(.title3)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding()
        .frame(minWidth: 980, minHeight: 560)
    }

    private func hexRow(_ row: Int) -> some View {
        let start = row * Self.bytesPerRow
        let end = min(start + Self.bytesPerRow, data.count)
        let bytes = data[data.startIndex + start ..< data.startIndex + end]

        var hexParts: [String] = []
        var asciiParts: [String] = []
        for byte in bytes {
            hexParts.append(String(format: "%02X", byte))
            asciiParts.append((byte >= 0x20 && byte < 0x7F) ? String(UnicodeScalar(byte)) : ".")
        }
        // Pad the hex column so short final rows still line up under full ones.
        while hexParts.count < Self.bytesPerRow { hexParts.append("  ") }

        let offsetText = String(format: "%06X", start)
        let hexText = hexParts.joined(separator: " ")
        let asciiText = asciiParts.joined()

        return Text("\(offsetText)  \(hexText)  \(asciiText)")
            .font(.system(size: 21, weight: .regular, design: .monospaced))
            .lineLimit(1)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
