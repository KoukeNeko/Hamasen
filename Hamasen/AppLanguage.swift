import AppKit
import Foundation

/// The language Hamasen runs in, expressed the way macOS itself models it.
///
/// System Settings › General › Language & Region › Applications sets a
/// per-app language by writing `AppleLanguages` into the app's own preferences
/// domain. This picker writes the same key in the same place, so the two agree
/// rather than fight; "follow the system" is the absence of the key.
///
/// A language only takes effect at the next launch. Writing the key in-process
/// moves nothing — not `Bundle.preferredLocalizations`, not a freshly built
/// `Bundle` — which is why Apple's own pane offers to relaunch, and why this
/// does too.
enum AppLanguage: Hashable, Identifiable, CaseIterable {
    case system
    case fixed(String)

    /// The languages the bundle actually ships, so the picker cannot offer one
    /// that would silently fall back to the development region.
    static let availableIdentifiers: [String] = {
        let identifiers = Bundle.main.localizations.filter { $0 != "Base" }
        // Stable, and with the source language first rather than in whatever
        // order the bundle happens to list.
        return identifiers.sorted { lhs, rhs in
            (lhs == "zh-Hant" ? 0 : 1, lhs) < (rhs == "zh-Hant" ? 0 : 1, rhs)
        }
    }()

    static var allCases: [AppLanguage] { [.system] + availableIdentifiers.map(AppLanguage.fixed) }

    var id: String {
        switch self {
        case .system: return "system"
        case .fixed(let identifier): return identifier
        }
    }

    /// Each language names itself, the way every macOS language list does —
    /// a reader looking for 日本語 should not have to know the current UI
    /// language to find it.
    var endonym: String? {
        guard case .fixed(let identifier) = self else { return nil }
        let locale = Locale(identifier: identifier)
        return locale.localizedString(forIdentifier: identifier)?.localizedCapitalized
            ?? identifier
    }

    // MARK: - Reading and writing the preference

    private static let preferenceKey = "AppleLanguages"

    static var selected: AppLanguage {
        guard let identifier = UserDefaults.standard.stringArray(forKey: preferenceKey)?.first
        else { return .system }
        return .fixed(identifier)
    }

    /// The language the app is actually running in, which stays on the old
    /// value until the app is relaunched.
    static var effectiveIdentifier: String? {
        Bundle.main.preferredLocalizations.first
    }

    func apply() {
        switch self {
        case .system:
            // An empty array is not the same as no preference: System Settings
            // guards against writing one, because it would mean "no languages".
            UserDefaults.standard.removeObject(forKey: Self.preferenceKey)
        case .fixed(let identifier):
            UserDefaults.standard.set([identifier], forKey: Self.preferenceKey)
        }
    }

    /// What was stored when this process started. The running app keeps that
    /// language whatever the preference says now, so it is the only thing the
    /// current selection can meaningfully be compared against.
    private static let selectionAtLaunch = selected

    /// Whether the app has to be relaunched for the selection to take effect.
    static var needsRelaunch: Bool { selected != selectionAtLaunch }

    /// Reads the launch-time selection while the app starts, so the comparison
    /// cannot first run after the user has already changed the preference.
    static func captureLaunchState() { _ = selectionAtLaunch }
}

/// Relaunching and the system's own language settings, kept out of the view.
enum AppLanguageSettings {
    /// The Language & Region pane, where macOS keeps the per-app language list.
    private static let languageSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Localization-Settings.extension"
    )

    static func openSystemLanguageSettings() {
        guard let languageSettingsURL else { return }
        NSWorkspace.shared.open(languageSettingsURL)
    }

    /// Starts a fresh instance and lets this one go, so the new process picks
    /// up the language at launch.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
