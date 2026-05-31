import Foundation

public final class DetectionEngine: @unchecked Sendable {
    private var config: BlocklistConfig
    private var exactMatcher: AhoCorasick
    private var compactExactMatcher: AhoCorasick
    private var piiDetector: PIIDetector
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
        self.stateMachine.updateConfig(config.hysteresis)
    }

    public func analyze(text: String) -> StateTransition? {
        let normalized = TextNormalizer.normalize(text)
        let compact = TextNormalizer.compact(text)
        var matches: [MatchResult] = piiDetector.detect(in: normalized)
        if compact != normalized {
            matches.append(contentsOf: piiDetector.detect(in: compact))
        }

        let exactHits = exactMatcher.search(in: normalized)
        for hit in exactHits {
            matches.append(MatchResult(kind: "phrase", matched: hit))
        }
        let compactHits = compactExactMatcher.search(in: compact)
        for hit in compactHits {
            matches.append(MatchResult(kind: "phrase", matched: hit))
        }

        for entry in config.phrases where entry.fuzzy {
            let phrase = TextNormalizer.normalize(entry.text)
            let compactPhrase = TextNormalizer.compact(entry.text)
            if FuzzyMatcher.fuzzyMatch(phrase: phrase, in: normalized) ||
                FuzzyMatcher.fuzzyMatch(phrase: compactPhrase, in: compact) {
                matches.append(MatchResult(kind: "phrase-fuzzy", matched: entry.text))
            }
        }

        let hasMatch = !matches.isEmpty
        let bestMatch = matches.first?.matched
        return stateMachine.processFrame(hasMatch: hasMatch, matchText: bestMatch)
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
