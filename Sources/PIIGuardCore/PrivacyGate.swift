import Foundation

public final class PrivacyGate {
    public private(set) var isBlocked = true
    public private(set) var reason = "Waiting for a privacy check"
    public private(set) var cleanChecks = 0
    public private(set) var pendingManualApproval = false
    public private(set) var pendingClearanceDelay = false
    public var requiredCleanChecks = 5
    public var requiresManualApproval = false
    public var requiresClearanceDelay = false
    private var detectedSinceClear = false

    public init() {}

    public func update(hasPII: Bool, detectionReason: String = "PII detected", unavailableReason: String? = nil) {
        if let unavailableReason {
            isBlocked = true
            reason = unavailableReason
            cleanChecks = 0
        } else if hasPII {
            isBlocked = true
            reason = detectionReason
            cleanChecks = 0
            detectedSinceClear = true
            pendingManualApproval = false
            pendingClearanceDelay = false
        } else if pendingClearanceDelay {
            isBlocked = true
            reason = "Clean checks passed · waiting for stream delay"
        } else if pendingManualApproval {
            isBlocked = true
            reason = "Manual clearance required"
        } else if isBlocked {
            cleanChecks += 1
            reason = "Checking for PII · \(cleanChecks)/\(requiredCleanChecks) clean bursts"
            if cleanChecks >= requiredCleanChecks {
                if requiresClearanceDelay {
                    pendingClearanceDelay = true
                    reason = "Clean checks passed · waiting for stream delay"
                } else {
                    finishClearance()
                }
            }
        } else {
            reason = "Protected"
        }
    }

    public func reset(_ reason: String) {
        isBlocked = true
        self.reason = reason
        cleanChecks = 0
        pendingManualApproval = false
        pendingClearanceDelay = false
        detectedSinceClear = false
    }

    public func completeClearanceDelay() {
        guard pendingClearanceDelay else { return }
        pendingClearanceDelay = false
        finishClearance()
    }

    public func approveManualClearance() {
        isBlocked = false
        reason = "Protected"
        cleanChecks = 0
        pendingManualApproval = false
        pendingClearanceDelay = false
        detectedSinceClear = false
    }

    public func requireManualClearance() {
        isBlocked = true
        reason = "Manual clearance required"
        pendingManualApproval = true
    }

    private func finishClearance() {
        if requiresManualApproval && detectedSinceClear {
            isBlocked = true
            pendingManualApproval = true
            reason = "Clean checks passed · approval required"
        } else {
            isBlocked = false
            reason = "Protected"
            detectedSinceClear = false
        }
    }
}
