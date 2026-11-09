import Foundation
import Network

struct Reply {
    let status: Int
    let body: [String: Any]
    static func error(_ status: Int, _ message: String) -> Self {
        Self(status: status, body: ["error": message])
    }
}

@MainActor
final class ImportServer {
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private let submit: (String, Data) -> Reply

    init(status: @escaping @MainActor @Sendable (String) -> Void, submit: @escaping (String, Data) -> Reply) {
        self.submit = submit
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18765)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: status("正在监听")
                    case .failed(let error), .waiting(let error): status("无法监听：\(error.localizedDescription)")
                    case .cancelled: status("已停止")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch { status("无法监听：\(error.localizedDescription)") }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection: connection, submit: submit) { [weak self] in
            self?.clients[id] = nil
        }
        clients[id] = client
        client.start()
    }

    deinit { listener?.cancel() }
}

@MainActor
private final class Client {
    private let connection: NWConnection
    private let submit: (String, Data) -> Reply
    private let done: () -> Void
    private var data = Data()
    private var request: (length: Int, token: String)?
    private var closed = false
    private let maxHeader = 8192
    private let maxBody = 1_048_576

    init(connection: NWConnection, submit: @escaping (String, Data) -> Reply, done: @escaping () -> Void) {
        self.connection = connection
        self.submit = submit
        self.done = done
    }

    func start() {
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.close() }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let bytes { self.data.append(bytes) }
                if self.process() { return }
                if complete || error != nil { self.close() }
                else { self.receive() }
            }
        }
    }

    private func process() -> Bool {
        if request == nil {
            guard let delimiter = data.range(of: Data([13, 10, 13, 10])) else {
                return data.count > maxHeader ? respond(.error(431, "请求头过大")) : false
            }
            guard delimiter.lowerBound <= maxHeader else { return respond(.error(431, "请求头过大")) }
            guard let head = String(data: data[..<delimiter.lowerBound], encoding: .utf8) else {
                return respond(.error(400, "请求头无效"))
            }
            data = Data(data[delimiter.upperBound...])
            let lines = head.components(separatedBy: "\r\n")
            let line = lines[0].split(separator: " ")
            guard line.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(line[2]) else {
                return respond(.error(400, "请求行无效"))
            }
            guard line[1] == "/competitions" else { return respond(.error(404, "接口不存在")) }
            guard line[0] == "POST" else { return respond(.error(405, "请使用 POST")) }
            var headers: [String: String] = [:]
            for header in lines.dropFirst() {
                guard let colon = header.firstIndex(of: ":") else { return respond(.error(400, "请求头无效")) }
                let key = header[..<colon].lowercased()
                guard headers[key] == nil else { return respond(.error(400, "请求头重复")) }
                headers[key] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let auth = headers["authorization"], auth.hasPrefix("Bearer ") else {
                return respond(.error(401, "需要 Bearer Token"))
            }
            guard headers["transfer-encoding"] == nil,
                  let value = headers["content-length"], let length = Int(value), length >= 0 else {
                return respond(.error(400, "需要有效的 Content-Length"))
            }
            guard length <= maxBody else { return respond(.error(413, "JSON 超过 1 MiB")) }
            if headers["expect"] != nil { return respond(.error(417, "不支持 Expect 请求头")) }
            request = (length, String(auth.dropFirst(7)))
        }
        guard let request, data.count >= request.length else { return false }
        return respond(submit(request.token, Data(data.prefix(request.length))))
    }

    @discardableResult
    private func respond(_ reply: Reply) -> Bool {
        let body = (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data("{}".utf8)
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       405: "Method Not Allowed", 413: "Content Too Large", 417: "Expectation Failed",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        let extra = reply.status == 405 ? "Allow: POST\r\n" : ""
        var response = Data("HTTP/1.1 \(reply.status) \(reasons[reply.status] ?? "Error")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        return true
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        done()
    }
}
