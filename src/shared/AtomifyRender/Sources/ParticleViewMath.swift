import Foundation
import simd

/// The pure parts of `ParticleView`: unit conversions and the per-frame view.
public enum ParticleViewMath {
    /// A point in view coordinates (top-left origin) to drawable pixels.
    public static func pixel(fromPoint point: SIMD2<Float>, boundsSize: SIMD2<Float>,
                             drawableSize: SIMD2<Float>) -> SIMD2<Float> {
        guard boundsSize.x > 0, boundsSize.y > 0 else { return point }
        return point * (drawableSize / boundsSize)
    }

    /// Pixels per point.
    public static func contentScale(boundsSize: SIMD2<Float>, drawableSize: SIMD2<Float>) -> Float {
        guard boundsSize.y > 0, drawableSize.y > 0 else { return 1 }
        return drawableSize.y / boundsSize.y
    }

    /// The view `ParticleView` renders each frame: the camera's view
    /// matrix and a reverse-Z perspective with an infinite far plane.
    public static func renderView(camera: OrbitCamera, drawableSize: SIMD2<Float>,
                                  boundsSize: SIMD2<Float>) -> RenderView {
        let aspect = drawableSize.y > 0 ? drawableSize.x / drawableSize.y : 1
        let planes = camera.clipPlanes(sceneRadius: .infinity)
        return RenderView(viewMatrix: camera.viewMatrix,
                          projectionMatrix: camera.projectionMatrix(aspect: aspect, near: planes.near,
                                                                    far: planes.far, reverseZ: true),
                          viewportSize: drawableSize,
                          contentScale: contentScale(boundsSize: boundsSize, drawableSize: drawableSize))
    }

    /// Zoom factor for a scroll of `delta` (positive zooms in). Trackpads
    /// send many small precise deltas (points), wheels a few coarse ones
    /// (lines). A full trackpad swipe of a few hundred points zooms about
    /// 2x; one wheel notch about 5%. Each event is capped at 1.5x, so
    /// accelerated flicks stay controllable.
    public static func zoomFactor(scrollDelta delta: Float, precise: Bool) -> Float {
        guard delta.isFinite else { return 1 }
        let exponent = delta * (precise ? 0.0025 : 0.05)
        let cap = logf(1.5)
        return expf(min(max(exponent, -cap), cap))
    }

    /// Whether a press that moved `distance` points in total is a click.
    public static func isClick(dragDistance distance: Float) -> Bool {
        distance < 4
    }

    /// What a released mouse press means.
    public enum ClickAction: Equatable, Sendable {
        /// A drag, or a third or later click of a series: nothing.
        case none
        /// A single click: pick, after `delay` seconds when a second click
        /// could still make it a double click (cancelled if it does).
        case pick(delay: Double)
        /// The second click of a double click: only the double-click action,
        /// and the pending pick of the first click is cancelled.
        case doubleClick
    }

    /// The action for a press released after `clickCount` clicks and
    /// `dragDistance` points of movement. With `handlesDoubleClick`, a single
    /// click waits `doubleClickInterval` so the two clicks of a double click
    /// do not also pick (toggle the controls, or deselect an atom).
    public static func clickAction(clickCount: Int, dragDistance: Float, handlesDoubleClick: Bool,
                                   doubleClickInterval: Double) -> ClickAction {
        guard isClick(dragDistance: dragDistance) else { return .none }
        switch clickCount {
        case ...1:
            return .pick(delay: handlesDoubleClick ? max(doubleClickInterval, 0) : 0)
        case 2:
            return handlesDoubleClick ? .doubleClick : .none
        default:
            return .none
        }
    }

    /// Whether enough time passed since the last report to report again.
    public static func shouldReport(now: Double, last: Double, interval: Double = 0.25) -> Bool {
        now - last >= interval || now < last
    }

    /// Frames per second from `frames` drawn over `elapsed` seconds, 0 when
    /// the interval is not usable.
    public static func frameRate(frames: Int, elapsed: Double) -> Double {
        guard frames > 0, elapsed.isFinite, elapsed > 0 else { return 0 }
        return Double(frames) / elapsed
    }
}
