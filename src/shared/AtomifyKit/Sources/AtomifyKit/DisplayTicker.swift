import Foundation
#if canImport(UIKit)
import QuartzCore
import UIKit
#endif

/// Calls `tick` on the main thread once per display refresh (up to 120 Hz),
/// until it returns false or `stop()` is called. Only where UIKit's display
/// link exists; elsewhere `init` returns nil and callers poll on a timer.
@MainActor
final class DisplayTicker {
    #if canImport(UIKit)
    private var link: CADisplayLink?
    private let target: Target
    #endif

    init?(tick: @escaping @MainActor () -> Bool) {
        #if canImport(UIKit)
        let target = Target(tick: tick)
        self.target = target
        let link = CADisplayLink(target: target, selector: #selector(Target.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        #else
        return nil
        #endif
    }

    func stop() {
        #if canImport(UIKit)
        link?.invalidate()
        link = nil
        #endif
    }

    #if canImport(UIKit)
    /// The display link keeps its target alive, so it is not the ticker.
    /// Fired on the main run loop, where the link was added.
    @MainActor private final class Target: NSObject {
        let tick: @MainActor () -> Bool
        init(tick: @escaping @MainActor () -> Bool) { self.tick = tick }

        @objc func fire(_ link: CADisplayLink) {
            if !tick() { link.invalidate() }
        }
    }
    #endif
}
