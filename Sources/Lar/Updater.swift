#if !LAR_APPSTORE
import AppKit
import CryptoKit
import LarCore
import Observation
import os

/// The Mac updates itself from GitHub's releases: the disk image is downloaded, checked against its SHA-256, and the
/// app inside must be notarized and signed by the same team as the running one (no team written here: it's read
/// from this app's own signature). Then the app in place is swapped and the launchd agent starts the new one. A
/// build that isn't signed by a team (a local ad hoc build) never updates itself.
///
/// The Mac App Store version (LAR_APPSTORE) is updated by the store.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case available(String)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var update: AppUpdate?
    /// While a call is going on, an update waits.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.coupled.lar", category: "update")
    static let interval: Duration = .seconds(6 * 60 * 60)

    static var installsByItself: Bool {
        get { Preferences.bool(forKey: "autoUpdate") ?? true }
        set { Preferences.set(newValue, forKey: "autoUpdate") }
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Checks now and every few hours. A copy built with the extensions kept outside the repository (LAR_PRIVATE)
    /// never replaces itself with the public release.
    func start() {
        #if LAR_PRIVATE
        return
        #endif
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func check() async {
        guard case .idle = state else {
            if case .available = state, Self.installsByItself { await install() }
            return
        }
        do {
            guard let found = try await UpdateChecker(currentVersion: Self.currentVersion).availableUpdate(),
                  found.disk != nil, found.checksum != nil else { return }
            update = found
            state = .available(found.version)
            if Self.installsByItself { await install() }
        } catch {
            Self.log.notice("check: \(error.localizedDescription, privacy: .public)")
        }
    }

    func install() async {
        guard let update, let disk = update.disk, let checksum = update.checksum, !isBusy() else { return }
        guard let team = Self.team(of: Bundle.main.bundleURL) else {
            state = .failed(String(localized: "Esta cópia não é assinada; baixe a nova versão na página do Lar."))
            return
        }
        state = .installing(update.version)
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("lar-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let image = work.appendingPathComponent(disk.lastPathComponent)
            let (downloaded, _) = try await URLSession.shared.download(from: disk)
            try FileManager.default.moveItem(at: downloaded, to: image)
            let (sum, _) = try await URLSession.shared.data(from: checksum)
            let expected = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: image, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected.lowercased() == actual else { throw UpdateError(String(localized: "o arquivo baixado não confere")) }

            let mount = work.appendingPathComponent("mount")
            try Self.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let newApp = mount.appendingPathComponent("Lar.app")
            guard Self.team(of: newApp) == team else { throw UpdateError(String(localized: "a assinatura da nova versão não confere")) }
            try Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", newApp.path])

            // Copied beside the app in use, then swapped (the running copy keeps going until the new one starts).
            let target = Bundle.main.bundleURL
            let staged = target.deletingLastPathComponent().appendingPathComponent(".Lar-\(update.version).app")
            try? FileManager.default.removeItem(at: staged)
            try Self.run("/usr/bin/ditto", [newApp.path, staged.path])
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            Notifier.post([HomeAlert(id: "update:\(update.version)", title: "Lar",
                                     body: String(localized: "Atualizado para a versão \(update.version).")) ], force: true)
            relaunch()
        } catch {
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            Self.log.error("install: \(message, privacy: .public)")
            state = .failed(String(localized: "Não deu para atualizar: \(message)"))
        }
    }

    /// The agent restarts Lar (the new copy); without it, a new copy is opened and this one quits.
    private func relaunch() {
        if StartAtLogin.agent.status == .enabled,
           (try? Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.coupled.lar.agent"])) != nil {
            return
        }
        let path = Bundle.main.bundleURL.path
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 2; /usr/bin/open \"$0\"", path]
        try? shell.run()
        NSApplication.shared.terminate(nil)
    }

    /// The team that signed an app, or nil when it isn't signed by one.
    static func team(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
#endif
