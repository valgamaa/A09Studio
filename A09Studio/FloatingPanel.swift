import AppKit
import SwiftUI

/// Hosts a SwiftUI view in its own regular, titled NSWindow instead of a
/// SwiftUI `.sheet` -- a sheet is docked to its parent window (slides out
/// from the titlebar) and can't be dragged around or moved to another
/// display, and it blocks interaction with the window it's attached to
/// while open. A real NSWindow does neither.
///
/// Keep one instance alive (in a `@State` on the view that owns it) for as
/// long as that kind of window should exist. Calling `show(...)` again on
/// an instance that's already open updates its content -- so it reflects
/// whatever changed since it was last shown -- and brings it back to the
/// front, rather than opening a second copy.
@MainActor
final class FloatingPanel<Content: View> {
    private var window: NSWindow?
    private var hosting: NSHostingController<Content>?

    func show(title: String, defaultSize: CGSize, @ViewBuilder content: () -> Content) {
        let rootView = content()
        if let hosting, let window {
            hosting.rootView = rootView
            window.makeKeyAndOrderFront(nil)
            return
        }
        let newHosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: newHosting)
        newWindow.title = title
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.setContentSize(defaultSize)
        // Keep the NSWindow object around (just hidden) after the user
        // closes it, rather than deallocating it -- so a later `show()`
        // reuses it instead of risking a dangling reference.
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        hosting = newHosting
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }
}
