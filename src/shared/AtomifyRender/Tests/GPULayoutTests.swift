import simd
import XCTest
@testable import AtomifyRender

/// The Swift mirrors must match the MSL structs in `ShaderSource` byte for byte.
final class GPULayoutTests: XCTestCase {
    func testStrides() {
        XCTAssertEqual(MemoryLayout<GPUParticle>.stride, 16)
        XCTAssertEqual(MemoryLayout<GPUStyle>.stride, 32)
        XCTAssertEqual(MemoryLayout<GPUBond>.stride, 8)
        XCTAssertEqual(MemoryLayout<GPULineSegment>.stride, 48)
        XCTAssertEqual(MemoryLayout<ViewUniforms>.stride, 160)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.stride, 16)
        XCTAssertEqual(MemoryLayout<SSAOUniforms>.stride, 96)
        XCTAssertEqual(MemoryLayout<CompositeUniforms>.stride, 48)
    }

    func testParticleOffsets() {
        XCTAssertEqual(MemoryLayout<GPUParticle>.offset(of: \.x), 0)
        XCTAssertEqual(MemoryLayout<GPUParticle>.offset(of: \.y), 4)
        XCTAssertEqual(MemoryLayout<GPUParticle>.offset(of: \.z), 8)
        XCTAssertEqual(MemoryLayout<GPUParticle>.offset(of: \.styleFlags), 12)
        XCTAssertEqual(MemoryLayout<GPUParticle>.alignment, 4)
    }

    func testUniformOffsets() {
        XCTAssertEqual(MemoryLayout<ViewUniforms>.offset(of: \.projection), 64)
        XCTAssertEqual(MemoryLayout<ViewUniforms>.offset(of: \.lightDirection), 128)
        XCTAssertEqual(MemoryLayout<ViewUniforms>.offset(of: \.params), 144)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.nearFade), 16)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.bond), 32)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.options), 48)
        XCTAssertEqual(MemoryLayout<SSAOUniforms>.offset(of: \.params), 64)
        XCTAssertEqual(MemoryLayout<SSAOUniforms>.offset(of: \.screen), 80)
        XCTAssertEqual(MemoryLayout<CompositeUniforms>.offset(of: \.sizes), 16)
        XCTAssertEqual(MemoryLayout<CompositeUniforms>.offset(of: \.outlineColor), 32)
        XCTAssertEqual(MemoryLayout<GPULineSegment>.offset(of: \.end), 16)
        XCTAssertEqual(MemoryLayout<GPULineSegment>.offset(of: \.color), 32)
        XCTAssertEqual(MemoryLayout<GPUStyle>.offset(of: \.params), 16)
    }

    func testViewUniformsArrayIsTightlyPacked() {
        // Two views are uploaded as one array with setVertexBytes.
        XCTAssertEqual(MemoryLayout<ViewUniforms>.stride * 2, 320)
        XCTAssertEqual(MemoryLayout<ViewUniforms>.alignment, 16)
    }
}
