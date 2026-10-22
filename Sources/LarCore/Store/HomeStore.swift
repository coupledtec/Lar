import Foundation
import Observation
import os

/// How one account is doing.
public enum AccountState: Equatable, Sendable {
    case notConfigured
    case loading
    case connected
    case unauthorized
    case failed(String)
}

/// Source of truth for the device list: every account's devices as last read, overlaid with optimistic changes.
///
/// Like ACStore, a change shows at once and is kept as an override until the cloud confirms it or it expires.
/// Commands go out one at a time; a newer command for the same device and field replaces one not yet sent.
/// Accounts are read in parallel and independently: one failing never hides the others' devices.
@MainActor
@Observable
public final class HomeStore {
    public private(set) var serverDevices: [HomeDevice] = []
    public private(set) var accounts: [Provider: AccountState] = [:]
    public private(set) var isRefreshing = false
    /// A short-lived error to show, e.g. a command the device rejected.
    public private(set) var transientMessage: String?
    @ObservationIgnored private var overrides: [String: [HomeField: Override]] = [:]

    /// Polls faster while the popover is open.
    public var isPopoverVisible = false {
        didSet {
            guard oldValue != isPopoverVisible, isActive else { return }
            startPolling(immediately: isPopoverVisible)
        }
    }

    public static let overrideLifetime: TimeInterval = 10
    public static let visibleInterval: Duration = .seconds(20)
    public static let backgroundInterval: Duration = .seconds(300)
    /// When to read the account back after a command, to confirm it.
    static let refreshAfterSend: Duration = .seconds(3)
    static let messageDuration: Duration = .seconds(4)
    /// Pause between two commands in a burst, so the clouds' rate limits aren't hit.
    static let minimumSendGap: Duration = .milliseconds(300)
    /// Consecutive failed reads of an account before its devices are shown as offline.
    static let failuresBeforeOffline = 3

    @ObservationIgnored private let makeProviders: () -> [any DeviceProvider]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var providers: [Provider: any DeviceProvider] = [:]
    @ObservationIgnored private var failures: [Provider: Int] = [:]
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSoonTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    struct Override {
        var command: HomeCommand
        var expires: Date
    }

    struct AccountRead: Sendable {
        var provider: Provider
        var devices: [HomeDevice]
        var error: (any Error)?
    }

    struct Pending {
        var deviceID: String
        var command: HomeCommand
    }

    public init(
        makeProviders: @escaping () -> [any DeviceProvider],
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.makeProviders = makeProviders
        self.now = now
        self.sleep = sleep
        self.isPreview = false
        reloadAccounts()
    }

    /// A store with fixed devices that never touches the network, for snapshots.
    public init(previewDevices: [HomeDevice], accounts: [Provider: AccountState] = [.lg: .connected, .tuya: .connected]) {
        self.makeProviders = { [] }
        self.now = Date.init
        self.sleep = { _ in }
        self.isPreview = true
        self.serverDevices = previewDevices
        self.accounts = accounts
    }

    // MARK: State

    /// What the UI shows: the accounts' devices with pending changes applied, grouped by kind, then by name.
    public var devices: [HomeDevice] {
        let date = now()
        return serverDevices.map { device in
            var device = device
            for override in (overrides[device.id] ?? [:]).values where override.expires > date {
                device = device.applying(override.command)
            }
            return device
        }
        .sorted { a, b in
            let ka = Self.kindOrder.firstIndex(of: a.kind) ?? 99, kb = Self.kindOrder.firstIndex(of: b.kind) ?? 99
            return ka != kb ? ka < kb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public static let kindOrder: [DeviceKind] = [.tv, .speaker, .airConditioner, .light, .plug, .fan, .camera, .laundry, .kitchen, .climateSensor, .other]

    public func device(id: String) -> HomeDevice? { devices.first { $0.id == id } }

    /// Whether any account has keys; with none, the app opens on Settings.
    public var hasAccounts: Bool { accounts.values.contains { $0 != .notConfigured } }

    /// How many lights and plugs are on, for the menu bar.
    public var switchedOnCount: Int { devices.filter { $0.isOn == true && $0.isOnline && $0.kind != .camera }.count }

    // MARK: Lifecycle

    /// Rebuilds the clients after a key changes; their tokens start over.
    public func reloadAccounts() {
        let list = makeProviders()
        providers = Dictionary(list.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        for provider in Provider.allCases {
            accounts[provider] = providers[provider] == nil ? .notConfigured : (accounts[provider] == .connected ? .connected : .loading)
        }
        serverDevices.removeAll { providers[$0.provider] == nil }
        failures = [:]
    }

    public func start() {
        isActive = true
        startPolling(immediately: true)
    }

    /// Stops polling, e.g. while the Mac sleeps.
    public func suspend() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling(immediately: Bool) {
        guard !isPreview else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = immediately
            while !Task.isCancelled {
                guard let self else { return }
                if first {
                    await self.refresh()
                } else {
                    first = true
                }
                try? await Task.sleep(for: self.isPopoverVisible ? Self.visibleInterval : Self.backgroundInterval)
            }
        }
    }

    // MARK: Refresh

    /// Reads every account at once. An account that fails keeps its last devices until it has failed a few times.
    public func refresh() async {
        guard !isPreview, !isRefreshing, !providers.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let current = Array(providers.values)
        let results = await withTaskGroup(of: AccountRead.self) { group in
            for provider in current {
                group.addTask {
                    // Each read says whose it is, taken from the client itself.
                    do {
                        return AccountRead(provider: provider.provider, devices: try await provider.devices(), error: nil)
                    } catch {
                        return AccountRead(provider: provider.provider, devices: [], error: error)
                    }
                }
            }
            var all: [AccountRead] = []
            for await result in group { all.append(result) }
            return all
        }
        for read in results where providers[read.provider] != nil {
            let kind = read.provider
            switch read.error.map(Result<[HomeDevice], Error>.failure) ?? .success(read.devices) {
            case .success(let list):
                Self.log.debug("\(kind.rawValue, privacy: .public): \(list.count, privacy: .public) devices")
                failures[kind] = 0
                accounts[kind] = .connected
                // Replace by the devices' own account, so a list can never pile up on top of its last copy.
                let incoming = Set(list.map(\.provider)).union([kind])
                serverDevices = serverDevices.filter { !incoming.contains($0.provider) } + list
            case .failure(let error):
                let error = error as? ProviderError ?? .network(error.localizedDescription)
                failures[kind, default: 0] += 1
                if error == .unauthorized {
                    accounts[kind] = .unauthorized
                } else {
                    accounts[kind] = .failed(error.message)
                }
                if error == .unauthorized || failures[kind, default: 0] >= Self.failuresBeforeOffline {
                    serverDevices = serverDevices.map { $0.provider == kind ? Self.offline($0) : $0 }
                }
            }
        }
        // Never two copies of a device, whatever an account sends.
        var seen = Set<String>()
        serverDevices = serverDevices.filter { seen.insert($0.id).inserted }
        pruneOverrides()
        let ids = serverDevices.map(\.id)
        Self.log.debug("refresh: \(ids.count, privacy: .public) devices, \(Set(ids).count, privacy: .public) unique")
    }

    private static let log = Logger(subsystem: "com.coupled.lar", category: "home")

    private static func offline(_ device: HomeDevice) -> HomeDevice {
        var device = device
        device.isOnline = false
        return device
    }

    /// Drops overrides the cloud has confirmed or that have expired.
    private func pruneOverrides() {
        let date = now()
        for (id, fields) in overrides {
            guard let server = serverDevices.first(where: { $0.id == id }) else {
                overrides[id] = nil
                continue
            }
            let kept = fields.filter { _, override in
                override.expires > date && server.applying(override.command) != server
            }
            overrides[id] = kept.isEmpty ? nil : kept
        }
    }

    private func scheduleRefresh(after delay: Duration) {
        guard !isPreview else { return }
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Commands

    public func perform(_ command: HomeCommand, on deviceID: String) {
        guard let current = device(id: deviceID), current.isOnline || current.canSwitch else { return }
        let pending = queue.contains { $0.deviceID == deviceID && $0.command.field == command.field }
        if current.applying(command) == current, !pending { return }
        overrides[deviceID, default: [:]][command.field] = Override(
            command: command, expires: now().addingTimeInterval(Self.overrideLifetime)
        )
        if isPreview { return }
        if let index = queue.firstIndex(where: { $0.deviceID == deviceID && $0.command.field == command.field }) {
            queue[index].command = command
        } else {
            queue.append(Pending(deviceID: deviceID, command: command))
        }
        startWorker()
    }

    public func toggle(_ deviceID: String) {
        guard let device = device(id: deviceID), let on = device.isOn else { return }
        perform(.power(!on), on: deviceID)
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.send(next)
                if !self.queue.isEmpty { await self.sleep(Self.minimumSendGap) }
            }
            self?.worker = nil
        }
    }

    private func send(_ pending: Pending) async {
        guard let device = serverDevices.first(where: { $0.id == pending.deviceID }),
              let provider = providers[device.provider]
        else { return }
        do {
            try await provider.send(pending.command, to: device)
            overrides[pending.deviceID]?[pending.command.field]?.expires = now().addingTimeInterval(Self.overrideLifetime)
            scheduleRefresh(after: Self.refreshAfterSend)
        } catch {
            if overrides[pending.deviceID]?[pending.command.field]?.command == pending.command {
                overrides[pending.deviceID]?[pending.command.field] = nil
            }
            let error = error as? ProviderError ?? .network(error.localizedDescription)
            if error == .unauthorized { accounts[device.provider] = .unauthorized }
            showMessage("\(device.name): \(error.message)")
        }
    }

    // MARK: TV

    /// The TV's remote: keys and apps go straight out (they change nothing the list keeps).
    public var tv: AndroidTVProvider? { providers[.androidTV] as? AndroidTVProvider }

    public func press(_ key: AndroidTVProvider.Key, on deviceID: String) {
        guard let tv, let device = device(id: deviceID) else { return }
        Task {
            do {
                try await tv.press(key, on: device)
            } catch {
                showMessage("TV: \((error as? ProviderError)?.message ?? error.localizedDescription)")
            }
        }
    }

    public func tvApps(on deviceID: String) async -> [AndroidTVProvider.App] {
        guard let tv, let device = device(id: deviceID) else { return [] }
        return (try? await tv.apps(on: device)) ?? []
    }

    public func openApp(_ package: String, on deviceID: String) {
        guard let tv, let device = device(id: deviceID) else { return }
        Task {
            do {
                try await tv.openApp(package, on: device)
                scheduleRefresh(after: .seconds(2))
            } catch {
                showMessage("TV: \((error as? ProviderError)?.message ?? error.localizedDescription)")
            }
        }
    }

    // MARK: Cameras

    /// A fresh live video link for a camera (they expire within minutes).
    public func liveStreamURL(for deviceID: String) async throws -> URL {
        guard let device = device(id: deviceID),
              let provider = providers[device.provider] as? any LiveVideoProvider
        else { throw ProviderError.unsupported }
        return try await provider.liveStreamURL(for: device)
    }

    private func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}
