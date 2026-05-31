import Foundation

public final class AhoCorasick {
    private final class Node {
        var children: [Character: Node] = [:]
        var fail: Node?
        var outputs: [String] = []
    }

    private let root = Node()

    public init(phrases: [String]) {
        for phrase in phrases where !phrase.isEmpty {
            insert(phrase)
        }
        buildFailureLinks()
    }

    public func search(in text: String) -> [String] {
        var matches: [String] = []
        var node = root
        for ch in text {
            while node !== root && node.children[ch] == nil {
                node = node.fail ?? root
            }
            if let next = node.children[ch] {
                node = next
            }
            for output in node.outputs where !matches.contains(output) {
                matches.append(output)
            }
        }
        return matches
    }

    private func insert(_ phrase: String) {
        var node = root
        for ch in phrase {
            if node.children[ch] == nil {
                node.children[ch] = Node()
            }
            node = node.children[ch]!
        }
        node.outputs.append(phrase)
    }

    private func buildFailureLinks() {
        var queue: [Node] = []
        for child in root.children.values {
            child.fail = root
            queue.append(child)
        }
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for (ch, child) in current.children {
                queue.append(child)
                var fail = current.fail
                while fail != nil && fail?.children[ch] == nil {
                    fail = fail?.fail
                }
                child.fail = fail?.children[ch] ?? root
                child.outputs.append(contentsOf: child.fail?.outputs ?? [])
            }
        }
    }
}
