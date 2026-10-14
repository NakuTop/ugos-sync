import XCTest
@testable import UGOSSyncCore

private actor PairingMock: EngineAPI {
    struct Call: Sendable { let method: String; let route: String; let body: JSON? }
    var calls: [Call] = []
    let id: String
    var folders: [JSON]
    let devices: [JSON]
    let failCreate: Bool
    let failDelete: Bool
    let commitThenFail: Bool
    init(id: String, folders: [JSON] = [], devices: [JSON] = [], failCreate: Bool = false, failDelete: Bool = false, commitThenFail: Bool = false) {
        self.id = id; self.folders = folders; self.devices = devices; self.failCreate = failCreate; self.failDelete = failDelete; self.commitThenFail = commitThenFail
    }
    func request(method: String, route: String, body: JSON?) async throws -> JSON {
        calls.append(Call(method: method, route: route, body: body))
        if method == "GET" {
            switch route {
            case "/rest/config": return .object(["folders": .array(folders), "devices": .array(devices)])
            case "/rest/system/status": return .object(["myID": .string(id)])
            case "/rest/config/defaults/folder": return .object(["customDefault": .string("preserved")])
            case "/rest/config/defaults/device": return .object(["compression": .string("metadata")])
            default: throw SyncError.response
            }
        }
        if method == "POST" && route == "/rest/config/folders" {
            if failCreate { throw SyncError.server(500) }
            folders.removeAll { $0["id"].string == body?["id"].string }
            folders.append(body!)
            if commitThenFail { throw SyncError.unavailable }
        }
        if method == "DELETE" {
            if failDelete { throw SyncError.server(500) }
            folders.removeAll { route == "/rest/config/folders/" + ($0["id"].string ?? "") }
        }
        return .null
    }
    func mutations() -> [Call] { calls.filter { $0.method != "GET" } }
    func currentFolders() -> [JSON] { folders }
}

final class FolderPairingTests: XCTestCase {
    let spec = FolderMappingSpec(localPath: "/Users/example/Work", nasPath: "/home/example/Work", name: "Work", direction: .upload)
    func testCreatesSameIDAndPreservesDefaultsAndExistingDevices() async throws {
        let local = PairingMock(id: "LOCAL", devices: [.object(["deviceID": .string("NAS")])])
        let nas = PairingMock(id: "NAS", devices: [.object(["deviceID": .string("LOCAL")])])
        let id = try await FolderPairer(local: local, nas: nas).create(spec)
        let l = await local.currentFolders(), n = await nas.currentFolders()
        XCTAssertEqual(l[0]["id"].string, id); XCTAssertEqual(n[0]["id"].string, id)
        XCTAssertEqual(l[0]["type"].string, "sendonly"); XCTAssertEqual(n[0]["type"].string, "receiveonly")
        XCTAssertEqual(l[0]["customDefault"].string, "preserved")
        XCTAssertEqual(l[0]["markerName"].string, ".stfolder-" + id)
        let mutations = await local.mutations() + nas.mutations()
        XCTAssertFalse(mutations.contains { $0.route.contains("devices") })
    }
    func testRejectsDuplicateAndParentChildPathsBeforeMutation() async throws {
        for path in ["/Users/example/Work", "/Users/example", "/Users/example/Work/Sub"] {
            let local = PairingMock(id: "LOCAL", folders: [.object(["id": .string("old"), "path": .string(path)])])
            let nas = PairingMock(id: "NAS")
            do { _ = try await FolderPairer(local: local, nas: nas).create(spec); XCTFail("Must reject overlap") }
            catch FolderPairingError.overlappingPath { }
            let mutations = await local.mutations() + nas.mutations()
            XCTAssertTrue(mutations.isEmpty)
        }
    }
    func testRejectsNASOverlapAndUnsafePaths() async throws {
        let local = PairingMock(id: "LOCAL")
        let nas = PairingMock(id: "NAS", folders: [.object(["id": .string("old"), "path": .string("/home/example")])])
        do { _ = try await FolderPairer(local: local, nas: nas).create(spec); XCTFail() }
        catch FolderPairingError.overlappingPath { }
        for path in ["/", "relative", "/a/../b"] {
            do { _ = try await FolderPairer(local: local, nas: nas).create(.init(localPath: path, nasPath: spec.nasPath, name: "Work", direction: .upload)); XCTFail() }
            catch SyncError.unsafePath { }
        }
    }
    func testLocalFailureRollsBackOnlyNewNASFolder() async throws {
        let old: JSON = .object(["id": .string("existing"), "path": .string("/unrelated")])
        let local = PairingMock(id: "LOCAL", failCreate: true)
        let nas = PairingMock(id: "NAS", folders: [old])
        do { _ = try await FolderPairer(local: local, nas: nas).create(spec); XCTFail() }
        catch FolderPairingError.localCreationFailed { }
        let folders = await nas.currentFolders()
        XCTAssertEqual(folders, [old])
        let mutations = await nas.mutations()
        let created = mutations.first { $0.route == "/rest/config/folders" }!.body!["id"].string!
        XCTAssertEqual(mutations.filter { $0.method == "DELETE" }.map(\.route), ["/rest/config/folders/" + created])
        XCTAssertFalse(mutations.contains { $0.method == "DELETE" && $0.route.contains("devices") })
    }
    func testRollbackFailureIsExplicit() async throws {
        let local = PairingMock(id: "LOCAL", failCreate: true)
        let nas = PairingMock(id: "NAS", failDelete: true)
        do { _ = try await FolderPairer(local: local, nas: nas).create(spec); XCTFail() }
        catch FolderPairingError.rollbackFailed { }
    }
    func testLostLocalResponseDoesNotDeleteCommittedMapping() async throws {
        let local=PairingMock(id:"LOCAL",commitThenFail:true)
        let nas=PairingMock(id:"NAS")
        let id=try await FolderPairer(local:local,nas:nas).create(spec)
        let remote=await nas.currentFolders();let client=await local.currentFolders()
        XCTAssertEqual(remote.first?["id"].string,id);XCTAssertEqual(client.first?["id"].string,id)
        let calls=await nas.mutations();XCTAssertFalse(calls.contains { $0.method == "DELETE" })
    }
    func testLostNASResponseReadsBackBeforeContinuing() async throws {
        let local=PairingMock(id:"LOCAL")
        let nas=PairingMock(id:"NAS",commitThenFail:true)
        let id=try await FolderPairer(local:local,nas:nas).create(spec)
        let remote=await nas.currentFolders();let client=await local.currentFolders()
        XCTAssertEqual(remote.first?["id"].string,id);XCTAssertEqual(client.first?["id"].string,id)
    }

    func testPausePreservesNASFieldsThroughSupportedUpsert() async throws {
        let folder:JSON = .object(["id":.string("existing"),"path":.string("/example"),"paused":.bool(false),"markerName":.string("preserve-marker")])
        let local=PairingMock(id:"LOCAL",folders:[folder])
        let nas=PairingMock(id:"NAS",folders:[folder])
        try await FolderPairer(local:local,nas:nas).pause(folderID:"existing",paused:true)
        let remote=await nas.currentFolders();XCTAssertEqual(remote.count,1)
        XCTAssertEqual(remote[0]["paused"].bool,true);XCTAssertEqual(remote[0]["markerName"].string,"preserve-marker")
        let mutations=await nas.mutations();XCTAssertEqual(mutations.first?.route,"/rest/config/folders")
    }
    func testRejectsLocalSymlinkToExistingFolder() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let real=root.appendingPathComponent("real"),link=root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at:real,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:real)
        let local=PairingMock(id:"LOCAL",folders:[.object(["id":.string("old"),"path":.string(real.path)])])
        let nas=PairingMock(id:"NAS")
        do { _=try await FolderPairer(local:local,nas:nas).create(.init(localPath:link.path,nasPath:spec.nasPath,name:"Alias",direction:.upload));XCTFail("Must reject same directory through symlink") }
        catch FolderPairingError.overlappingPath { }
        let mutations=await local.mutations();XCTAssertTrue(mutations.isEmpty)
    }

}
