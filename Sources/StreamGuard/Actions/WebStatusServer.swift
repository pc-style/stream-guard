import CryptoKit
import Foundation
import Network
import StreamGuardCore

final class WebStatusServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var webSocketConnections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "dev.pcstyle.stream-guard.web")
    private var statusProvider: () -> StatusPayload
    private var statusHTML: String
    private var controlHandler: ((String) -> Void)?

    init(
        port: UInt16 = 8765,
        statusProvider: @escaping () -> StatusPayload,
        statusHTML: String,
        controlHandler: ((String) -> Void)? = nil
    ) {
        self.port = port
        self.statusProvider = statusProvider
        self.statusHTML = statusHTML
        self.controlHandler = controlHandler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // NWListener binds to all interfaces for the selected port, equivalent to 0.0.0.0.
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        webSocketConnections.removeAll()
    }

    func broadcast(transition: StateTransition, status: StatusPayload) {
        let encoder = JSONEncoder()
        guard let statusData = try? encoder.encode(status),
              var payload = (try? JSONSerialization.jsonObject(with: statusData)) as? [String: Any] else { return }
        payload["event"] = "state_change"
        payload["previous"] = transition.previous.rawValue
        payload["state"] = transition.current.rawValue
        payload["lastMatch"] = transition.lastMatch
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let message = Self.frameMessage(opcode: 0x1, payload: data)
        for connection in webSocketConnections.values {
            connection.send(content: message, completion: .contentProcessed { _ in })
        }
    }

    private func handle(connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = Self.path(from: request)
            if request.contains("Upgrade: websocket") {
                self.handleWebSocketUpgrade(connection: connection, request: request)
            } else if path == "/control/start" {
                self.controlHandler?("start")
                self.sendJSON(on: connection, body: "{\"ok\":true,\"action\":\"start\"}")
            } else if path == "/control/stop" {
                self.controlHandler?("stop")
                self.sendJSON(on: connection, body: "{\"ok\":true,\"action\":\"stop\"}")
            } else if path == "/control/mode/full" {
                self.controlHandler?("mode/full")
                self.sendJSON(on: connection, body: "{\"ok\":true,\"action\":\"mode/full\"}")
            } else if path == "/control/mode/roi" {
                self.controlHandler?("mode/roi")
                self.sendJSON(on: connection, body: "{\"ok\":true,\"action\":\"mode/roi\"}")
            } else if path == "/control/mode/yodo" {
                self.controlHandler?("mode/yodo")
                self.sendJSON(on: connection, body: "{\"ok\":true,\"action\":\"mode/yodo\"}")
            } else if path == "/control/mode/yodo-ocr" {
                self.controlHandler?("mode/yodo-ocr")
                self.sendJSON(on: connection, body: "{\"ok\":true,\"action\":\"mode/yodo-ocr\"}")
            } else if path == "/status" {
                self.sendStatus(on: connection)
            } else if path == "/" || path == "/index" {
                self.sendHTML(on: connection)
            } else {
                self.sendNotFound(on: connection)
            }
        }
    }

    private static func path(from request: String) -> String {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
    }

    private func sendStatus(on connection: NWConnection) {
        let payload = statusProvider()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let body = try? encoder.encode(payload),
              let bodyString = String(data: body, encoding: .utf8) else { return }
        sendRawResponse(
            on: connection,
            statusLine: "HTTP/1.1 200 OK",
            contentType: "application/json",
            body: bodyString
        )
    }

    private func sendJSON(on connection: NWConnection, body: String) {
        sendRawResponse(
            on: connection,
            statusLine: "HTTP/1.1 200 OK",
            contentType: "application/json",
            body: body
        )
    }

    private func sendRawResponse(on connection: NWConnection, statusLine: String, contentType: String, body: String) {
        let response = """
        \(statusLine)\r
        Content-Type: \(contentType)\r
        Access-Control-Allow-Origin: *\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHTML(on connection: NWConnection) {
        let body = statusHTML
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendNotFound(on connection: NWConnection) {
        let body = "Not Found"
        let response = """
        HTTP/1.1 404 Not Found\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleWebSocketUpgrade(connection: NWConnection, request: String) {
        guard let keyLine = request.split(separator: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }) else {
            connection.cancel()
            return
        }
        let key = keyLine.replacingOccurrences(of: "Sec-WebSocket-Key:", with: "").trimmingCharacters(in: .whitespaces)
        let accept = Self.webSocketAccept(for: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.webSocketConnections[ObjectIdentifier(connection)] = connection
            self.receiveWebSocket(on: connection)
            let payload = self.statusProvider()
            if let data = try? JSONEncoder().encode(payload) {
                let message = Self.frameMessage(opcode: 0x1, payload: data)
                connection.send(content: message, completion: .contentProcessed { _ in })
            }
        })
    }

    private func receiveWebSocket(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.webSocketConnections.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
                return
            }
            self?.receiveWebSocket(on: connection)
        }
    }

    private static func webSocketAccept(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let hash = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(hash).base64EncodedString()
    }

    private static func frameMessage(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 65535 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }
}
