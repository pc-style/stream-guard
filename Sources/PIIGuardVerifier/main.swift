import Foundation
import PIIGuardCore

let engine = DetectionEngine()
var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
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

let gate = PrivacyGate()
gate.requiredCleanChecks = 3
gate.update(hasPII: true)
check(gate.isBlocked && gate.reason == "PII detected", "PII blocks immediately")
gate.update(hasPII: false)
gate.update(hasPII: false)
check(gate.isBlocked, "gate stays blocked before clean threshold")
gate.update(hasPII: false)
check(!gate.isBlocked, "gate clears at clean threshold")
gate.update(hasPII: false, unavailableReason: "Accessibility unavailable")
check(gate.isBlocked, "unavailable detection fails closed")

let safeGate = PrivacyGate()
safeGate.requiredCleanChecks = 2
safeGate.requiresManualApproval = true
safeGate.update(hasPII: false)
safeGate.update(hasPII: false)
check(!safeGate.isBlocked, "safe mode does not require approval at startup")
safeGate.update(hasPII: true)
safeGate.update(hasPII: false)
safeGate.update(hasPII: false)
check(safeGate.isBlocked && safeGate.pendingManualApproval, "safe mode latches after PII")
safeGate.approveManualClearance()
check(!safeGate.isBlocked, "manual clearance unblocks safe mode")

let delayedGate = PrivacyGate()
delayedGate.requiredCleanChecks = 2
delayedGate.requiresClearanceDelay = true
delayedGate.update(hasPII: false)
delayedGate.update(hasPII: false)
check(delayedGate.isBlocked && delayedGate.pendingClearanceDelay, "clean threshold waits for stream delay")
delayedGate.completeClearanceDelay()
check(!delayedGate.isBlocked, "stream delay completion unblocks preview")

guard failures.isEmpty else {
    FileHandle.standardError.write(Data("Verification failed: \(failures.joined(separator: ", "))\n".utf8))
    exit(1)
}
print("PII Guard verification passed (13 checks)")
