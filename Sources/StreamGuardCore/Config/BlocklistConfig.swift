import Foundation

public enum GuardState: String, Codable, Sendable, Equatable {
    case clear = "clear"
    case suspect = "suspect"
    case armed = "armed"
}

public struct PhraseEntry: Codable, Sendable, Equatable {
    public let text: String
    public let fuzzy: Bool

    public init(text: String, fuzzy: Bool) {
        self.text = text
        self.fuzzy = fuzzy
    }
}

public struct PatternConfig: Codable, Sendable, Equatable {
    public var phone: Bool
    public var email: Bool
    public var ssn: Bool

    public init(phone: Bool = true, email: Bool = true, ssn: Bool = false) {
        self.phone = phone
        self.email = email
        self.ssn = ssn
    }
}

public struct HysteresisConfig: Codable, Sendable, Equatable {
    public var triggerFrames: Int
    public var clearFrames: Int

    public init(triggerFrames: Int = 1, clearFrames: Int = 3) {
        self.triggerFrames = triggerFrames
        self.clearFrames = clearFrames
    }
}

public struct OCRConfig: Codable, Sendable, Equatable {
    public var fps: Double
    public var recognitionLevel: String
    public var minimumTextHeight: Float

    public init(fps: Double = 6, recognitionLevel: String = "fast", minimumTextHeight: Float = 0.01) {
        self.fps = fps
        self.recognitionLevel = recognitionLevel
        self.minimumTextHeight = minimumTextHeight
    }
}

public struct OBSConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var blackoutScene: String

    public init(enabled: Bool = false, host: String = "127.0.0.1", port: Int = 4455, blackoutScene: String = "BLACKOUT") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.blackoutScene = blackoutScene
    }
}

public struct BlocklistConfig: Codable, Sendable, Equatable {
    public var phrases: [PhraseEntry]
    public var patterns: PatternConfig
    public var hysteresis: HysteresisConfig
    public var ocr: OCRConfig
    public var obs: OBSConfig

    public init(
        phrases: [PhraseEntry] = [],
        patterns: PatternConfig = PatternConfig(),
        hysteresis: HysteresisConfig = HysteresisConfig(),
        ocr: OCRConfig = OCRConfig(),
        obs: OBSConfig = OBSConfig()
    ) {
        self.phrases = phrases
        self.patterns = patterns
        self.hysteresis = hysteresis
        self.ocr = ocr
        self.obs = obs
    }

    public static let `default` = BlocklistConfig(
        phrases: [
            PhraseEntry(text: "example-banned-term", fuzzy: true),
            PhraseEntry(text: "exact-ban", fuzzy: false),
        ],
        patterns: PatternConfig(),
        hysteresis: HysteresisConfig(),
        ocr: OCRConfig(),
        obs: OBSConfig()
    )
}

public struct StatusPayload: Codable, Sendable, Equatable {
    public let state: String
    public let lastMatch: String?
    public let timestamp: TimeInterval
    public let monitoring: Bool
    public let ocrFrames: Int
    public let lastOCRText: String
    public let mergedText: String
    public let lastOCRLatencyMS: Double?
    public let lastOCRAt: TimeInterval?
    public let overlayVisible: Bool

    public init(
        state: GuardState,
        lastMatch: String?,
        timestamp: Date = Date(),
        monitoring: Bool = false,
        ocrFrames: Int = 0,
        lastOCRText: String = "",
        mergedText: String = "",
        lastOCRLatencyMS: Double? = nil,
        lastOCRAt: Date? = nil,
        overlayVisible: Bool = false
    ) {
        self.state = state.rawValue
        self.lastMatch = lastMatch
        self.timestamp = timestamp.timeIntervalSince1970
        self.monitoring = monitoring
        self.ocrFrames = ocrFrames
        self.lastOCRText = lastOCRText
        self.mergedText = mergedText
        self.lastOCRLatencyMS = lastOCRLatencyMS
        self.lastOCRAt = lastOCRAt?.timeIntervalSince1970
        self.overlayVisible = overlayVisible
    }
}

public struct StateTransition: Sendable, Equatable {
    public let previous: GuardState
    public let current: GuardState
    public let lastMatch: String?

    public init(previous: GuardState, current: GuardState, lastMatch: String?) {
        self.previous = previous
        self.current = current
        self.lastMatch = lastMatch
    }
}
