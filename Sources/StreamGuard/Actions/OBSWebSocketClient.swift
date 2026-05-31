import Foundation
import Network
import StreamGuardCore

final class OBSWebSocketClient: @unchecked Sendable {
    private var config: OBSConfig
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "dev.pcstyle.stream-guard.obs")
    private var previousScene: String?
    private var connected = false
    private var identified = false
    private var receiveBuffer = Data()
    private var requestCounter = 0

    init(config: OBSConfig) {
        self.config = config
    }

    func updateConfig(_ config: OBSConfig) {
        self.config = config
        if config.enabled {
            connectIfNeeded()
        } else {
            disconnect()
        }
    }

    func connectIfNeeded() {
        guard config.enabled, connection == nil else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(config.port))
        )
        let parameters = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connected = true
                self?.receiveLoop()
            case .failed, .cancelled:
                self?.connected = false
                self?.identified = false
                self?.connection = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connected = false
        identified = false
        receiveBuffer.removeAll()
    }

    func onArmed() {
        guard config.enabled else { return }
        connectIfNeeded()
        sendRequest(type: "GetCurrentProgramScene") { [weak self] response in
            if let sceneName = response?["currentProgramSceneName"] as? String {
                self?.previousScene = sceneName
            }
            self?.setScene(name: self?.config.blackoutScene ?? "BLACKOUT")
        }
    }

    func onClear() {
        guard config.enabled, let previousScene else { return }
        setScene(name: previousScene)
        self.previousScene = nil
    }

    private func setScene(name: String) {
        sendRequest(type: "SetCurrentProgramScene", data: ["sceneName": name])
    }

    private func sendRequest(type: String, data: [String: Any] = [:], completion: (([String: Any]?) -> Void)? = nil) {
        guard connected else { return }
        requestCounter += 1
        let requestId = "sg-\(requestCounter)"
        let payload: [String: Any] = [
            "op": 6,
            "d": [
                "requestType": type,
                "requestId": requestId,
                "requestData": data,
            ],
        ]
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: json, encoding: .utf8) {
            connection?.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in })
        }
        _ = completion
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data {
                self.receiveBuffer.append(data)
                self.processMessages()
            }
            if isComplete {
                self.disconnect()
            } else {
                self.receiveLoop()
            }
        }
    }

    private func processMessages() {
        guard let text = String(data: receiveBuffer, encoding: .utf8) else { return }
        let chunks = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        receiveBuffer.removeAll()
        if !text.hasSuffix("\n"), let last = chunks.last {
            receiveBuffer = Data(last.utf8)
        }
        for chunk in chunks.dropLast(text.hasSuffix("\n") ? 0 : (chunks.isEmpty ? 0 : 1)) {
            handleMessage(chunk)
        }
        if text.hasSuffix("\n"), let last = chunks.last {
            handleMessage(last)
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
        default:
            break
        }
    }

    private func sendRaw(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        connection?.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in })
    }
}
