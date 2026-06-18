import Foundation

public struct FuzzyMatchResult: Sendable, Equatable {
    public let candidate: String
    public let score: Double
    public let distance: Int

    public init(candidate: String, score: Double, distance: Int) {
        self.candidate = candidate
        self.score = score
        self.distance = distance
    }
}

public enum FuzzyMatcher {
    private static let maxSlidingWindowCharacters = 4096
    private static let maxNeedleCharacters = 96

    public static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    public static func fuzzyMatch(phrase: String, in text: String, maxDistance: Int = 2) -> Bool {
        let needle = phrase.lowercased()
        guard needle.count >= 4 else {
            return hasWordBoundaryMatch(needle: needle, in: text.lowercased())
        }

        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for word in words {
            if levenshtein(String(word), needle) <= maxDistance {
                return true
            }
        }

        let compactText = TextNormalizer.compact(text)
        let compactNeedle = TextNormalizer.compact(needle)
        if compactNeedle.count >= 4 && compactText.contains(compactNeedle) {
            return true
        }

        if compactText.count >= compactNeedle.count {
            let chars = Array(compactText)
            for start in 0...(chars.count - compactNeedle.count) {
                let slice = String(chars[start..<(start + compactNeedle.count)])
                if levenshtein(slice, compactNeedle) <= maxDistance {
                    return true
                }
            }
        }
        return false
    }

    public static func bestMatch(phrase: String, in text: String) -> FuzzyMatchResult? {
        let normalizedNeedle = TextNormalizer.normalize(phrase)
        let compactNeedle = TextNormalizer.compact(phrase)
        guard !normalizedNeedle.isEmpty || !compactNeedle.isEmpty else { return nil }

        let normalizedText = TextNormalizer.normalize(text)
        let compactText = TextNormalizer.compact(text)
        var best: FuzzyMatchResult?

        func consider(_ rawCandidate: String) {
            let normalizedCandidate = TextNormalizer.normalize(rawCandidate)
            guard !normalizedCandidate.isEmpty else { return }
            let result = compare(needle: normalizedNeedle, candidate: normalizedCandidate)
            if best == nil || result.score > best!.score ||
                (result.score == best!.score && result.distance < best!.distance) {
                best = result
            }
        }

        if normalizedText.contains(normalizedNeedle) {
            return FuzzyMatchResult(candidate: normalizedNeedle, score: 1, distance: 0)
        }
        if compactNeedle.count >= 2, compactText.contains(compactNeedle) {
            return FuzzyMatchResult(candidate: compactNeedle, score: 1, distance: 0)
        }

        for candidate in candidates(from: normalizedText, phrase: normalizedNeedle) {
            consider(candidate)
        }

        if compactNeedle.count >= 2,
           compactNeedle.count <= maxNeedleCharacters,
           compactText.count <= maxSlidingWindowCharacters,
           compactText.count >= compactNeedle.count {
            let chars = Array(compactText)
            let needleLength = compactNeedle.count
            for length in candidateLengths(around: needleLength, maxLength: chars.count) {
                guard length > 0, chars.count >= length else { continue }
                for start in 0...(chars.count - length) {
                    let compactCandidate = String(chars[start..<(start + length)])
                    let result = compare(needle: compactNeedle, candidate: compactCandidate)
                    if best == nil || result.score > best!.score ||
                        (result.score == best!.score && result.distance < best!.distance) {
                        best = result
                    }
                }
            }
        }

        return best
    }

    public static func similarity(phrase: String, candidate: String) -> FuzzyMatchResult {
        compare(
            needle: TextNormalizer.normalize(phrase),
            candidate: TextNormalizer.normalize(candidate)
        )
    }

    public static func hasWordBoundaryMatch(needle: String, in haystack: String) -> Bool {
        guard needle.count >= 2 else { return false }
        let pattern = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: needle) + #"(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    private static func compare(needle: String, candidate: String) -> FuzzyMatchResult {
        if needle == candidate {
            return FuzzyMatchResult(candidate: candidate, score: 1, distance: 0)
        }
        let distance = levenshtein(candidate, needle)
        let denominator = max(needle.count, candidate.count, 1)
        let score = max(0, 1 - (Double(distance) / Double(denominator)))
        return FuzzyMatchResult(candidate: candidate, score: score, distance: distance)
    }

    private static func candidates(from text: String, phrase: String) -> [String] {
        var results: [String] = []
        results.append(contentsOf: emailCandidates(in: text))

        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let phraseWordCount = max(
            1,
            phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        let windowSizes = candidateLengths(around: phraseWordCount, maxLength: words.count)
        for size in windowSizes {
            guard size > 0, words.count >= size else { continue }
            for start in 0...(words.count - size) {
                results.append(words[start..<(start + size)].joined(separator: " "))
            }
        }

        return Array(Set(results))
    }

    private static func emailCandidates(in text: String) -> [String] {
        let pattern = #"[a-z0-9._%+-]+@[a-z0-9.-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func candidateLengths(around length: Int, maxLength: Int) -> [Int] {
        guard maxLength > 0 else { return [] }
        let lower = max(1, length - 1)
        let upper = min(maxLength, length + 1)
        return Array(lower...upper)
    }
}
