import Foundation

public enum FuzzyMatcher {
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

    public static func hasWordBoundaryMatch(needle: String, in haystack: String) -> Bool {
        guard needle.count >= 2 else { return false }
        let pattern = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: needle) + #"(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }
}
