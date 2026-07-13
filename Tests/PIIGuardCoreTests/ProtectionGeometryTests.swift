import Foundation
import Testing
@testable import PIIGuardCore

@Test func globalTopLeftGeometryMapsToBottomLeftPixelsAndClips() {
    let geometry = CaptureGeometry(globalBounds: CGRect(x: 100, y: 200, width: 1000, height: 500), pixelSize: CGSize(width: 2000, height: 1000))
    #expect(geometry.imageRect(for: CGRect(x: 100, y: 200, width: 100, height: 50), padding: 0) == CGRect(x: 0, y: 900, width: 200, height: 100))
    #expect(geometry.imageRect(for: CGRect(x: 50, y: 150, width: 100, height: 100), padding: 0) == CGRect(x: 0, y: 900, width: 100, height: 100))
}

@Test func snapshotsAreCaptureTimeFreshAndReplacementIsAtomic() {
    let store = SnapshotStore()
    let old = ProtectionSnapshot(generation: 1, capturedAt: 10, maskRects: [], blocksFrame: false, reason: "old")
    store.replace(old)
    #expect(store.decision(at: 11, maximumAge: 2, expectedGeneration: 1) == old)
    #expect(store.decision(at: 11, maximumAge: 2, expectedGeneration: 2) == nil)
    #expect(store.decision(at: 13, maximumAge: 2, expectedGeneration: 1) == nil)
    let new = ProtectionSnapshot(generation: 2, capturedAt: 13, maskRects: [], blocksFrame: true, reason: "new")
    store.replace(new)
    #expect(store.decision(at: 13, maximumAge: 2, expectedGeneration: 2) == new)
    #expect(store.decision(at: 13, maximumAge: 2, expectedGeneration: 1) == nil)
}

@Test func contentRectHandlesLetterboxingScaleAndOrigin() {
    let geometry = CaptureGeometry(globalBounds: CGRect(x: 100, y: 200, width: 1000, height: 500), pixelSize: CGSize(width: 2200, height: 1200), contentRect: CGRect(x: 100, y: 100, width: 2000, height: 1000))
    #expect(geometry.imageRect(for: CGRect(x: 100, y: 200, width: 100, height: 50), padding: 0) == CGRect(x: 100, y: 1000, width: 200, height: 100))
}

@Test func ciTopQuarterConvertsToCGImageTopQuarter() {
    #expect(cgImageCropRect(fromCIRect: CGRect(x: 17, y: 600, width: 100, height: 200), imageHeight: 800) == CGRect(x: 17, y: 0, width: 100, height: 200))
}

@Test func detectionRangesRemainUTF16WithEmojiAndCombiningMarks() {
    let text = "👩🏽‍💻 e\u{301} mail test@example.com"
    let result = DetectionEngine().detect(in: text, options: DetectionOptions(enabledKinds: [.email]))
    #expect(result.count == 1)
    #expect((text as NSString).substring(with: result[0].range) == "test@example.com")
    #expect(result[0].range.location == (text as NSString).range(of: "test@example.com").location)
}
