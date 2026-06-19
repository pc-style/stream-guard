import AppKit
import CoreMedia
import CoreVideo
import Foundation
import StreamGuardCore

@MainActor
final class AppCoordinator: NSObject, ScreenCaptureDelegate {
    static let shared = AppCoordinator()

    private enum FrameSource {
        case stream
        case watchdogSnapshot
    }

    /// When no SCStream frame arrives within this interval, pull a watchdog snapshot.
    private static let streamWatchdogStaleInterval: CFAbsoluteTime = 0.5
    /// While clear with text-like regions, allow faster OCR retries than config.ocr.fps.
    private static let ocrBurstFPS: Double = 25
    private static let ocrBurstDuration: CFAbsoluteTime = 0.5

    private let captureManager = ScreenCaptureManager()
    private let overlay = BlackoutOverlay()
    private var ocrService: VisionOCRService
    private var detectionEngine: DetectionEngine
    private let textBuffer = TextMergeBuffer()
    private var webServer: WebStatusServer?
    private let obsClient: OBSWebSocketClient
    private let configWatcher = ConfigWatcher()
    private var config: BlocklistConfig
    private var obsReadiness = OBSReadiness()

    private var isMonitoring = false
    private var captureTimer: Timer?
    private var pipelineInFlight = false
    private var snapshotInFlight = false
    private var pendingPixelBuffer: CVPixelBuffer?
    private var pendingFrameSource: FrameSource?
    private var pendingFrameReceivedAt: Date?
    private var lastOCRTime: CFAbsoluteTime = 0
    private var ocrBurstDeadline: CFAbsoluteTime = 0
    private var ocrSequentialCropAppend = false
    private var ocrDetectionAppliedInPass = false
    private var lastStreamFrameTime: CFAbsoluteTime = 0
    private var previousFingerprint: [UInt8]?
    private var lastOCRHadNoMatch = true
    private var permissionGrantedAfterRequest = false
    private var ocrFrameCount = 0
    private var lastOCRText = ""
    private var lastMergedText = ""
    private var lastOCRLatencyMS: Double?
    private var lastOCRAt: Date?
    private var lastSnapshotDurationMS: Double?
    private var lastPreprocessDurationMS: Double?
    private var lastFrameReceivedAt: Date?
    private var lastPipelineFrameReceivedAt: Date?
    private var lastPipelineStartedAt: Date?
    private var lastPreprocessDoneAt: Date?
    private var lastOCRStartedAt: Date?
    private var lastOCRDoneAt: Date?
    private var lastStateTransitionAt: Date?
    private var lastFrameToPipelineMS: Double?
    private var lastPipelineToPreprocessMS: Double?
    private var lastPreprocessToOCRDoneMS: Double?
    private var lastOCRDoneToArmedMS: Double?
    private var lastFrameToArmedMS: Double?
    private var lastTextRegionCount = 0
    private var lastTextRegionCoverage = 0.0
    private var lastROIImageCount = 0
    private var lastROISkippedOCR = false
    private var lastYODORegionCount = 0
    private var lastYODOMaskCoverage = 0.0

    var onStatusChange: ((String) -> Void)?

    private override init() {
        ConfigLoader.seedUserConfigIfNeeded()
        let config = ConfigLoader.loadEffective()
        self.config = config
        self.detectionEngine = DetectionEngine(config: config)
        self.ocrService = VisionOCRService(config: config.ocr)
        self.obsClient = OBSWebSocketClient(config: config.obs)
        super.init()
        captureManager.delegate = self
        setupWebServer()
        setupConfigWatcher()
    }

    func applicationDidFinishLaunching() {
        if config.obs.enabled {
            obsClient.connectIfNeeded()
        }
        if ProcessInfo.processInfo.environment["STREAM_GUARD_AUTO_START"] == "1" {
            startMonitoring()
        }
    }

    var monitoring: Bool { isMonitoring }
    var currentConfig: BlocklistConfig { config }
    var currentOBSReadiness: OBSReadiness { obsReadiness }
    var currentSetupReadiness: SetupReadiness {
        SetupReadiness(
            screenRecordingGranted: captureManager.hasPermission(),
            obs: obsReadiness,
            detectorSettingsComplete: detectorsComplete(config),
            protectionMode: config.userSettings.protectionMode
        )
    }

    func startMonitoring() {
        guard !isMonitoring else { return }

        let readiness = currentSetupReadiness
        guard readiness.canStartProtection else {
            if !readiness.screenRecordingGranted {
                notify("Screen Recording permission required")
            } else if readiness.protectionMode.usesOBS && !readiness.obs.isReady {
                notify("OBS protection refused: \(readiness.obs.message)")
            } else {
                notify("Detector settings incomplete")
            }
            return
        }

        if !captureManager.hasPermission() {
            permissionGrantedAfterRequest = captureManager.requestPermission()
            if !captureManager.hasPermission() {
                notify("Screen recording permission required")
                return
            }
            if permissionGrantedAfterRequest {
                notify("Permission granted — please restart Stream Guard")
            }
        }

        Task {
            do {
                resetDetectionState()
                overlay.prepareWindow()
                try await captureManager.start()
                isMonitoring = true
                lastStreamFrameTime = CFAbsoluteTimeGetCurrent()
                startCaptureTimer()
                await refreshOverlayExclusion()
                notify("Monitoring started")
            } catch {
                notify(error.localizedDescription)
            }
        }
    }

    func stopMonitoring() {
        stopCaptureTimer()
        Task {
            do {
                try await captureManager.stop()
            } catch {
                notify(error.localizedDescription)
            }
            isMonitoring = false
            overlay.hide()
            resetDetectionState()
            notify("Monitoring stopped")
        }
    }

    func currentStatusPayload() -> StatusPayload {
        StatusPayload(
            state: detectionEngine.stateMachine.state,
            lastMatch: detectionEngine.stateMachine.lastMatch,
            monitoring: isMonitoring,
            ocrFrames: ocrFrameCount,
            lastOCRText: lastOCRText,
            mergedText: lastMergedText,
            ocrGuardMode: config.filtering.mode,
            lastDecision: detectionEngine.lastDecision,
            lastOCRLatencyMS: lastOCRLatencyMS,
            lastOCRAt: lastOCRAt,
            overlayVisible: overlay.visible && detectionEngine.stateMachine.state != .clear,
            lastSnapshotDurationMS: lastSnapshotDurationMS,
            lastPreprocessDurationMS: lastPreprocessDurationMS,
            lastFrameReceivedAt: lastFrameReceivedAt,
            lastPipelineStartedAt: lastPipelineStartedAt,
            lastPreprocessDoneAt: lastPreprocessDoneAt,
            lastOCRStartedAt: lastOCRStartedAt,
            lastOCRDoneAt: lastOCRDoneAt,
            lastStateTransitionAt: lastStateTransitionAt,
            lastFrameToPipelineMS: lastFrameToPipelineMS,
            lastPipelineToPreprocessMS: lastPipelineToPreprocessMS,
            lastPreprocessToOCRDoneMS: lastPreprocessToOCRDoneMS,
            lastOCRDoneToArmedMS: lastOCRDoneToArmedMS,
            lastFrameToArmedMS: lastFrameToArmedMS,
            pipelineMode: config.pipeline.mode,
            lastTextRegionCount: lastTextRegionCount,
            lastTextRegionCoverage: lastTextRegionCoverage,
            lastROIImageCount: lastROIImageCount,
            lastROISkippedOCR: lastROISkippedOCR,
            lastYODORegionCount: lastYODORegionCount,
            lastYODOMaskCoverage: lastYODOMaskCoverage,
            protectionMode: config.userSettings.protectionMode,
            sensitivity: config.userSettings.sensitivity,
            obsReadiness: obsReadiness
        )
    }

    func openStatusPage() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8765/")!)
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(ConfigLoader.userConfigURL().deletingLastPathComponent())
    }

    func obsLuaScriptURL() -> URL? {
        Bundle.module.url(forResource: "stream_guard_protector", withExtension: "lua")
            ?? Bundle.main.url(forResource: "stream_guard_protector", withExtension: "lua")
            ?? URL(fileURLWithPath: "obs/stream_guard_protector.lua")
    }

    func testOBSReadiness(completion: @escaping (OBSReadiness) -> Void) {
        obsClient.testConnectionAndBlackout { [weak self] readiness in
            Task { @MainActor in
                self?.obsReadiness = readiness
                self?.notify(readiness.message)
                completion(readiness)
            }
        }
    }

    func saveOBSPassword(_ password: String) throws {
        try KeychainStore.shared.setOBSPassword(password)
        notify("OBS password saved to Keychain")
    }

    func updateUserSettings(_ settings: UserSettingsConfig) {
        config.userSettings = settings
        config.applyUserSettingsCompatibility()
        persistAndApplyConfig(config)
        notify("Settings saved")
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try LaunchAgentManager.setEnabled(enabled)
        notify(enabled ? "Launch at Login enabled" : "Launch at Login disabled")
    }

    func launchAtLoginEnabled() -> Bool { LaunchAgentManager.isEnabled() }

    private func setupWebServer() {
        let html = Self.loadStatusHTML()
        let server = WebStatusServer(
            statusProvider: { [weak self] in
                self?.currentStatusPayload() ?? StatusPayload(state: .clear, lastMatch: nil)
            },
            statusHTML: html,
            controlHandler: { [weak self] action in
                Task { @MainActor in
                    switch action {
                    case "start":
                        self?.startMonitoring()
                    case "stop":
                        self?.stopMonitoring()
                    case "mode/full":
                        self?.setPipelineMode(.fullFrame)
                    case "mode/roi":
                        self?.setPipelineMode(.roiCascade)
                    case "mode/yodo":
                        self?.setPipelineMode(.yodoMask)
                    case "mode/yodo-ocr":
                        self?.setPipelineMode(.yodoOCR)
                    case "guard/blur-all":
                        self?.setGuardMode(.blurAll)
                    case "guard/whitelist":
                        self?.setGuardMode(.whitelist)
                    case "guard/blacklist":
                        self?.setGuardMode(.blacklist)
                    default:
                        break
                    }
                }
            }
        )
        try? server.start()
        webServer = server
    }

    private func setupConfigWatcher() {
        configWatcher.onReload = { [weak self] newConfig in
            self?.applyConfig(newConfig)
        }
        configWatcher.start()
    }

    private func applyConfig(_ newConfig: BlocklistConfig) {
        let previousConfig = config
        var newConfig = newConfig
        newConfig.applyUserSettingsCompatibility()
        config = newConfig
        detectionEngine.updateConfig(newConfig)
        ocrService.updateConfig(newConfig.ocr)
        obsClient.updateConfig(newConfig.obs)
        if previousConfig.pipeline != newConfig.pipeline ||
            previousConfig.phrases != newConfig.phrases ||
            previousConfig.patterns != newConfig.patterns ||
            previousConfig.hysteresis != newConfig.hysteresis ||
            previousConfig.filtering != newConfig.filtering {
            resetDetectionState()
            overlay.hide()
        }
    }

    private func setPipelineMode(_ mode: PipelineMode) {
        guard config.pipeline.mode != mode else { return }
        config.pipeline.mode = mode
        resetDetectionState()
        overlay.hide()
        notify("Pipeline mode: \(mode.rawValue)")
    }

    func setGuardModeFromMenu(_ mode: OCRGuardMode) {
        setGuardMode(mode)
    }

    private func persistAndApplyConfig(_ newConfig: BlocklistConfig) {
        do {
            try ConfigLoader.save(newConfig)
            applyConfig(newConfig)
        } catch {
            notify("Could not save settings: \(error.localizedDescription)")
        }
    }

    private func detectorsComplete(_ config: BlocklistConfig) -> Bool {
        config.patterns.email || config.patterns.phone || config.patterns.secrets || !config.filtering.blacklist.isEmpty || !config.phrases.isEmpty
    }

    private func setGuardMode(_ mode: OCRGuardMode) {
        guard config.filtering.mode != mode else { return }
        config.filtering.mode = mode
        detectionEngine.updateConfig(config)
        resetDetectionState()
        overlay.hide()
        let suffix = mode.isBuggy ? " (buggy)" : ""
        notify("OCR guard mode: \(mode.rawValue)\(suffix)")
    }

    private func resetDetectionState() {
        textBuffer.clear()
        detectionEngine.stateMachine.reset()
        detectionEngine.resetDecision()
        previousFingerprint = nil
        lastOCRTime = 0
        ocrBurstDeadline = 0
        ocrSequentialCropAppend = false
        ocrDetectionAppliedInPass = false
        lastStreamFrameTime = 0
        pipelineInFlight = false
        snapshotInFlight = false
        pendingPixelBuffer = nil
        pendingFrameSource = nil
        pendingFrameReceivedAt = nil
        lastOCRHadNoMatch = true
        ocrFrameCount = 0
        lastOCRText = ""
        lastMergedText = ""
        lastOCRLatencyMS = nil
        lastOCRAt = nil
        lastSnapshotDurationMS = nil
        lastPreprocessDurationMS = nil
        lastFrameReceivedAt = nil
        lastPipelineFrameReceivedAt = nil
        lastPipelineStartedAt = nil
        lastPreprocessDoneAt = nil
        lastOCRStartedAt = nil
        lastOCRDoneAt = nil
        lastStateTransitionAt = nil
        lastFrameToPipelineMS = nil
        lastPipelineToPreprocessMS = nil
        lastPreprocessToOCRDoneMS = nil
        lastOCRDoneToArmedMS = nil
        lastFrameToArmedMS = nil
        lastTextRegionCount = 0
        lastTextRegionCoverage = 0
        lastROIImageCount = 0
        lastROISkippedOCR = false
        lastYODORegionCount = 0
        lastYODOMaskCoverage = 0
    }

    private func refreshOverlayExclusion() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard let windowID = overlay.windowID else { return }
        await captureManager.setExcludedWindows([windowID])
    }

    private static func loadStatusHTML() -> String {
        if let url = Bundle.module.url(forResource: "status", withExtension: "html"),
           let html = try? String(contentsOf: url) {
            return html
        }
        if let url = Bundle.main.url(forResource: "status", withExtension: "html"),
           let html = try? String(contentsOf: url) {
            return html
        }
        let fallback = URL(fileURLWithPath: "web/status.html")
        if let html = try? String(contentsOf: fallback) {
            return html
        }
        return "<html><body><h1>Stream Guard</h1><p>Status page missing.</p></body></html>"
    }

    private func notify(_ message: String) {
        onStatusChange?(message)
    }

    // MARK: - Capture cadence

    /// Watchdog timer: SCStream drives arming on content change; snapshots only when the stream
    /// is stale or we need static-frame samples for clear hysteresis.
    private func startCaptureTimer() {
        captureTimer?.invalidate()
        let interval = 1.0 / max(config.ocr.fps, 1.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runWatchdogTickIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    private func stopCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = nil
        snapshotInFlight = false
    }

    private func runWatchdogTickIfNeeded() async {
        guard isMonitoring else { return }
        drainThrottledPendingIfReady()
        let now = CFAbsoluteTimeGetCurrent()
        guard shouldRunWatchdogSnapshot(now: now) else { return }

        snapshotInFlight = true
        let snapshotStarted = CFAbsoluteTimeGetCurrent()
        let buffer = await captureManager.captureSnapshot()
        lastSnapshotDurationMS = (CFAbsoluteTimeGetCurrent() - snapshotStarted) * 1000
        snapshotInFlight = false

        if let buffer {
            enqueueFrame(pixelBuffer: buffer, source: .watchdogSnapshot)
        }
    }

    private func shouldRunWatchdogSnapshot(now: CFAbsoluteTime) -> Bool {
        guard !snapshotInFlight else { return false }
        guard canAcceptNewPipelineWork(now: now) else { return false }

        let state = detectionEngine.stateMachine.state
        if state != .clear {
            return true
        }

        let streamStale = lastStreamFrameTime == 0
            || (now - lastStreamFrameTime) >= Self.streamWatchdogStaleInterval
        return streamStale
    }

    private func canAcceptNewPipelineWork(now: CFAbsoluteTime) -> Bool {
        guard !pipelineInFlight else { return false }
        return (now - lastOCRTime) >= effectiveMinOCRInterval(now: now)
    }

    private func effectiveMinOCRInterval(now: CFAbsoluteTime) -> CFAbsoluteTime {
        if detectionEngine.stateMachine.state == .clear,
           now < ocrBurstDeadline {
            return 1.0 / Self.ocrBurstFPS
        }
        return 1.0 / max(config.ocr.fps, 1.0)
    }

    private func refreshOCRBurstIfNeeded(analysis: TextRegionAnalysis) {
        guard detectionEngine.stateMachine.state == .clear else { return }
        let hasTextRegions = !analysis.roiRegions.isEmpty || !analysis.yodoMaskRegions.isEmpty
        guard hasTextRegions else { return }
        let now = CFAbsoluteTimeGetCurrent()
        ocrBurstDeadline = max(ocrBurstDeadline, now + Self.ocrBurstDuration)
    }

    private func endOCRBurstIfMatched() {
        guard detectionEngine.stateMachine.state != .clear else { return }
        ocrBurstDeadline = 0
    }

    // MARK: - ScreenCaptureDelegate

    nonisolated func captureDidOutput(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        Task { @MainActor in
            self.enqueueFrame(pixelBuffer: pixelBuffer, source: .stream)
        }
    }

    nonisolated func captureDidFail(error: Error) {
        Task { @MainActor in
            self.notify(error.localizedDescription)
        }
    }

    private func enqueueFrame(pixelBuffer: CVPixelBuffer, source: FrameSource, receivedAt: Date = Date()) {
        lastFrameReceivedAt = receivedAt

        if source == .stream {
            lastStreamFrameTime = CFAbsoluteTimeGetCurrent()
            if pendingFrameSource == .watchdogSnapshot {
                pendingPixelBuffer = nil
                pendingFrameSource = nil
                pendingFrameReceivedAt = nil
            }
        }

        let now = CFAbsoluteTimeGetCurrent()

        if pipelineInFlight {
            if source == .stream || pendingFrameSource != .stream {
                pendingPixelBuffer = pixelBuffer
                pendingFrameSource = source
                pendingFrameReceivedAt = receivedAt
            }
            return
        }

        guard canAcceptNewPipelineWork(now: now) else {
            pendingPixelBuffer = pixelBuffer
            pendingFrameSource = source
            pendingFrameReceivedAt = receivedAt
            return
        }

        startPipeline(pixelBuffer: pixelBuffer, frameReceivedAt: receivedAt)
    }

    private func startPipeline(pixelBuffer: CVPixelBuffer, frameReceivedAt: Date) {
        let pipelineStartedAt = Date()
        lastPipelineFrameReceivedAt = frameReceivedAt
        lastPipelineStartedAt = pipelineStartedAt
        lastFrameToPipelineMS = pipelineStartedAt.timeIntervalSince(frameReceivedAt) * 1000
        lastPreprocessDoneAt = nil
        lastOCRStartedAt = nil
        lastOCRDoneAt = nil
        lastPipelineToPreprocessMS = nil
        lastPreprocessToOCRDoneMS = nil
        let preprocessStarted = CFAbsoluteTimeGetCurrent()

        let fingerprint = FrameDiffGate.fingerprint(pixelBuffer: pixelBuffer)
        let changeRatio = FrameDiffGate.changeRatio(previous: previousFingerprint, current: fingerprint)
        previousFingerprint = fingerprint

        let state = detectionEngine.stateMachine.state
        if state == .clear,
           changeRatio < FrameDiffGate.unchangedThreshold,
           lastOCRHadNoMatch {
            markPreprocessDone(startedAt: preprocessStarted)
            drainPendingFrameIfAny()
            return
        }

        switch config.pipeline.mode {
        case .fullFrame:
            startFullFrameOCR(pixelBuffer: pixelBuffer, preprocessStarted: preprocessStarted)
        case .roiCascade:
            startROICascade(pixelBuffer: pixelBuffer, preprocessStarted: preprocessStarted)
        case .yodoMask:
            runYODOMaskPass(pixelBuffer: pixelBuffer, preprocessStarted: preprocessStarted)
        case .yodoOCR:
            startYODOOCR(pixelBuffer: pixelBuffer, preprocessStarted: preprocessStarted)
        }
    }

    private func markPreprocessDone(startedAt preprocessStarted: CFAbsoluteTime) {
        let doneAt = Date()
        lastPreprocessDoneAt = doneAt
        lastPreprocessDurationMS = (CFAbsoluteTimeGetCurrent() - preprocessStarted) * 1000
        if let pipelineStartedAt = lastPipelineStartedAt {
            lastPipelineToPreprocessMS = doneAt.timeIntervalSince(pipelineStartedAt) * 1000
        }
    }

    private func startFullFrameOCR(pixelBuffer: CVPixelBuffer, preprocessStarted: CFAbsoluteTime) {
        resetRegionMetricsForFullFrame()
        guard let image = ImageDownscaler.imageForOCR(pixelBuffer: pixelBuffer) else {
            markPreprocessDone(startedAt: preprocessStarted)
            drainPendingFrameIfAny()
            return
        }

        markPreprocessDone(startedAt: preprocessStarted)
        startOCR(images: [image])
    }

    private func startROICascade(pixelBuffer: CVPixelBuffer, preprocessStarted: CFAbsoluteTime) {
        let analysis = TextRegionDetector.analyze(pixelBuffer: pixelBuffer)
        recordRegionAnalysis(analysis)
        let images = ImageDownscaler.adaptiveCroppedImagesForOCR(
            pixelBuffer: pixelBuffer,
            regions: analysis.roiRegions
        )
        lastROIImageCount = images.count
        lastROISkippedOCR = images.isEmpty

        if images.isEmpty {
            markPreprocessDone(startedAt: preprocessStarted)
            finishRecognizedObservations([])
            drainPendingFrameIfAny()
            return
        }

        markPreprocessDone(startedAt: preprocessStarted)
        startOCR(images: images)
    }

    private func runYODOMaskPass(pixelBuffer: CVPixelBuffer, preprocessStarted: CFAbsoluteTime) {
        let analysis = TextRegionDetector.analyze(pixelBuffer: pixelBuffer)
        recordRegionAnalysis(analysis)
        lastROIImageCount = 0
        lastROISkippedOCR = true
        markPreprocessDone(startedAt: preprocessStarted)
        lastOCRText = "YODO mask mode: OCR skipped"
        lastMergedText = ""
        lastOCRHadNoMatch = true

        if config.pipeline.yodoShowsMasks {
            overlay.showMasks(analysis.yodoMaskRegions.map(\.normalizedRect))
        }

        let transition = detectionEngine.analyze(text: "")
        if let transition {
            handleTransition(transition)
        }
        drainPendingFrameIfAny()
    }

    private func startYODOOCR(pixelBuffer: CVPixelBuffer, preprocessStarted: CFAbsoluteTime) {
        let analysis = TextRegionDetector.analyze(pixelBuffer: pixelBuffer)
        recordRegionAnalysis(analysis)
        let images = ImageDownscaler.adaptiveCroppedImagesForOCR(
            pixelBuffer: pixelBuffer,
            regions: analysis.yodoMaskRegions
        )
        lastROIImageCount = images.count
        lastROISkippedOCR = images.isEmpty

        if config.pipeline.yodoShowsMasks {
            overlay.showMasks(analysis.yodoMaskRegions.map(\.normalizedRect))
        }

        if images.isEmpty {
            markPreprocessDone(startedAt: preprocessStarted)
            finishRecognizedObservations([])
            drainPendingFrameIfAny()
            return
        }

        markPreprocessDone(startedAt: preprocessStarted)
        startOCR(images: images)
    }

    private func startOCR(images: [CGImage]) {
        pipelineInFlight = true
        ocrSequentialCropAppend = false
        ocrDetectionAppliedInPass = false
        let now = CFAbsoluteTimeGetCurrent()
        lastOCRTime = now
        lastOCRStartedAt = Date()
        let ocrStartedAt = CFAbsoluteTimeGetCurrent()

        if images.count > 1 {
            ocrService.recognizeSequential(images: images, shouldStop: { [weak self] cropObservations in
                guard let self else { return false }
                return self.processCropFastPath(cropObservations)
            }, completion: { [weak self] result in
                Task { @MainActor in
                    self?.completeOCRPass(result: result, startedAt: ocrStartedAt)
                }
            })
            return
        }

        ocrService.recognize(images: images) { [weak self] result in
            Task { @MainActor in
                self?.completeOCRPass(result: result, startedAt: ocrStartedAt)
            }
        }
    }

    private func completeOCRPass(result: Result<[OCRObservation], Error>, startedAt: CFAbsoluteTime) {
        pipelineInFlight = false
        let ocrDoneAt = Date()
        lastOCRLatencyMS = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        lastOCRAt = ocrDoneAt
        lastOCRDoneAt = ocrDoneAt
        if let preprocessDoneAt = lastPreprocessDoneAt {
            lastPreprocessToOCRDoneMS = ocrDoneAt.timeIntervalSince(preprocessDoneAt) * 1000
        }
        switch result {
        case .success(let observations):
            ocrFrameCount += 1
            finishRecognizedObservations(observations)
        case .failure(let error):
            lastOCRText = "OCR error: \(error.localizedDescription)"
            lastOCRHadNoMatch = false
            notify("OCR error: \(error.localizedDescription)")
        }
        ocrSequentialCropAppend = false
        ocrDetectionAppliedInPass = false
        drainPendingFrameIfAny()
    }

    /// Appends crop OCR, checks compact variants + merge buffer; arms without waiting for other crops.
    @discardableResult
    private func processCropFastPath(_ cropObservations: [OCRObservation]) -> Bool {
        let cropStrings = cropObservations.map(\.text)
        guard !cropStrings.isEmpty else { return false }
        for observation in cropObservations {
            textBuffer.append(observation.text)
        }
        ocrSequentialCropAppend = true
        lastOCRText = cropStrings.joined(separator: " | ")
        let merged = textBuffer.mergedText()
        lastMergedText = merged
        let analysisText = analysisTextForDetection(merged: merged, latestCropStrings: cropStrings)
        guard detectionEngine.wouldTrigger(text: analysisText) else { return false }
        applyDetectionResult(analysisText: analysisText)
        return detectionEngine.stateMachine.state != .clear
    }

    private func finishRecognizedObservations(_ observations: [OCRObservation]) {
        let strings = observations.map(\.text)
        if !ocrSequentialCropAppend {
            for observation in observations {
                textBuffer.append(observation.text)
            }
        }
        lastOCRText = strings.joined(separator: " | ")
        let merged = textBuffer.mergedText()
        lastMergedText = merged
        guard !ocrDetectionAppliedInPass else { return }
        applyDetectionResult(analysisText: analysisTextForDetection(merged: merged))
    }

    private func analysisTextForDetection(merged: String, latestCropStrings: [String] = []) -> String {
        var parts: [String] = []
        if !merged.isEmpty {
            parts.append(merged)
        }
        let compactMerged = textBuffer.compactMergedText()
        if !compactMerged.isEmpty, compactMerged != merged {
            parts.append(compactMerged)
        }
        if !latestCropStrings.isEmpty {
            let cropJoined = latestCropStrings.joined(separator: " ")
            let cropCompact = TextNormalizer.compact(cropJoined)
            if !cropJoined.isEmpty {
                parts.append(cropJoined)
            }
            if !cropCompact.isEmpty, cropCompact != cropJoined {
                parts.append(cropCompact)
            }
        }
        return parts.joined(separator: "\n")
    }

    private func applyDetectionResult(analysisText: String) {
        let transition = detectionEngine.analyze(text: analysisText)
        ocrDetectionAppliedInPass = true
        lastOCRHadNoMatch = detectionEngine.stateMachine.state == .clear
        if let transition {
            handleTransition(transition)
            endOCRBurstIfMatched()
        }
    }

    private func recordRegionAnalysis(_ analysis: TextRegionAnalysis) {
        lastTextRegionCount = analysis.roiRegions.count
        lastTextRegionCoverage = analysis.roiCoverage
        lastYODORegionCount = analysis.yodoMaskRegions.count
        lastYODOMaskCoverage = analysis.yodoMaskCoverage
        refreshOCRBurstIfNeeded(analysis: analysis)
    }

    private func resetRegionMetricsForFullFrame() {
        lastTextRegionCount = 0
        lastTextRegionCoverage = 1
        lastROIImageCount = 1
        lastROISkippedOCR = false
        lastYODORegionCount = 0
        lastYODOMaskCoverage = 0
    }

    /// Drains a frame queued only because `canAcceptNewPipelineWork` was false (OCR interval).
    private func drainThrottledPendingIfReady() {
        guard pendingPixelBuffer != nil, pendingFrameSource != nil else { return }
        guard !pipelineInFlight else { return }
        guard canAcceptNewPipelineWork(now: CFAbsoluteTimeGetCurrent()) else { return }
        drainPendingFrameIfAny()
    }

    private func drainPendingFrameIfAny() {
        guard let buffer = pendingPixelBuffer, let source = pendingFrameSource else { return }
        let receivedAt = pendingFrameReceivedAt ?? Date()
        pendingPixelBuffer = nil
        pendingFrameSource = nil
        pendingFrameReceivedAt = nil
        enqueueFrame(pixelBuffer: buffer, source: source, receivedAt: receivedAt)
    }

    private func handleTransition(_ transition: StateTransition) {
        let transitionAt = Date()
        lastStateTransitionAt = transitionAt
        switch transition.current {
        case .armed:
            if let ocrDoneAt = lastOCRDoneAt {
                lastOCRDoneToArmedMS = transitionAt.timeIntervalSince(ocrDoneAt) * 1000
            }
            if let frameReceivedAt = lastPipelineFrameReceivedAt {
                lastFrameToArmedMS = transitionAt.timeIntervalSince(frameReceivedAt) * 1000
            }
        case .clear:
            lastOCRDoneToArmedMS = nil
            lastFrameToArmedMS = nil
        case .suspect:
            break
        }
        webServer?.broadcast(transition: transition, status: currentStatusPayload())
        switch transition.current {
        case .armed:
            if config.userSettings.protectionMode.usesLocalOverlay {
                overlay.show()
                Task { await refreshOverlayExclusion() }
            }
            if config.userSettings.protectionMode.usesOBS {
                obsClient.onArmed()
            }
            notify("ARMED — \(transition.lastMatch ?? "match")")
        case .clear:
            overlay.hide()
            if config.userSettings.protectionMode.usesOBS {
                obsClient.onClear()
            }
            notify("CLEAR")
        case .suspect:
            notify("SUSPECT — \(transition.lastMatch ?? "match")")
        }
    }
}
