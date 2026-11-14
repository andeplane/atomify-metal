import Testing
@testable import AtomifyKit

@Suite struct AppNavigationTests {
    private func escape(gallery: Bool = false, depth: Int = 0, welcome: Bool = false, panel: Bool = false)
        -> AppNavigation.EscapeAction {
        AppNavigation.escapeAction(showsGallery: gallery, galleryDepth: depth, showsWelcome: welcome,
                                   panelOpen: panel)
    }

    @Test func escapeClosesTheTopmostThing() {
        #expect(escape(welcome: true, panel: true) == .closeWelcome)
        #expect(escape(panel: true) == .closePanel)
        #expect(escape() == .none)
        #expect(escape(gallery: true, depth: 2, welcome: true) == .galleryBack)
        #expect(escape(gallery: true, depth: 1) == .galleryBack)
        #expect(escape(gallery: true) == .leaveGallery)
    }

    @Test func speedStepsThroughTheChoices() {
        let choices = [0.25, 0.5, 1, 2, 4, 10, Double.infinity]
        #expect(AppNavigation.steppedSpeed(from: 1, by: 1, in: choices) == 2)
        #expect(AppNavigation.steppedSpeed(from: 1, by: -1, in: choices) == 0.5)
        #expect(AppNavigation.steppedSpeed(from: 10, by: 1, in: choices) == .infinity)
        #expect(AppNavigation.steppedSpeed(from: .infinity, by: 1, in: choices) == .infinity)
        #expect(AppNavigation.steppedSpeed(from: 0.25, by: -1, in: choices) == 0.25)
        #expect(AppNavigation.steppedSpeed(from: 1, by: 20, in: choices) == .infinity)
        // Between choices: the next one up or down.
        #expect(AppNavigation.steppedSpeed(from: 3, by: 1, in: choices) == 4)
        #expect(AppNavigation.steppedSpeed(from: 3, by: -1, in: choices) == 2)
        #expect(AppNavigation.steppedSpeed(from: 0.1, by: 1, in: choices) == 0.25)
        #expect(AppNavigation.steppedSpeed(from: 0.1, by: -1, in: choices) == 0.25)
        #expect(AppNavigation.steppedSpeed(from: 3, by: 0, in: [1, 2]) == 2)
        #expect(AppNavigation.steppedSpeed(from: 3, by: 1, in: []) == 3)
    }
}
