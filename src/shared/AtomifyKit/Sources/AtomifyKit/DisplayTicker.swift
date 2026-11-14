import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Calls `tick` on the main thread once per display refresh (up to 120 Hz),
/// until it returns false or `stop()` is called. Uses UIKit's display link,
/// or on macOS the main screen's (macOS 14+). Where neither exists (no
/// screen, as in a login-less process) `init` returns nil and callers poll on
/// a timer.
@MainActor
final class DisplayTicker {
    private var link: CADisplayLink?
    private let target: Target

    init?(tick: @escaping @MainActor () -> Bool) {
        let target = Target(tick: tick)
        self.target = target
        #if canImport(UIKit)
        let link = CADisplayLink(target: target, selector: #selector(Target.fire(_:)))
        #elseif canImport(AppKit)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let link = screen.displayLink(target: target, selector: #selector(Target.fire(_:)))
        #endif
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The display link keeps its target alive, so it is not the ticker.
    /// Fired on the main run loop, where the link was added.
    @MainActor private final class Target: NSObject {
        let tick: @MainActor () -> Bool
        init(tick: @escaping @MainActor () -> Bool) { self.tick = tick }

        @objc func fire(_ link: CADisplayLink) {
            if !tick() { link.invalidate() }
        }
    }
}
