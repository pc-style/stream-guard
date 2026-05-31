import Foundation
import StreamGuardCore

@main
struct StreamGuardTestRunner {
    static func main() {
        var failures = 0

        func section(_ title: String) {
            print("\n=== \(title) ===")
        }

        func show(_ label: String, _ value: String) {
            print("  \(label): \(value)")
        }

        func pause() {
            Thread.sleep(forTimeInterval: 0.18)
        }

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                print("  PASS: \(message)")
            } else {
                print("  FAIL: \(message)")
                failures += 1
            }
            pause()
        }

        print("Stream Guard visible test runner")
        print("No XCTest. No Xcode.app. This is a plain Swift executable.")

        section("PII detection")
        let phoneDetector = PIIDetector(patterns: PatternConfig())
        let phoneInput = "call me at (555) 123-4567 tonight"
        show("input", phoneInput)
        let phoneMatches = phoneDetector.detect(in: phoneInput)
        show("matches", phoneMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(phoneMatches.contains { $0.kind == "phone" }, "detects US phone")

        let noisyDigitsInput = "ocr garbage 1234567151 beside status text"
        show("input", noisyDigitsInput)
        let noisyDigitMatches = phoneDetector.detect(in: noisyDigitsInput)
        show("matches", noisyDigitMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(!noisyDigitMatches.contains { $0.kind == "phone" }, "rejects unformatted OCR digit noise")

        let gappedInput = "phone: 555 then 123-4567"
        show("input", gappedInput)
        let gappedMatches = phoneDetector.detect(in: gappedInput)
        show("matches", gappedMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(gappedMatches.contains { $0.kind == "phone" }, "detects gapped split phone on one screen")

        let emailInput = "email leak@test.com here"
        show("input", emailInput)
        let emailMatches = phoneDetector.detect(in: emailInput)
        show("matches", emailMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(emailMatches.contains { $0.kind == "email" }, "detects email")

        section("Pattern toggles")
        let disabledPhone = PIIDetector(patterns: PatternConfig(phone: false, email: true, ssn: false))
        let disabledInput = "555-123-4567 leak@test.com"
        show("input", disabledInput)
        let disabledMatches = disabledPhone.detect(in: disabledInput)
        show("matches", disabledMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(!disabledMatches.contains { $0.kind == "phone" }, "phone disabled")
        expect(disabledMatches.contains { $0.kind == "email" }, "email still enabled")

        section("Phrase matching")
        let ac = AhoCorasick(phrases: ["exact-ban", "other"])
        let exactInput = "this has exact-ban in it"
        show("input", exactInput)
        show("hits", ac.search(in: exactInput).joined(separator: ", "))
        expect(ac.search(in: exactInput).contains("exact-ban"), "aho-corasick exact phrase")

        section("Fuzzy and word-boundary matching")
        show("fuzzy phrase", "example-banned-term")
        show("ocr text", "example-bannned-term")
        expect(FuzzyMatcher.fuzzyMatch(phrase: "example-banned-term", in: "example-bannned-term"), "fuzzy typo match")
        show("boundary input", "that is bad news")
        expect(FuzzyMatcher.hasWordBoundaryMatch(needle: "bad", in: "that is bad news"), "word boundary match")
        show("substring input", "badge")
        expect(!FuzzyMatcher.hasWordBoundaryMatch(needle: "bad", in: "badge"), "word boundary rejects substring")

        section("Hysteresis: CLEAR -> SUSPECT -> ARMED")
        let hysteresis = HysteresisStateMachine(config: HysteresisConfig(triggerFrames: 2, clearFrames: 3))
        show("frame 0", "state=\(hysteresis.state.rawValue)")
        expect(hysteresis.state == .clear, "starts clear")
        _ = hysteresis.processFrame(hasMatch: true, matchText: "555-123-4567")
        show("frame 1", "match=true state=\(hysteresis.state.rawValue)")
        expect(hysteresis.state == .suspect, "first match -> suspect")
        let armedTransition = hysteresis.processFrame(hasMatch: true, matchText: "555-123-4567")
        show("frame 2", "match=true state=\(hysteresis.state.rawValue)")
        expect(hysteresis.state == .armed, "second match -> armed")
        expect(armedTransition?.current == .armed, "armed transition emitted")

        section("Hysteresis clear")
        let clearMachine = HysteresisStateMachine(config: HysteresisConfig(triggerFrames: 1, clearFrames: 3))
        _ = clearMachine.processFrame(hasMatch: true, matchText: "secret")
        show("frame 1", "match=true state=\(clearMachine.state.rawValue)")
        _ = clearMachine.processFrame(hasMatch: false, matchText: nil)
        show("frame 2", "match=false state=\(clearMachine.state.rawValue)")
        _ = clearMachine.processFrame(hasMatch: false, matchText: nil)
        show("frame 3", "match=false state=\(clearMachine.state.rawValue)")
        let clearTransition = clearMachine.processFrame(hasMatch: false, matchText: nil)
        show("frame 4", "match=false state=\(clearMachine.state.rawValue)")
        expect(clearMachine.state == .clear, "clears after clearFrames")
        expect(clearTransition?.current == .clear, "clear transition emitted")

        section("Detection engine: blocklist")
        var config = BlocklistConfig.default
        config.patterns = PatternConfig(phone: false, email: false, ssn: false)
        config.phrases = [PhraseEntry(text: "exact-ban", fuzzy: false)]
        config.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        let engine = DetectionEngine(config: config)
        let blocklistInput = "stream says exact-ban now"
        show("input", blocklistInput)
        let engineTransition = engine.analyze(text: blocklistInput)
        show("state", engine.stateMachine.state.rawValue)
        expect(engine.stateMachine.state == .armed, "engine arms on blocklist")
        expect(engineTransition?.current == .armed, "engine transition")

        section("Detection engine: multi-word phrase")
        var multiWordConfig = BlocklistConfig.default
        multiWordConfig.patterns = PatternConfig(phone: false, email: false, ssn: false)
        multiWordConfig.phrases = [PhraseEntry(text: "bad phrase", fuzzy: false)]
        multiWordConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        let multiWordEngine = DetectionEngine(config: multiWordConfig)
        let multiWordInput = "stream says bad phrase now"
        show("input", multiWordInput)
        let multiWordTransition = multiWordEngine.analyze(text: multiWordInput)
        show("state", multiWordEngine.stateMachine.state.rawValue)
        expect(multiWordEngine.stateMachine.state == .armed, "engine arms on multi-word blocklist phrase")
        expect(multiWordTransition?.current == .armed, "multi-word phrase transition")

        section("Text merge buffer")
        let buffer = TextMergeBuffer(windowSeconds: 5)
        buffer.append("555")
        buffer.append("1234567")
        show("frame text", "\"555\" + \"1234567\"")
        show("compact", buffer.compactMergedText())
        expect(buffer.compactMergedText().contains("5551234567"), "text merge buffer")

        section("OCR crop downscale policy")
        expect(OCRImagePolicy.adaptiveCropDownscaleFactor(cropWidth: 640, cropHeight: 180) == 1, "terminal-sized crop stays 1x")
        expect(OCRImagePolicy.adaptiveCropDownscaleFactor(cropWidth: 1200, cropHeight: 400) == 2, "large crop downscales 2x")

        section("Detection engine: wouldTrigger")
        var peekConfig = BlocklistConfig.default
        peekConfig.hysteresis = HysteresisConfig(triggerFrames: 2, clearFrames: 2)
        let peekEngine = DetectionEngine(config: peekConfig)
        expect(peekEngine.wouldTrigger(text: "(555) 123-4567"), "wouldTrigger sees phone")
        expect(!peekEngine.wouldTrigger(text: "no sensitive data"), "wouldTrigger negative")
        expect(peekEngine.stateMachine.state == .clear, "wouldTrigger does not advance hysteresis")
        _ = peekEngine.analyze(text: "(555) 123-4567")
        expect(peekEngine.stateMachine.state == .suspect, "analyze advances hysteresis")

        section("Split-frame phone detection")
        var phoneConfig = BlocklistConfig.default
        phoneConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        let phoneEngine = DetectionEngine(config: phoneConfig)
        let splitBuffer = TextMergeBuffer(windowSeconds: 5)
        splitBuffer.append("555")
        splitBuffer.append("123-4567")
        show("frame text", "\"555\" + \"123-4567\"")
        show("compact", splitBuffer.compactMergedText())
        let splitTransition = phoneEngine.analyze(text: splitBuffer.compactMergedText())
        show("state", phoneEngine.stateMachine.state.rawValue)
        expect(phoneEngine.stateMachine.state == .armed, "split-frame phone via compact merge")
        expect(splitTransition?.current == .armed, "split-frame phone transition")

        section("Config hot reload")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamGuardTestRunner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configURL = tempDir.appendingPathComponent("blocklist.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let initialData = try? encoder.encode(BlocklistConfig.default) {
            try? initialData.write(to: configURL)
        }
        let watcher = ConfigWatcher(url: configURL)
        let reloadSemaphore = DispatchSemaphore(value: 0)
        watcher.onReload = { config in
            if config.phrases.contains(where: { $0.text == "atomic replace" }) {
                print("  reload observed: atomic replace")
                reloadSemaphore.signal()
            }
        }
        watcher.start()
        var replacement = BlocklistConfig.default
        replacement.phrases = [PhraseEntry(text: "atomic replace", fuzzy: false)]
        if let replacementData = try? encoder.encode(replacement) {
            let replacementURL = tempDir.appendingPathComponent("blocklist.tmp")
            try? replacementData.write(to: replacementURL)
            _ = try? FileManager.default.replaceItemAt(configURL, withItemAt: replacementURL)
        }
        let reloadResult = reloadSemaphore.wait(timeout: .now() + 3)
        watcher.stop()
        try? FileManager.default.removeItem(at: tempDir)
        expect(reloadResult == .success, "config watcher reloads after atomic replacement")

        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
