import Foundation

public enum SensitiveKind: String, CaseIterable, Codable, Sendable {
    case email = "Email"
    case phone = "Phone number"
    case creditCard = "Payment card"
    case nationalID = "Polish PESEL"
    case ipAddress = "IP address"
    case custom = "Custom phrase"
}

public struct Detection: Equatable, Sendable {
    public let range: NSRange
    public let kind: SensitiveKind

    public init(range: NSRange, kind: SensitiveKind) {
        self.range = range
        self.kind = kind
    }
}

public struct DetectionOptions: Sendable {
    public var enabledKinds: Set<SensitiveKind>
    public var customPhrases: [String]

    public init(
        enabledKinds: Set<SensitiveKind> = Set(SensitiveKind.allCases),
        customPhrases: [String] = []
    ) {
        self.enabledKinds = enabledKinds
        self.customPhrases = customPhrases
    }
}

public struct DetectionEngine: Sendable {
    private static let patterns: [(SensitiveKind, String)] = [
        (SensitiveKind.email, #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#),
        (.phone, #"(?<!\w)(?:\+?\d[\d ()-]{7,}\d)(?!\w)"#),
        (.creditCard, #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#),
        (.nationalID, #"(?<!\d)\d{11}(?!\d)"#),
        (.ipAddress, #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#)
    ]
    private static let regexes: [(SensitiveKind, NSRegularExpression)] = patterns.map { kind, pattern in
        (kind, try! NSRegularExpression(pattern: pattern))
    }

    public init() {}

    public func detect(in text: String, options: DetectionOptions) -> [Detection] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [Detection] = []

        for (kind, regex) in Self.regexes where options.enabledKinds.contains(kind) {
            for match in regex.matches(in: text, range: fullRange) {
                guard isValid(match: match, kind: kind, text: text) else { continue }
                results.append(Detection(range: match.range, kind: kind))
            }
        }

        if options.enabledKinds.contains(.custom) {
            for phrase in options.customPhrases where !phrase.isEmpty {
                var searchRange = text.startIndex..<text.endIndex
                while let found = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                    results.append(Detection(range: NSRange(found, in: text), kind: .custom))
                    searchRange = found.upperBound..<text.endIndex
                }
            }
        }

        return results
            .sorted {
                if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
                if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
                return priority($0.kind) > priority($1.kind)
            }
            .reduce(into: []) { unique, item in
                if !unique.contains(where: { NSIntersectionRange($0.range, item.range).length > 0 }) {
                    unique.append(item)
                }
            }
    }

    private func priority(_ kind: SensitiveKind) -> Int {
        switch kind {
        case .custom: return 6
        case .creditCard: return 5
        case .nationalID: return 4
        case .email: return 3
        case .ipAddress: return 2
        case .phone: return 1
        }
    }

    private func isValid(match: NSTextCheckingResult, kind: SensitiveKind, text: String) -> Bool {
        guard let range = Range(match.range, in: text) else { return false }
        let value = String(text[range])
        switch kind {
        case .creditCard:
            let digits = value.filter(\.isNumber)
            guard (13...19).contains(digits.count) else { return false }
            return luhnValid(digits)
        case .nationalID:
            return peselValid(value)
        case .ipAddress:
            let parts = value.split(separator: ".")
            return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
        default:
            return true
        }
    }

    private func luhnValid(_ digits: String) -> Bool {
        let values = digits.compactMap { $0.wholeNumberValue }
        let sum = values.reversed().enumerated().reduce(0) { total, pair in
            let value = pair.offset.isMultiple(of: 2) ? pair.element : pair.element * 2
            return total + (value > 9 ? value - 9 : value)
        }
        return sum % 10 == 0
    }

    private func peselValid(_ value: String) -> Bool {
        let digits = value.compactMap { $0.wholeNumberValue }
        guard digits.count == 11 else { return false }
        let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
        let checksum = (10 - zip(digits.prefix(10), weights).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10
        return checksum == digits[10]
    }
}
