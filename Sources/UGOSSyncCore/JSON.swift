import Foundation

public enum JSON: Codable, Sendable, Equatable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else { self = .array(try c.decode([JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { object?[key] ?? .null }
    public var object: [String: JSON]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSON]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var int: Int { if case .number(let v) = self { return Int(v) }; return 0 }
    public static func decode(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
}

public protocol EngineAPI: Sendable {
    func request(method: String, route: String, body: JSON?) async throws -> JSON
}

public enum SyncError: Error, LocalizedError {
    case configuration, unavailable, authentication, secondFactor, server(Int), response, unsafePath, crypto
    public var errorDescription: String? {
        switch self {
        case .configuration: return "同步配置不完整"
        case .unavailable: return "暂时无法连接，请检查网络"
        case .authentication: return "登录已失效，请重新登录"
        case .secondFactor: return "此账号需要完成验证码验证"
        case .server(let code): return "服务返回错误（\(code)）"
        case .response: return "服务返回的数据无法识别"
        case .unsafePath: return "请选择可读写且不重复的文件夹"
        case .crypto: return "无法完成账号加密"
        }
    }
}
