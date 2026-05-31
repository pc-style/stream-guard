import AppKit
import CoreMedia
import CoreVideo
import Foundation
import StreamGuardCore

@MainActor
final class AppCoordinator: NSObject, ScreenCaptureDelegate {
    static let shared = AppCoordinator()

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
    private var snapshotInFlight = false
    private var ocrInFlight = false
    private var lastOCRTime: CFAbsoluteTime = 0
    private var previousFingerprint: [UInt8]?
    private var permissionGrantedAfterRequest = false
    private var ocrFrameCount = 0
    private var lastOCRText = ""
    private var lastMergedText = ""
    private var lastOCRLatencyMS: Double?
    private var lastOCRAt: Date?

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
        updateOverlayExclusion()
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
                updateOverlayExclusion()
                try await captureManager.start()
                isMonitoring = true
                startCaptureTimer()
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
            overlayVisible: overlay.visible
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
        ocrInFlight = false
        ocrFrameCount = 0
        lastOCRText = ""
        lastMergedText = ""
        lastOCRLatencyMS = nil
        lastOCRAt = nil
    }

    private func updateOverlayExclusion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let windowID = self.overlay.windowID else { return }
            self.captureManager.setExcludedWindows([windowID])
        }
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

    /// `SCStream` only emits frames when the screen content changes, so a static
    /// page (or our blackout overlay) starves the OCR pipeline and the hysteresis
    /// state machine can never accumulate the clean frames needed to clear. This
    /// timer pulls fresh frames at the OCR rate to give detection a steady clock.
    private func startCaptureTimer() {
        captureTimer?.invalidate()
        let interval = 1.0 / max(config.ocr.fps, 1.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMonitoring, !self.snapshotInFlight else { return }
                self.snapshotInFlight = true
                let buffer = await self.captureManager.captureSnapshot()
                self.snapshotInFlight = false
                if let buffer {
                    self.processFrame(pixelBuffer: buffer)
                }
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

    // MARK: - ScreenCaptureDelegate

    nonisolated func captureDidOutput(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        Task { @MainActor in
            self.processFrame(pixelBuffer: pixelBuffer)
        }
    }

    nonisolated func captureDidFail(error: Error) {
        Task { @MainActor in
            self.notify(error.localizedDescription)
        }
    }

    private func processFrame(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let fingerprint: [UInt8]
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let data = Data(bytes: base, count: bytesPerRow * height)
            fingerprint = FrameDiffGate.downsampleFingerprint(from: data, width: width, height: height)
        } else {
            fingerprint = []
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        previousFingerprint = fingerprint

        let now = CFAbsoluteTimeGetCurrent()
        let minOCRInterval = 1.0 / max(config.ocr.fps, 1.0)

        guard !ocrInFlight else { return }
        guard (now - lastOCRTime) >= minOCRInterval else { return }

        guard let image = ImageDownscaler.downscale(pixelBuffer: pixelBuffer) else { return }

        ocrInFlight = true
        lastOCRTime = now
        let ocrStartedAt = CFAbsoluteTimeGetCurrent()

        ocrService.recognize(image: image) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.ocrInFlight = false
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
                    if let transition = self.detectionEngine.analyze(text: analysisText) {
                        self.handleTransition(transition)
                    }
                case .failure(let error):
                    self.lastOCRText = "OCR error: \(error.localizedDescription)"
                    self.notify("OCR error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleTransition(_ transition: StateTransition) {
        webServer?.broadcast(transition: transition)
        switch transition.current {
        case .armed:
            overlay.show()
            updateOverlayExclusion()
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
