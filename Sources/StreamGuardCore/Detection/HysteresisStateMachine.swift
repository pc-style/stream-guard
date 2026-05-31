import Foundation

public final class HysteresisStateMachine: @unchecked Sendable {
    public private(set) var state: GuardState = .clear
    public private(set) var lastMatch: String?

    private var consecutiveMatchFrames = 0
    private var consecutiveClearFrames = 0
    private var config: HysteresisConfig

    public init(config: HysteresisConfig) {
        self.config = config
    }

    public func updateConfig(_ config: HysteresisConfig) {
        self.config = config
    }

    @discardableResult
    public func processFrame(hasMatch: Bool, matchText: String?) -> StateTransition? {
        var transition: StateTransition?
        let previous = state

        if hasMatch {
            consecutiveClearFrames = 0
            consecutiveMatchFrames += 1
            if let matchText {
                lastMatch = matchText
            }

            switch state {
            case .clear:
                state = .suspect
            case .suspect:
                break
            case .armed:
                break
            }
            if consecutiveMatchFrames >= config.triggerFrames {
                state = .armed
            }
        } else {
            consecutiveMatchFrames = 0
            consecutiveClearFrames += 1

            switch state {
            case .armed, .suspect:
                if consecutiveClearFrames >= config.clearFrames {
                    state = .clear
                    lastMatch = nil
                } else if state == .armed {
                    state = .suspect
                }
            case .clear:
                break
            }
        }

        if previous != state {
            transition = StateTransition(previous: previous, current: state, lastMatch: lastMatch)
        }
        return transition
    }

    public func reset() {
        state = .clear
        lastMatch = nil
        consecutiveMatchFrames = 0
        consecutiveClearFrames = 0
    }
}
