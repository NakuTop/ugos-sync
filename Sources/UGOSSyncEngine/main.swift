import Foundation
import CryptoKit
import Darwin

struct Settings: Codable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let engineSHA256: String
    let configurationDirectory: String
    let workDirectory: String
    let guiPort: Int
    let statusFile: String
}

enum SetupError: Error { case refused(String) }

func privateSettings(_ path: String) throws -> Settings {
    var st = stat()
    guard lstat(path, &st) == 0, st.st_uid == getuid(),
          st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          st.st_mode & 0o077 == 0, st.st_size <= 65536 else {
        throw SetupError.refused("private_settings_required")
    }
    let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard settings.arguments.count <= 40, settings.guiPort > 0, settings.guiPort < 65536,
          settings.executable.hasPrefix("/"), settings.configurationDirectory.hasPrefix("/"),
          settings.workDirectory.hasPrefix("/"), settings.statusFile.hasPrefix("/") else {
        throw SetupError.refused("invalid_paths_or_arguments")
    }
    let homeArguments = settings.arguments.filter { $0.hasPrefix("-home=") || $0.hasPrefix("--home=") }
    let guiArguments = settings.arguments.filter { $0.hasPrefix("-gui-address=") || $0.hasPrefix("--gui-address=") }
    guard homeArguments.count == 1,
          homeArguments[0].components(separatedBy: "=").dropFirst().joined(separator: "=") == settings.configurationDirectory,
          guiArguments.count == 1,
          guiArguments[0].hasSuffix("=127.0.0.1:\(settings.guiPort)"),
          settings.arguments.contains(where: { $0 == "-no-browser" || $0 == "--no-browser" }),
          settings.arguments.contains(where: { $0 == "-no-upgrade" || $0 == "--no-upgrade" }),
          !settings.arguments.contains(where: { $0.hasPrefix("-reset") || $0.hasPrefix("--reset") || $0 == "--unpaused" || $0 == "-unpaused" }) else {
        throw SetupError.refused("existing_profile_and_loopback_required")
    }
    guard FileManager.default.fileExists(atPath: settings.configurationDirectory + "/config.xml"),
          FileManager.default.fileExists(atPath: settings.configurationDirectory + "/cert.pem"),
          FileManager.default.fileExists(atPath: settings.configurationDirectory + "/key.pem") else {
        throw SetupError.refused("existing_configuration_required")
    }
    let engine = try Data(contentsOf: URL(fileURLWithPath: settings.executable), options: .mappedIfSafe)
    let digest = SHA256.hash(data: engine).map { String(format: "%02x", $0) }.joined()
    guard digest == settings.engineSHA256 else { throw SetupError.refused("engine_identity_changed") }
    let verification = Process()
    verification.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    verification.arguments = ["--verify", "--strict", settings.executable]
    verification.standardOutput = FileHandle.nullDevice
    verification.standardError = FileHandle.nullDevice
    try verification.run()
    verification.waitUntilExit()
    guard verification.terminationStatus == 0 else { throw SetupError.refused("engine_signature_invalid") }
    return settings
}

func listenerExists(_ port: Int) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
    catch { return false }
}

final class Runner {
    let settings: Settings
    private let lock = NSLock()
    private var stopping = false
    private var child: Process?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastMode = ""

    init(_ settings: Settings) { self.settings = settings }

    func stop() {
        lock.lock(); stopping = true; let active = child; lock.unlock()
        if let active = active, active.isRunning { active.terminate() }
    }

    func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }; return stopping
    }

    func status(_ mode: String, childPID: Int32? = nil, exitCode: Int32? = nil) {
        var value: [String: Any] = [
            "mode": mode, "wrapperPID": getpid(),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "workDirectory": settings.workDirectory,
            "configurationDirectory": settings.configurationDirectory,
            "guiPort": settings.guiPort,
            "engineSHA256": settings.engineSHA256
        ]
        if let pid = childPID { value["enginePID"] = pid }
        if let code = exitCode { value["lastExitCode"] = code }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: settings.statusFile), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.statusFile)
        } catch { log("status_write_failed") }
        if mode != lastMode { lastMode = mode; log(mode) }
    }

    func log(_ message: String) {
        print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        fflush(stdout)
    }

    func run() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume(); signalSources.append(source)
        }
        while !shouldStop() {
            if listenerExists(settings.guiPort) {
                status("existing_engine_active")
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: settings.executable)
            process.arguments = settings.arguments
            var environment = ProcessInfo.processInfo.environment
            for (name, value) in settings.environment { environment[name] = value }
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: settings.configurationDirectory)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                status("starting_standalone_engine")
                try process.run()
                lock.lock(); child = process; let stopNow = stopping; lock.unlock()
                if stopNow { process.terminate() }
                status("standalone_engine_running", childPID: process.processIdentifier)
                process.waitUntilExit()
                lock.lock(); child = nil; lock.unlock()
                status("engine_exited", exitCode: process.terminationStatus)
            } catch { status("engine_start_failed") }
            if !shouldStop() { Thread.sleep(forTimeInterval: 10) }
        }
        status("stopped")
    }
}

do {
    guard CommandLine.arguments.count >= 2 else { throw SetupError.refused("settings_path_required") }
    let settings = try privateSettings(CommandLine.arguments[1])
    if CommandLine.arguments.dropFirst(2).contains("--check") {
        let output: [String: Any] = ["valid": true, "engine": settings.executable,
                                   "workDirectoryReadable": FileManager.default.isReadableFile(atPath: settings.workDirectory),
                                   "existingListener": listenerExists(settings.guiPort)]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        let runner = Runner(settings)
        withExtendedLifetime(runner) { runner.run() }
    }
} catch {
    fputs("UGOS Sync configuration refused; inspect the private installation state.\n", stderr)
    exit(2)
}
