import Foundation

public struct NASDirectory: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public init(path: String, name: String) { self.path = path; self.name = name }
}
public actor NASDirectoryBrowser {
    private let client: NASClient
    public init(client: NASClient) { self.client = client }
    private func nodes(_ value: JSON) -> [NASDirectory] {
        (value.array ?? [value]).compactMap { item in
            guard let path = item["path"].string, path.hasPrefix("/"), !path.split(separator:"/").contains("..") else { return nil }
            return NASDirectory(path:path,name:item["name"].string ?? URL(fileURLWithPath:path).lastPathComponent)
        }
    }
    public func roots() async throws -> [NASDirectory] {
        let home = try await client.authenticated(method:"GET",path:"/ugreen/v1/filemgr/getHomeShare").body["data"]
        let shared = try await client.authenticated(method:"GET",path:"/ugreen/v1/filemgr/getShareList").body["data"]["result"]
        var seen = Set<String>()
        return (nodes(home)+nodes(shared)).filter { seen.insert($0.path).inserted }
    }
    public func children(of directory: NASDirectory) async throws -> [NASDirectory] {
        let body: JSON = .object(["isOnlyFolder":.bool(true),"as_dir":.bool(true),"limit":.number(2000),"page":.number(1),"path":.string(directory.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/"),"reverse":.bool(false),"sort_type":.number(1)])
        var fields = body.object!; fields["path"] = .string(directory.path.hasSuffix("/") ? directory.path : directory.path+"/")
        let result = try await client.authenticated(method:"POST",path:"/ugreen/v1/filemgr/getDirFileList",body:.object(fields)).body["data"]["files"]
        guard let files = result.array else { throw SyncError.response }
        return files.compactMap { item in
            guard let name = item["name"].string, !name.contains("/"), name != ".", name != ".." else { return nil }
            return NASDirectory(path:item["path"].string ?? directory.path+"/"+name,name:name)
        }
    }
    public func isWritable(path: String) async throws -> Bool {
        let data = try await client.authenticated(method:"GET",path:"/ugreen/v1/filemgr/queryWritable",parameters:["path":path]).body["data"]
        if let value = data.bool ?? data["writable"].bool ?? data["isWritable"].bool ?? data["result"].bool { return value }
        return true // The original picker checks API success, not a payload boolean.
    }
}
