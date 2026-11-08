import AtomifyEngine
import Foundation
import Testing
import simd
@testable import AtomifyVision

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
    simd_length(a - b) < tolerance
}

/// The same rotation, either sign.
private func close(_ a: simd_quatf, _ b: simd_quatf, _ tolerance: Float = 1e-4) -> Bool {
    abs(abs(simd_dot(a.vector, b.vector)) - 1) < tolerance
}

private func degrees(_ value: Float) -> Float { value * .pi / 180 }

struct TwoHandRollTests {
    private let box = BoxPlacement(position: [0, 1, -1], orientation: simd_quatf(angle: 0.3, axis: [0, 1, 0]), scale: 1.5)
    private let left = SIMD3<Float>(-0.3, 1, -1), right = SIMD3<Float>(0.3, 1, -1)
    /// Some hand orientation, so rolls are measured relative to a non-identity start.
    private let wrist = simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.4)))

    @Test func bothHandsRollingRollsTheBoxTheSame() {
        let roll = simd_quatf(angle: degrees(30), axis: [1, 0, 0])
        let held = box.held(from: (HandPose(position: left, orientation: wrist), HandPose(position: right, orientation: wrist)),
                            to: (HandPose(position: left, orientation: roll * wrist),
                                 HandPose(position: right, orientation: roll * wrist)))
        #expect(close(held.orientation, roll * box.orientation))
        #expect(close(held.position, box.position))
        #expect(abs(held.scale - box.scale) < 1e-5)
    }

    @Test func oneHandRollingRollsTheBoxHalfAsMuch() {
        let roll = simd_quatf(angle: degrees(30), axis: [1, 0, 0])
        let held = box.held(from: (HandPose(position: left), HandPose(position: right)),
                            to: (HandPose(position: left), HandPose(position: right, orientation: roll)))
        #expect(close(held.orientation, simd_quatf(angle: degrees(15), axis: [1, 0, 0]) * box.orientation))
    }

    @Test func rollingTheOtherWayAndAboutTheReversedAxisAgree() {
        // Hands in the other order: the axis points -x, so a +30° roll about it
        // is -30° about +x.
        let roll = simd_quatf(angle: degrees(-30), axis: [1, 0, 0])
        let held = box.held(from: (HandPose(position: right), HandPose(position: left)),
                            to: (HandPose(position: right, orientation: roll), HandPose(position: left, orientation: roll)))
        #expect(close(held.orientation, roll * box.orientation))
    }

    @Test func handsTurningWithTheSwingAddNoRoll() {
        // A quarter turn about the vertical; the wrists turn along with it.
        let swing = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        let mid = SIMD3<Float>(0, 1, -1)
        let newLeft = mid + swing.act(left - mid), newRight = mid + swing.act(right - mid)
        let held = box.held(from: (HandPose(position: left, orientation: wrist), HandPose(position: right, orientation: wrist)),
                            to: (HandPose(position: newLeft, orientation: swing * wrist),
                                 HandPose(position: newRight, orientation: swing * wrist)))
        #expect(close(held.orientation, swing * box.orientation))
        #expect(close(held.position, box.position))
    }

    @Test func translatingBothHandsOnlyMovesTheBox() {
        let shift = SIMD3<Float>(0.2, -0.1, 0.3)
        let held = box.held(from: (HandPose(position: left, orientation: wrist), HandPose(position: right, orientation: wrist)),
                            to: (HandPose(position: left + shift, orientation: wrist),
                                 HandPose(position: right + shift, orientation: wrist)))
        #expect(close(held.position, box.position + shift))
        #expect(close(held.orientation, box.orientation))
        #expect(abs(held.scale - box.scale) < 1e-5)
    }

    @Test func spreadingHandsScalesAboutTheirMidpoint() {
        let held = box.held(from: (HandPose(position: left), HandPose(position: right)),
                            to: (HandPose(position: [-0.6, 1, -1]), HandPose(position: [0.6, 1, -1])))
        #expect(abs(held.scale - 3) < 1e-5)
        #expect(close(held.position, box.position))
        // A point in the right hand stays in it.
        #expect(close(held.worldPoint(fromLocal: box.localPoint(fromWorld: right)), [0.6, 1, -1]))
    }

    @Test func handsThatStartTogetherChangeNothing() {
        let held = box.held(from: (HandPose(position: left), HandPose(position: left + [0.005, 0, 0])),
                            to: (HandPose(position: left), HandPose(position: right)))
        #expect(held == box)
    }

    @Test func handsSwappingEndsTurnsHalfwayAroundWithoutBlowingUp() {
        let held = box.held(from: (HandPose(position: left), HandPose(position: right)),
                            to: (HandPose(position: right), HandPose(position: left)))
        let axis = box.orientation.inverse.act([1, 0, 0])
        #expect(close(held.orientation.act(axis), [-1, 0, 0]))
        #expect(held.orientation.vector.x.isFinite && abs(simd_length(held.orientation.vector) - 1) < 1e-4)
    }

    @Test func shortestArcHandlesOppositeDirections() {
        for direction in [SIMD3<Float>(1, 0, 0), [0, 1, 0], simd_normalize(SIMD3<Float>(0.3, -0.2, 0.9))] {
            let arc = BoxPlacement.shortestArc(from: direction, to: -direction)
            #expect(close(arc.act(direction), -direction))
        }
        let arc = BoxPlacement.shortestArc(from: [1, 0, 0], to: [0, 0, 1])
        #expect(close(arc.act([1, 0, 0]), [0, 0, 1]))
    }

    @Test func twistAngleIsSignedAndIgnoresQuaternionSign() {
        let axis = SIMD3<Float>(0, 0, 1)
        let turn = simd_quatf(angle: degrees(40), axis: axis)
        #expect(abs(BoxPlacement.twistAngle(of: turn, about: axis) - degrees(40)) < 1e-4)
        #expect(abs(BoxPlacement.twistAngle(of: simd_quatf(vector: -turn.vector), about: axis) - degrees(40)) < 1e-4)
        #expect(abs(BoxPlacement.twistAngle(of: turn, about: -axis) + degrees(40)) < 1e-4)
        // A half turn about a perpendicular axis has no twist.
        #expect(BoxPlacement.twistAngle(of: simd_quatf(angle: .pi, axis: [1, 0, 0]), about: axis) == 0)
        // A twist plus a swing keeps the twist.
        let swing = simd_quatf(angle: 0.4, axis: [1, 0, 0])
        #expect(abs(BoxPlacement.twistAngle(of: swing * turn, about: axis) - degrees(40)) < 1e-4)
    }

    @Test func boxGripTouchesCarryOrientation() {
        var grip = BoxGrip()
        let roll = simd_quatf(angle: degrees(30), axis: [1, 0, 0])
        _ = grip.update([.init(id: 1, position: left, ended: false), .init(id: 2, position: right, ended: false)],
                        placement: box)
        let rolled = grip.update([.init(id: 1, position: left, orientation: roll, ended: false),
                                  .init(id: 2, position: right, orientation: roll, ended: false)], placement: box)
        #expect(rolled.map { close($0.orientation, roll * box.orientation) } == true)
        grip.reset()
        #expect(!grip.isHolding)
    }
}

struct PinchRouterTests {
    private let box = BoxPlacement(position: [0, 1, -1])

    private func pinch(_ id: Int, _ position: SIMD3<Float>, ended: Bool = false,
                       orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) -> PinchSample {
        PinchSample(id: id, kind: .direct, position: position, orientation: orientation, ended: ended)
    }

    @Test func aLonePinchGrabsAnAtomAndDragsIt() {
        var router = PinchRouter()
        let began = router.update([pinch(1, [0, 1, -1])], placement: box)
        #expect(began.atomBegan?.id == 1)
        #expect(began.atomPinch?.id == 1)
        #expect(!began.atomEnded && !began.isGripping && began.placement == nil)
        #expect(router.mode == .atom(pinch: 1))

        let moved = router.update([pinch(1, [0.1, 1, -1])], placement: box)
        #expect(moved.atomBegan == nil)
        #expect(moved.atomPinch?.position == SIMD3(0.1, 1, -1))

        let ended = router.update([pinch(1, [0.1, 1, -1], ended: true)], placement: box)
        #expect(ended.atomEnded && ended.atomPinch == nil)
        #expect(router.mode == .idle)
    }

    @Test func aSecondPinchEndsTheAtomGrabAndStartsTheGripAtOnce() {
        var router = PinchRouter()
        _ = router.update([pinch(1, [-0.2, 1, -1])], placement: box)
        let joined = router.update([pinch(1, [-0.2, 1, -1]), pinch(2, [0.2, 1, -1])], placement: box)
        #expect(joined.atomEnded)
        #expect(joined.atomPinch == nil && joined.atomBegan == nil)
        #expect(joined.isGripping)
        #expect(joined.placement == box)
        #expect(router.mode == .grip(1, 2))

        // The grip works from the placement when it began, whatever is passed later.
        let moved = router.update([pinch(1, [-0.4, 1, -1]), pinch(2, [0.4, 1, -1])],
                                  placement: BoxPlacement(position: [5, 5, 5]))
        #expect(moved.placement.map { abs($0.scale - 2) < 1e-5 && close($0.position, box.position) } == true)
        #expect(!moved.atomEnded)
    }

    @Test func releasingOneHandWaitsForAllHandsBeforeAtomsAgain() {
        var router = PinchRouter()
        _ = router.update([pinch(1, [-0.2, 1, -1]), pinch(2, [0.2, 1, -1])], placement: box)
        #expect(router.mode == .grip(1, 2))

        let one = router.update([pinch(1, [-0.2, 1, -1], ended: true), pinch(2, [0.2, 1, -1])], placement: box)
        #expect(router.mode == .afterGrip)
        #expect(one == PinchRouter.Output())
        // The leftover hand moving does nothing.
        #expect(router.update([pinch(2, [0.5, 1.2, -1])], placement: box) == PinchRouter.Output())
        // Another hand joining does not grip again either.
        #expect(router.update([pinch(2, [0.5, 1.2, -1]), pinch(3, [0, 1, -1])], placement: box) == PinchRouter.Output())
        #expect(router.mode == .afterGrip)

        #expect(router.update([pinch(2, [0.5, 1.2, -1], ended: true), pinch(3, [0, 1, -1], ended: true)],
                              placement: box) == PinchRouter.Output())
        #expect(router.mode == .idle)

        let again = router.update([pinch(4, [0, 1, -1])], placement: box)
        #expect(again.atomBegan?.id == 4)
        #expect(router.mode == .atom(pinch: 4))
    }

    @Test func aPinchMissingFromTheListHasEnded() {
        var router = PinchRouter()
        _ = router.update([pinch(1, [0, 1, -1])], placement: box)
        let gone = router.update([], placement: box)
        #expect(gone.atomEnded)
        #expect(router.mode == .idle)

        _ = router.update([pinch(2, [-0.2, 1, -1]), pinch(3, [0.2, 1, -1])], placement: box)
        _ = router.update([pinch(3, [0.2, 1, -1])], placement: box)
        #expect(router.mode == .afterGrip)
        _ = router.update([], placement: box)
        #expect(router.mode == .idle)
    }

    @Test func aThirdPinchIsIgnoredWhileGripping() {
        var router = PinchRouter()
        _ = router.update([pinch(1, [-0.2, 1, -1]), pinch(2, [0.2, 1, -1])], placement: box)
        let third = router.update([pinch(1, [-0.2, 1, -1]), pinch(2, [0.2, 1, -1]), pinch(3, [5, 5, 5])],
                                  placement: box)
        #expect(third.isGripping && third.placement == box)
        #expect(router.mode == .grip(1, 2))
    }

    @Test func gripRollsWithTheWrists() {
        var router = PinchRouter()
        let roll = simd_quatf(angle: degrees(30), axis: [1, 0, 0])
        _ = router.update([pinch(1, [-0.2, 1, -1]), pinch(2, [0.2, 1, -1])], placement: box)
        let rolled = router.update([pinch(1, [-0.2, 1, -1], orientation: roll), pinch(2, [0.2, 1, -1], orientation: roll)],
                                   placement: box)
        #expect(rolled.placement.map { close($0.orientation, roll) } == true)
    }

    @Test func theAtomPinchEndingAsAnotherJoinsDoesNotGrabAgain() {
        var router = PinchRouter()
        _ = router.update([pinch(1, [0, 1, -1])], placement: box)
        let swap = router.update([pinch(1, [0, 1, -1], ended: true), pinch(2, [0.2, 1, -1])], placement: box)
        #expect(swap.atomEnded && swap.atomBegan == nil && !swap.isGripping)
        #expect(router.mode == .afterGrip)
        router.reset()
        #expect(router.mode == .idle)
        #expect(router.update([pinch(5, [0, 1, -1])], placement: box).atomBegan?.id == 5)
    }

    @Test func endedPinchesNeverStartAnything() {
        var router = PinchRouter()
        #expect(router.update([pinch(1, [0, 1, -1], ended: true)], placement: box) == PinchRouter.Output())
        #expect(router.mode == .idle)
    }
}

struct AtomRayHitTests {
    private let snapshot = SimulationSnapshot(
        typeCount: 1, boxLow: [-10, -10, -10], boxHigh: [10, 10, 10], tags: [1, 2, 3, 4], types: [1, 1, 1, 1],
        positions: [[0, 0, 5], [0, 0, 2], [0, 0, -3], [3, 0, 2]])

    @Test func firstAtomAlongTheRayWins() {
        let hit = snapshot.atomHit(rayOrigin: .zero, direction: [0, 0, 7], radius: { _ in 0.5 }, tolerance: 0)
        #expect(hit == 1)
    }

    @Test func atomsBehindTheOriginAreIgnored() {
        let hit = snapshot.atomHit(rayOrigin: [0, 0, 1], direction: [0, 0, -1], radius: { _ in 0.5 }, tolerance: 0)
        #expect(hit == 2)
        #expect(snapshot.atomHit(rayOrigin: [0, 0, 6], direction: [0, 0, 1], radius: { _ in 0.5 }, tolerance: 0) == nil)
    }

    @Test func toleranceWidensTheTarget() {
        // Passes 1 from atom 1's center (and 4 from atom 4's).
        let origin = SIMD3<Float>(0, 1, -1)
        #expect(snapshot.atomHit(rayOrigin: origin, direction: [0, 0, 1], radius: { _ in 0.5 }, tolerance: 0) == nil)
        #expect(snapshot.atomHit(rayOrigin: origin, direction: [0, 0, 1], radius: { _ in 0.5 }, tolerance: 0.6) == 1)
        // Per-atom radii count too.
        #expect(snapshot.atomHit(rayOrigin: origin, direction: [0, 0, 1], radius: { $0 == 0 ? 1.2 : 0.1 },
                                 tolerance: 0) == 0)
    }

    @Test func anOriginInsideAnAtomHitsIt() {
        let hit = snapshot.atomHit(rayOrigin: [3, 0.1, 2], direction: [-1, 0, 0], radius: { _ in 0.5 }, tolerance: 0)
        #expect(hit == 3)
    }

    @Test func missesAndDegenerateRaysReturnNil() {
        #expect(snapshot.atomHit(rayOrigin: .zero, direction: [0, 1, 0], radius: { _ in 0.5 }, tolerance: 0) == nil)
        #expect(snapshot.atomHit(rayOrigin: .zero, direction: .zero, radius: { _ in 0.5 }, tolerance: 0) == nil)
        #expect(snapshot.atomHit(rayOrigin: .zero, direction: [0, 0, 1], radius: { _ in 0 }, tolerance: 0) == nil)
    }
}

struct GrabDragTests {
    @Test func directPinchesMoveOneToOne() {
        let start = PinchSample(id: 1, kind: .direct, position: [0, 1, -0.5])
        let drag = GrabDrag(atomPosition: [0.02, 1, -0.5], pinch: start)
        #expect(drag.gain == 1)
        var moved = start
        moved.position = [0.1, 1.05, -0.5]
        #expect(close(drag.target(for: moved), [0.12, 1.05, -0.5]))
    }

    @Test func indirectPinchesScaleWithTheAtomsDistance() {
        let eyes = SIMD3<Float>(0, 1.6, 0)
        let ray = PinchSample.Ray(origin: eyes, direction: [0, 0, -1])
        // Hand 0.4 m from the eyes, atom 1.2 m away: three times as far.
        let start = PinchSample(id: 1, kind: .indirect, position: eyes + [0, 0, -0.4], ray: ray)
        let drag = GrabDrag(atomPosition: eyes + [0, 0, -1.2], pinch: start)
        #expect(abs(drag.gain - 3) < 1e-5)
        var moved = start
        moved.position += [0.1, 0, 0]
        #expect(close(drag.target(for: moved), eyes + [0.3, 0, -1.2]))

        // Clamped to 1...5, and a hand at the eyes counts as 15 cm away.
        #expect(GrabDrag(atomPosition: eyes + [0, 0, -0.1], pinch: start).gain == 1)
        #expect(GrabDrag(atomPosition: eyes + [0, 0, -10], pinch: start).gain == 5)
        let nearEyes = PinchSample(id: 1, kind: .indirect, position: eyes, ray: ray)
        #expect(abs(GrabDrag(atomPosition: eyes + [0, 0, -0.45], pinch: nearEyes).gain - 3) < 1e-4)
        // No ray: a fixed gain.
        #expect(GrabDrag(atomPosition: eyes + [0, 0, -1.2], pinch: PinchSample(id: 1, kind: .indirect, position: eyes)).gain == 2)
        // Non-finite input falls back to the fixed gain.
        let broken = PinchSample(id: 1, kind: .indirect, position: eyes,
                                 ray: .init(origin: [.infinity, 0, 0], direction: [0, 0, -1]))
        #expect(GrabDrag(atomPosition: eyes, pinch: broken).gain == 2)
    }

    @Test func smoothingMovesAThirdOfTheWayAtMostAndNoFartherThanTheMaximumStep() {
        // Short move: 35 % of the way.
        #expect(close(GrabDrag.smoothed(from: .zero, toward: [1, 0, 0], maxStep: 10), [0.35, 0, 0]))
        // Long move: capped at the maximum step.
        #expect(close(GrabDrag.smoothed(from: .zero, toward: [0, 10, 0], maxStep: 0.5), [0, 0.5, 0]))
        // Already there: stays.
        #expect(GrabDrag.smoothed(from: [1, 2, 3], toward: [1, 2, 3], maxStep: 0.5) == SIMD3(1, 2, 3))
    }
}

struct DemoPresentationFieldTests {
    @Test func decodesTheNewOptionalFields() throws {
        let demo = try JSONDecoder().decode(Demo.self, from: Data("""
            {"id":"water","title":"Water","summary":"Water","category":"Liquids","folder":"water",
             "inputScript":"in.water","stepsPerSecond":120.5,"frame":"room","showsBox":false,
             "hint":"Pinch a molecule"}
            """.utf8))
        #expect(demo.stepsPerSecond == 120.5)
        #expect(demo.frame == "room")
        #expect(demo.showsBox == false)
        #expect(demo.hint == "Pinch a molecule")

        let plain = try JSONDecoder().decode(Demo.self, from: Data("""
            {"id":"old","title":"Old","summary":"Old","category":"Old","folder":"old","inputScript":"in.old"}
            """.utf8))
        #expect(plain.stepsPerSecond == nil && plain.frame == nil && plain.showsBox == nil && plain.hint == nil)
    }
}

struct DemoCatalogBasicsTests {
    @Test func categoriesKeepFirstAppearanceOrder() {
        let catalog = DemoCatalog(demos: [
            Demo(id: "a", title: "A", summary: "", category: "Liquids", folder: "a", inputScript: "in.a"),
            Demo(id: "b", title: "B", summary: "", category: "Solids", folder: "b", inputScript: "in.b", modes: ["watch"]),
            Demo(id: "c", title: "C", summary: "", category: "Liquids", folder: "c", inputScript: "in.c"),
        ])
        #expect(catalog.categories == ["Liquids", "Solids"])
        #expect(catalog.releaseDemos.isEmpty)
        #expect(!catalog.demos[1].suits(mode: "touch"))
    }

    @Test func workingCopyOfADemoWithoutItsScriptThrows() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("atomify-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let demo = Demo(id: "e", title: "E", summary: "", category: "X", folder: "empty", inputScript: "in.missing")
        #expect(throws: CocoaError.self) {
            _ = try DemoCatalog.makeWorkingCopy(of: demo, from: root, into: root)
        }
    }
}
