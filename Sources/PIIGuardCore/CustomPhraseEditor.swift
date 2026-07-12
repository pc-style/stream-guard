import Foundation

public enum CustomPhraseChange: Equatable, Sendable {
    case changed([String])
    case unchanged
    case duplicate
}

public enum CustomPhraseEditor {
    public static func update(
        _ phrases: [String],
        with rawPhrase: String,
        editing index: Int?
    ) -> CustomPhraseChange {
        let phrase = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return .unchanged }

        if let index {
            guard phrases.indices.contains(index) else { return .unchanged }
            guard !phrases.indices.contains(where: { $0 != index && equivalent(phrases[$0], phrase) }) else {
                return .duplicate
            }
            guard phrases[index] != phrase else { return .unchanged }

            var updated = phrases
            updated[index] = phrase
            return .changed(updated)
        }

        guard !phrases.contains(where: { equivalent($0, phrase) }) else { return .duplicate }
        return .changed(phrases + [phrase])
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
