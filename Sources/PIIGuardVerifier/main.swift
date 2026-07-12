import Foundation
import PIIGuardCore

let engine = DetectionEngine()
var failures: [String] = []
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures.append(message) }
}

let common = engine.detect(
    in: "Email me@example.com, card 4242 4242 4242 4242, IP 192.168.1.5, not 999.999.1.1",
    options: DetectionOptions()
)
check(Set(common.map(\.kind)) == Set([.email, .creditCard, .ipAddress]), "common PII validation")

let pesel = engine.detect(in: "PESEL 44051401458 invalid 44051401459", options: DetectionOptions())
check(pesel.filter { $0.kind == .nationalID }.count == 1, "PESEL checksum validation")

let custom = engine.detect(in: "Project NIGHTJAR", options: DetectionOptions(customPhrases: ["nightjar"]))
check(custom.first?.kind == .custom, "case-insensitive custom phrase")

let disabled = DetectionOptions(enabledKinds: [.email], customPhrases: ["nightjar"])
check(engine.detect(in: "NIGHTJAR", options: disabled).isEmpty, "disabled custom phrase")

check(
    CustomPhraseEditor.update(["Café"], with: " CAFE ", editing: nil) == .duplicate,
    "duplicate custom phrase add is case and diacritic insensitive"
)
check(
    CustomPhraseEditor.update(["Nightjar", "Café"], with: "NIGHTJAR", editing: 1) == .duplicate,
    "duplicate custom phrase edit is rejected"
)
check(
    CustomPhraseEditor.update(["Nightjar", "Café"], with: " Skylark ", editing: 1)
        == .changed(["Nightjar", "Skylark"]),
    "valid custom phrase edit changes only its selected value"
)
check(
    CustomPhraseEditor.update(["Nightjar"], with: "Nightjar", editing: 0) == .unchanged,
    "unchanged custom phrase edit does not report a settings change"
)

for _ in 0..<20 {
    check(engine.detect(in: "contact cache@example.com", options: DetectionOptions()).first?.kind == .email, "cached regex detection remains stable")
}

let normalBuffer = DelayBufferPolicy(width: 1280, height: 720, delaySeconds: 2, fps: 10)
check(normalBuffer.maxFrames == 20, "normal delay buffer preserves requested frame cadence")
check(abs(normalBuffer.sampleInterval - 0.1) < 0.000_001, "normal delay buffer samples at capture cadence")

let boundedBuffer = DelayBufferPolicy(width: 2560, height: 1440, delaySeconds: 10, fps: 30)
check(boundedBuffer.estimatedMaximumBytes <= DelayBufferPolicy.defaultMemoryBudgetBytes, "large delay buffer stays within memory budget")
check(boundedBuffer.maxFrames < 300, "large delay buffer reduces retained full frames")
check(boundedBuffer.sampleInterval > 1.0 / 30.0, "large delay buffer applies bounded sampling")

let overflowBuffer = DelayBufferPolicy(width: Int.max, height: Int.max, delaySeconds: 10, fps: 30, memoryBudgetBytes: 1_024)
check(overflowBuffer.maxFrames == 1, "overflowing dimensions retain at most one frame")
check(overflowBuffer.estimatedBytesPerFrame == Int.max, "overflowing frame estimate saturates")
check(overflowBuffer.estimatedMaximumBytes == Int.max, "overflowing buffer estimate does not wrap")

let gate = PrivacyGate()
gate.requiredCleanChecks = 3
gate.update(.detected("PII detected"))
check(gate.isBlocked && gate.reason == "PII detected", "PII blocks immediately")
gate.update(.clean)
gate.update(.clean)
check(gate.isBlocked, "gate stays blocked before clean threshold")
gate.update(.clean)
check(!gate.isBlocked, "gate clears at clean threshold")
gate.update(.inconclusive("Accessibility unavailable"))
check(gate.isBlocked && gate.cleanChecks == 0, "inconclusive scan fails closed")
gate.update(.clean)
gate.update(.clean)
check(gate.isBlocked, "inconclusive scan requires a fresh clean cycle")
gate.update(.clean)
check(!gate.isBlocked, "fresh clean cycle can clear an inconclusive scan")

let safeGate = PrivacyGate()
safeGate.requiredCleanChecks = 2
safeGate.requiresManualApproval = true
safeGate.update(.clean)
safeGate.update(.clean)
check(!safeGate.isBlocked, "safe mode does not require approval at startup")
safeGate.update(.detected("PII detected"))
safeGate.update(.clean)
safeGate.update(.clean)
check(safeGate.isBlocked && safeGate.pendingManualApproval, "safe mode latches after PII")
safeGate.update(.inconclusive("Scan timed out"))
check(safeGate.isBlocked && !safeGate.pendingManualApproval, "inconclusive scan invalidates pending approval")
safeGate.approveManualClearance()
check(safeGate.isBlocked, "stale manual approval cannot unblock")
safeGate.requireManualClearance()
safeGate.approveManualClearance()
check(safeGate.isBlocked && !safeGate.pendingManualApproval, "stale prompt cannot restore invalidated manual approval")
safeGate.update(.clean)
safeGate.update(.clean)
check(safeGate.pendingManualApproval, "fresh clean cycle restores manual approval")
safeGate.approveManualClearance()
check(!safeGate.isBlocked, "current manual clearance unblocks safe mode")

let delayedGate = PrivacyGate()
delayedGate.requiredCleanChecks = 2
delayedGate.requiresClearanceDelay = true
delayedGate.update(.clean)
delayedGate.update(.clean)
check(delayedGate.isBlocked && delayedGate.pendingClearanceDelay, "clean threshold waits for stream delay")
delayedGate.update(.inconclusive("Accessibility permission required"))
check(delayedGate.isBlocked && !delayedGate.pendingClearanceDelay, "permission loss invalidates clearance delay")
delayedGate.completeClearanceDelay()
check(delayedGate.isBlocked, "stale clearance timer cannot unblock")
delayedGate.update(.clean)
delayedGate.update(.clean)
check(delayedGate.pendingClearanceDelay, "permission recovery requires fresh clean checks")
delayedGate.completeClearanceDelay()
check(!delayedGate.isBlocked, "fresh stream delay completion unblocks preview")

let detectedDuringDelay = PrivacyGate()
detectedDuringDelay.requiredCleanChecks = 1
detectedDuringDelay.requiresClearanceDelay = true
detectedDuringDelay.update(.clean)
detectedDuringDelay.update(.detected("PII detected"))
detectedDuringDelay.completeClearanceDelay()
check(detectedDuringDelay.isBlocked && !detectedDuringDelay.pendingClearanceDelay, "detection invalidates pending clearance timer")

guard failures.isEmpty else {
    FileHandle.standardError.write(Data("Verification failed: \(failures.joined(separator: ", "))\n".utf8))
    exit(1)
}
print("PII Guard verification passed (\(checks) checks)")
