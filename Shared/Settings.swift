import Foundation

/// Shared between the host app (read-write) and extensions (read-only) via a
/// sandbox shared-preference exception on this domain.
enum PreviewSettings {
    static let domain = "local.threemfpreview.settings"
    static var defaults: UserDefaults { UserDefaults(suiteName: domain) ?? .standard }

    enum Theme: String, CaseIterable { case system, light, dark }

    static var theme: Theme {
        get { Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "theme") }
    }
    enum AllPlatesLayout: String, CaseIterable { case combined, grid }

    /// How "All plates" is shown: the slicer's original layout, or a grid of close-ups.
    static var allPlatesLayout: AllPlatesLayout {
        get { AllPlatesLayout(rawValue: defaults.string(forKey: "allPlatesLayout") ?? "") ?? .combined }
        set { defaults.set(newValue.rawValue, forKey: "allPlatesLayout") }
    }
    static var showPlate: Bool {
        get { defaults.bool(forKey: "showPlate") }
        set { defaults.set(newValue, forKey: "showPlate") }
    }
    static var showInfo: Bool {
        get { defaults.bool(forKey: "showInfo") }
        set { defaults.set(newValue, forKey: "showInfo") }
    }
}
