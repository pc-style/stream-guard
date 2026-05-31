import Foundation
import StreamGuardCore

final class OBSWebSocketClient: @unchecked Sendable {
    private var config: OBSConfig
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "dev.pcstyle.stream-guard.obs")
    private var previousScene: String?
    private var connected = false
    private var identified = false
    private var requestCounter = 0
    private var pendingResponses: [String: ([String: Any]?) -> Void] = [:]
    private var pendingActions: [() -> Void] = []

    init(config: OBSConfig) {
        self.config = config
    }

    func updateConfig(_ config: OBSConfig) {
        queue.async {
            let endpointChanged = self.config.host != config.host || self.config.port != config.port
            self.config = config
            if config.enabled {
                if endpointChanged {
                    self.disconnectLocked()
                }
                self.connectIfNeededLocked()
            } else {
                self.disconnectLocked()
            }
        }
    }

    func connectIfNeeded() {
        queue.async {
            self.connectIfNeededLocked()
        }
    }

    func disconnect() {
        queue.async {
            self.disconnectLocked()
        }
    }

    func onArmed() {
        queue.async {
            guard self.config.enabled else { return }
            self.runWhenReady {
                if self.config.controlMode == "source" {
                    self.setBlackoutSource(enabled: true)
                } else {
                    self.sendRequest(type: "GetCurrentProgramScene") { [weak self] response in
                        guard let self else { return }
                        if let sceneName = response?["currentProgramSceneName"] as? String {
                            self.previousScene = sceneName
                        }
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
        if identified {
            action()
        } else {
            pendingActions.append(action)
        }
    }

    private func flushPendingActions() {
        let actions = pendingActions
        pendingActions.removeAll()
        for action in actions {
            action()
        }
    }

    private func setScene(name: String) {
        sendRequest(type: "SetCurrentProgramScene", data: ["sceneName": name])
    }

    private func setBlackoutSource(enabled: Bool) {
        let sceneName = config.protectedScene
        let sourceName = config.blackoutSource
        sendRequest(
            type: "GetSceneItemId",
            data: [
                "sceneName": sceneName,
                "sourceName": sourceName,
            ]
        ) { [weak self] response in
            guard let self,
                  let itemId = response?["sceneItemId"] as? Int else { return }
            self.sendRequest(
                type: "SetSceneItemEnabled",
                data: [
                    "sceneName": sceneName,
                    "sceneItemId": itemId,
                    "sceneItemEnabled": enabled,
                ]
            )
        }
    }

    private func sendRequest(type: String, data: [String: Any] = [:], completion: (([String: Any]?) -> Void)? = nil) {
        guard connected, identified, let webSocket else {
            if let completion {
                pendingActions.append { self.sendRequest(type: type, data: data, completion: completion) }
            } else {
                pendingActions.append { self.sendRequest(type: type, data: data) }
            }
            connectIfNeededLocked()
            return
        }
        requestCounter += 1
        let requestId = "sg-\(requestCounter)"
        if let completion {
            pendingResponses[requestId] = completion
        }
        let payload: [String: Any] = [
            "op": 6,
            "d": [
                "requestType": type,
                "requestId": requestId,
                "requestData": data,
            ],
        ]
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
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLoop()
                case .failure:
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
            let identify: [String: Any] = [
                "op": 1,
                "d": [
                    "rpcVersion": 1,
                    "eventSubscriptions": 0,
                ],
            ]
            sendRaw(identify)
        case 2:
            identified = true
            flushPendingActions()
        case 7:
            guard let body = json["d"] as? [String: Any],
                  let requestId = body["requestId"] as? String else { return }
            let completion = pendingResponses.removeValue(forKey: requestId)
            completion?(body["responseData"] as? [String: Any])
        default:
            break
        }
    }

    private func sendRaw(_ payload: [String: Any]) {
        guard let webSocket else { return }
        sendRaw(payload, webSocket: webSocket)
    }

    private func sendRaw(_ payload: [String: Any], webSocket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            self?.queue.async {
                self?.disconnectLocked()
            }
        }
    }
}
