import Foundation

public enum SyncDirection: String, Codable, Sendable, CaseIterable {
    case upload, download, bidirectional
    var localType: String { self == .upload ? "sendonly" : self == .download ? "receiveonly" : "sendreceive" }
    var nasType: String { self == .upload ? "receiveonly" : self == .download ? "sendonly" : "sendreceive" }
}

public struct FolderMappingSpec: Sendable {
    public let localPath: String
    public let nasPath: String
    public let name: String
    public let direction: SyncDirection
    public init(localPath: String, nasPath: String, name: String, direction: SyncDirection) {
        self.localPath = localPath; self.nasPath = nasPath; self.name = name; self.direction = direction
    }
}

public enum FolderPairingError: Error, LocalizedError {
    case uncertainCreation(String)
    case busy, invalidConfiguration, overlappingPath(String), localCreationFailed(String), pauseFailed(String), rollbackFailed(local: String, rollback: String)
    public var errorDescription: String? {
        switch self {
        case .uncertainCreation(let id): return "目录创建结果尚未确认，请先检查映射状态：\(id)"
        case .busy: return "目录映射操作正在进行，请稍后重试"
        case .invalidConfiguration: return "同步引擎配置不完整"
        case .overlappingPath(let path): return "该目录与已有同步目录重复或重叠：\(path)"
        case .localCreationFailed(let reason): return "本地创建失败，已撤销本次 NAS 目录映射：\(reason)"
        case .pauseFailed(let reason): return "本地暂停状态更新失败，已恢复 NAS 的原状态：\(reason)"
        case .rollbackFailed(let local, let rollback): return "本地操作失败（\(local)）；NAS 回滚失败（\(rollback)），请检查映射状态"
        }
    }
}

/// Actor serialization prevents concurrent creations in this client from using stale snapshots.
public actor FolderPairer {
    private let local: any EngineAPI
    private let nas: any EngineAPI
    private var changing = false
    public init(local: any EngineAPI, nas: any EngineAPI) { self.local = local; self.nas = nas }

    public func create(_ spec: FolderMappingSpec) async throws -> String {
        guard !changing else { throw FolderPairingError.busy }
        changing = true
        defer { changing = false }
        let localPath = URL(fileURLWithPath:try Self.validatedPath(spec.localPath)).resolvingSymlinksInPath().path
        let nasPath = try Self.validatedPath(spec.nasPath)
        guard !spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SyncError.configuration }
        let localConfig = try await local.request(method: "GET", route: "/rest/config", body: nil)
        let nasConfig = try await nas.request(method: "GET", route: "/rest/config", body: nil)
        try Self.rejectOverlap(localPath, in: localConfig, localFilesystem:true)
        try Self.rejectOverlap(nasPath, in: nasConfig)
        let localStatus = try await local.request(method: "GET", route: "/rest/system/status", body: nil)
        let nasStatus = try await nas.request(method: "GET", route: "/rest/system/status", body: nil)
        guard let localID = localStatus["myID"].string, !localID.isEmpty,
              let nasID = nasStatus["myID"].string, !nasID.isEmpty, localID != nasID else { throw FolderPairingError.invalidConfiguration }
        let localDefaults = try await Self.defaults("folder", config:localConfig, engine:local)
        let nasDefaults = nasConfig["defaults"]["folder"].object.map(JSON.object) ?? localDefaults
        guard localDefaults.object != nil, nasDefaults.object != nil else { throw FolderPairingError.invalidConfiguration }
        let id = "ugos-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await Self.ensureDevice(nasID, config: localConfig, engine: local)
        let fallbackDevice = nasConfig["devices"].array?.contains(where:{$0["deviceID"].string == localID}) == true ? nil : try await Self.defaults("device",config:localConfig,engine:local)
        try await Self.ensureDevice(localID, config: nasConfig, engine: nas, fallback:fallbackDevice)
        let remoteFolder = Self.folder(defaults: nasDefaults, id: id, path: nasPath, name: spec.name,
                                     type: spec.direction.nasType, devices: [localID, nasID])
        let localFolder = Self.folder(defaults: localDefaults, id: id, path: localPath, name: spec.name,
                                    type: spec.direction.localType, devices: [localID, nasID])
        do { _ = try await nas.request(method: "POST", route: "/rest/config/folders", body: remoteFolder) }
        catch {
            guard let snapshot=try? await nas.request(method:"GET",route:"/rest/config",body:nil),let folders=snapshot["folders"].array else { throw FolderPairingError.uncertainCreation(id) }
            guard folders.contains(where:{$0["id"].string==id && $0["path"].string==nasPath}) else { throw error }
        }
        do {
            _ = try await local.request(method: "POST", route: "/rest/config/folders", body: localFolder)
        } catch {
            let cause = error.localizedDescription
            guard let snapshot=try? await local.request(method:"GET",route:"/rest/config",body:nil),let folders=snapshot["folders"].array else { throw FolderPairingError.uncertainCreation(id) }
            if folders.contains(where:{$0["id"].string==id && $0["path"].string==localPath}) { return id }
            // Only this freshly generated ID is removed; existing devices and folders are untouched.
            do {
                do { _ = try await nas.request(method:"DELETE",route:"/rest/config/folders/\(id)",body:nil) }
                catch {
                    let current=try await nas.request(method:"GET",route:"/rest/config",body:nil)
                    guard var fields=current.object,let existing=current["folders"].array else { throw SyncError.response }
                    if let fresh=existing.first(where:{$0["id"].string==id}) {
                        guard fresh["path"].string==nasPath else { throw SyncError.configuration }
                        fields["folders"] = .array(existing.filter { $0["id"].string != id })
                        _=try await nas.request(method:"PUT",route:"/rest/config",body:.object(fields))
                        let after=try await nas.request(method:"GET",route:"/rest/config",body:nil)
                        guard after["folders"].array?.contains(where:{$0["id"].string==id}) == false else { throw SyncError.response }
                    }
                }
            }
            catch { throw FolderPairingError.rollbackFailed(local: cause, rollback: error.localizedDescription) }
            throw FolderPairingError.localCreationFailed(cause)
        }
        return id
    }

    public func pause(folderID: String, paused: Bool) async throws {
        guard !changing else { throw FolderPairingError.busy }
        changing = true
        defer { changing = false }
        guard !folderID.isEmpty, folderID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw SyncError.configuration }
        let route = "/rest/config/folders/\(folderID)"
        let lc=try await local.request(method:"GET",route:"/rest/config",body:nil)
        let nc=try await nas.request(method:"GET",route:"/rest/config",body:nil)
        let oldLocal=lc["folders"].array?.first(where:{$0["id"].string==folderID}) ?? .null
        let oldNAS=nc["folders"].array?.first(where:{$0["id"].string==folderID}) ?? .null
        guard oldLocal["id"].string == folderID, oldNAS["id"].string == folderID,
              let prior = oldNAS["paused"].bool else { throw FolderPairingError.invalidConfiguration }
        var changed=oldNAS.object!;changed["paused"] = .bool(paused)
        _ = try await nas.request(method:"POST",route:"/rest/config/folders",body:.object(changed))
        do { _ = try await local.request(method: "PATCH", route: route, body: .object(["paused": .bool(paused)])) }
        catch {
            let cause = error.localizedDescription
            do { var restored=oldNAS.object!;restored["paused"] = .bool(prior);_ = try await nas.request(method:"POST",route:"/rest/config/folders",body:.object(restored)) }
            catch { throw FolderPairingError.rollbackFailed(local: cause, rollback: error.localizedDescription) }
            throw FolderPairingError.pauseFailed(cause)
        }
    }

    public func mappings() async throws -> [JSON] {
        let localConfig = try await local.request(method: "GET", route: "/rest/config", body: nil)
        let nasConfig = try await nas.request(method: "GET", route: "/rest/config", body: nil)
        guard let localFolders = localConfig["folders"].array, let nasFolders = nasConfig["folders"].array else { throw FolderPairingError.invalidConfiguration }
        let remote = Dictionary(nasFolders.compactMap { f in f["id"].string.map { ($0, f) } }, uniquingKeysWith: { first, _ in first })
        return localFolders.compactMap { f in
            guard let id = f["id"].string, let n = remote[id] else { return nil }
            return .object(["id": .string(id), "local": f, "nas": n])
        }
    }

    private static func validatedPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              !path.split(separator: "/").contains("..") else { throw SyncError.unsafePath }
        let normalized = (path as NSString).standardizingPath
        guard normalized.hasPrefix("/"), normalized != "/" else { throw SyncError.unsafePath }
        return normalized
    }
    private static func rejectOverlap(_ path: String, in config: JSON, localFilesystem:Bool = false) throws {
        guard let folders = config["folders"].array, config["devices"].array != nil else { throw FolderPairingError.invalidConfiguration }
        for folder in folders {
            guard let raw = folder["path"].string else { throw FolderPairingError.invalidConfiguration }
            let existing = localFilesystem ? URL(fileURLWithPath:raw).resolvingSymlinksInPath().path : (raw as NSString).standardizingPath
            if path == existing || path.hasPrefix(existing == "/" ? "/" : existing + "/") || existing.hasPrefix(path + "/") {
                throw FolderPairingError.overlappingPath(path)
            }
        }
    }
    private static func defaults(_ kind:String,config:JSON,engine:any EngineAPI) async throws -> JSON {
        if let fields=config["defaults"][kind].object { return .object(fields) }
        return try await engine.request(method:"GET",route:"/rest/config/defaults/"+kind,body:nil)
    }
    private static func ensureDevice(_ id: String, config: JSON, engine: any EngineAPI, fallback:JSON? = nil) async throws {
        if config["devices"].array?.contains(where: { $0["deviceID"].string == id }) == true { return }
        let defaults:JSON
        if let fields=config["defaults"]["device"].object { defaults = .object(fields) }
        else if let fallback { defaults=fallback }
        else { defaults=try await Self.defaults("device",config:config,engine:engine) }
        guard var device = defaults.object else { throw FolderPairingError.invalidConfiguration }
        device["deviceID"] = .string(id)
        _ = try await engine.request(method: "POST", route: "/rest/config/devices", body: .object(device))
    }
    private static func folder(defaults: JSON, id: String, path: String, name: String, type: String, devices: [String]) -> JSON {
        var value = defaults.object!
        value["id"] = .string(id); value["path"] = .string(path); value["label"] = .string(name)
        value["type"] = .string(type); value["paused"] = .bool(false)
        value["devices"] = .array(devices.map { .object(["deviceID": .string($0)]) })
        value["fsWatcherEnabled"] = .bool(true); value["rescanIntervalS"] = .number(3600)
        value["fsWatcherDelayS"] = .number(10); value["markerName"] = .string(".stfolder-" + id)
        value["maxConflicts"] = .number(5); value["ignorePerms"] = .bool(true)
        return .object(value)
    }
}
