import AppKit
import SwiftUI

extension OpenSettingsAction {
    /// Opens Settings and brings the app with it.
    ///
    /// Opening it alone orders the window within this app's own windows and
    /// stops there. Whenever Hamasen is not already the active app the window
    /// appears behind whatever the user was looking at — and it usually is
    /// not active, because the menu bar icon and Finder are the ways in and
    /// neither makes it so.
    @MainActor
    func raisingTheApp() {
        self()
        NSApp.activate(ignoringOtherApps: true)
    }
}
