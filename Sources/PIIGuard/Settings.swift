import Foundation
import PIIGuardCore

enum ClearMode: String, CaseIterable {
    case quick
    case balanced
    case strict
    case safe

    var title: String {
        switch self {
        case .quick: return "Quick · 3 clean bursts"
        case .balanced: return "Balanced · adaptive"
        case .strict: return "Strict · 10 clean bursts"
        case .safe: return "Safe · manual approval after PII"
        }
    }

    func requiredChecks(checksPerSecond: Double) -> Int {
        switch self {
        case .quick: return 3
        case .balanced: return checksPerSecond < 10 ? 5 : 10
        case .strict: return 10
        case .safe: return checksPerSecond < 10 ? 5 : 10
        }
    }

    var requiresManualApproval: Bool { self == .safe }
}

enum CaptureResolution: String, CaseIterable {
    case p720, p1080, p1440

    var title: String {
        switch self { case .p720: return "1280 × 720"; case .p1080: return "1920 × 1080"; case .p1440: return "2560 × 1440" }
    }
    var size: (width: Int, height: Int) {
        switch self { case .p720: return (1280, 720); case .p1080: return (1920, 1080); case .p1440: return (2560, 1440) }
    }
}

enum ProtectionPreset: String, CaseIterable {
    case safe, balanced, fast
    var title: String {
        switch self {
        case .safe: return "Safe · OCR gaps · 0.5 s reconciliation"
        case .balanced: return "Balanced · exact AX masks · 3 s reconciliation"
        case .fast: return "Fast · exact AX masks · 5 s reconciliation"
        }
    }
    var reconciliationInterval: TimeInterval { self == .safe ? 0.5 : (self == .balanced ? 3 : 5) }
    var accessibilityTimeout: TimeInterval { self == .safe ? 1.0 : (self == .balanced ? 0.75 : 0.3) }
    var usesOCR: Bool { self == .safe }
}

final class Settings {
    private let defaults = UserDefaults.standard
    private let phraseKey = "customPhrases"

    var isEnabled: Bool {
        get { defaults.object(forKey: "isEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isEnabled") }
    }

    var protectionPreset: ProtectionPreset {
        get { ProtectionPreset(rawValue: defaults.string(forKey: "protectionPreset") ?? "balanced") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "protectionPreset") }
    }

    var customPhrases: [String] {
        get { defaults.stringArray(forKey: phraseKey) ?? [] }
        set { defaults.set(newValue, forKey: phraseKey) }
    }

    var delaySeconds: Double {
        get { defaults.object(forKey: "delaySeconds") as? Double ?? 2 }
        set { defaults.set(newValue, forKey: "delaySeconds") }
    }

    var clearMode: ClearMode {
        get { ClearMode(rawValue: defaults.string(forKey: "clearMode") ?? "balanced") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "clearMode") }
    }

    var captureResolution: CaptureResolution {
        get { CaptureResolution(rawValue: defaults.string(forKey: "captureResolution") ?? "p720") ?? .p720 }
        set { defaults.set(newValue.rawValue, forKey: "captureResolution") }
    }

    var captureFPS: Int {
        get { defaults.object(forKey: "captureFPS") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "captureFPS") }
    }

    var showsCursor: Bool {
        get { defaults.object(forKey: "showsCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showsCursor") }
    }

    func isKindEnabled(_ kind: SensitiveKind) -> Bool {
        defaults.object(forKey: "kind.\(kind.rawValue)") as? Bool ?? true
    }

    func setKind(_ kind: SensitiveKind, enabled: Bool) {
        defaults.set(enabled, forKey: "kind.\(kind.rawValue)")
    }

    var detectionOptions: DetectionOptions {
        DetectionOptions(
            enabledKinds: Set(SensitiveKind.allCases.filter(isKindEnabled)),
            customPhrases: customPhrases
        )
    }
}
