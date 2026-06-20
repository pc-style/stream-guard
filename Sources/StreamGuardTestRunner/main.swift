import Foundation
import Network
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
        expect(emailMatches.contains { $0.kind == "email" && $0.matched == "leak@test.com" }, "detects exact email")

        let spacedEmailCases = [
            ("email leak @ test.com here", "leak@test.com"),
            ("email leak@test . com here", "leak@test.com"),
            ("email leak @ test . com here", "leak@test.com"),
            ("email leak @ test.technology here", "leak@test.technology"),
        ]
        for (spacedEmailInput, expectedMatch) in spacedEmailCases {
            show("input", spacedEmailInput)
            let spacedEmailMatches = phoneDetector.detect(in: spacedEmailInput)
            show("matches", spacedEmailMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
            expect(spacedEmailMatches.contains { $0.kind == "email" && $0.matched == expectedMatch }, "detects exact OCR-spaced email punctuation")
        }

        let secretInputs = [
            "token " + "ghp" + "_abcdefghijklmnopqrstuvwxyz123456",
            "openai " + "sk" + "-abcdefghijklmnopqrstuvwxyz123456",
            "aws " + "AKIA" + "IOSFODNN7EXAMPLE",
            "slack " + "xoxb" + "-123456789012-abcdefghijklmnop",
            "jwt " + "eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.signatureABC123",
            "-----BEGIN PRIVATE KEY-----",
            "api_key = abcdefghijklmnopqrstuvwxyz123456",
        ]
        for secretInput in secretInputs {
            show("secret input", secretInput)
            let secretMatches = phoneDetector.detect(in: secretInput)
            show("matches", secretMatches.map { "\($0.kind)=\($0.ruleText ?? $0.matched)" }.joined(separator: ", "))
            expect(secretMatches.contains { $0.kind.contains("token") || $0.kind.contains("key") || $0.kind == "jwt" || $0.kind == "private-key" }, "detects common developer secret")
        }

        let multipleGitHubSecrets = "tokens " + "ghp" + "_abcdefghijklmnopqrstuvwxyz123456 and " + "ghp" + "_123456abcdefghijklmnopqrstuvwxyz"
        let multipleGitHubMatches = phoneDetector.detect(in: multipleGitHubSecrets).filter { $0.kind == "github-token" }
        show("multiple same-kind secrets", String(multipleGitHubMatches.count))
        expect(multipleGitHubMatches.count == 2, "detects multiple same-kind secrets")

        let ssnDetector = PIIDetector(patterns: PatternConfig(phone: false, email: false, ssn: true))
        let validSSNInput = "paperwork shows 123-45-6789"
        show("input", validSSNInput)
        let validSSNMatches = ssnDetector.detect(in: validSSNInput)
        show("matches", validSSNMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(validSSNMatches.contains { $0.kind == "ssn" }, "detects valid SSN")

        let invalidSSNInputs = [
            "area zero 000-45-6789",
            "reserved area 666-45-6789",
            "advertising area 900-45-6789",
            "group zero 123-00-6789",
            "serial zero 123-45-0000",
        ]
        for invalidSSNInput in invalidSSNInputs {
            show("invalid ssn input", invalidSSNInput)
            let invalidSSNMatches = ssnDetector.detect(in: invalidSSNInput)
            show("matches", invalidSSNMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
            expect(!invalidSSNMatches.contains { $0.kind == "ssn" }, "rejects impossible SSN groups")
        }
        let mixedSSNInput = "ignore 000-45-6789 but catch 123-45-6789"
        show("mixed ssn input", mixedSSNInput)
        let mixedSSNMatches = ssnDetector.detect(in: mixedSSNInput)
        show("matches", mixedSSNMatches.map { "\($0.kind)=\($0.matched)" }.joined(separator: ", "))
        expect(mixedSSNMatches.contains { $0.matched == "123-45-6789" }, "continues scanning after invalid SSN")

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
        let compactPhraseResult = FuzzyMatcher.bestMatch(
            phrase: "private stream notes",
            in: "OCR merged privatestream n0tes"
        )
        show("compact match score", String(format: "%.2f", compactPhraseResult?.score ?? 0))
        expect((compactPhraseResult?.score ?? 0) >= 0.86, "compact fuzzy compares against compact phrase")
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

        section("OCR guard: whitelist suppression")
        var allowConfig = BlocklistConfig.default
        allowConfig.patterns = PatternConfig(phone: false, email: true, ssn: false)
        allowConfig.phrases = []
        allowConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        allowConfig.filtering = OCRFilteringConfig(
            mode: .blacklist,
            whitelist: [OCRListEntry(text: "support@example.com", fuzzy: true, minimumSimilarity: 0.92)],
            blacklist: []
        )
        let allowEngine = DetectionEngine(config: allowConfig)
        let allowInput = "contact support@example.com for public help"
        show("input", allowInput)
        let allowTransition = allowEngine.analyze(text: allowInput)
        show("decision", allowEngine.lastDecision.reason)
        show("whitelist score", String(format: "%.2f", allowEngine.lastDecision.whitelistMatch?.score ?? 0))
        expect(allowEngine.stateMachine.state == .clear, "whitelist suppresses matching email false positive")
        expect(allowTransition == nil, "whitelist suppression emits no transition")
        expect(allowEngine.lastDecision.whitelistMatch?.entryText == "support@example.com", "records whitelist entry")
        let spacedAllowInput = "contact support @ example . com for public help"
        show("input", spacedAllowInput)
        let spacedAllowTransition = allowEngine.analyze(text: spacedAllowInput)
        show("decision", allowEngine.lastDecision.reason)
        show("whitelist score", String(format: "%.2f", allowEngine.lastDecision.whitelistMatch?.score ?? 0))
        expect(allowEngine.stateMachine.state == .clear, "whitelist suppresses OCR-spaced safe email")
        expect(spacedAllowTransition == nil, "OCR-spaced whitelist suppression emits no transition")
        expect(allowEngine.lastDecision.whitelistMatch?.entryText == "support@example.com", "records spaced email whitelist entry")

        var genericAllowConfig = BlocklistConfig.default
        genericAllowConfig.patterns = PatternConfig(phone: false, email: true, ssn: false)
        genericAllowConfig.phrases = []
        genericAllowConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        genericAllowConfig.filtering = OCRFilteringConfig(
            mode: .blacklist,
            whitelist: [OCRListEntry(text: "email", fuzzy: false, minimumSimilarity: 1)],
            blacklist: []
        )
        let genericAllowEngine = DetectionEngine(config: genericAllowConfig)
        let genericAllowInput = "leaked person@example.com"
        show("generic whitelist input", genericAllowInput)
        _ = genericAllowEngine.analyze(text: genericAllowInput)
        show("state", genericAllowEngine.stateMachine.state.rawValue)
        expect(genericAllowEngine.stateMachine.state == .armed, "generic PII label whitelist does not suppress all emails")

        section("OCR guard: blacklist similarity")
        var denyConfig = BlocklistConfig.default
        denyConfig.patterns = PatternConfig(phone: false, email: false, ssn: false)
        denyConfig.phrases = []
        denyConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        denyConfig.filtering = OCRFilteringConfig(
            mode: .blacklist,
            whitelist: [],
            blacklist: [OCRListEntry(text: "private stream notes", fuzzy: true, minimumSimilarity: 0.86)]
        )
        let denyEngine = DetectionEngine(config: denyConfig)
        let denyInput = "OCR saw private stream n0tes on screen"
        show("input", denyInput)
        let denyTransition = denyEngine.analyze(text: denyInput)
        show("score", String(format: "%.2f", denyEngine.lastDecision.match?.score ?? 0))
        expect(denyEngine.stateMachine.state == .armed, "blacklist fuzzy threshold blocks OCR-near phrase")
        expect(denyTransition?.current == .armed, "blacklist fuzzy transition")

        section("OCR guard: similarity threshold")
        var strictConfig = BlocklistConfig.default
        strictConfig.patterns = PatternConfig(phone: false, email: false, ssn: false)
        strictConfig.phrases = []
        strictConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        strictConfig.filtering = OCRFilteringConfig(
            mode: .blacklist,
            whitelist: [],
            blacklist: [OCRListEntry(text: "launch payroll", fuzzy: true, minimumSimilarity: 0.99)]
        )
        let strictEngine = DetectionEngine(config: strictConfig)
        let nearMissInput = "lannch payroll"
        show("input", nearMissInput)
        _ = strictEngine.analyze(text: nearMissInput)
        show("decision", strictEngine.lastDecision.reason)
        expect(strictEngine.stateMachine.state == .clear, "strict similarity rejects near miss")
        strictConfig.filtering.blacklist = [OCRListEntry(text: "launch payroll", fuzzy: true, minimumSimilarity: 0.9)]
        let relaxedEngine = DetectionEngine(config: strictConfig)
        _ = relaxedEngine.analyze(text: nearMissInput)
        show("relaxed score", String(format: "%.2f", relaxedEngine.lastDecision.match?.score ?? 0))
        expect(relaxedEngine.stateMachine.state == .armed, "lower similarity accepts near miss")

        section("OCR guard: blur-all is intentionally buggy")
        var blurAllConfig = BlocklistConfig.default
        blurAllConfig.patterns = PatternConfig(phone: false, email: false, ssn: false)
        blurAllConfig.phrases = []
        blurAllConfig.hysteresis = HysteresisConfig(triggerFrames: 1, clearFrames: 2)
        blurAllConfig.filtering = OCRFilteringConfig(mode: .blurAll)
        let blurAllEngine = DetectionEngine(config: blurAllConfig)
        let harmlessInput = "safe public heading"
        show("input", harmlessInput)
        let blurTransition = blurAllEngine.analyze(text: harmlessInput)
        show("decision", blurAllEngine.lastDecision.reason)
        expect(blurAllEngine.stateMachine.state == .armed, "blur-all blocks harmless OCR text")
        expect(blurTransition?.current == .armed, "blur-all transition")
        expect(OCRGuardMode.blurAll.warning?.contains("overblocks") == true, "blur-all warning is diagnostics-only wording")


        section("User-facing settings defaults")

        let partialSettingsJSON = """
        { "userSettings": { "sensitivity": "balanced" } }
        """.data(using: .utf8)!
        let partialSettings = try? JSONDecoder().decode(BlocklistConfig.self, from: partialSettingsJSON)
        expect(partialSettings?.userSettings.protectionMode == .both, "partial userSettings decode uses defaults")
        expect(partialSettings?.userSettings.sensitivity == .balanced, "partial userSettings preserves explicit field")

        let advancedJSON = """
        {
          "patterns": { "phone": true, "email": true, "ssn": false, "secrets": false, "cards": true, "nationalIDs": false },
          "filtering": { "mode": "whitelist", "whitelist": [], "blacklist": [], "blurAllMinimumCharacters": 2 },
          "userSettings": { "safeText": ["safe one"], "sensitiveText": ["secret one"] }
        }
        """.data(using: .utf8)!
        let advancedConfig = try? JSONDecoder().decode(BlocklistConfig.self, from: advancedJSON)
        expect(advancedConfig?.filtering.mode == .whitelist, "advanced filtering mode is preserved")
        expect(advancedConfig?.patterns.secrets == false && advancedConfig?.patterns.cards == true, "advanced pattern flags are preserved")
        expect(advancedConfig?.filtering.whitelist.contains { $0.managedByUserSettings && $0.text == "safe one" } == true, "user settings safe text is marked managed")
        var reconciled = advancedConfig ?? BlocklistConfig.default
        reconciled.userSettings.safeText = []
        reconciled.applyUserSettingsCompatibility()
        expect(!reconciled.filtering.whitelist.contains { $0.managedByUserSettings }, "deleted setup safe text removes managed entries")

        let defaultConfig = BlocklistConfig.default
        expect(defaultConfig.userSettings.protectionMode == .both, "default protection mode is both")
        expect(defaultConfig.userSettings.sensitivity == .safe, "default sensitivity is Safe")
        expect(defaultConfig.patterns.email && defaultConfig.patterns.phone && defaultConfig.patterns.secrets, "email, phone, secrets enabled")
        expect(!defaultConfig.patterns.ssn && !defaultConfig.patterns.cards && !defaultConfig.patterns.nationalIDs, "SSN/cards/national IDs off by default")
        let missingScreen = SetupReadiness(screenRecordingGranted: false, obs: OBSReadiness(state: .ready, message: "ready"), protectionMode: .both)
        expect(!missingScreen.canStartProtection, "missing Screen Recording blocks protection")
        let missingOBS = SetupReadiness(screenRecordingGranted: true, obs: OBSReadiness(state: .protectedSceneMissing, message: "missing"), protectionMode: .both)
        expect(!missingOBS.canStartProtection, "missing OBS readiness blocks OBS protection")
        let localOnly = SetupReadiness(screenRecordingGranted: true, obs: OBSReadiness(state: .disconnected, message: "missing"), protectionMode: .localOverlay)
        expect(localOnly.canStartProtection, "local overlay can start without OBS")
        var balanced = BlocklistConfig.default
        balanced.userSettings.sensitivity = .balanced
        balanced.applyUserSettingsCompatibility()
        expect(balanced.hysteresis.triggerFrames >= 2, "Balanced requires repeat before arming")
        var safe = BlocklistConfig.default
        safe.userSettings.sensitivity = .safe
        safe.applyUserSettingsCompatibility()
        expect(safe.hysteresis.triggerFrames == 1, "Safe blocks first likely leak")

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


        section("Privacy and packaging constants")
        expect(WebPrivacyPolicy.defaultBindHost == "127.0.0.1", "status server bind host is loopback")

        expect(WebPrivacyPolicy.requiredLocalEndpointUsesAnyPort, "status server required local endpoint uses any port")

        let listenerResult: Bool = {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(IPv4Address(WebPrivacyPolicy.defaultBindHost)!),
                port: .any
            )
            do {
                let listener = try NWListener(using: parameters, on: .any)
                listener.start(queue: DispatchQueue(label: "dev.pcstyle.stream-guard.test-listener"))
                listener.cancel()
                return true
            } catch {
                show("loopback listener error", error.localizedDescription)
                return false
            }
        }()
        expect(listenerResult, "loopback required endpoint can bind with listener port")

        let encodedConfig = (try? JSONEncoder().encode(BlocklistConfig.default)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(!encodedConfig.lowercased().contains("password"), "OBS password is not part of config JSON")

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
