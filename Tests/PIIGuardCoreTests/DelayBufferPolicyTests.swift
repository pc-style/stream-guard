import Testing
@testable import PIIGuardCore

@Test func largeCaptureStaysWithinMemoryBudget() {
    let policy = DelayBufferPolicy(width: 2560, height: 1440, delaySeconds: 10, fps: 30)

    #expect(policy.estimatedMaximumBytes <= DelayBufferPolicy.defaultMemoryBudgetBytes)
    #expect(policy.maxFrames < 300)
    #expect(policy.sampleInterval > 1.0 / 30.0)
}

@Test func normalCapturePreservesRequestedCadence() {
    let policy = DelayBufferPolicy(width: 1280, height: 720, delaySeconds: 2, fps: 10)

    #expect(policy.maxFrames == 20)
    #expect(abs(policy.sampleInterval - 0.1) < 0.000_001)
}

@Test func overflowingDimensionsSaturateWithoutArithmeticTrap() {
    let policy = DelayBufferPolicy(
        width: Int.max,
        height: Int.max,
        delaySeconds: 10,
        fps: 30,
        memoryBudgetBytes: 1_024
    )

    #expect(policy.maxFrames == 1)
    #expect(policy.estimatedBytesPerFrame == Int.max)
    #expect(policy.estimatedMaximumBytes == Int.max)
}
