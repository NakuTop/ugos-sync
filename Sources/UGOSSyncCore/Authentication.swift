import Foundation
import Security

public enum NASLoginError: Error, LocalizedError {
    case passwordRejected
    public var errorDescription:String? { "NAS 未接受本次密码验证（1003）。请核对 NAS 用户名与密码；不会自动重试。" }
}

public struct CloudSession: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var username: String
}

public enum RSAEncryption {
    public static func encrypt(_ text: String, publicKey: String) throws -> String {
        var pem = publicKey
        if !pem.contains("BEGIN"), let data = Data(base64Encoded:pem), let decoded=String(data:data,encoding:.utf8),decoded.contains("BEGIN") { pem=decoded }
        let content=pem.replacingOccurrences(of:"-----BEGIN PUBLIC KEY-----",with:"")
            .replacingOccurrences(of:"-----END PUBLIC KEY-----",with:"")
            .replacingOccurrences(of:"-----BEGIN RSA PUBLIC KEY-----",with:"")
            .replacingOccurrences(of:"-----END RSA PUBLIC KEY-----",with:"")
            .filter { !$0.isWhitespace }
        guard let der=Data(base64Encoded:content) else { throw SyncError.crypto }
        let raw=try pkcs1(der)
        let attrs:[String:Any]=[kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeyClass as String:kSecAttrKeyClassPublic]
        var error:Unmanaged<CFError>?
        guard let key=SecKeyCreateWithData(raw as CFData,attrs as CFDictionary,&error),
              SecKeyIsAlgorithmSupported(key,.encrypt,.rsaEncryptionPKCS1),
              let result=SecKeyCreateEncryptedData(key,.rsaEncryptionPKCS1,Data(text.utf8) as CFData,&error) else { throw SyncError.crypto }
        return (result as Data).base64EncodedString()
    }
    /// Security accepts PKCS#1. Strip the standard SubjectPublicKeyInfo wrapper, retaining the inner RSA sequence.
    private static func pkcs1(_ data: Data) throws -> Data {
        let bytes=[UInt8](data)
        func element(_ offset:Int) throws -> (tag:UInt8,start:Int,end:Int,next:Int) {
            guard offset+2<=bytes.count else { throw SyncError.crypto }
            var p=offset+1;let first=Int(bytes[p]);p+=1;var count=first
            if first&0x80 != 0 {
                let n=first&0x7f;guard n>0,n<=4,p+n<=bytes.count else { throw SyncError.crypto }
                count=0;for b in bytes[p..<p+n] { count=count*256+Int(b) };p+=n
            }
            guard count>=0,p+count<=bytes.count else { throw SyncError.crypto }
            return (bytes[offset],p,p+count,p+count)
        }
        let outer=try element(0);guard outer.tag==0x30,outer.end==bytes.count else { throw SyncError.crypto }
        let first=try element(outer.start)
        if first.tag==0x02 { return data }
        guard first.tag==0x30 else { throw SyncError.crypto }
        let bits=try element(first.next)
        guard bits.tag==0x03,bits.start<bits.end,bytes[bits.start]==0 else { throw SyncError.crypto }
        return Data(bytes[(bits.start+1)..<bits.end])
    }
}

public actor AuthenticationClient {
    private let transport:URLSession
    public let clientID:String
    private let connectionID=String(UUID().uuidString.prefix(24))+"PC-darwin"
    public init(clientID:String=AuthenticationClient.installationID, configuration:URLSessionConfiguration?=nil) {
        self.clientID=clientID
        let c=configuration ?? URLSessionConfiguration.ephemeral;c.httpShouldSetCookies=false;c.urlCache=nil
        c.timeoutIntervalForRequest=15;c.timeoutIntervalForResource=25
        transport=URLSession(configuration:c, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    private func call(base:URL,path:String,method:String,body:JSON?=nil,form:[String:String]?=nil,token:String?=nil) async throws -> NASHTTPResult {
        guard base.scheme=="https" || (base.scheme=="http" && base.host != nil),base.user==nil,base.password==nil,base.query==nil else { throw SyncError.configuration }
        var parts=URLComponents(url:base,resolvingAgainstBaseURL:false)!
        let route=URLComponents(string:path)!
        parts.path=route.path;parts.queryItems=route.queryItems
        guard let url=parts.url else { throw SyncError.configuration }
        var req=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData);req.httpMethod=method
        req.setValue("PC/WEB",forHTTPHeaderField:"UG-Agent");req.setValue("zh-CN",forHTTPHeaderField:"Accept-Language")
        req.setValue(clientID,forHTTPHeaderField:"UG-Client-Id")
        req.setValue(connectionID,forHTTPHeaderField:"Client-Id")
        req.setValue("Mac",forHTTPHeaderField:"User-Feature")
        req.setValue("78579",forHTTPHeaderField:"Client-Version")
        req.setValue("1.20.0",forHTTPHeaderField:"Client-Version-Str")
        if let token { req.setValue(token,forHTTPHeaderField:"Authorization") }
        if let body { req.httpBody=try body.data();req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if let form {
            let boundary="UGOSSync-"+UUID().uuidString
            var text=""
            for (key,value) in form.sorted(by:{$0.key<$1.key}) {
                guard !key.contains("\r"),!key.contains("\n"),!key.contains("\"") else { throw SyncError.configuration }
                text+="--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
            }
            text+="--\(boundary)--\r\n";req.httpBody=Data(text.utf8);req.setValue("multipart/form-data; boundary="+boundary,forHTTPHeaderField:"Content-Type")
        }
        do {
            let (data,response)=try await transport.data(for:req)
            guard let http=response as? HTTPURLResponse,data.count<=2*1024*1024,http.url?.host==base.host else { throw SyncError.response }
            let headers=http.allHeaderFields.reduce(into:[String:String]()) { out,pair in out[String(describing:pair.key).lowercased()]=String(describing:pair.value) }
            // The shipped password worker reads this public-key challenge header without treating its body as a login response.
            if path == "/ugreen/v1/verify/check", headers["x-rsa-token"] != nil {
                return NASHTTPResult(body:(try? JSON.decode(data)) ?? .object([:]),headers:headers)
            }
            if [401,403].contains(http.statusCode) { throw SyncError.authentication }
            guard http.statusCode==200 else { throw SyncError.server(http.statusCode) }
            let value=try JSON.decode(data)
            guard value["code"].int==200 else {
                if [401,403,9902].contains(value["code"].int) { throw SyncError.authentication }
                throw SyncError.server(value["code"].int)
            }
            return NASHTTPResult(body:value,headers:headers)
        } catch let error as SyncError { throw error } catch { throw SyncError.unavailable }
    }
    public func challengeNAS(baseURL:URL,username:String) async throws -> (publicKey:String,code:Int) {
        let challenge=try await call(base:baseURL,path:"/ugreen/v1/verify/check",method:"POST",body:.object(["username":.string(username)]))
        guard let encoded=challenge.headers["x-rsa-token"],let keyData=Data(base64Encoded:encoded),let publicKey=String(data:keyData,encoding:.utf8) else { throw SyncError.crypto }
        return (publicKey,challenge.body["code"].int)
    }
    public func loginNAS(baseURL:URL,username:String,password:String) async throws -> NASSession {
        let publicKey=try await challengeNAS(baseURL:baseURL,username:username).publicKey
        let encrypted=try RSAEncryption.encrypt(password,publicKey:publicKey)
        let data:JSON
        do { data=try await call(base:baseURL,path:"/ugreen/v1/verify/login",method:"POST",body:.object(["username":.string(username),"password":.string(encrypted),"keepalive":.bool(true),"otp":.bool(true),"is_simple":.bool(false)])).body["data"] }
        catch SyncError.server(1003) { throw NASLoginError.passwordRejected }
        if data["enable_otp"].bool==true && data["token"].string==nil { throw SyncError.secondFactor }
        guard let token=data["token"].string,!token.isEmpty else { throw SyncError.authentication }
        return NASSession(baseURL:baseURL,access:NASAccess(apiToken:token,staticToken:data["static_token"].string,isUgk:data["is_ugk"].bool ?? false,tokenWhere:data["auth_type"].string ?? "url"),clientID:clientID,username:data["username"].string ?? username,deviceName:data["nas_name"].string ?? "NAS",serial:data["sn"].string ?? "",uid:data["uid"].int,publicKey:data["public_key"].string.flatMap { Data(base64Encoded:$0) }.flatMap { String(data:$0,encoding:.utf8) })
    }
    public func loginCloud(username:String,password:String) async throws -> CloudSession {
        let base=URL(string:"https://api.ugnas.com")!
        let seed=try await call(base:base,path:"/api/user/v3/sa/auth/seed",method:"GET").body["data"]
        guard let key=seed["encryptKey"].string,let uuid=seed["uuid"].string else { throw SyncError.response }
        var form=metadata();form["grant_type"]="password";form["username"]=try RSAEncryption.encrypt(username,publicKey:key);form["password"]=try RSAEncryption.encrypt(password,publicKey:key);form["uuid"]=uuid
        let data=try await call(base:base,path:"/api/oauth/token",method:"POST",form:form).body["data"]["accessToken"]
        guard let access=data["access_token"].string,let refresh=data["refresh_token"].string else { throw SyncError.authentication }
        return CloudSession(accessToken:access,refreshToken:refresh,username:username)
    }
    public func refreshCloud(_ session:CloudSession) async throws -> CloudSession {
        var form=metadata();form["grant_type"]="refresh_token";form["refresh_token"]=session.refreshToken
        let data=try await call(base:URL(string:"https://api.ugnas.com")!,path:"/api/oauth/token",method:"POST",form:form).body["data"]["accessToken"]
        guard let access=data["access_token"].string else { throw SyncError.authentication }
        return CloudSession(accessToken:access,refreshToken:data["refresh_token"].string ?? session.refreshToken,username:session.username)
    }
    public func devices(_ session:CloudSession) async throws -> JSON {
        try await call(base:URL(string:"https://api.ugnas.com")!,path:"/api/user/v1/bind/device?versionNo=8989",method:"GET",token:session.accessToken).body["data"]
    }
    public func resolve(alias:String) async throws -> URL {
        let data=try await call(base:URL(string:"https://api.ugnas.com")!,path:"/api/p2p/v2/ta/nodeInfo/byAlias",method:"POST",body:.object(["alias":.string(alias)])).body["data"]
        guard let domain=data["relayDomain"].string,let resolved=data["alias"].string,let url=URL(string:"https://"+resolved+"."+domain),url.host != nil else { throw SyncError.response }
        return url
    }
    public nonisolated static var installationID: String {
        let key = "UGOSSyncInstallationID"
        if let value = UserDefaults.standard.string(forKey:key) { return value }
        let value=UUID().uuidString;UserDefaults.standard.set(value,forKey:key);return value
    }
    private func metadata() -> [String:String] {
        ["platform":"Mac","clientType":"Mac","osVer":ProcessInfo.processInfo.operatingSystemVersionString,"model":"Mac","bid":Self.installationID,"alias":""]
    }
}

public enum SessionStore {
    private static let service="com.nakutop.ugos-sync.session"
    public static func saveNAS(_ value:NASSession) throws { try PrivateFiles.write(try JSONEncoder().encode(value),to:PrivateFiles.root.appendingPathComponent("nas-session.json")) }
    public static func loadNAS() throws -> NASSession { try JSONDecoder().decode(NASSession.self,from:PrivateFiles.read(PrivateFiles.root.appendingPathComponent("nas-session.json"))) }
    public static func saveCloud(_ value:CloudSession) throws { try save(try JSONEncoder().encode(value),account:"cloud") }
    public static func loadCloud() throws -> CloudSession { try JSONDecoder().decode(CloudSession.self,from:load(account:"cloud")) }
    private static func save(_ data:Data,account:String) throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var item=query;item[kSecValueData as String]=data
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw SyncError.configuration }
        } else if status != errSecSuccess { throw SyncError.configuration }
    }
    private static func load(account:String) throws -> Data {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value:CFTypeRef?;guard SecItemCopyMatching(query as CFDictionary,&value)==errSecSuccess,let data=value as? Data else { throw SyncError.authentication }
        return data
    }
}
