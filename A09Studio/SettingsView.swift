import SwiftUI
import UniformTypeIdentifiers

/// The app's Settings window (A09Studio > Settings…, or Cmd-,). Three
/// sections: Assembler, Programmer, Terminal -- matching the three tools
/// this app drives. Configure once here, then Assemble/Program/Connect
/// just work without re-entering the same values every time.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            assemblerTab
                .tabItem { Label("Assembler", systemImage: "hammer") }
            programmerTab
                .tabItem { Label("Programmer", systemImage: "cpu") }
            terminalTab
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var assemblerTab: some View {
        Form {
            Section {
                HStack {
                    TextField("Bundled a09 (default)", text: $settings.assemblerExecutablePath)
                    Button("Choose…") { chooseExecutable(into: $settings.assemblerExecutablePath) }
                    if !settings.assemblerExecutablePath.isEmpty {
                        Button("Reset") { settings.assemblerExecutablePath = "" }
                    }
                }
                Text("Leave blank to use the a09 tool built into this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Assembler Executable")
            }

            Section {
                TextField("e.g. -OTSC -Dsym=1", text: $settings.assemblerExtraArguments)
                Text("Appended to every a09 invocation, before the source file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Extra Arguments")
            }
        }
        .padding(.top, 8)
    }

    private var programmerTab: some View {
        Form {
            Section {
                TextField("e.g. AT28C256", text: $settings.programmerDevice)
                Text("Pre-fills the chip field in the Programmer panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Default Chip / Device")
            }

            Section {
                HStack {
                    TextField("Auto-detect (Homebrew / PATH)", text: $settings.miniproExecutablePath)
                    Button("Choose…") { chooseExecutable(into: $settings.miniproExecutablePath) }
                    if !settings.miniproExecutablePath.isEmpty {
                        Button("Reset") { settings.miniproExecutablePath = "" }
                    }
                }
                Text("Leave blank to auto-detect minipro (Homebrew locations, then PATH).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("minipro Executable")
            }

            Section {
                TextField("e.g. -y", text: $settings.programmerExtraArguments)
                Text("Appended to every minipro invocation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Extra Arguments")
            }
        }
        .padding(.top, 8)
    }

    private var terminalTab: some View {
        Form {
            Section {
                Picker("Default Baud", selection: $settings.serialDefaultBaud) {
                    ForEach([300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400], id: \.self) { baud in
                        Text("\(baud)").tag(baud)
                    }
                }
                Text("38400 matches the SBC's MC68681 console UART setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Serial Port")
            }

            Section {
                Picker("Line Ending", selection: $settings.serialLineEndingRaw) {
                    ForEach(AppSettings.LineEnding.allCases) { ending in
                        Text(ending.rawValue).tag(ending.rawValue)
                    }
                }
                Toggle("Local Echo", isOn: $settings.serialLocalEcho)
                Text("CR-only matches FLEX's line convention. Leave Local Echo off if the target already echoes typed characters back (the SBC's console driver does).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Line Handling")
            }

            Section {
                TextField("e.g. L", text: $settings.serialDownloadPrefix)
                Text("Sent as a line, before the S-record stream -- whatever command your monitor needs to enter load mode. Leave blank if it doesn't need one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Inter-line delay: \(settings.serialDownloadLineDelayMs) ms", value: $settings.serialDownloadLineDelayMs, in: 0...200, step: 5)
                Text("Paces the S-record download (and the gap after the prefix) so a monitor with no flow control doesn't drop bytes. Increase if a download fails partway through; 0 if your monitor handles full speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("S-Record Download")
            }
        }
        .padding(.top, 8)
    }

    private func chooseExecutable(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable, .item]
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}

#Preview {
    SettingsView()
}
