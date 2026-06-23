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
            } else if let match = detectSpacedEmail(in: lowered) {
                results.append(MatchResult(kind: "email", matched: match, score: 1, ruleText: "email"))
            }
        }
        if patterns.ssn || patterns.nationalIDs {
            if let match = detectSSN(in: normalized) {
                results.append(MatchResult(kind: "ssn", matched: match, score: 1, ruleText: "ssn"))
            }
        }
        if patterns.secrets {
            results.append(contentsOf: detectSecrets(in: text))
        }
        if patterns.cards, let match = detectCard(in: normalized) {
            results.append(MatchResult(kind: "card", matched: match, score: 1, ruleText: "payment card"))
        }
        return deduplicated(results)
    }

    private func detectSecrets(in text: String) -> [MatchResult] {
        let patterns: [(String, String, String)] = [
            ("github-token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b"#, "GitHub token"),
            ("github-fine-grained-token", #"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#, "GitHub fine-grained token"),
            ("openai-token", #"\bsk-[A-Za-z0-9_-]{20,}\b"#, "OpenAI/API key token"),
            ("aws-access-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, "AWS access key id"),
            ("slack-token", #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "Slack token"),
            ("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "JWT"),
            ("private-key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "private key header"),
            ("api-key-like", #"(?i)\b(?:api[_-]?key|secret|token)\s*[:=]\s*[A-Za-z0-9_./+\-=]{16,}\b"#, "API key-like secret"),
        ]
        var results: [MatchResult] = []
        for (kind, pattern, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                results.append(MatchResult(kind: kind, matched: String(text[swiftRange]), score: 1, ruleText: label))
            }
        }
        return results
    }

    private func detectCard(in text: String) -> String? {
        let pattern = #"\b(?:\d[ -]*?){13,19}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let candidate = String(text[swiftRange])
            let digits = candidate.filter(\.isNumber)
            guard digits.count >= 13, digits.count <= 19, luhn(digits) else { continue }
            return candidate
        }
        return nil
    }

    private func luhn(_ digits: String) -> Bool {
        var sum = 0
        let reversed = digits.reversed().map { Int(String($0)) ?? 0 }
        for (index, digit) in reversed.enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum > 0 && sum % 10 == 0
    }

    private func deduplicated(_ matches: [MatchResult]) -> [MatchResult] {
        var seen = Set<String>()
        var output: [MatchResult] = []
        for match in matches {
            let key = "\(match.kind):\(match.matched)"
            if seen.insert(key).inserted { output.append(match) }
        }
        return output
    }

    private func detectPhone(in text: String) -> String? {
        let patterns = [
            #"(?:\+?1[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)\d{3}[\s.-]?\d{4}"#,
            #"(?:\+?1[\s.·•-]?)?(?:\(?\d{3}\)?[\s.·•-]?)\d{3}[\s.·•-]?\d{4}"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let swiftRange = Range(match.range, in: text) else { continue }
            let candidate = String(text[swiftRange])
            let digits = candidate.filter(\.isNumber)
            guard digits.count >= 10 else { continue }
            guard looksLikePhone(candidate: candidate, in: text, at: swiftRange) else { continue }
            return candidate
        }

        return nil
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

    private func detectSpacedEmail(in text: String) -> String? {
        let pattern = #"(?<![a-z0-9._%+-])[a-z0-9._%+-]+\s*@\s*[a-z0-9-]+(?:\s*\.\s*[a-z]{2,})(?!\s*\.\s*[a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }

        let candidate = String(text[swiftRange])
        guard candidate.contains(where: \.isWhitespace) else { return nil }
        let normalizedCandidate = candidate.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return detectEmail(in: normalizedCandidate)
    }

    private func detectSSN(in text: String) -> String? {
        let pattern = #"\b\d{3}[\s-]?\d{2}[\s-]?\d{4}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let candidate = String(text[swiftRange])
            if isValidSSN(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isValidSSN(_ candidate: String) -> Bool {
        let digits = candidate.filter(\.isNumber)
        guard digits.count == 9 else { return false }

        let area = Int(digits.prefix(3)) ?? 0
        let groupStart = digits.index(digits.startIndex, offsetBy: 3)
        let groupEnd = digits.index(groupStart, offsetBy: 2)
        let group = Int(digits[groupStart..<groupEnd]) ?? 0
        let serial = Int(digits.suffix(4)) ?? 0

        guard area != 0, area != 666, area < 900 else { return false }
        guard group != 0 else { return false }
        guard serial != 0 else { return false }
        return true
    }
}
