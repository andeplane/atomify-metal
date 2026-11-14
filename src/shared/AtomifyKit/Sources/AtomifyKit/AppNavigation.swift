import Foundation

/// Keyboard decisions of the app shells, kept apart from their views so
/// they can be tested: what Escape closes, and which speed a step picks.
public enum AppNavigation {
    /// What Escape does, the topmost thing first.
    public enum EscapeAction: Equatable, Sendable {
        /// Closes the welcome card over the simulation.
        case closeWelcome
        /// Closes the side panel beside the simulation.
        case closePanel
        /// Goes back one page in the gallery (detail, settings, files...).
        case galleryBack
        /// Leaves the gallery for the simulation.
        case leaveGallery
        /// Nothing is open.
        case none
    }

    /// Escape closes the welcome, then an open panel; in the gallery it
    /// goes back a page, and from its root returns to the simulation.
    public static func escapeAction(showsGallery: Bool, galleryDepth: Int, showsWelcome: Bool,
                                    panelOpen: Bool) -> EscapeAction {
        if showsGallery { return galleryDepth > 0 ? .galleryBack : .leaveGallery }
        if showsWelcome { return .closeWelcome }
        if panelOpen { return .closePanel }
        return .none
    }

    /// The speed `steps` choices away from `current` in `choices` (in
    /// increasing order), clamped at both ends. A speed that is not one of
    /// the choices steps from the nearest choice below or above it.
    public static func steppedSpeed(from current: Double, by steps: Int, in choices: [Double]) -> Double {
        guard !choices.isEmpty else { return current }
        let index: Int
        if let exact = choices.firstIndex(of: current) {
            index = exact + steps
        } else if steps > 0 {
            index = (choices.firstIndex { $0 > current } ?? choices.count) + steps - 1
        } else {
            index = (choices.lastIndex { $0 < current } ?? -1) + steps + 1
        }
        return choices[min(max(index, 0), choices.count - 1)]
    }
}
