import Foundation
import UGOSSyncCore
import Darwin
import CryptoKit

func argument(_ name: String) -> String? { guard let i=CommandLine.arguments.firstIndex(of:name),i+1<CommandLine.arguments.count else { return nil };return CommandLine.arguments[i+1] }
let root = PrivateFiles.root
let activity = ProcessInfo.processInfo.beginActivity(options:[.idleSystemSleepDisabled], reason:"Keep NAS file synchronization online while this background service runs")
func report(_ fields: [String:JSON]) { var value=fields; value["updatedAt"] = .number(Date().timeIntervalSince1970); try? PrivateFiles.write(try JSON.object(value).data(),to:root.appendingPathComponent("runtime-status.json")) }

actor ReconnectProof {
    var initial = false
    var disconnected = false
    func step(_ state:String) -> Int {
        if state == "reconnecting" { disconnected=true }
        if state == "online" && !initial { initial=true;return 1 }
        if state == "online" && disconnected { return 2 }
        return 0
    }
}
Task {
    do {
        let settingsURL=argument("--engine-settings").map { URL(fileURLWithPath:$0) } ?? root.appendingPathComponent("engine-settings.json")
        let settings=try EngineSettings.load(settingsURL)
        try settings.verifyVendorEngine()
        let local=try LocalEngineClient(settings:settings)
        // The existing engine supervisor is retained during migration; never open a profile twice.
        var info:JSON?
        for _ in 0..<30 {
            info=try? await local.request(method:"GET",route:"/rest/system/status")
            if info?["myID"].string != nil { break }
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        guard let localID=info?["myID"].string else { throw SyncError.unavailable }
        var candidates:[NASSession]
        if let path=argument("--session-import") { candidates=try SessionImport.candidateSessions(URL(fileURLWithPath:path)) }
        else { candidates=[try SessionStore.loadNAS()] }
        var selected:NASClient?
        var lastError:Error=SyncError.authentication
        if argument("--session-import") == nil && !CommandLine.arguments.contains("--probe") && !CommandLine.arguments.contains("--browse-probe") && !CommandLine.arguments.contains("--directory-probe") && argument("--verify-file") == nil && !CommandLine.arguments.contains("--reconnect-probe") && !CommandLine.arguments.contains("--refresh-probe") { selected=try NASClient(session:candidates[0]) }
        for identity in candidates where selected == nil {
            guard identity.baseURL.host != "127.0.0.1",identity.baseURL.host != "localhost",identity.baseURL.scheme=="https" else { continue }
            do {
                let client=try NASClient(session:identity)
                let remote=try await client.request(method:"GET",route:"/rest/system/status")
                guard let remoteID=remote["myID"].string else { throw SyncError.response }
                
                let config=try await local.request(method:"GET",route:"/rest/config")
                guard config["devices"].array?.contains(where:{$0["deviceID"].string==remoteID})==true else { throw SyncError.authentication }
                
                selected=client
                if argument("--session-import") != nil { try SessionStore.saveNAS(identity) }
                break
            } catch { lastError=error;continue }
        }
        guard let nas=selected else { throw lastError }
        if CommandLine.arguments.contains("--challenge-probe") {
            let identity=await nas.session()
            let result=try await AuthenticationClient().challengeNAS(baseURL:identity.baseURL,username:identity.username)
            print("NAS public-key challenge received; body code: \(result.code)")
            exit(0)
        }
        if CommandLine.arguments.contains("--probe") { print("Authenticated NAS and engine identity verified");exit(0) }
        if CommandLine.arguments.contains("--browse-probe") {
            let browser=NASDirectoryBrowser(client:nas)
            let roots=try await browser.roots()
            print("Root directories: \(roots.count)")
            for folder in roots.prefix(2) { let children=try await browser.children(of:folder);print("Child directories: \(children.count)") }
            exit(0)
        }
        if CommandLine.arguments.contains("--directory-probe") {
            let b=NASDirectoryBrowser(client:nas);let roots=try await b.roots()
            for d in roots.prefix(1) {
                let result=try await nas.authenticated(method:"GET",path:"/ugreen/v1/filemgr/queryWritable",parameters:["path":d.path]).body
                print(String(decoding:try result.data(),as:UTF8.self))
            }
            exit(0)
        }
        if let relative=argument("--verify-file") {
            guard !relative.hasPrefix("/"), !relative.split(separator:"/").contains("..") else { throw SyncError.unsafePath }
            let lc=try await local.request(method:"GET",route:"/rest/config")
            guard let f=lc["folders"].array?.first(where:{$0["path"].string==settings.workDirectory}),let fid=f["id"].string else { throw SyncError.configuration }
            let rc=try await nas.request(method:"GET",route:"/rest/config")
            guard let folder=rc["folders"].array?.first(where:{$0["id"].string==fid}),let path=folder["path"].string else { throw SyncError.configuration }
            let remote=try await nas.readSmallFile(path:path+"/"+relative)
            let source=try Data(contentsOf:URL(fileURLWithPath:settings.workDirectory).appendingPathComponent(relative))
            print("NAS raw byte SHA256: "+SHA256.hash(data:remote).map { String(format:"%02x",$0) }.joined())
            print("Byte equality: \(source==remote)")
            exit(source==remote ? 0 : 1)
        }
        let heartbeat=NASHeartbeat(client:nas,localID:localID)
        if CommandLine.arguments.contains("--reconnect-probe") {
            let proof=ReconnectProof()
            await heartbeat.run { state in
                let action=await proof.step(state)
                print("Heartbeat: \(state)");fflush(stdout)
                if action == 1 { await heartbeat.reconnect() }
                if action == 2 { await heartbeat.stop();print("Controlled socket reconnect passed");exit(0) }
            }
            exit(1)
        }
        if CommandLine.arguments.contains("--refresh-probe") {
            try SessionStore.saveNAS(try await nas.refreshSession())
            print("Authenticated NAS session refresh passed");exit(0)
        }
        let refresh=Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:900_000_000_000)
                do { try SessionStore.saveNAS(try await nas.refreshSession()) } catch { report(["heartbeat":.string("session-refresh-failed")]) }
            }
        }
        defer { refresh.cancel() }
        await heartbeat.run { state in report(["heartbeat":.string(state),"pid":.number(Double(getpid()))]) }
    } catch {
        let message=(error as? SyncError)?.localizedDescription ?? error.localizedDescription
        fputs(message+"\n",stderr)
        if !CommandLine.arguments.contains(where: { $0.contains("probe") || $0 == "--verify-file" }) { report(["heartbeat":.string("unavailable"),"error":.string(message)]) };exit(1)
    }
}
dispatchMain()
