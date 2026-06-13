import Foundation

public enum TextNormalizer {
    private static let homoglyphs: [Character: Character] = [
        "0": "0", "O": "0", "o": "0",
        "1": "1", "l": "1", "I": "1", "|": "1",
    ]

    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var mapped = String()
        mapped.reserveCapacity(lowered.count)
        for ch in lowered {
            if let replacement = homoglyphs[ch] {
                mapped.append(replacement)
            } else {
                mapped.append(ch)
            }
        }
        let collapsed = mapped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    public static func compact(_ text: String) -> String {
        normalize(text).replacingOccurrences(of: " ", with: "")
    }
}

public struct MatchResult: Sendable, Equatable {
    public let kind: String
    public let matched: String
    public let score: Double?
    public let ruleText: String?

    public init(kind: String, matched: String, score: Double? = nil, ruleText: String? = nil) {
        self.kind = kind
        self.matched = matched
        self.score = score
        self.ruleText = ruleText
    }
}

public struct PIIDetector: Sendable {
    public let patterns: PatternConfig

    public init(patterns: PatternConfig) {
        self.patterns = patterns
    }

    public func detect(in text: String) -> [MatchResult] {
        var results: [MatchResult] = []
        let normalized = TextNormalizer.normalize(text)
        let lowered = text.lowercased()

        if patterns.phone {
            if let match = detectPhone(in: normalized) {
                results.append(MatchResult(kind: "phone", matched: match, score: 1, ruleText: "phone"))
            } else if let match = detectPhoneWithGaps(in: TextNormalizer.compact(text)) {
                results.append(MatchResult(kind: "phone", matched: match, score: 1, ruleText: "phone"))
            }
        }
        if patterns.email {
            if let match = detectEmail(in: lowered) {
                results.append(MatchResult(kind: "email", matched: match, score: 1, ruleText: "email"))
            }
        }
        if patterns.ssn {
            if let match = detectSSN(in: normalized) {
                results.append(MatchResult(kind: "ssn", matched: match, score: 1, ruleText: "ssn"))
            }
        }
        return results
    }

    private func detectPhone(in text: String) -> String? {
        let pattern = #"(?:\+?1[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)\d{3}[\s.-]?\d{4}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        let candidate = String(text[swiftRange])
        let digits = candidate.filter(\.isNumber)
        guard digits.count >= 10 else { return nil }
        guard looksLikePhone(candidate: candidate, in: text, at: swiftRange) else { return nil }
        return candidate
    }

    /// Matches phones split by short non-digit runs, e.g. `555` + `then` + `123-4567` on one screen.
    private func detectPhoneWithGaps(in compact: String) -> String? {
        // Require a real separator between area code and prefix (not bare 10 digits).
        let pattern = #"\d{3}[^\d]{1,8}\d{3}[^\d]{0,8}\d{4}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(compact.startIndex..<compact.endIndex, in: compact)
        guard let match = regex.firstMatch(in: compact, range: range),
              let swiftRange = Range(match.range, in: compact) else { return nil }
        let candidate = String(compact[swiftRange])
        let digits = candidate.filter(\.isNumber)
        guard digits.count == 10 || (digits.count == 11 && digits.first == "1") else { return nil }
        return candidate
    }

    private func looksLikePhone(candidate: String, in text: String, at range: Range<String.Index>) -> Bool {
        let hasPhoneFormatting = candidate.contains { "+().- ".contains($0) }
        if hasPhoneFormatting {
            return true
        }

        let contextStart = text.index(range.lowerBound, offsetBy: -16, limitedBy: text.startIndex) ?? text.startIndex
        let contextEnd = text.index(range.upperBound, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
        let context = String(text[contextStart..<contextEnd]).lowercased()
        return context.contains("phone") ||
            context.contains("tel") ||
            context.contains("call") ||
            context.contains("sms")
    }

    private func detectEmail(in text: String) -> String? {
        let pattern = #"[a-z0-9._%+-]+@[a-z0-9-]+\.[a-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func detectSSN(in text: String) -> String? {
        let pattern = #"\b\d{3}[\s-]?\d{2}[\s-]?\d{4}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
