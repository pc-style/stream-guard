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

public enum OCRGuardMode: String, Codable, Sendable, Equatable, CaseIterable {
    case blurAll = "blurAll"
    case whitelist = "whitelist"
    case blacklist = "blacklist"

    public var isBuggy: Bool {
        self == .blurAll
    }

    public var warning: String? {
        switch self {
        case .blurAll:
            return "Buggy: blur-all mode intentionally overblocks any OCR text and can blur harmless content."
        case .whitelist, .blacklist:
            return nil
        }
    }
}

public struct OCRListEntry: Codable, Sendable, Equatable {
    public var text: String
    public var fuzzy: Bool
    public var minimumSimilarity: Double

    public init(text: String, fuzzy: Bool = true, minimumSimilarity: Double = 0.88) {
        self.text = text
        self.fuzzy = fuzzy
        self.minimumSimilarity = Self.clampedSimilarity(minimumSimilarity)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case fuzzy
        case minimumSimilarity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.fuzzy = try container.decodeIfPresent(Bool.self, forKey: .fuzzy) ?? true
        let similarity = try container.decodeIfPresent(Double.self, forKey: .minimumSimilarity) ?? 0.88
        self.minimumSimilarity = Self.clampedSimilarity(similarity)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(fuzzy, forKey: .fuzzy)
        try container.encode(minimumSimilarity, forKey: .minimumSimilarity)
    }

    private static func clampedSimilarity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.88 }
        return min(1, max(0, value))
    }
}

public struct OCRFilteringConfig: Codable, Sendable, Equatable {
    public var mode: OCRGuardMode
    public var whitelist: [OCRListEntry]
    public var blacklist: [OCRListEntry]
    public var blurAllMinimumCharacters: Int

    public init(
        mode: OCRGuardMode = .blacklist,
        whitelist: [OCRListEntry] = [],
        blacklist: [OCRListEntry] = [],
        blurAllMinimumCharacters: Int = 2
    ) {
        self.mode = mode
        self.whitelist = whitelist
        self.blacklist = blacklist
        self.blurAllMinimumCharacters = max(1, blurAllMinimumCharacters)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case whitelist
        case blacklist
        case blurAllMinimumCharacters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(OCRGuardMode.self, forKey: .mode) ?? .blacklist
        self.whitelist = try container.decodeIfPresent([OCRListEntry].self, forKey: .whitelist) ?? []
        self.blacklist = try container.decodeIfPresent([OCRListEntry].self, forKey: .blacklist) ?? []
        let minimumCharacters = try container.decodeIfPresent(Int.self, forKey: .blurAllMinimumCharacters) ?? 2
        self.blurAllMinimumCharacters = max(1, minimumCharacters)
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

public enum PipelineMode: String, Codable, Sendable, Equatable, CaseIterable {
    case fullFrame = "fullFrame"
    case roiCascade = "roiCascade"
    case yodoMask = "yodoMask"
    case yodoOCR = "yodoOCR"
}

public struct PipelineConfig: Codable, Sendable, Equatable {
    public var mode: PipelineMode
    public var yodoShowsMasks: Bool

    public init(mode: PipelineMode = .fullFrame, yodoShowsMasks: Bool = true) {
        self.mode = mode
        self.yodoShowsMasks = yodoShowsMasks
    }
}

public struct OBSConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var controlMode: String
    public var blackoutScene: String
    public var protectedScene: String
    public var blackoutSource: String

    public init(
        enabled: Bool = false,
        host: String = "127.0.0.1",
        port: Int = 4455,
        controlMode: String = "scene",
        blackoutScene: String = "BLACKOUT",
        protectedScene: String = "STREAM_GUARD_PROTECTED",
        blackoutSource: String = "STREAM_GUARD_BLACKOUT"
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.controlMode = controlMode
        self.blackoutScene = blackoutScene
        self.protectedScene = protectedScene
        self.blackoutSource = blackoutSource
    }
}

public struct BlocklistConfig: Codable, Sendable, Equatable {
    public var phrases: [PhraseEntry]
    public var patterns: PatternConfig
    public var hysteresis: HysteresisConfig
    public var ocr: OCRConfig
    public var filtering: OCRFilteringConfig
    public var pipeline: PipelineConfig
    public var obs: OBSConfig

    public init(
        phrases: [PhraseEntry] = [],
        patterns: PatternConfig = PatternConfig(),
        hysteresis: HysteresisConfig = HysteresisConfig(),
        ocr: OCRConfig = OCRConfig(),
        filtering: OCRFilteringConfig = OCRFilteringConfig(),
        pipeline: PipelineConfig = PipelineConfig(),
        obs: OBSConfig = OBSConfig()
    ) {
        self.phrases = phrases
        self.patterns = patterns
        self.hysteresis = hysteresis
        self.ocr = ocr
        self.filtering = filtering
        self.pipeline = pipeline
        self.obs = obs
    }

    private enum CodingKeys: String, CodingKey {
        case phrases
        case patterns
        case hysteresis
        case ocr
        case filtering
        case pipeline
        case obs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.phrases = try container.decodeIfPresent([PhraseEntry].self, forKey: .phrases) ?? []
        self.patterns = try container.decodeIfPresent(PatternConfig.self, forKey: .patterns) ?? PatternConfig()
        self.hysteresis = try container.decodeIfPresent(HysteresisConfig.self, forKey: .hysteresis) ?? HysteresisConfig()
        self.ocr = try container.decodeIfPresent(OCRConfig.self, forKey: .ocr) ?? OCRConfig()
        self.filtering = try container.decodeIfPresent(OCRFilteringConfig.self, forKey: .filtering) ?? OCRFilteringConfig()
        self.pipeline = try container.decodeIfPresent(PipelineConfig.self, forKey: .pipeline) ?? PipelineConfig()
        self.obs = try container.decodeIfPresent(OBSConfig.self, forKey: .obs) ?? OBSConfig()
    }

    public static let `default` = BlocklistConfig(
        phrases: [
            PhraseEntry(text: "example-banned-term", fuzzy: true),
            PhraseEntry(text: "exact-ban", fuzzy: false),
        ],
        patterns: PatternConfig(),
        hysteresis: HysteresisConfig(),
        ocr: OCRConfig(),
        filtering: OCRFilteringConfig(
            mode: .blacklist,
            whitelist: [
                OCRListEntry(text: "support@example.com", fuzzy: true, minimumSimilarity: 0.92),
                OCRListEntry(text: "public demo", fuzzy: true, minimumSimilarity: 0.88),
            ],
            blacklist: [
                OCRListEntry(text: "private@example.com", fuzzy: true, minimumSimilarity: 0.9),
                OCRListEntry(text: "private stream notes", fuzzy: true, minimumSimilarity: 0.86),
            ]
        ),
        pipeline: PipelineConfig(),
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
    public let ocrGuardMode: String
    public let ocrGuardModeWarning: String?
    public let lastDetectionReason: String
    public let lastDetectionScore: Double?
    public let lastDetectionMatchedText: String?
    public let lastDetectionRuleText: String?
    public let lastWhitelistText: String?
    public let lastWhitelistScore: Double?
    public let lastOCRLatencyMS: Double?
    public let lastOCRAt: TimeInterval?
    public let overlayVisible: Bool
    public let lastSnapshotDurationMS: Double?
    public let lastPreprocessDurationMS: Double?
    public let lastFrameReceivedAt: TimeInterval?
    public let lastPipelineStartedAt: TimeInterval?
    public let lastPreprocessDoneAt: TimeInterval?
    public let lastOCRStartedAt: TimeInterval?
    public let lastOCRDoneAt: TimeInterval?
    public let lastStateTransitionAt: TimeInterval?
    public let lastFrameToPipelineMS: Double?
    public let lastPipelineToPreprocessMS: Double?
    public let lastPreprocessToOCRDoneMS: Double?
    public let lastOCRDoneToArmedMS: Double?
    public let lastFrameToArmedMS: Double?
    public let pipelineMode: String
    public let lastTextRegionCount: Int
    public let lastTextRegionCoverage: Double
    public let lastROIImageCount: Int
    public let lastROISkippedOCR: Bool
    public let lastYODORegionCount: Int
    public let lastYODOMaskCoverage: Double

    public init(
        state: GuardState,
        lastMatch: String?,
        timestamp: Date = Date(),
        monitoring: Bool = false,
        ocrFrames: Int = 0,
        lastOCRText: String = "",
        mergedText: String = "",
        ocrGuardMode: OCRGuardMode = .blacklist,
        lastDecision: DetectionDecision = DetectionDecision.notEvaluated(mode: .blacklist),
        lastOCRLatencyMS: Double? = nil,
        lastOCRAt: Date? = nil,
        overlayVisible: Bool = false,
        lastSnapshotDurationMS: Double? = nil,
        lastPreprocessDurationMS: Double? = nil,
        lastFrameReceivedAt: Date? = nil,
        lastPipelineStartedAt: Date? = nil,
        lastPreprocessDoneAt: Date? = nil,
        lastOCRStartedAt: Date? = nil,
        lastOCRDoneAt: Date? = nil,
        lastStateTransitionAt: Date? = nil,
        lastFrameToPipelineMS: Double? = nil,
        lastPipelineToPreprocessMS: Double? = nil,
        lastPreprocessToOCRDoneMS: Double? = nil,
        lastOCRDoneToArmedMS: Double? = nil,
        lastFrameToArmedMS: Double? = nil,
        pipelineMode: PipelineMode = .fullFrame,
        lastTextRegionCount: Int = 0,
        lastTextRegionCoverage: Double = 0,
        lastROIImageCount: Int = 0,
        lastROISkippedOCR: Bool = false,
        lastYODORegionCount: Int = 0,
        lastYODOMaskCoverage: Double = 0
    ) {
        self.state = state.rawValue
        self.lastMatch = lastMatch
        self.timestamp = timestamp.timeIntervalSince1970
        self.monitoring = monitoring
        self.ocrFrames = ocrFrames
        self.lastOCRText = lastOCRText
        self.mergedText = mergedText
        self.ocrGuardMode = ocrGuardMode.rawValue
        self.ocrGuardModeWarning = ocrGuardMode.warning
        self.lastDetectionReason = lastDecision.reason
        self.lastDetectionScore = lastDecision.match?.score
        self.lastDetectionMatchedText = lastDecision.match?.matched
        self.lastDetectionRuleText = lastDecision.match?.ruleText
        self.lastWhitelistText = lastDecision.whitelistMatch?.entryText
        self.lastWhitelistScore = lastDecision.whitelistMatch?.score
        self.lastOCRLatencyMS = lastOCRLatencyMS
        self.lastOCRAt = lastOCRAt?.timeIntervalSince1970
        self.overlayVisible = overlayVisible
        self.lastSnapshotDurationMS = lastSnapshotDurationMS
        self.lastPreprocessDurationMS = lastPreprocessDurationMS
        self.lastFrameReceivedAt = lastFrameReceivedAt?.timeIntervalSince1970
        self.lastPipelineStartedAt = lastPipelineStartedAt?.timeIntervalSince1970
        self.lastPreprocessDoneAt = lastPreprocessDoneAt?.timeIntervalSince1970
        self.lastOCRStartedAt = lastOCRStartedAt?.timeIntervalSince1970
        self.lastOCRDoneAt = lastOCRDoneAt?.timeIntervalSince1970
        self.lastStateTransitionAt = lastStateTransitionAt?.timeIntervalSince1970
        self.lastFrameToPipelineMS = lastFrameToPipelineMS
        self.lastPipelineToPreprocessMS = lastPipelineToPreprocessMS
        self.lastPreprocessToOCRDoneMS = lastPreprocessToOCRDoneMS
        self.lastOCRDoneToArmedMS = lastOCRDoneToArmedMS
        self.lastFrameToArmedMS = lastFrameToArmedMS
        self.pipelineMode = pipelineMode.rawValue
        self.lastTextRegionCount = lastTextRegionCount
        self.lastTextRegionCoverage = lastTextRegionCoverage
        self.lastROIImageCount = lastROIImageCount
        self.lastROISkippedOCR = lastROISkippedOCR
        self.lastYODORegionCount = lastYODORegionCount
        self.lastYODOMaskCoverage = lastYODOMaskCoverage
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
