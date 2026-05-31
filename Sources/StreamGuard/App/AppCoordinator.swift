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

    private let captureManager = ScreenCaptureManager()
    private let overlay = BlackoutOverlay()
    private var ocrService: VisionOCRService
    private var detectionEngine: DetectionEngine
    private let textBuffer = TextMergeBuffer()
    private var webServer: WebStatusServer?
    private let obsClient: OBSWebSocketClient
    private let configWatcher = ConfigWatcher()
    private var config: BlocklistConfig

    private var isMonitoring = false
    private var captureTimer: Timer?
    private var pipelineInFlight = false
    private var snapshotInFlight = false
    private var pendingPixelBuffer: CVPixelBuffer?
    private var pendingFrameSource: FrameSource?
    private var lastOCRTime: CFAbsoluteTime = 0
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

    func startMonitoring() {
        guard !isMonitoring else { return }

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
            lastOCRLatencyMS: lastOCRLatencyMS,
            lastOCRAt: lastOCRAt,
            overlayVisible: overlay.visible,
            lastSnapshotDurationMS: lastSnapshotDurationMS,
            lastPreprocessDurationMS: lastPreprocessDurationMS,
            lastFrameReceivedAt: lastFrameReceivedAt
        )
    }

    func openStatusPage() {
        NSWorkspace.shared.open(URL(string: "http://0.0.0.0:8765/")!)
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(ConfigLoader.userConfigURL().deletingLastPathComponent())
    }

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
        config = newConfig
        detectionEngine.updateConfig(newConfig)
        ocrService.updateConfig(newConfig.ocr)
        obsClient.updateConfig(newConfig.obs)
    }

    private func resetDetectionState() {
        textBuffer.clear()
        detectionEngine.stateMachine.reset()
        previousFingerprint = nil
        lastOCRTime = 0
        lastStreamFrameTime = 0
        pipelineInFlight = false
        snapshotInFlight = false
        pendingPixelBuffer = nil
        pendingFrameSource = nil
        lastOCRHadNoMatch = true
        ocrFrameCount = 0
        lastOCRText = ""
        lastMergedText = ""
        lastOCRLatencyMS = nil
        lastOCRAt = nil
        lastSnapshotDurationMS = nil
        lastPreprocessDurationMS = nil
        lastFrameReceivedAt = nil
    }

    private func refreshOverlayExclusion() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard let windowID = overlay.windowID else { return }
        await captureManager.setExcludedWindows([windowID])
    }

    private static func loadStatusHTML() -> String {
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
        let minOCRInterval = 1.0 / max(config.ocr.fps, 1.0)
        return (now - lastOCRTime) >= minOCRInterval
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

    private func enqueueFrame(pixelBuffer: CVPixelBuffer, source: FrameSource) {
        lastFrameReceivedAt = Date()

        if source == .stream {
            lastStreamFrameTime = CFAbsoluteTimeGetCurrent()
            if pendingFrameSource == .watchdogSnapshot {
                pendingPixelBuffer = nil
                pendingFrameSource = nil
            }
        }

        let now = CFAbsoluteTimeGetCurrent()

        if pipelineInFlight {
            if source == .stream || pendingFrameSource != .stream {
                pendingPixelBuffer = pixelBuffer
                pendingFrameSource = source
            }
            return
        }

        guard canAcceptNewPipelineWork(now: now) else {
            pendingPixelBuffer = pixelBuffer
            pendingFrameSource = source
            return
        }

        startPipeline(pixelBuffer: pixelBuffer)
    }

    private func startPipeline(pixelBuffer: CVPixelBuffer) {
        let preprocessStarted = CFAbsoluteTimeGetCurrent()

        let fingerprint = FrameDiffGate.fingerprint(pixelBuffer: pixelBuffer)
        let changeRatio = FrameDiffGate.changeRatio(previous: previousFingerprint, current: fingerprint)
        previousFingerprint = fingerprint

        let state = detectionEngine.stateMachine.state
        if state == .clear,
           changeRatio < FrameDiffGate.unchangedThreshold,
           lastOCRHadNoMatch {
            lastPreprocessDurationMS = (CFAbsoluteTimeGetCurrent() - preprocessStarted) * 1000
            drainPendingFrameIfAny()
            return
        }

        guard let image = ImageDownscaler.imageForOCR(pixelBuffer: pixelBuffer) else {
            drainPendingFrameIfAny()
            return
        }

        lastPreprocessDurationMS = (CFAbsoluteTimeGetCurrent() - preprocessStarted) * 1000

        pipelineInFlight = true
        let now = CFAbsoluteTimeGetCurrent()
        lastOCRTime = now
        let ocrStartedAt = CFAbsoluteTimeGetCurrent()

        ocrService.recognize(image: image) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.pipelineInFlight = false
                self.lastOCRLatencyMS = (CFAbsoluteTimeGetCurrent() - ocrStartedAt) * 1000
                self.lastOCRAt = Date()
                switch result {
                case .success(let strings):
                    self.ocrFrameCount += 1
                    self.lastOCRText = strings.joined(separator: " | ")
                    for string in strings {
                        self.textBuffer.append(string)
                    }
                    let merged = self.textBuffer.mergedText()
                    let compactMerged = self.textBuffer.compactMergedText()
                    self.lastMergedText = merged
                    let analysisText = compactMerged.isEmpty ? merged : "\(merged)\n\(compactMerged)"
                    let transition = self.detectionEngine.analyze(text: analysisText)
                    self.lastOCRHadNoMatch = self.detectionEngine.stateMachine.state == .clear
                    if let transition {
                        self.handleTransition(transition)
                    }
                case .failure(let error):
                    self.lastOCRText = "OCR error: \(error.localizedDescription)"
                    self.lastOCRHadNoMatch = false
                    self.notify("OCR error: \(error.localizedDescription)")
                }
                self.drainPendingFrameIfAny()
            }
        }
    }

    private func drainPendingFrameIfAny() {
        guard let buffer = pendingPixelBuffer, let source = pendingFrameSource else { return }
        pendingPixelBuffer = nil
        pendingFrameSource = nil
        enqueueFrame(pixelBuffer: buffer, source: source)
    }

    private func handleTransition(_ transition: StateTransition) {
        webServer?.broadcast(transition: transition)
        switch transition.current {
        case .armed:
            overlay.show()
            Task { await refreshOverlayExclusion() }
            obsClient.onArmed()
            notify("ARMED — \(transition.lastMatch ?? "match")")
        case .clear:
            overlay.hide()
            obsClient.onClear()
            notify("CLEAR")
        case .suspect:
            notify("SUSPECT — \(transition.lastMatch ?? "match")")
        }
    }
}
