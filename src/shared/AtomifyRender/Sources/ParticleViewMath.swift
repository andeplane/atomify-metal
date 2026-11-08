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
    /// send many small precise deltas, wheels a few coarse ones.
    public static func zoomFactor(scrollDelta delta: Float, precise: Bool) -> Float {
        guard delta.isFinite else { return 1 }
        return expf(delta * (precise ? 0.01 : 0.1))
    }

    /// Whether a press that moved `distance` points in total is a click.
    public static func isClick(dragDistance distance: Float) -> Bool {
        distance < 4
    }

    /// Whether enough time passed since the last report to report again.
    public static func shouldReport(now: Double, last: Double, interval: Double = 0.25) -> Bool {
        now - last >= interval || now < last
    }
}
