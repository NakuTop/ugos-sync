import Foundation
import CryptoKit

public struct NASAccess: Codable, Sendable {
    public var apiToken: String
    public var staticToken: String
    public var isUgk: Bool
    public var tokenWhere: String
    public init(apiToken: String, staticToken: String? = nil, isUgk: Bool = false, tokenWhere: String = "url") {
        self.apiToken = apiToken; self.staticToken = staticToken ?? apiToken; self.isUgk = isUgk; self.tokenWhere = tokenWhere
    }
}

public struct NASSession: Codable, Sendable {
    public var baseURL: URL
    public var access: NASAccess
    public var clientID: String
    public var username: String
    public var deviceName: String
    public var serial: String
    public var uid: Int
    public var publicKey: String?
    public init(baseURL: URL, access: NASAccess, clientID: String, username: String = "", deviceName: String = "NAS", serial: String = "", uid: Int = 0, publicKey: String? = nil) {
        self.baseURL = baseURL; self.access = access; self.clientID = clientID
        self.username = username; self.deviceName = deviceName; self.serial = serial; self.uid = uid; self.publicKey = publicKey
    }
}

public struct NASHTTPResult: Sendable {
    public let body: JSON
    public let headers: [String: String]
}

public actor NASClient: EngineAPI {
    private let connectionID = String(UUID().uuidString.prefix(24))+"PC-darwin"
    private var identity: NASSession
    private var engineKey: String?
    private let transport: URLSession
    public init(session: NASSession) throws {
        guard ["https", "http"].contains(session.baseURL.scheme), session.baseURL.host != nil,
              session.baseURL.user == nil, session.baseURL.password == nil, session.baseURL.query == nil,
              !session.access.apiToken.isEmpty else { throw SyncError.configuration }
        identity = session
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.urlCache = nil
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25
        transport = URLSession(configuration: c, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    public func session() -> NASSession { identity }
    public func replaceSession(_ value: NASSession) { identity = value; engineKey = nil }

    public func authenticated(method: String, path: String, body: JSON? = nil, parameters: [String: String] = [:], downstreamKey: String? = nil) async throws -> NASHTTPResult {
        var parts = URLComponents(url: identity.baseURL, resolvingAgainstBaseURL: false)!
        parts.path = identity.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !parts.path.hasPrefix("/") { parts.path = "/" + parts.path }
        var query = parameters
        if identity.access.tokenWhere != "header" || (path.contains("/syncthing/") || path.hasSuffix("/is_login")) { query["token"] = identity.access.apiToken }
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw SyncError.configuration }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.setValue("PC/WEB", forHTTPHeaderField: "UG-Agent")
        req.setValue("Mac", forHTTPHeaderField: "User-Feature")
        req.setValue(connectionID, forHTTPHeaderField: "Client-Id")
        req.setValue("1.20.0", forHTTPHeaderField: "Client-Version-Str")
        req.setValue("78579", forHTTPHeaderField: "Client-Version")
        req.setValue("zh-CN", forHTTPHeaderField: "X-Specify-Language")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue(identity.clientID, forHTTPHeaderField: "UG-Client-Id")
        req.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        if identity.access.tokenWhere == "header" { req.setValue(identity.access.apiToken, forHTTPHeaderField: "X-Ugreen-Token") }
        if path.hasPrefix("/ugreen/v1/filemgr/") || path == "/ugreen/v1/verify/refresh" {
            guard identity.baseURL.scheme == "https", let publicKey=identity.publicKey else { throw SyncError.authentication }
            req.setValue(Insecure.MD5.hash(data:Data(identity.access.apiToken.utf8)).map { String(format:"%02x",$0) }.joined(),forHTTPHeaderField:"X-Ugreen-Security-Key")
            if identity.access.tokenWhere == "header" {
                req.setValue(try RSAEncryption.encrypt(identity.access.apiToken,publicKey:publicKey),forHTTPHeaderField:"X-Ugreen-Token")
            }
        }
        if let key = downstreamKey { req.setValue(key, forHTTPHeaderField: "X-API-Key") }
        if let body { req.httpBody = try body.data(); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await transport.data(for: req)
            guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else { throw SyncError.response }
            guard http.url?.host == identity.baseURL.host else { throw SyncError.authentication }
            if [401,403].contains(http.statusCode) { throw SyncError.authentication }
            guard (200...299).contains(http.statusCode) else { throw SyncError.server(http.statusCode) }
            let value = data.isEmpty ? JSON.object([:]) : try JSON.decode(data)
            if case .number(let n) = value["code"], Int(n) != 200 && Int(n) != 0 {
                if [401,403,9902].contains(Int(n)) { throw SyncError.authentication }
                throw SyncError.server(Int(n))
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in result[String(describing: pair.key).lowercased()] = String(describing: pair.value) }
            return NASHTTPResult(body: value, headers: headers)
        } catch let error as SyncError { throw error }
        catch { throw SyncError.unavailable } // Never include authenticated URLs in diagnostic text.
    }

    public func loadEngineKey() async throws -> String {
        if let key = engineKey { return key }
        for path in ["/ugreen/v1/sync/syncthing/apiKey", "/ugreen/v1/web/sync/syncthing/apiKey"] {
            do {
                let value = try await authenticated(method: "GET", path: path).body
                guard let key = value["data"]["result"].string ?? value["data"].string, !key.isEmpty else { continue }
                engineKey = key; return key
            } catch { continue }
        }
        throw SyncError.unavailable
    }

    public func request(method: String, route: String, body: JSON? = nil) async throws -> JSON {
        guard route.hasPrefix("/rest/") else { throw SyncError.configuration }
        let key = try await loadEngineKey()
        let routeParts = URLComponents(string: route)
        let params = Dictionary(uniqueKeysWithValues: (routeParts?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let value = try await authenticated(method: method, path: "/ugreen/v1/web/sync/syncthing/proxy" + (routeParts?.path ?? route), body: body, parameters: params, downstreamKey: key).body
        return Self.unwrapEngine(value)
    }

    public static func unwrapEngine(_ input: JSON) -> JSON {
        var value = input
        let markers: Set<String> = ["myID","devices","folders","ping","errors","globalBytes","inSyncBytes","needTotalItems","connections","random","progress","files","id","path","isConfigSynced","inSync"]
        for _ in 0..<8 {
            if let text = value.string, let data = text.data(using: .utf8), let parsed = try? JSON.decode(data) { value = parsed; continue }
            guard let obj = value.object else { return value }
            if !markers.isDisjoint(with: obj.keys) { return value }
            if let data = obj["data"] { value = data; continue }
            if let result = obj["result"] { value = result; continue }
            return value
        }
        return value
    }

    public func readSmallFile(path: String, maximum: Int = 131072) async throws -> Data {
        let metadata = try await authenticated(method:"GET",path:"/ugreen/v1/filemgr/queryPathInfo",parameters:["path":path]).body["data"]
        guard let size=metadata["size"].object == nil ? Optional(metadata["size"].int) : nil, size >= 0, size <= maximum else { throw SyncError.response }
        var parts=URLComponents(url:identity.baseURL,resolvingAgainstBaseURL:false)!
        parts.path="/ugreen/v1/filemgr/downloadFile"
        parts.queryItems=[URLQueryItem(name:"paths",value:path),URLQueryItem(name:"token",value:identity.access.apiToken),URLQueryItem(name:"coding",value:"true")]
        var req=URLRequest(url:parts.url!);req.setValue("Mac",forHTTPHeaderField:"User-Feature")
        req.setValue("bytes=0-\(max(0,size-1))",forHTTPHeaderField:"Range")
        do {
            let (data,response)=try await transport.data(for:req)
            guard let http=response as? HTTPURLResponse,[200,206].contains(http.statusCode),data.count<=maximum else { throw SyncError.response }
            return data
        } catch let error as SyncError { throw error } catch { throw SyncError.unavailable }
    }

    public func webSocketURL() throws -> URL {
        var parts = URLComponents(url: identity.baseURL, resolvingAgainstBaseURL: false)!
        parts.scheme = identity.baseURL.scheme == "https" ? "wss" : "ws"
        parts.path = "/ugreen/v1/web/sync/ws"
        parts.queryItems = [URLQueryItem(name: "client_id", value: connectionID), URLQueryItem(name: "lang", value: "zh-CN"), URLQueryItem(name: identity.access.isUgk ? "ugk" : "token", value: identity.access.isUgk ? identity.access.staticToken : identity.access.apiToken)]
        guard let url = parts.url else { throw SyncError.configuration }; return url
    }

    public func refreshSession() async throws -> NASSession {
        let result = try await authenticated(method: "PUT", path: "/ugreen/v1/verify/refresh").body["data"]
        if let token = result["token"].string, !token.isEmpty {
            identity.access = NASAccess(apiToken: token, staticToken: result["static_token"].string ?? identity.access.staticToken, isUgk: result["is_ugk"].bool ?? identity.access.isUgk, tokenWhere: result["auth_type"].string ?? identity.access.tokenWhere)
            if let encoded=result["public_key"].string,let raw=Data(base64Encoded:encoded),let key=String(data:raw,encoding:.utf8) { identity.publicKey=key }
            engineKey = nil
        }
        return identity
    }
}

public actor NASHeartbeat {
    private let client: NASClient
    private let localID: String
    private var stopped = false
    private var socket: URLSessionWebSocketTask?
    private var sender: URLSession?
    private var messages = 0
    private var connectedAt: Date?
    public init(client: NASClient, localID: String) { self.client = client; self.localID = localID }
    public func stop() { stopped = true; socket?.cancel(with: .goingAway, reason: nil) }
    public func statistics() -> (messages: Int, connectedAt: Date?) { (messages, connectedAt) }
    public func reconnect() { socket?.cancel(with:.goingAway,reason:nil) }
    public func run(onState: @Sendable @escaping (String) async -> Void) async {
        var retries = 0
        while !stopped && !Task.isCancelled {
            do {
                let url = try await client.webSocketURL()
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 10
                let session = URLSession(configuration: config); sender = session
                let task = session.webSocketTask(with: url); socket = task; task.resume()
                let receiver = Task { [weak self] in
                    while !Task.isCancelled {
                        _ = try await task.receive()
                        await self?.received()
                    }
                }
                defer { receiver.cancel(); task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel(); socket = nil }
                var lastSubscribe = Date.distantPast
                while !stopped && !Task.isCancelled {
                    let heartbeat = try JSON.object(["msg_type":.string("cli_hb"),"uuid":.string(localID)]).data()
                    try await task.send(.string(String(decoding: heartbeat, as: UTF8.self)))
                    if connectedAt == nil { connectedAt = Date() }
                    retries = 0
                    await onState("online")
                    if Date().timeIntervalSince(lastSubscribe) >= 30 {
                        try await task.send(.string("{\"type\":\"subscribe\",\"msg\":\"\"}"))
                        lastSubscribe = Date()
                    }
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                }
            } catch {
                connectedAt = nil
                await onState("reconnecting")
                let delay = [5,15,30][min(retries,2)]; retries += 1
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
        await onState("stopped")
    }
    private func received() { messages += 1 }
}
