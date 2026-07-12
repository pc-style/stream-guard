import Foundation

public enum PrivacyScanResult: Equatable {
    case clean
    case detected(String)
    case inconclusive(String)
}

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

    public func update(_ result: PrivacyScanResult) {
        switch result {
        case .inconclusive(let reason):
            invalidateClearance(reason)
        case .detected(let reason):
            invalidateClearance(reason)
            detectedSinceClear = true
        case .clean where pendingClearanceDelay:
            isBlocked = true
            reason = "Clean checks passed · waiting for stream delay"
        case .clean where pendingManualApproval:
            isBlocked = true
            reason = "Manual clearance required"
        case .clean where isBlocked:
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
        case .clean:
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
        guard pendingManualApproval else { return }
        isBlocked = false
        reason = "Protected"
        cleanChecks = 0
        pendingManualApproval = false
        pendingClearanceDelay = false
        detectedSinceClear = false
    }

    public func requireManualClearance() {
        guard pendingManualApproval else { return }
        isBlocked = true
        reason = "Manual clearance required"
    }

    private func invalidateClearance(_ reason: String) {
        isBlocked = true
        self.reason = reason
        cleanChecks = 0
        pendingManualApproval = false
        pendingClearanceDelay = false
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
