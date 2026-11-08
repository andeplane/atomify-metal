import ARKit
import QuartzCore
import simd

/// Runs the lab's one ARKitSession: world tracking, for the head pose used
/// to place the experiment in front of the wearer, plus any other providers
/// (hand tracking).
@MainActor
final class HeadTracker {
    private var session: ARKitSession?
    private var provider: WorldTrackingProvider?
    private var startup: Task<Void, Never>?
    private(set) var problem: String?

    func start(additionalProviders: [any DataProvider] = []) {
        guard session == nil else { return }
        var providers = additionalProviders
        let provider = WorldTrackingProvider.isSupported ? WorldTrackingProvider() : nil
        if let provider { providers.insert(provider, at: 0) }
        guard !providers.isEmpty else { return }
        let session = ARKitSession()
        self.session = session
        self.provider = provider
        problem = nil
        startup = Task {
            guard !Task.isCancelled, self.session === session else { return }
            do {
                try await session.run(providers)
                if Task.isCancelled || self.session !== session { session.stop() }
            }
            catch { problem = "Tracking could not start: \(error.localizedDescription)" }
        }
    }

    func stop() {
        startup?.cancel()
        startup = nil
        session?.stop()
        session = nil
        provider = nil
    }

    /// The device's origin-from-device transform in world space (meters),
    /// when tracked. The device looks along its -z.
    func pose() -> simd_float4x4? {
        guard let provider, provider.state == .running,
              let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked else { return nil }
        return anchor.originFromAnchorTransform
    }
}
