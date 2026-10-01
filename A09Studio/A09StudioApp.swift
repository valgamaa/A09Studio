import SwiftUI

@main
struct A09StudioApp: App {
    @StateObject private var document = EditorDocument()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    document.openViaPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if document.recentURLs.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(document.recentURLs, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                document.open(url: url)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            document.clearRecents()
                        }
                    }
                }

                Divider()

                Button("Save…") {
                    document.save()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
