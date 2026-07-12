import Testing
@testable import PIIGuardCore

@Test func inconclusiveScanRequiresFreshCleanCycle() {
    let gate = PrivacyGate()
    gate.requiredCleanChecks = 3

    gate.update(.clean)
    gate.update(.clean)
    gate.update(.inconclusive("Accessibility unavailable"))

    #expect(gate.isBlocked)
    #expect(gate.cleanChecks == 0)

    gate.update(.clean)
    gate.update(.clean)
    #expect(gate.isBlocked)
    gate.update(.clean)
    #expect(!gate.isBlocked)
}

@Test func detectionInvalidatesPendingClearanceDelay() {
    let gate = PrivacyGate()
    gate.requiredCleanChecks = 1
    gate.requiresClearanceDelay = true

    gate.update(.clean)
    #expect(gate.pendingClearanceDelay)

    gate.update(.detected("PII detected"))
    gate.completeClearanceDelay()

    #expect(gate.isBlocked)
    #expect(!gate.pendingClearanceDelay)
    #expect(gate.reason == "PII detected")
}

@Test func staleManualApprovalCannotUnblockAfterInconclusiveScan() {
    let gate = PrivacyGate()
    gate.requiredCleanChecks = 1
    gate.requiresManualApproval = true

    gate.update(.detected("PII detected"))
    gate.update(.clean)
    #expect(gate.pendingManualApproval)

    gate.update(.inconclusive("Scan timed out"))
    gate.approveManualClearance()

    #expect(gate.isBlocked)
    #expect(!gate.pendingManualApproval)
}

@Test func resetInvalidatesAllPendingClearanceState() {
    let gate = PrivacyGate()
    gate.requiredCleanChecks = 1
    gate.requiresClearanceDelay = true
    gate.update(.clean)

    gate.reset("Capture restarted")
    gate.completeClearanceDelay()
    gate.approveManualClearance()

    #expect(gate.isBlocked)
    #expect(gate.cleanChecks == 0)
    #expect(!gate.pendingClearanceDelay)
    #expect(!gate.pendingManualApproval)
    #expect(gate.reason == "Capture restarted")
}

@Test func staleManualRequestCannotRestoreInvalidatedApproval() {
    let gate = PrivacyGate()
    gate.requiredCleanChecks = 1
    gate.requiresManualApproval = true
    gate.update(.detected("PII detected"))
    gate.update(.clean)
    #expect(gate.pendingManualApproval)

    gate.update(.inconclusive("Scan timed out"))
    gate.requireManualClearance()
    gate.approveManualClearance()

    #expect(gate.isBlocked)
    #expect(!gate.pendingManualApproval)
    #expect(gate.reason == "Scan timed out")
}
