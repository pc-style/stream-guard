import CryptoKit
import Foundation
import StreamGuardCore

final class OBSWebSocketClient: @unchecked Sendable {
    private var config: OBSConfig
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "dev.pcstyle.stream-guard.obs")
    private let passwordProvider: () -> String?
    private var previousScene: String?
    private var connected = false
    private var identified = false
    private var requestCounter = 0
    private var pendingResponses: [String: (OBSRequestResult) -> Void] = [:]
    private var pendingActions: [() -> Void] = []
    private var readinessCompletion: ((OBSReadiness) -> Void)?
    private(set) var lastReadiness = OBSReadiness()

    init(config: OBSConfig, passwordProvider: @escaping () -> String? = { KeychainStore.shared.obsPassword() }) {
        self.config = config
        self.passwordProvider = passwordProvider
    }

    func updateConfig(_ config: OBSConfig) {
        queue.async {
            let endpointChanged = self.config.host != config.host || self.config.port != config.port
            self.config = config
            if config.enabled {
                if endpointChanged { self.disconnectLocked() }
                self.connectIfNeededLocked()
            } else {
                self.disconnectLocked()
            }
        }
    }

    func connectIfNeeded() { queue.async { self.connectIfNeededLocked() } }
    func disconnect() { queue.async { self.disconnectLocked() } }

    func readiness(completion: @escaping (OBSReadiness) -> Void) {
        queue.async { completion(self.lastReadiness) }
    }

    func testConnectionAndBlackout(completion: @escaping (OBSReadiness) -> Void) {
        queue.async {
            self.readinessCompletion = completion
            self.disconnectLocked()
            self.connectIfNeededLocked()
            self.runWhenReady { self.verifyProtectedScene() }
        }
    }

    func onArmed() {
        queue.async {
            guard self.config.enabled else { return }
            self.runWhenReady {
                if self.config.controlMode == "source" {
                    self.setBlackoutSource(enabled: true)
                } else {
                    self.sendRequest(type: "GetCurrentProgramScene") { [weak self] result in
                        guard let self else { return }
                        if let sceneName = result.data?["currentProgramSceneName"] as? String { self.previousScene = sceneName }
                        self.setScene(name: self.config.blackoutScene)
                    }
                }
            }
        }
    }

    func onClear() {
        queue.async {
            guard self.config.enabled else { return }
            self.runWhenReady {
                if self.config.controlMode == "source" {
                    self.setBlackoutSource(enabled: false)
                } else if let previousScene = self.previousScene {
                    self.setScene(name: previousScene)
                    self.previousScene = nil
                }
            }
        }
    }

    private func connectIfNeededLocked() {
        guard config.enabled, webSocket == nil else { return }
        guard let url = URL(string: "ws://\(config.host):\(config.port)") else { return }
        setReadiness(.disconnected, "Connecting to OBS…")
        let task = session.webSocketTask(with: url)
        webSocket = task
        connected = true
        task.resume()
        receiveLoop()
    }

    private func disconnectLocked() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        connected = false
        identified = false
        pendingResponses.removeAll()
        pendingActions.removeAll()
    }

    private func runWhenReady(_ action: @escaping () -> Void) {
        connectIfNeededLocked()
        if identified { action() } else { pendingActions.append(action) }
    }

    private func flushPendingActions() {
        let actions = pendingActions
        pendingActions.removeAll()
        for action in actions { action() }
    }

    private func setScene(name: String) { sendRequest(type: "SetCurrentProgramScene", data: ["sceneName": name]) }

    private func setBlackoutSource(enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        let sceneName = config.protectedScene
        let sourceName = config.blackoutSource
        sendRequest(type: "GetSceneItemId", data: ["sceneName": sceneName, "sourceName": sourceName]) { [weak self] result in
            guard let self, result.ok, let itemId = result.data?["sceneItemId"] as? Int else {
                completion?(false)
                return
            }
            self.sendRequest(type: "SetSceneItemEnabled", data: ["sceneName": sceneName, "sceneItemId": itemId, "sceneItemEnabled": enabled]) { result in
                completion?(result.ok)
            }
        }
    }

    private func verifyProtectedScene() {
        setReadiness(.authenticated, "OBS authenticated; verifying protected scene…")
        sendRequest(type: "GetSceneList") { [weak self] result in
            guard let self else { return }
            guard result.ok, let scenes = result.data?["scenes"] as? [[String: Any]] else {
                self.completeReadiness(OBSReadiness(state: .disconnected, message: result.comment ?? "Could not query OBS scenes", testedAt: Date()))
                return
            }
            let names = Set(scenes.compactMap { $0["sceneName"] as? String })
            guard names.contains(self.config.protectedScene) else {
                self.completeReadiness(OBSReadiness(state: .protectedSceneMissing, message: "Protected delayed scene ‘\(self.config.protectedScene)’ is missing", testedAt: Date()))
                return
            }
            self.verifyBlackoutSource()
        }
    }

    private func verifyBlackoutSource() {
        sendRequest(type: "GetSceneItemId", data: ["sceneName": config.protectedScene, "sourceName": config.blackoutSource]) { [weak self] result in
            guard let self else { return }
            guard result.ok, result.data?["sceneItemId"] is Int else {
                self.completeReadiness(OBSReadiness(state: .blackoutSourceMissing, message: "Blackout source ‘\(self.config.blackoutSource)’ is missing in ‘\(self.config.protectedScene)’", testedAt: Date()))
                return
            }
            self.testBlackoutToggle()
        }
    }

    private func testBlackoutToggle() {
        setBlackoutSource(enabled: true) { [weak self] enabled in
            guard let self else { return }
            guard enabled else {
                self.completeReadiness(OBSReadiness(state: .testBlackoutFailed, message: "Could not enable blackout source", testedAt: Date()))
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.35) {
                self.setBlackoutSource(enabled: false) { disabled in
                    let readiness = disabled
                        ? OBSReadiness(state: .ready, message: "OBS ready: protected scene and blackout source verified", testedAt: Date())
                        : OBSReadiness(state: .testBlackoutFailed, message: "Could not disable blackout source after test", testedAt: Date())
                    self.completeReadiness(readiness)
                }
            }
        }
    }

    private func sendRequest(type: String, data: [String: Any] = [:], completion: ((OBSRequestResult) -> Void)? = nil) {
        guard connected, identified, let webSocket else {
            if let completion { pendingActions.append { self.sendRequest(type: type, data: data, completion: completion) } }
            else { pendingActions.append { self.sendRequest(type: type, data: data) } }
            connectIfNeededLocked()
            return
        }
        requestCounter += 1
        let requestId = "sg-\(requestCounter)"
        if let completion { pendingResponses[requestId] = completion }
        let payload: [String: Any] = ["op": 6, "d": ["requestType": type, "requestId": requestId, "requestData": data]]
        sendRaw(payload, webSocket: webSocket)
    }

    private func receiveLoop() {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleMessage(text)
                    case .data(let data): if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                    @unknown default: break
                    }
                    self.receiveLoop()
                case .failure:
                    self.setReadiness(.disconnected, "OBS websocket disconnected")
                    self.disconnectLocked()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else { return }

        switch op {
        case 0:
            guard let d = json["d"] as? [String: Any] else { return }
            var identifyData: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 0]
            if let auth = d["authentication"] as? [String: Any] {
                guard let password = passwordProvider(), !password.isEmpty else {
                    completeReadiness(OBSReadiness(state: .passwordRequired, message: "OBS requires a websocket password; save it in setup to continue", testedAt: Date()))
                    disconnectLocked()
                    return
                }
                guard let challenge = auth["challenge"] as? String, let salt = auth["salt"] as? String else {
                    completeReadiness(OBSReadiness(state: .passwordRequired, message: "OBS authentication challenge was invalid", testedAt: Date()))
                    disconnectLocked()
                    return
                }
                identifyData["authentication"] = Self.authentication(password: password, salt: salt, challenge: challenge)
            }
            sendRaw(["op": 1, "d": identifyData])
        case 2:
            identified = true
            setReadiness(.authenticated, "OBS websocket authenticated")
            flushPendingActions()
        case 7:
            guard let body = json["d"] as? [String: Any], let requestId = body["requestId"] as? String else { return }
            let status = body["requestStatus"] as? [String: Any]
            let code = status?["code"] as? Int ?? 100
            let result = OBSRequestResult(
                ok: status?["result"] as? Bool ?? (code == 100),
                code: code,
                comment: status?["comment"] as? String,
                data: body["responseData"] as? [String: Any]
            )
            pendingResponses.removeValue(forKey: requestId)?(result)
        default:
            break
        }
    }

    private func setReadiness(_ state: OBSReadinessState, _ message: String) {
        lastReadiness = OBSReadiness(state: state, message: message, testedAt: Date())
    }

    private func completeReadiness(_ readiness: OBSReadiness) {
        lastReadiness = readiness
        let completion = readinessCompletion
        readinessCompletion = nil
        completion?(readiness)
    }

    private static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data((password + salt).utf8)
        let secretHash = SHA256.hash(data: secret)
        let secretBase64 = Data(secretHash).base64EncodedString()
        let authHash = SHA256.hash(data: Data((secretBase64 + challenge).utf8))
        return Data(authHash).base64EncodedString()
    }

    private func sendRaw(_ payload: [String: Any]) { guard let webSocket else { return }; sendRaw(payload, webSocket: webSocket) }

    private func sendRaw(_ payload: [String: Any], webSocket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            self?.queue.async {
                self?.setReadiness(.disconnected, "OBS websocket send failed")
                self?.disconnectLocked()
            }
        }
    }
}

private struct OBSRequestResult {
    let ok: Bool
    let code: Int
    let comment: String?
    let data: [String: Any]?
}
