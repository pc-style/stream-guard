import Foundation

public struct WhitelistDecision: Sendable, Equatable {
    public let entryText: String
    public let matchedText: String
    public let score: Double

    public init(entryText: String, matchedText: String, score: Double) {
        self.entryText = entryText
        self.matchedText = matchedText
        self.score = score
    }
}

public struct DetectionDecision: Sendable, Equatable {
    public let mode: OCRGuardMode
    public let shouldTrigger: Bool
    public let match: MatchResult?
    public let whitelistMatch: WhitelistDecision?
    public let reason: String

    public init(
        mode: OCRGuardMode,
        shouldTrigger: Bool,
        match: MatchResult?,
        whitelistMatch: WhitelistDecision?,
        reason: String
    ) {
        self.mode = mode
        self.shouldTrigger = shouldTrigger
        self.match = match
        self.whitelistMatch = whitelistMatch
        self.reason = reason
    }

    public static func notEvaluated(mode: OCRGuardMode) -> DetectionDecision {
        DetectionDecision(
            mode: mode,
            shouldTrigger: false,
            match: nil,
            whitelistMatch: nil,
            reason: "No OCR decision yet"
        )
    }
}

public final class DetectionEngine: @unchecked Sendable {
    private var config: BlocklistConfig
    private var exactMatcher: AhoCorasick
    private var compactExactMatcher: AhoCorasick
    private var piiDetector: PIIDetector
    public private(set) var lastDecision: DetectionDecision
    public let stateMachine: HysteresisStateMachine

    public init(config: BlocklistConfig) {
        self.config = config
        let exactPhrases = config.phrases
            .filter { !$0.fuzzy }
            .map { TextNormalizer.normalize($0.text) }
        let compactExactPhrases = config.phrases
            .filter { !$0.fuzzy }
            .map { TextNormalizer.compact($0.text) }
        self.exactMatcher = AhoCorasick(phrases: exactPhrases)
        self.compactExactMatcher = AhoCorasick(phrases: compactExactPhrases)
        self.piiDetector = PIIDetector(patterns: config.patterns)
        self.lastDecision = .notEvaluated(mode: config.filtering.mode)
        self.stateMachine = HysteresisStateMachine(config: config.hysteresis)
    }

    public func updateConfig(_ config: BlocklistConfig) {
        self.config = config
        let exactPhrases = config.phrases
            .filter { !$0.fuzzy }
            .map { TextNormalizer.normalize($0.text) }
        let compactExactPhrases = config.phrases
            .filter { !$0.fuzzy }
            .map { TextNormalizer.compact($0.text) }
        self.exactMatcher = AhoCorasick(phrases: exactPhrases)
        self.compactExactMatcher = AhoCorasick(phrases: compactExactPhrases)
        self.piiDetector = PIIDetector(patterns: config.patterns)
        self.lastDecision = .notEvaluated(mode: config.filtering.mode)
        self.stateMachine.updateConfig(config.hysteresis)
    }

    public func wouldTrigger(text: String) -> Bool {
        evaluate(text: text).shouldTrigger
    }

    public func analyze(text: String) -> StateTransition? {
        let decision = evaluate(text: text)
        lastDecision = decision
        return stateMachine.processFrame(hasMatch: decision.shouldTrigger, matchText: decision.match?.matched)
    }

    public func resetDecision() {
        lastDecision = .notEvaluated(mode: config.filtering.mode)
    }

    private func evaluate(text: String) -> DetectionDecision {
        let mode = config.filtering.mode
        switch mode {
        case .blurAll:
            return evaluateBlurAll(text: text)
        case .whitelist:
            return evaluateListBackedMode(text: text, includeCustomBlacklist: false)
        case .blacklist:
            return evaluateListBackedMode(text: text, includeCustomBlacklist: true)
        }
    }

    private func evaluateBlurAll(text: String) -> DetectionDecision {
        let trimmed = TextNormalizer.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first { $0.count >= config.filtering.blurAllMinimumCharacters }

        guard let token else {
            return DetectionDecision(
                mode: .blurAll,
                shouldTrigger: false,
                match: nil,
                whitelistMatch: nil,
                reason: "Blur-all saw no OCR token long enough to block"
            )
        }

        let match = MatchResult(
            kind: "blur-all-buggy",
            matched: String(token),
            score: 1,
            ruleText: "any OCR text"
        )
        return DetectionDecision(
            mode: .blurAll,
            shouldTrigger: true,
            match: match,
            whitelistMatch: nil,
            reason: "Buggy blur-all mode blocks any detected OCR text"
        )
    }

    private func evaluateListBackedMode(text: String, includeCustomBlacklist: Bool) -> DetectionDecision {
        let matches = findMatches(in: text, includeCustomBlacklist: includeCustomBlacklist)
        guard !matches.isEmpty else {
            return DetectionDecision(
                mode: config.filtering.mode,
                shouldTrigger: false,
                match: nil,
                whitelistMatch: nil,
                reason: includeCustomBlacklist
                    ? "No PII, phrase, or blacklist match"
                    : "No PII or legacy phrase match"
            )
        }

        let unsuppressed = matches.filter { whitelistSuppression(for: $0) == nil }
        if let match = bestMatch(from: unsuppressed) {
            return DetectionDecision(
                mode: config.filtering.mode,
                shouldTrigger: true,
                match: match,
                whitelistMatch: nil,
                reason: includeCustomBlacklist
                    ? "Blocked by blacklist or built-in detector"
                    : "Blocked by built-in detector"
            )
        }

        let bestSuppression = matches
            .compactMap { whitelistSuppression(for: $0) }
            .max { $0.score < $1.score }
        return DetectionDecision(
            mode: config.filtering.mode,
            shouldTrigger: false,
            match: bestMatch(from: matches),
            whitelistMatch: bestSuppression,
            reason: "Suppressed by whitelist similarity threshold"
        )
    }

    private func findMatches(in text: String, includeCustomBlacklist: Bool) -> [MatchResult] {
        let normalized = TextNormalizer.normalize(text)
        let compact = TextNormalizer.compact(text)
        var matches: [MatchResult] = piiDetector.detect(in: text)
        if normalized != text {
            matches.append(contentsOf: piiDetector.detect(in: normalized))
        }
        if compact != normalized {
            matches.append(contentsOf: piiDetector.detect(in: compact))
        }

        let exactHits = exactMatcher.search(in: normalized)
        for hit in exactHits {
            matches.append(MatchResult(kind: "phrase", matched: hit, score: 1, ruleText: hit))
        }
        let compactHits = compactExactMatcher.search(in: compact)
        for hit in compactHits {
            matches.append(MatchResult(kind: "phrase", matched: hit, score: 1, ruleText: hit))
        }

        for entry in config.phrases where entry.fuzzy {
            if let result = FuzzyMatcher.bestMatch(phrase: entry.text, in: normalized),
               result.score >= 0.82 {
                matches.append(MatchResult(
                    kind: "phrase-fuzzy",
                    matched: result.candidate,
                    score: result.score,
                    ruleText: entry.text
                ))
            } else {
                let phrase = TextNormalizer.normalize(entry.text)
                let compactPhrase = TextNormalizer.compact(entry.text)
                if FuzzyMatcher.fuzzyMatch(phrase: phrase, in: normalized) ||
                    FuzzyMatcher.fuzzyMatch(phrase: compactPhrase, in: compact) {
                    matches.append(MatchResult(
                        kind: "phrase-fuzzy",
                        matched: entry.text,
                        score: nil,
                        ruleText: entry.text
                    ))
                }
            }
        }

        if includeCustomBlacklist {
            for entry in config.filtering.blacklist {
                if let match = listMatch(entry: entry, text: text, kind: "blacklist") {
                    matches.append(match)
                }
            }
        }

        return matches
    }

    private func listMatch(entry: OCRListEntry, text: String, kind: String) -> MatchResult? {
        guard let result = FuzzyMatcher.bestMatch(phrase: entry.text, in: text) else { return nil }
        let threshold = entry.fuzzy ? entry.minimumSimilarity : 1
        guard result.score >= threshold else { return nil }
        return MatchResult(
            kind: entry.fuzzy ? "\(kind)-fuzzy" : kind,
            matched: result.candidate,
            score: result.score,
            ruleText: entry.text
        )
    }

    private func whitelistSuppression(for match: MatchResult) -> WhitelistDecision? {
        var best: WhitelistDecision?
        for entry in config.filtering.whitelist {
            let candidates = whitelistCandidates(for: match)
            for candidate in candidates {
                let result = FuzzyMatcher.similarity(phrase: entry.text, candidate: candidate)
                let threshold = entry.fuzzy ? entry.minimumSimilarity : 1
                guard result.score >= threshold else { continue }
                let decision = WhitelistDecision(
                    entryText: entry.text,
                    matchedText: candidate,
                    score: result.score
                )
                if best == nil || decision.score > best!.score {
                    best = decision
                }
            }
        }
        return best
    }

    private func whitelistCandidates(for match: MatchResult) -> [String] {
        var values = [match.matched]
        if let ruleText = match.ruleText, ruleText != match.matched {
            values.append(ruleText)
        }
        return Array(Set(values.filter { !$0.isEmpty }))
    }

    private func bestMatch(from matches: [MatchResult]) -> MatchResult? {
        matches.max { lhs, rhs in
            (lhs.score ?? 1) < (rhs.score ?? 1)
        }
    }
}

public final class TextMergeBuffer: @unchecked Sendable {
    private struct Entry {
        let text: String
        let timestamp: Date
    }

    private var entries: [Entry] = []
    private let windowSeconds: TimeInterval

    public init(windowSeconds: TimeInterval = 2.5) {
        self.windowSeconds = windowSeconds
    }

    public func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        entries.append(Entry(text: trimmed, timestamp: now))
        prune(now: now)
    }

    public func mergedText() -> String {
        prune(now: Date())
        return entries.map(\.text).joined(separator: " ")
    }

    public func compactMergedText() -> String {
        TextNormalizer.compact(mergedText())
    }

    public func clear() {
        entries.removeAll()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        entries.removeAll { $0.timestamp < cutoff }
    }
}
