import AtomifyEngine
import Foundation
import Testing
import simd
@testable import AtomifyVision

private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
    simd_length(a - b) < tolerance
}

/// A head at `position`, turned `yaw` about the vertical and pitched `pitch`
/// (positive looks up), as ARKit reports a device anchor.
private func head(at position: SIMD3<Float>, yaw: Float = 0, pitch: Float = 0) -> simd_float4x4 {
    let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    var matrix = simd_float4x4(rotation)
    matrix.columns.3 = SIMD4(position, 1)
    return matrix
}

struct LabComfortTests {
    @Test func opensOneMetreAheadAndSlightlyBelowTheEyes() {
        let placement = LabComfort.placement(head: head(at: [0.3, 1.6, 0.2]))
        #expect(near(placement.position, [0.3, 1.45, -0.8]))
        #expect(abs(placement.orientation.angle) < 1e-4)
        #expect(placement.scale == 1)
    }

    @Test func facesTheWearerWhicheverWayTheyTurn() {
        let yaw: Float = .pi / 2    // facing -x
        let placement = LabComfort.placement(head: head(at: [0, 1.5, 0], yaw: yaw))
        #expect(near(placement.position, [-1, 1.35, 0]))
        // The content's near side (+z) points back at the wearer.
        #expect(near(placement.orientation.act([0, 0, 1]), [1, 0, 0]))
    }

    @Test func ignoresHeadPitch() {
        let level = LabComfort.placement(head: head(at: [0, 1.6, 0]))
        let lookingDown = LabComfort.placement(head: head(at: [0, 1.6, 0], pitch: -0.6))
        let lookingUp = LabComfort.placement(head: head(at: [0, 1.6, 0], pitch: 0.6))
        #expect(near(lookingDown.position, level.position))
        #expect(near(lookingUp.position, level.position))
        #expect(near(lookingDown.orientation.act([0, 1, 0]), [0, 1, 0]))
    }

    @Test func lookingStraightDownOrUpStillPlacesInFront() {
        let down = LabComfort.placement(head: head(at: [0, 1.6, 0], pitch: -.pi / 2))
        let up = LabComfort.placement(head: head(at: [0, 1.6, 0], pitch: .pi / 2))
        #expect(near(down.position, [0, 1.45, -1]))
        #expect(near(up.position, [0, 1.45, -1]))
    }

    @Test func fallsBackWithoutAUsableHeadPose() {
        #expect(LabComfort.placement(head: nil).position == LabComfort.fallbackPosition)
        var broken = head(at: [0, 1.6, 0])
        broken.columns.3.x = .nan
        #expect(LabComfort.placement(head: broken).position == LabComfort.fallbackPosition)
        // A device reported at the floor is not a wearer's head.
        #expect(LabComfort.placement(head: head(at: .zero)).position == LabComfort.fallbackPosition)
        #expect(LabComfort.placement(head: head(at: [0, 3.2, 0])).position == LabComfort.fallbackPosition)
    }

    @Test func tipSitsUnderTheContentHoweverItIsTurnedOrSized() {
        let extent = SIMD3<Float>(0.55, 0.3, 0.4)
        let level = BoxPlacement(position: [0, 1.4, -1])
        #expect(abs(LabComfort.worldHalfHeight(of: level, extent: extent) - 0.15) < 1e-5)
        #expect(near(LabComfort.tipPosition(below: level, extent: extent), [0, 1.4 - 0.15 - LabComfort.tipGap, -1]))

        // Tipped onto its side and doubled: the long side is now vertical.
        let tipped = BoxPlacement(position: [0, 1.4, -1], orientation: simd_quatf(angle: .pi / 2, axis: [0, 0, 1]), scale: 2)
        #expect(abs(LabComfort.worldHalfHeight(of: tipped, extent: extent) - 0.55) < 1e-4)

        // Any turn: every corner stays above the tip.
        let turned = BoxPlacement(position: [0.2, 1.3, -0.9],
                                  orientation: simd_quatf(angle: 0.9, axis: simd_normalize([1, 2, 0.5])), scale: 1.3)
        let tip = LabComfort.tipPosition(below: turned, extent: extent)
        for k in 0..<8 {
            let corner = SIMD3<Float>(k & 1 == 0 ? -1 : 1, k & 2 == 0 ? -1 : 1, k & 4 == 0 ? -1 : 1) * extent / 2
            #expect(turned.worldPoint(fromLocal: corner).y >= tip.y + LabComfort.tipGap - 1e-4)
        }
    }
}

struct LabTipsTests {
    @Test func teachesPullingFirstThenHoldingThenNothing() {
        var tips = LabTips()
        #expect(tips.current == .pullAtom)
        tips.atomPulled()
        #expect(tips.current == .holdWithBothHands)
        tips.atomPulled()
        #expect(tips.current == .holdWithBothHands)
        tips.heldWithBothHands()
        #expect(tips.current == nil)
        tips.atomPulled()
        #expect(tips.current == nil)
    }

    @Test func holdingFirstSkipsTheSecondTipAfterPulling() {
        var tips = LabTips()
        tips.heldWithBothHands()
        #expect(tips.current == .pullAtom)
        tips.atomPulled()
        #expect(tips.current == nil)
    }

    @Test func tipsAreShortAndActionable() {
        for tip in [LabTips.Tip.pullAtom, .holdWithBothHands] {
            #expect(!tip.text.isEmpty && tip.text.count <= 50)
            #expect(tip.text.hasPrefix("Pinch"))
            #expect(!tip.systemImage.isEmpty)
        }
    }
}

struct GrabLinkTests {
    private let pinch = PinchSample(id: 1, kind: .direct, position: [0, 1.2, -0.6])

    @Test func refreshesTheHeldAtomEveryFrameEvenWhenTheHandIsStill() {
        var link = GrabLink()
        #expect(link.frame(canHold: true) == .none)
        link.begin(AtomGrab(tag: 42, atomPosition: [0, 1.2, -0.62], pinch: pinch))
        for _ in 0..<5 {
            #expect(link.frame(canHold: true) == .hold(tag: 42, target: [0, 1.2, -0.62]))
        }
    }

    @Test func easesTowardTheHandInBoundedSteps() {
        var link = GrabLink()
        link.begin(AtomGrab(tag: 7, atomPosition: [0, 1.2, -0.6], pinch: pinch))
        var moved = pinch
        moved.position += [0.3, 0, 0]
        link.follow(moved)
        var previous = SIMD3<Float>(0, 1.2, -0.6)
        for _ in 0..<200 {
            guard case .hold(_, let target) = link.frame(canHold: true) else {
                Issue.record("Expected a hold")
                return
            }
            #expect(simd_distance(target, previous) <= AtomGrab.maxStep + 1e-6)
            previous = target
        }
        #expect(near(previous, [0.3, 1.2, -0.6], 1e-3))
    }

    @Test func releasesOnceWhenThePinchEnds() {
        var link = GrabLink()
        link.begin(AtomGrab(tag: 3, atomPosition: .zero, pinch: pinch))
        _ = link.frame(canHold: true)
        link.end()
        #expect(!link.isHolding)
        #expect(link.frame(canHold: true) == .release)
        #expect(link.frame(canHold: true) == .none)
        link.end()
        #expect(link.frame(canHold: true) == .none)
    }

    @Test func pausingOrGrippingDropsTheAtomUntilANewPinch() {
        var link = GrabLink()
        link.begin(AtomGrab(tag: 3, atomPosition: .zero, pinch: pinch))
        #expect(link.frame(canHold: false) == .release)
        #expect(!link.isHolding)
        #expect(link.frame(canHold: true) == .none)
        link.follow(pinch)
        #expect(link.frame(canHold: true) == .none)
    }

    @Test func aNewGrabReplacesTheOldOneWithoutAStrayRelease() {
        var link = GrabLink()
        link.begin(AtomGrab(tag: 1, atomPosition: .zero, pinch: pinch))
        link.end()
        link.begin(AtomGrab(tag: 2, atomPosition: [0.1, 0, 0], pinch: pinch))
        #expect(link.frame(canHold: true) == .hold(tag: 2, target: [0.1, 0, 0]))
    }

    @Test func reportsEachNewGrabOnceForFeedback() {
        var link = GrabLink()
        #expect(link.takeBegan() == nil)
        link.begin(AtomGrab(tag: 9, atomPosition: .zero, pinch: pinch))
        #expect(link.takeBegan() == 9)
        #expect(link.takeBegan() == nil)
        link.begin(AtomGrab(tag: 10, atomPosition: .zero, pinch: pinch))
        link.end()
        #expect(link.takeBegan() == nil)
    }

    @Test func ignoresNonFiniteHandPositions() {
        var grab = AtomGrab(tag: 1, atomPosition: [0, 1, -1], pinch: pinch)
        var broken = pinch
        broken.position.x = .infinity
        grab.follow(broken)
        #expect(grab.desired == [0, 1, -1])
    }
}

struct AtomPickTests {
    private let snapshot = SimulationSnapshot(typeCount: 1, boxLow: .zero, boxHigh: [10, 10, 10],
                                              tags: [1, 2, 3], types: [1, 1, 1],
                                              positions: [[1, 1, 1], [2, 1, 1], [5, 5, 5]])

    @Test func directPinchPicksTheNearestAtomWithinReach() {
        #expect(snapshot.atomNear([1.6, 1, 1], reach: 0.8, radius: { _ in 0.3 }) == 1)
        #expect(snapshot.atomNear([1.4, 1, 1], reach: 0.8, radius: { _ in 0.3 }) == 0)
        #expect(snapshot.atomNear([3.5, 3, 3], reach: 0.8, radius: { _ in 0.3 }) == nil)
    }

    @Test func aLargeAtomCanBePinchedAnywhereOnItsSurface() {
        // Reach is small, but atom 3 is drawn 2 units wide.
        let radius: (Int) -> Float = { $0 == 2 ? 2 : 0.3 }
        #expect(snapshot.atomNear([5, 6.8, 5], reach: 0.5, radius: radius) == 2)
        #expect(snapshot.atomNear([5, 7.2, 5], reach: 0.5, radius: radius) == nil)
    }
}

struct SpeedAndReadoutTests {
    private func demo(stepsPerSecond: Double?) -> Demo {
        var demo = Demo(id: "d", title: "D", summary: "", category: "", folder: "d", inputScript: "in.d")
        demo.stepsPerSecond = stepsPerSecond
        return demo
    }

    @Test func normalUsesTheDemoRateAndSlowIsAFractionOfIt() {
        let fast = demo(stepsPerSecond: 600)
        #expect(SimulationSpeed.normal.stepsPerSecond(for: fast) == 600)
        #expect(abs((SimulationSpeed.slow.stepsPerSecond(for: fast) ?? 0) - 180) < 1e-9)
        #expect(SimulationSpeed.fast.stepsPerSecond(for: fast) == nil)
    }

    @Test func missingOrInvalidRatesUseTheDefault() {
        for rate in [nil, 0, -5, .infinity, .nan] as [Double?] {
            #expect(SimulationSpeed.normal.stepsPerSecond(for: demo(stepsPerSecond: rate)) == 120)
        }
        #expect(SimulationSpeed.allCases.map(\.title) == ["Slow", "Normal", "Fast"])
    }

    @Test func temperatureReadsInKelvinOrReducedUnits() {
        let english = Locale(identifier: "en_US")
        #expect(Readout.temperature(299.6, units: "metal", locale: english) == "300 K")
        #expect(Readout.temperature(310.2, units: "real", locale: english) == "310 K")
        #expect(Readout.temperature(0.8512, units: "lj", locale: english) == "T = 0.85 (reduced)")
        #expect(Readout.temperature(300, units: "", locale: english) == nil)
        #expect(Readout.temperature(.nan, units: "metal", locale: english) == nil)
    }
}
