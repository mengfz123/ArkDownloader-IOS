import Foundation
import Network

/// Lightweight HTTP RPC server using Network framework. Mirrors the Android RpcServer API.
final class RpcServer {
    private var listener: NWListener?
    private var token: String = ""
    private var bridge: DownloadRepositoryBridge?
    private var bindHost: String = "127.0.0.1"
    private var listenPort: UInt16 = UInt16(AppSettings.defaultRpcPort)
    private let queue = DispatchQueue(label: "ark.rpc.server")
    private(set) var running: Bool = false

    func start(port: Int, rpcToken: String, remote: Bool, bridge: DownloadRepositoryBridge) {
        stop()
        self.token = rpcToken.trimmingCharacters(in: .whitespaces)
        self.bridge = bridge
        self.bindHost = remote ? "0.0.0.0" : "127.0.0.1"
        self.listenPort = UInt16(max(1, min(65535, port)))
        let parameters = NWParameters.tcp
        let portNW = NWEndpoint.Port(rawValue: self.listenPort)!
        do {
            let listener = try NWListener(using: parameters, on: portNW)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            self.running = true
        } catch {
            self.running = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    func status() -> [String: Any] {
        let remote = bindHost == "0.0.0.0" || bindHost == "::"
        let port = Int(listenPort)
        let localUrl = "http://127.0.0.1:\(port)"
        return [
            "running": running,
            "remote": remote,
            "port": port,
            "bindHost": remote ? "0.0.0.0" : "127.0.0.1",
            "localUrl": localUrl,
            "lanUrl": remote && running ? "http://\(localLanIp()):\(port)" : "",
            "tokenEnabled": !token.isEmpty
        ]
    }

    private func localLanIp() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                if let interface = ptr?.pointee {
                    let addr = interface.ifa_addr.pointee
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(addr.sa_len), &hostname,
                                    socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        let name = String(cString: hostname)
                        if name != "127.0.0.1" && !name.hasPrefix("169.254") {
                            address = name
                            break
                        }
                    }
                }
                ptr = ptr?.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        receiveLoop(connection, buffer: &buffer)
    }

    private func receiveLoop(_ connection: NWConnection, buffer: inout Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data {
                buffer.append(data)
            }
            if let error = error {
                if case .posix(let code) = error, code == .ECONNRESET {
                    connection.cancel()
                    return
                }
            }
            // Try to parse a complete HTTP request
            if let request = self.parseRequest(buffer) {
                self.dispatchRequest(connection, request: request)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveLoop(connection, buffer: &buffer)
        }
    }

    private struct HttpRequest {
        let method: String
        let path: String
        let queryItems: [URLQueryItem]
        let headers: [String: String]
        let body: String
    }

    private func parseRequest(_ data: Data) -> HttpRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else { return nil }
        let headerLines = parts[0].components(separatedBy: "\r\n")
        guard let firstLine = headerLines.first else { return nil }
        let tokens = firstLine.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        let method = tokens[0]
        let fullPath = tokens[1]
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                headers[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        // Body
        var body = ""
        if parts.count > 1 {
            body = parts.dropFirst().joined(separator: "\r\n\r\n")
        }
        // If Content-Length present and body not complete, wait
        if let cl = headers["content-length"], let len = Int(cl), body.utf8.count < len {
            return nil
        }
        // Parse path + query
        let comps = URLComponents(string: fullPath)
        let path = comps?.path ?? fullPath
        let queryItems = comps?.queryItems ?? []
        return HttpRequest(method: method, path: path, queryItems: queryItems, headers: headers, body: body)
    }

    private func dispatchRequest(_ connection: NWConnection, request: HttpRequest) {
        let response = handle(request)
        sendResponse(connection, response: response)
    }

    private func handle(_ request: HttpRequest) -> String {
        if request.method == "OPTIONS" {
            return corsResponse(httpStatus(200, body: ""))
        }
        let path = request.path.split(separator: "?")[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = "/\(path)"
        let needsAuth = cleanPath.hasPrefix("/api")
        if needsAuth && !authed(request.headers) {
            return corsResponse(gopeedErr("Invalid or missing token", http: 401, code: 1001))
        }
        guard let bridge = bridge else {
            return corsResponse(gopeedErr("服务未就绪", http: 500))
        }
        do {
            return try corsResponse(route(request, bridge: bridge))
        } catch let e as NSError where e.code == 400 {
            return corsResponse(gopeedErr(e.localizedDescription, http: 400))
        } catch {
            return corsResponse(gopeedErr(error.localizedDescription, http: 500))
        }
    }

    private func authed(_ headers: [String: String]) -> Bool {
        if token.isEmpty { return true }
        let lower = headers
        let auth = lower["authorization"] ?? ""
        if auth == "Bearer \(token)" || auth.hasPrefix("Bearer ") && auth.dropFirst(7).trimmingCharacters(in: .whitespaces) == token {
            return true
        }
        if auth == token { return true }
        if let ark = lower["x-arkdownloader-token"], ark == token { return true }
        if let pan = lower["x-panfetch-token"], pan == token { return true }
        return false
    }

    private func route(_ req: HttpRequest, bridge: DownloadRepositoryBridge) throws -> String {
        let method = req.method
        let path = req.path
        let params = Dictionary(grouping: req.queryItems, by: { $0.name }).mapValues { $0.compactMap { $0.value } }

        if method == "GET" && (path == "/health" || path == "/api/v1/info" || path == "/api/health") {
            return gopeedOk(bridge.getInfo())
        }
        if method == "POST" && (path == "/api/v1/resolve" || path == "/api/resolve") {
            let json = parseJSON(req.body)
            return gopeedOk(try bridge.resolveUrl(json))
        }
        if path == "/api/v1/config" || path == "/api/settings" {
            if method == "GET" { return gopeedOk(bridge.getSettings()) }
            if method == "PUT" {
                let json = parseJSON(req.body)
                return gopeedOk(try bridge.updateSettings(json))
            }
        }
        if method == "PUT" && (path == "/api/v1/tasks/pause" || path == "/api/tasks/pause") {
            bridge.pauseAll(); return gopeedOk(true)
        }
        if method == "PUT" && (path == "/api/v1/tasks/continue" || path == "/api/tasks/continue") {
            bridge.resumeAll(); return gopeedOk(true)
        }
        if method == "POST" && (path == "/api/v1/tasks/clear-completed" || path == "/api/tasks/clear-completed") {
            bridge.clearCompleted(); return gopeedOk(true)
        }
        if method == "DELETE" && (path == "/api/v1/tasks" || path == "/api/tasks") && (params["id"]?.isEmpty ?? true) {
            bridge.clearCompleted(); return gopeedOk(true)
        }
        if method == "POST" && (path == "/api/v1/tasks/batch" || path == "/api/tasks/batch") {
            let json = parseJSON(req.body)
            return gopeedOk(try bridge.createTasksBatch(json))
        }
        if method == "POST" && (path == "/api/v1/tasks/folder" || path == "/api/tasks/folder") {
            let json = parseJSON(req.body)
            return gopeedOk(try bridge.createFolderTasks(json))
        }
        if path == "/api/v1/tasks" || path == "/api/tasks" {
            if method == "GET" {
                let status = params["status"]?.first
                return gopeedOk(try bridge.listTasks(status))
            }
            if method == "POST" {
                let json = parseJSON(req.body)
                let id = try bridge.createTask(json)
                return gopeedOk(id)
            }
        }
        // Single task actions
        let patterns = [
            (try? NSRegularExpression(pattern: "^/api/v1/tasks/([^/]+)(?:/(pause|continue))?$"), true),
            (try? NSRegularExpression(pattern: "^/api/tasks/([^/]+)(?:/(pause|resume|continue|cancel|restart))?$"), false)
        ]
        for (regex, useV1) in patterns {
            guard let regex = regex else { continue }
            let range = NSRange(path.startIndex..., in: path)
            if let match = regex.firstMatch(in: path, range: range) {
                let idRange = Range(match.range(at: 1), in: path)!
                let id = String(path[idRange])
                var action: String? = nil
                if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
                   let aRange = Range(match.range(at: 2), in: path) {
                    action = String(path[aRange])
                }
                return try handleTaskAction(method, id: id, action: action, params: params, bridge: bridge, useV1: useV1)
            }
        }
        if method == "DELETE" && (path == "/api/v1/tasks" || path == "/api/tasks") {
            guard let id = params["id"]?.first else {
                return gopeedErr("id required", http: 400)
            }
            let deleteFiles = ["1", "true", "yes"].contains(params["file"]?.first) ||
                ["1", "true", "on", "yes"].contains(params["delete_files"]?.first)
            bridge.deleteTask(id, deleteFiles: deleteFiles)
            return gopeedOk(true)
        }
        return gopeedErr("Not Found", http: 404)
    }

    private func handleTaskAction(_ method: String, id: String, action: String?, params: [String: [String]], bridge: DownloadRepositoryBridge, useV1: Bool) throws -> String {
        guard let task = bridge.getTaskEntity(id) else {
            return gopeedErr("task not found", http: 404)
        }
        if action == nil && method == "GET" {
            return gopeedOk(useV1 ? bridge.taskToV1(task) : bridge.taskToDict(task))
        }
        if action == nil && method == "DELETE" {
            let deleteFiles = ["1", "true", "yes"].contains(params["file"]?.first) ||
                ["1", "true", "on", "yes"].contains(params["delete_files"]?.first)
            bridge.deleteTask(id, deleteFiles: deleteFiles)
            return gopeedOk(true)
        }
        if method == "PUT" || method == "POST" {
            switch action {
            case "pause": bridge.pauseTask(id); return gopeedOk(useV1 ? id : nil as Any?, message: useV1 ? nil : "Paused")
            case "continue", "resume": bridge.resumeTask(id); return gopeedOk(useV1 ? id : nil as Any?, message: useV1 ? nil : "Resumed")
            case "cancel": bridge.cancelTask(id); return gopeedOk(nil as Any?, message: "Cancelled")
            case "restart": return gopeedOk(bridge.taskToDict(bridge.restartTask(id)), message: "Restarted")
            default: return gopeedErr("Not Found", http: 404)
            }
        }
        return gopeedErr("Method Not Allowed", http: 405)
    }

    private func parseJSON(_ body: String) -> [String: Any] {
        guard !body.isEmpty,
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func sendResponse(_ connection: NWConnection, response: String) {
        let data = response.data(using: .utf8) ?? Data()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func httpStatus(_ code: Int, body: String) -> String {
        let statusText: String
        switch code {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Internal Server Error"
        }
        return "HTTP/1.1 \(code) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
    }

    private func corsResponse(_ response: String) -> String {
        // Add CORS headers to the response string (before the body)
        if let range = response.range(of: "\r\n\r\n") {
            let headers = response[..<range.lowerBound]
            let body = response[range.lowerBound...]
            let cors = "\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, X-ArkDownloader-Token, X-PanFetch-Token\r\nAccess-Control-Allow-Private-Network: true"
            return headers + cors + body
        }
        return response
    }

    private func gopeedOk(_ data: Any?, message: String? = nil) -> String {
        var obj: [String: Any] = ["code": 0, "msg": message ?? "", "data": toJsonValue(data ?? NSNull()), "success": true]
        if let m = message { obj["message"] = m }
        return jsonString(obj)
    }

    private func gopeedErr(_ msg: String, http: Int = 400, code: Int = 1000) -> String {
        let obj: [String: Any] = ["code": code, "msg": msg, "data": NSNull(), "detail": msg, "success": false]
        return jsonString(obj, httpStatus: http)
    }

    private func toJsonValue(_ value: Any) -> Any {
        switch value {
        case is NSNull: return NSNull()
        case let dict as [String: Any]: return dict.mapValues { toJsonValue($0) }
        case let arr as [Any]: return arr.map { toJsonValue($0) }
        default: return value
        }
    }

    private func jsonString(_ obj: [String: Any], httpStatus: Int = 200) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let str = String(data: data, encoding: .utf8) {
            return httpStatusStr(httpStatus, body: str)
        }
        return httpStatusStr(httpStatus, body: "{}")
    }

    private func httpStatusStr(_ code: Int, body: String) -> String {
        let statusText: String
        switch code {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Internal Server Error"
        }
        return "HTTP/1.1 \(code) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
    }
}

protocol DownloadRepositoryBridge: AnyObject {
    func getInfo() -> [String: Any?]
    func resolveUrl(_ body: [String: Any]) throws -> [String: Any?]
    func listTasks(_ status: String?) throws -> [[String: Any?]]
    func getTaskEntity(_ id: String) -> TaskEntity?
    func taskToDict(_ task: TaskEntity) -> [String: Any?]
    func taskToV1(_ task: TaskEntity) -> [String: Any?]
    func createTask(_ body: [String: Any]) throws -> String
    func createTasksBatch(_ body: [String: Any]) throws -> [String: Any?]
    func createFolderTasks(_ body: [String: Any]) throws -> [String: Any?]
    func pauseTask(_ id: String)
    func resumeTask(_ id: String)
    func cancelTask(_ id: String)
    func restartTask(_ id: String) -> TaskEntity
    func deleteTask(_ id: String, deleteFiles: Bool)
    func pauseAll()
    func resumeAll()
    func clearCompleted()
    func getSettings() -> [String: Any?]
    func updateSettings(_ body: [String: Any]) throws -> [String: Any?]
}
