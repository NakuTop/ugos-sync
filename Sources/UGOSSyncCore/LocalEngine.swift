import Foundation
import CryptoKit
import CommonCrypto
import Darwin

public struct EngineSettings: Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var engineSHA256: String
    public var configurationDirectory: String
    public var workDirectory: String
    public var guiPort: Int
    public var statusFile: String
    public static func load(_ url: URL) throws -> Self {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == getuid(), st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              st.st_mode & 0o077 == 0, st.st_size <= 65536 else { throw SyncError.configuration }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard (1...65535).contains(value.guiPort), value.configurationDirectory.hasPrefix("/"),
              value.arguments.contains(where: { $0.hasSuffix("=127.0.0.1:\(value.guiPort)") }),
              !value.arguments.contains(where: { $0.hasPrefix("--reset") || $0.hasPrefix("-reset") }),
              value.arguments.count <= 40 else { throw SyncError.configuration }
        return value
    }
    public func verifyVendorEngine() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format:"%02x",$0) }).joined() == engineSHA256 else { throw SyncError.configuration }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/codesign")
        process.arguments = ["--verify","--strict",executable]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SyncError.configuration }
    }
}

private final class KeyParser: NSObject, XMLParserDelegate {
    var path: [String] = []; var key = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) { path.append(name) }
    func parser(_ parser: XMLParser, foundCharacters text: String) { if path.suffix(2) == ["gui","apikey"] { key += text } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !path.isEmpty { path.removeLast() } }
}

public actor LocalEngineClient: EngineAPI {
    public let settings: EngineSettings
    private let key: String
    private let transport: URLSession
    public init(settings: EngineSettings) throws {
        self.settings = settings
        guard let argument = settings.arguments.first(where: { $0.hasPrefix("-secretkey=") || $0.hasPrefix("--secretkey=") }), let separator = argument.firstIndex(of:"=") else { throw SyncError.configuration }
        let secret = String(argument[argument.index(after: separator)...])
        let raw = try Data(contentsOf: URL(fileURLWithPath: settings.configurationDirectory).appendingPathComponent("config.xml"))
        guard raw.count >= 48, raw.count <= 4 * 1024 * 1024, raw.count % 16 == 0,
              Data(Insecure.MD5.hash(data: raw.dropLast(16))) == raw.suffix(16) else { throw SyncError.crypto }
        let aes = Data(Insecure.MD5.hash(data: Data((secret + "ugos").utf8)))
        let iv = Data(raw.prefix(16)); let cipher = Data(raw.dropFirst(16).dropLast(16))
        var plain = Data(count:cipher.count+kCCBlockSizeAES128); let capacity = plain.count; var moved = 0
        let status = plain.withUnsafeMutableBytes { output in cipher.withUnsafeBytes { input in aes.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(kCCDecrypt),CCAlgorithm(kCCAlgorithmAES),CCOptions(kCCOptionPKCS7Padding),k.baseAddress,aes.count,v.baseAddress,input.baseAddress,cipher.count,output.baseAddress,capacity,&moved)
        }}}}
        guard status == kCCSuccess, moved >= 4 else { throw SyncError.crypto }
        plain.count = moved
        guard plain.suffix(4) == Data("ugos".utf8) else { throw SyncError.crypto }
        let reader = KeyParser(); let parser = XMLParser(data:plain.dropLast(4)); parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !reader.key.isEmpty else { throw SyncError.crypto }
        key = reader.key.trimmingCharacters(in:.whitespacesAndNewlines)
        let c = URLSessionConfiguration.ephemeral; c.connectionProxyDictionary = [:]; c.urlCache = nil
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 8
        transport = URLSession(configuration:c)
    }
    public func request(method: String, route: String, body: JSON? = nil) async throws -> JSON {
        guard route.hasPrefix("/rest/"),let url=URL(string:"http://127.0.0.1:\(settings.guiPort)"+route) else { throw SyncError.configuration }
        var req=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData);req.httpMethod=method
        req.setValue(key,forHTTPHeaderField:"X-API-Key")
        if let body { req.httpBody=try body.data();req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        do {
            let (data,response)=try await transport.data(for:req)
            guard let http=response as? HTTPURLResponse,http.statusCode==200,data.count <= 4*1024*1024 else { throw SyncError.response }
            return data.isEmpty ? .object([:]) : try JSON.decode(data)
        } catch let error as SyncError { throw error } catch { throw SyncError.unavailable }
    }
}

public enum PrivateFiles {
    public static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UGOSSync") }
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".write-"+UUID().uuidString)
        let descriptor=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor>=0 else { throw SyncError.configuration }
        let file=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        do { try file.write(contentsOf:data);try file.close();guard rename(temporary.path,url.path)==0 else { throw SyncError.configuration } }
        catch { try? file.close();try? FileManager.default.removeItem(at:temporary);throw error }
    }
    public static func read(_ url: URL, maximum: Int=65536) throws -> Data {
        var st=stat()
        guard lstat(url.path,&st)==0,st.st_uid==getuid(),st.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),st.st_mode & 0o077==0,st.st_size<=maximum else { throw SyncError.configuration }
        return try Data(contentsOf:url)
    }
}

public enum SessionImport {
    public static func candidateSessions(_ url: URL) throws -> [NASSession] {
        let value=try JSON.decode(PrivateFiles.read(url))
        let a=value["accessInfo"]
        guard let token=a["api_token"].string,!token.isEmpty else { throw SyncError.configuration }
        let access=NASAccess(apiToken:token,staticToken:a["static_token"].string,isUgk:a["is_ugk"].bool ?? false,tokenWhere:a["token_where"].string ?? "url")
        let user=value["user"]; let id=value["clientID"].string ?? String(UUID().uuidString.dropLast(12))+"PC-darwin"
        return (value["candidateBaseURLs"].array ?? []).compactMap { item in
            guard let text=item.string,let base=URL(string:text) else { return nil }
            return NASSession(baseURL:base,access:access,clientID:id,username:user["username"].string ?? "",deviceName:user["nas_name"].string ?? "NAS",serial:user["deviceSn"].string ?? "",uid:user["uid"].int,publicKey:value["publicKey"].string)
        }
    }
}
