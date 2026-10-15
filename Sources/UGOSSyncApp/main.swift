import AppKit
import Darwin
import SwiftUI
import UGOSSyncCore

struct QueueEntry: Identifiable, Codable {
    let id: String
    let name: String
    let folder: String
    let direction: String
    let state: String
    let size: Int
}

@MainActor final class SyncModel: ObservableObject {
    @Published var status = "正在读取同步状态"
    @Published var connected = false
    @Published var folders: [JSON] = []
    @Published var entries: [QueueEntry] = []
    @Published var error: String?
    @Published var pending = 0
    @Published var session: NASSession?
    @Published var busy = false
    @Published var message: String?
    @Published var cloudDevices: [JSON] = []
    @Published var mappings: [JSON] = []
    private var local: LocalEngineClient?
    private var nas: NASClient?
    private let auth = AuthenticationClient()
    private var recentEntries: [QueueEntry] = []
    private let recentURL = PrivateFiles.root.appendingPathComponent("recent-files.json")
    private var refreshing = false
    private var timer: Timer?
    init() {
        if let stored = try? SessionStore.loadNAS() { session = stored; nas = try? NASClient(session: stored) }
        if let data = try? PrivateFiles.read(recentURL), let saved = try? JSONDecoder().decode([QueueEntry].self, from: data) { recentEntries = Array(saved.prefix(3)); entries = recentEntries }
        reloadEngine()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }
    func reloadEngine() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DotsWorkSync/settings.json")
        let primary = PrivateFiles.root.appendingPathComponent("engine-settings.json")
        if let settings = (try? EngineSettings.load(primary)) ?? (try? EngineSettings.load(legacy)) { local = try? LocalEngineClient(settings: settings) }
    }
    func refresh() async {
        await reloadSavedSession()
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        guard let local else { status = "尚未配置同步引擎"; connected = false; error = "打开设置以连接 NAS。"; return }
        do {
            let info = try await local.request(method: "GET", route: "/rest/system/status")
            let config = try await local.request(method: "GET", route: "/rest/config")
            let connections = try await local.request(method: "GET", route: "/rest/system/connections")
            guard let configured = config["folders"].array, let selfID = info["myID"].string else { throw SyncError.response }
            folders = configured
            let peers = connections["connections"].object ?? [:]
            connected = peers.values.contains { $0["connected"].bool == true }
            var next: [QueueEntry] = []; var total = 0; var unavailableQueue = false; var scanning = false; var folderErrors = false; var remoteReady = true
            for folder in configured where folder["paused"].bool != true {
                guard let id = folder["id"].string else { continue }
                let label = Self.label(folder)
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
                let folderStatus=try? await local.request(method:"GET",route:"/rest/db/status?folder=\(encoded)")
                if let folderStatus {
                    scanning = scanning || ["scanning","scan-waiting","sync-waiting","syncing"].contains(folderStatus["state"].string ?? "")
                    folderErrors = folderErrors || folderStatus["pullErrors"].int > 0 || folderStatus["errors"].int > 0 || folderStatus["state"].string == "error"
                } else { unavailableQueue=true }
                if folder["type"].string != "sendonly" {
                    do {
                        let result = try await local.request(method: "GET", route: "/rest/db/need?folder=\(encoded)&page=1&perpage=60")
                        for bucket in ["progress", "queued", "rest"] {
                            for file in result[bucket].array ?? [] {
                                next.append(entry(file, folder: label, id: id, direction: "从 NAS 接收", state: bucket == "progress" ? "正在接收" : "等待接收"))
                            }
                        }
                        let summary = try await local.request(method: "GET", route: "/rest/db/status?folder=\(encoded)")
                        total += summary["needTotalItems"].int
                    } catch { unavailableQueue = true }
                }
                if folder["type"].string != "receiveonly" {
                    for device in folder["devices"].array ?? [] {
                        guard let peer = device["deviceID"].string, peer != selfID else { continue }
                        let escaped = peer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? peer
                        do {
                            let summary = try await local.request(method: "GET", route: "/rest/db/completion?folder=\(encoded)&device=\(escaped)")
                            total += summary["needItems"].int
                            remoteReady = remoteReady && summary["remoteState"].string == "valid"
                            let result = try await local.request(method: "GET", route: "/rest/db/remoteneed?folder=\(encoded)&device=\(escaped)&page=1&perpage=60")
                            let files = result.array ?? result["files"].array
                            guard let files else { throw SyncError.response }
                            for file in files { next.append(entry(file, folder: label, id: id, direction: "传到 NAS", state: "等待 NAS 接收")) }
                        } catch { unavailableQueue = true }
                    }
                }
            }
            total = max(total, next.count)
            pending = total
            status = connected ? (configured.isEmpty ? "尚未添加同步文件夹" : (configured.allSatisfy { $0["paused"].bool == true } ? "同步已暂停" : (total > 0 ? "\(total) 项待同步" : "同步已完成"))) : "正在等待 NAS 连接"
            error = unavailableQueue ? "部分文件队列暂时无法读取，完成状态以可读的引擎数据为准。" : nil
            if connected && folderErrors { status="目录同步有错误";error="请检查文件夹权限或可用空间。" }
            else if connected && scanning { status="正在处理文件" }
            else if connected && !remoteReady { status="等待 NAS 同步确认" }
            if status == "同步已完成" { let paused=configured.filter { $0["paused"].bool == true }.count;if paused>0 { status="活动任务已同步 · \(paused) 个暂停" } }
            if unavailableQueue && total == 0 { status = connected ? "NAS 已连接 · 正在读取队列" : "正在等待 NAS 连接" }
            if let data=try? PrivateFiles.read(PrivateFiles.root.appendingPathComponent("runtime-status.json")),let daemon=try? JSON.decode(data),let state=daemon["heartbeat"].string {
                if state == "reconnecting" { status="正在重新连接 NAS";connected=false }
                else if state != "online" || Date().timeIntervalSince1970-Double(daemon["updatedAt"].int)>30 { status="后台连接需要检查";connected=false;self.error="请在同步设置中检查 NAS 登录，或重新启动后台服务。" }
            } else { status="后台尚未启动";connected=false }
            if session == nil { status="请先连接 NAS";connected=false }
            // Disk events provide actual file names even when a transfer finishes between polls.
            var candidates: [QueueEntry] = []
            if let events = try? await local.request(method: "GET", route: "/rest/events/disk?since=0&limit=100&timeout=0") {
                for event in (events.array ?? []).reversed() {
                    let data = event["data"]
                    guard let folderID = data["folder"].string,
                          let folder = configured.first(where: { $0["id"].string == folderID }),
                          let path = data["path"].string, data["type"].string != "dir" else { continue }
                    let direction = event["type"].string == "RemoteChangeDetected" ? "从 NAS 接收" : "传到 NAS"
                    candidates.append(QueueEntry(id: folderID + direction + path, name: path, folder: Self.label(folder), direction: direction, state: "未同步", size: 0))
                }
            }
            let confirmed = connected && error == nil && !scanning && !folderErrors && remoteReady && total == 0 && !configured.contains(where: { $0["paused"].bool == true })
            var seen = Set<String>()
            let ordered = next + candidates + recentEntries
            recentEntries = Array(ordered.filter { seen.insert($0.id).inserted }.prefix(3)).map { item in
                let waiting = next.contains(where: { $0.id == item.id })
                return QueueEntry(id: item.id, name: item.name, folder: item.folder, direction: item.direction,
                                  state: waiting ? "未同步" : (confirmed ? "已同步" : (item.state == "已同步" ? "已同步" : "未同步")), size: item.size)
            }
            entries = recentEntries
            if let data = try? JSONEncoder().encode(recentEntries) { try? PrivateFiles.write(data, to: recentURL) }

        } catch { connected = false; status = "同步引擎暂时不可用"; self.error = "请稍后刷新，或在设置中检查连接。"; entries = recentEntries; pending = 0 }
    }
    static func label(_ folder: JSON) -> String {
        let raw=folder["label"].string ?? URL(fileURLWithPath:folder["path"].string ?? "").lastPathComponent
        return raw.contains("->>auto") ? raw.components(separatedBy:"[").first ?? raw : raw
    }
    private func entry(_ file: JSON, folder: String, id: String, direction: String, state: String) -> QueueEntry {
        let name = file["name"].string ?? "未命名项目"
        return QueueEntry(id: id + direction + name, name: name, folder: folder, direction: direction, state: file["deleted"].bool == true ? "等待同步删除" : state, size: file["size"].int)
    }
    func loginNAS(address: String, username: String, password: String) async {
        busy = true; message = nil; defer { busy = false }
        do {
            let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let url: URL
            if raw.contains("://") { guard let parsed = URL(string: raw) else { throw SyncError.configuration }; url = parsed }
            else { url = try await auth.resolve(alias: raw) }
            let identity = try await auth.loginNAS(baseURL: url, username: username, password: password)
            try SessionStore.saveNAS(identity); session = identity; nas = try NASClient(session: identity)
            let restart=Process();restart.executableURL=URL(fileURLWithPath:"/bin/launchctl");restart.arguments=["kickstart","-k","gui/\(getuid())/com.nakutop.ugos-sync.daemon"];try? restart.run()
            message = "已连接 \(identity.deviceName)"; await loadMappings(); await refresh()
        } catch { message = error.localizedDescription }
    }
    func loginCloud(username: String, password: String) async {
        busy = true; message = nil; defer { busy = false }
        do { let identity = try await auth.loginCloud(username: username, password: password); try SessionStore.saveCloud(identity); try await readDevices(identity); message = "绿联云账号已登录" }
        catch { message = error.localizedDescription }
    }
    func loadDevices() async {
        busy = true; defer { busy = false }
        do { try await readDevices(SessionStore.loadCloud()) } catch { message = error.localizedDescription }
    }
    private func readDevices(_ identity: CloudSession) async throws {
        let response = try await auth.devices(identity)
        guard let list = response.array ?? response["list"].array ?? response["devices"].array else { throw SyncError.response }
        cloudDevices = list
    }
    private func reloadSavedSession() async {
        if let stored=try? SessionStore.loadNAS(), stored.access.apiToken != session?.access.apiToken || stored.publicKey != session?.publicKey || stored.clientID != session?.clientID || stored.baseURL != session?.baseURL {
            session=stored
            if let nas { await nas.replaceSession(stored) } else { nas=try? NASClient(session:stored) }
        }
    }
    func loadMappings() async {
        await reloadSavedSession()
        guard let local, let nas else { return }
        do { mappings = try await FolderPairer(local: local, nas: nas).mappings() } catch { message = error.localizedDescription }
    }
    func pause(id: String, paused: Bool) async {
        guard let local, let nas else { message = "请先连接 NAS"; return }
        busy = true; defer { busy = false }
        do { try await FolderPairer(local: local, nas: nas).pause(folderID: id, paused: paused); message = paused ? "同步已暂停" : "同步已恢复"; await loadMappings(); await refresh() }
        catch { message = error.localizedDescription }
    }
    func directoryRoots() async throws -> [NASDirectory] {
        guard let nas else { throw SyncError.authentication }
        return try await NASDirectoryBrowser(client: nas).roots()
    }
    func directoryChildren(_ directory: NASDirectory) async throws -> [NASDirectory] {
        guard let nas else { throw SyncError.authentication }
        return try await NASDirectoryBrowser(client: nas).children(of: directory)
    }
    func create(localPath: String, nasPath: String, name: String, direction: SyncDirection) async {
        guard let local, let nas else { message = "请先连接 NAS 并启动同步引擎"; return }
        busy = true; message = nil; defer { busy = false }
        do {
            guard try await NASDirectoryBrowser(client: nas).isWritable(path: nasPath) else { message = "所选 NAS 目录不可写，请选择你有写入权限的位置"; return }
            _ = try await FolderPairer(local: local, nas: nas).create(FolderMappingSpec(localPath: localPath, nasPath: nasPath, name: name, direction: direction)); message = "同步文件夹已添加"; await loadMappings(); await refresh() }
        catch { message = error.localizedDescription }
    }
}

struct StatusView: View {
    @ObservedObject var model: SyncModel
    let settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: model.connected ? "arrow.triangle.2.circlepath.circle.fill" : "network").font(.system(size: 28)).foregroundStyle(model.connected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) { Text("UGOS Sync").font(.headline); Text(model.status).font(.subheadline).foregroundStyle(.secondary) }
                Spacer(); Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新")
            }
            Divider()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.entries.isEmpty {
                Text("暂无最近同步文件，文件发生变化后将在这里显示。").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 14) { ForEach(model.entries) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.direction == "传到 NAS" ? "arrow.up.doc" : "arrow.down.doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2); Text("\(item.folder) · \(item.direction)").font(.caption).foregroundStyle(.secondary); Text(item.state).font(.caption2).foregroundStyle(item.state == "已同步" ? Color.green : Color.orange) }
                        Spacer(); if item.size > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
                    }
                } }.padding(.vertical, 2) }.frame(maxHeight: 330)
                Text("最近三个同步文件 · 每 6 秒更新").font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            HStack { Button("同步设置…", action: settings); Spacer(); Button("退出界面") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary) }
            Text("关闭界面后，后台同步继续运行").font(.caption2).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 380)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SyncModel
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var cloudUser = ""
    @State private var cloudPassword = ""
    @State private var localPath = ""
    @State private var nasPath = ""
    @State private var name = ""
    @State private var direction: SyncDirection = .upload
    @State private var selectingNAS = false
    var body: some View {
        TabView {
            account.tabItem { Label("连接", systemImage: "network") }
            mapping.tabItem { Label("同步文件夹", systemImage: "folder") }.onAppear { Task { await model.loadMappings() } }
        }.padding(16).frame(width: 580, height: 560).disabled(model.busy).overlay { if model.busy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .sheet(isPresented: $selectingNAS) { NASBrowserView(model: model, selection: $nasPath) }
        .onAppear { if let session = model.session { address = session.baseURL.absoluteString; username = session.username }; Task { await model.loadMappings() } }
    }
    var account: some View {
        Form {
            Section("NAS 登录") {
                if let identity = model.session { Label("已保存连接：\(identity.deviceName)", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                TextField("NAS 地址或 UGLink 别名", text: $address)
                TextField("NAS 用户名", text: $username)
                SecureField("NAS 密码", text: $password)
                Button("连接 NAS") { let secret = password; password = ""; Task { await model.loginNAS(address: address, username: username, password: secret) } }.disabled(address.isEmpty || username.isEmpty || password.isEmpty)
            }
            DisclosureGroup("通过绿联云查找设备（可选）") {
                Text("已连接 NAS 后，无需登录此处。仅在需要查找绑定设备时使用。").font(.caption).foregroundStyle(.secondary)
                TextField("手机号或邮箱", text: $cloudUser)
                SecureField("绿联云密码", text: $cloudPassword)
                HStack { Button("登录绿联云") { let secret = cloudPassword; cloudPassword = ""; Task { await model.loginCloud(username: cloudUser, password: secret) } }.disabled(cloudUser.isEmpty || cloudPassword.isEmpty); Button("读取已绑定设备") { Task { await model.loadDevices() } } }
                ForEach(Array(model.cloudDevices.enumerated()), id: \.offset) { _, device in
                    let deviceName = device["name"].string ?? device["nasName"].string ?? device["deviceName"].string ?? "已绑定设备"
                    HStack { Label(deviceName, systemImage: "externaldrive"); Spacer(); if let alias = device["alias"].string { Button("选择") { address = alias } } }
                }
            }
            if let text = model.message { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.formStyle(.grouped)
    }
    var mapping: some View {
        Form {
            Section("添加同步文件夹") {
                TextField("同步名称", text: $name)
                HStack { TextField("本地文件夹", text: $localPath); Button("选择…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { localPath = url.path; if name.isEmpty { name = url.lastPathComponent } } } }
                HStack { TextField("NAS 目标目录", text: $nasPath); Button("选择…") { selectingNAS = true }.disabled(model.session == nil) }
                Text("选择 NAS 上的文件夹；也可输入完整路径。创建前会检查写入权限。") .font(.caption).foregroundStyle(.secondary)
                if !model.mappings.isEmpty { Menu("选择已有 NAS 同步位置") { ForEach(Array(model.mappings.enumerated()), id: \.offset) { _, pair in if let path = pair["nas"]["path"].string { Button(path) { nasPath = path } } } } }
                Picker("同步方向", selection: $direction) { Text("本地 → NAS").tag(SyncDirection.upload); Text("NAS → 本地").tag(SyncDirection.download); Text("双向同步").tag(SyncDirection.bidirectional) }
                Text(direction == .bidirectional ? "双向同步会传播两端的修改和删除。" : "所选方向的文件修改和删除会同步到目标目录。") .font(.caption).foregroundStyle(.secondary)
                Button("创建同步") { Task { await model.create(localPath: localPath, nasPath: nasPath, name: name, direction: direction) } }.disabled(model.session == nil || localPath.isEmpty || nasPath.isEmpty || name.isEmpty)
            }
            Section("已有同步") {
                if model.mappings.isEmpty { Text("暂无可读取的目录映射").foregroundStyle(.secondary) }
                ForEach(Array(model.mappings.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(SyncModel.label(pair["local"])).font(.headline); Spacer(); if let id = pair["id"].string { let paused = pair["local"]["paused"].bool ?? false; Button(paused ? "恢复" : "暂停") { Task { await model.pause(id: id, paused: !paused) } } } }; Text(pair["local"]["path"].string ?? "").font(.caption); Text("NAS：" + (pair["nas"]["path"].string ?? "")).font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            }
            if let text = model.message { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.formStyle(.grouped)
    }
}


struct NASBrowserView: View {
    @ObservedObject var model: SyncModel
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var roots: [NASDirectory] = []
    @State private var selected = ""
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择 NAS 文件夹").font(.title2.weight(.semibold))
            Text("展开文件夹，选择同步的目标位置。").foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 240) }
            else if let error { VStack(alignment: .leading, spacing: 12) { Text(error).foregroundStyle(.secondary); Button("重新读取") { Task { await load() } } }.frame(maxWidth: .infinity, minHeight: 240) }
            else {
                ScrollView { VStack(alignment: .leading, spacing: 4) {
                    if roots.isEmpty { Text("当前账号没有可浏览的目录").foregroundStyle(.secondary) }
                    ForEach(roots) { directory in NASDirectoryRow(model: model, directory: directory, selected: $selected) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(height: 280)
            }
            Text(selected.isEmpty ? "尚未选择文件夹" : selected).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("选择此文件夹") { selection = selected; dismiss() }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty) }
        }.padding(24).frame(width: 520).task { selected = selection; await load() }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { roots = try await model.directoryRoots() } catch { self.error = error.localizedDescription }
    }
}

struct NASDirectoryRow: View {
    @ObservedObject var model: SyncModel
    let directory: NASDirectory
    @Binding var selected: String
    @State private var expanded = false
    @State private var children: [NASDirectory] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button { expanded.toggle(); if expanded && !loaded { Task { await load() } } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width: 12)
                }.buttonStyle(.borderless).accessibilityLabel(expanded ? "收起 \(directory.name)" : "展开 \(directory.name)")
                Button { selected = directory.path } label: {
                    HStack(spacing: 8) { Image(systemName: "folder"); Text(directory.name).lineLimit(1); Spacer(); if selected == directory.path { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 6)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if loading { ProgressView().controlSize(.small).padding(6) }
                    else if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { Task { await load() } }.font(.caption) }
                    else if children.isEmpty { Text("没有子文件夹").font(.caption).foregroundStyle(.tertiary).padding(.vertical, 5) }
                    else { ForEach(children) { child in AnyView(NASDirectoryRow(model: model, directory: child, selected: $selected)) } }
                }.padding(.leading, 22)
            }
        }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { children = try await model.directoryChildren(directory); loaded = true } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SyncModel()
    var item: NSStatusItem!
    let popover = NSPopover()
    var window: NSWindow?
    var reopenObserver:NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "UGOSSyncStatus"
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "UGOS Sync 同步状态")
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        let host=NSHostingController(rootView:StatusView(model:model,settings:{ [weak self] in self?.showSettings() }));host.sizingOptions=[.preferredContentSize];popover.contentViewController=host
        let menu=NSMenu();let appMenu=NSMenu();let parent=NSMenuItem();parent.submenu=appMenu;menu.addItem(parent)
        let status=NSMenuItem(title:"显示同步状态",action:#selector(toggle),keyEquivalent:"s");status.keyEquivalentModifierMask=[.command,.shift];status.target=self;appMenu.addItem(status)
        appMenu.addItem(NSMenuItem(title:"退出界面",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"));NSApp.mainMenu=menu
        reopenObserver=DistributedNotificationCenter.default().addObserver(forName:Notification.Name("com.nakutop.ugos-sync.reopen"),object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.window?.isVisible == true { self.window?.makeKeyAndOrderFront(nil) } else if !self.popover.isShown { self.showStatus() }
                NSApp.activate(ignoringOtherApps:true)
            }
        }
        if CommandLine.arguments.contains("--settings") { showSettings() } else if !CommandLine.arguments.contains("--background") { showStatus() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if window?.isVisible != true && !popover.isShown { showStatus() }; return false }
    @objc func toggle() { if popover.isShown { popover.performClose(nil) } else { showStatus() } }
    func showStatus() { guard let button=item.button else { return };popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);popover.contentViewController?.view.window?.makeKey() }
    func showSettings() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 612, height: 592), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "UGOS Sync 设置"; w.contentViewController = NSHostingController(rootView: SettingsView(model: model)); w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
let app = NSApplication.shared
if let id=Bundle.main.bundleIdentifier, let existing=NSRunningApplication.runningApplications(withBundleIdentifier:id).first(where:{$0.processIdentifier != getpid()}) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.nakutop.ugos-sync.reopen"),object:nil,userInfo:nil,deliverImmediately:true)
    existing.activate(options:[.activateIgnoringOtherApps]);exit(0)
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
