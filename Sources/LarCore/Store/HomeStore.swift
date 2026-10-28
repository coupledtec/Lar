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
    public private(set) var serverDevices: [HomeDevice] = [] {
        didSet { revision &+= 1 }
    }
    public private(set) var accounts: [Provider: AccountState] = [:]
    /// Devices that turn off by themselves, and when.
    public internal(set) var offTimers: [String: Date] = [:]
    @ObservationIgnored var offTimerTasks: [String: Task<Void, Never>] = [:]
    /// How each account's last reads went, for the Diagnostics screen.
    public private(set) var health: [Provider: AccountHealth] = [:]
    public private(set) var isRefreshing = false
    /// A short-lived error to show, e.g. a command the device rejected.
    public private(set) var transientMessage: String?
    @ObservationIgnored private var overrides: [String: [HomeField: Override]] = [:] {
        didSet { revision &+= 1 }
    }
    /// Changes whenever what `devices` is made of changes: the list is built again only then (and the views that
    /// show it are told, an optimistic change included).
    private var revision = 0
    @ObservationIgnored private var built: Built?
    /// Set when a read is asked for while one is going: it may have started before a command went out.
    @ObservationIgnored private var refreshAgain = false
    /// The owner's names, favorites, rooms and hidden devices, by device id.
    public var customizations: [String: DeviceCustomization] = [:] {
        didSet {
            guard oldValue != customizations else { return }
            revision &+= 1
            onListPreferencesChange?(customizations, grouping)
        }
    }
    /// How the list is grouped below the favorites.
    public var grouping: DeviceGrouping = .kind {
        didSet { if oldValue != grouping { onListPreferencesChange?(customizations, grouping) } }
    }
    /// Saves the two above when they change.
    /// Notifications to post after a refresh (a washer that finished). Only the Mac and the iPhone set it.
    @ObservationIgnored public var onAlerts: (([HomeAlert]) -> Void)?
    /// After every read of the accounts (the iPhone saves the widgets' copy and updates the Live Activities).
    @ObservationIgnored public var onRefreshed: (() -> Void)?
    /// An account just refused its keys (it was fine before): the app may sign in again by itself.
    @ObservationIgnored public var onUnauthorized: ((Provider) -> Void)?
    @ObservationIgnored public var onListPreferencesChange: (([String: DeviceCustomization], DeviceGrouping) -> Void)?

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
    @ObservationIgnored let now: () -> Date
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
        var duration: Duration = .zero
    }

    /// The list as last built, until something it's made of changes or an optimistic change in it expires.
    struct Built {
        var revision: Int
        var validUntil: Date
        var list: [HomeDevice]
        var index: [String: Int]
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
    public var devices: [HomeDevice] { build().list }

    private func build() -> Built {
        let date = now()
        if let built, built.revision == revision, date < built.validUntil { return built }
        var validUntil = Date.distantFuture
        // A device in the Home app by itself and in its own account shows once, from its account.
        let duplicates = HomeAppDuplicates.matches(in: serverDevices, names: customizations.compactMapValues(\.name))
        let list = serverDevices.filter { duplicates[$0.id] == nil }.map { device in
            var device = device
            if let name = customizations[device.id]?.name { device.name = name }
            for override in (overrides[device.id] ?? [:]).values where override.expires > date {
                device = device.applying(override.command)
                validUntil = min(validUntil, override.expires)
            }
            return device
        }
        .sorted { a, b in
            let ka = Self.kindOrder.firstIndex(of: a.kind) ?? 99, kb = Self.kindOrder.firstIndex(of: b.kind) ?? 99
            return ka != kb ? ka < kb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = Built(revision: revision, validUntil: validUntil, list: list, index: index)
        built = fresh
        return fresh
    }

    public static let kindOrder: [DeviceKind] = [.tv, .gameConsole, .speaker, .airConditioner, .light, .plug, .fan, .camera, .lock, .vacuum, .laundry, .kitchen, .climateSensor, .other]

    public func device(id: String) -> HomeDevice? {
        let built = build()
        return built.index[id].map { built.list[$0] }
    }

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

    /// Rebuilds the clients only when the accounts with keys differ from the ones in use: keys unreadable when the
    /// app was woken in the background (iPhone locked) are picked up once it's opened.
    public func reloadAccountsIfChanged() {
        let configured = Set(makeProviders().map(\.provider))
        if configured != Set(providers.keys) { reloadAccounts() }
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
    /// The devices last seen (the widget snapshot), shown until the accounts answer: a process that starts while an
    /// account is failing (the widgets, the watch) keeps showing it instead of an empty list.
    public func seed(_ devices: [HomeDevice]) {
        guard serverDevices.isEmpty, !devices.isEmpty else { return }
        var seen = Set<String>()
        serverDevices = devices.filter { seen.insert($0.id).inserted }
    }

    public func refresh() async {
        guard !isPreview, !providers.isEmpty else { return }
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await readAccounts()
        } while refreshAgain
    }

    /// Every account at once, each one shown as soon as it answers (a slow account doesn't hold the others back).
    private func readAccounts() async {
        let previous = serverDevices
        let current = Array(providers.values)
        await withTaskGroup(of: AccountRead.self) { group in
            for provider in current {
                group.addTask {
                    // Each read says whose it is, taken from the client itself.
                    let start = ContinuousClock.now
                    do {
                        let devices = try await provider.devices()
                        return AccountRead(provider: provider.provider, devices: devices, error: nil, duration: ContinuousClock.now - start)
                    } catch {
                        return AccountRead(provider: provider.provider, devices: [], error: error, duration: ContinuousClock.now - start)
                    }
                }
            }
            for await read in group { apply(read) }
        }
        if !previous.isEmpty, let onAlerts {
            let alerts = alerts(after: previous)
            if !alerts.isEmpty { onAlerts(alerts) }
        }
        onRefreshed?()
        let ids = serverDevices.map(\.id)
        Self.log.debug("refresh: \(ids.count, privacy: .public) devices, \(Set(ids).count, privacy: .public) unique")
    }

    private func apply(_ read: AccountRead) {
        guard providers[read.provider] != nil else { return }
        let kind = read.provider
        var entry = health[kind] ?? AccountHealth()
        entry.lastRead = now()
        entry.duration = read.duration
        if let error = read.error {
            entry.lastError = (error as? ProviderError)?.message ?? error.localizedDescription
            entry.lastErrorAt = now()
        } else {
            entry.deviceCount = read.devices.count
        }
        health[kind] = entry
        var next = serverDevices
        switch read.error.map(Result<[HomeDevice], Error>.failure) ?? .success(read.devices) {
        case .success(let list):
            Self.log.debug("\(kind.rawValue, privacy: .public): \(list.count, privacy: .public) devices")
            failures[kind] = 0
            accounts[kind] = .connected
            // Replace by the devices' own account, so a list can never pile up on top of its last copy.
            let incoming = Set(list.map(\.provider)).union([kind])
            next = next.filter { !incoming.contains($0.provider) } + list
        case .failure(let error):
            let error = error as? ProviderError ?? .network(error.localizedDescription)
            failures[kind, default: 0] += 1
            if error == .unauthorized {
                if accounts[kind] != .unauthorized { onUnauthorized?(kind) }
                accounts[kind] = .unauthorized
            } else {
                accounts[kind] = .failed(error.message)
            }
            if error == .unauthorized || failures[kind, default: 0] >= Self.failuresBeforeOffline {
                next = next.map { $0.provider == kind ? Self.offline($0) : $0 }
            }
        }
        // Never two copies of a device, whatever an account sends.
        var seen = Set<String>()
        next = next.filter { seen.insert($0.id).inserted }
        if next != serverDevices { serverDevices = next }
        pruneOverrides()
        markHomeAppDuplicates()
    }

    /// Devices that are in the Home app by themselves (seen there by this iPhone or iPad) are left out of the Mac's
    /// bridge, so the Home app doesn't show them twice; the mark syncs to the Mac with the rest of the list's
    /// preferences. Only changed after the Home app was read: no mark is lost while it can't be.
    private func markHomeAppDuplicates() {
        guard accounts[.homeKit] == .connected else { return }
        let native = Set(HomeAppDuplicates.matches(in: serverDevices, names: customizations.compactMapValues(\.name)).values)
        var next = customizations
        for device in serverDevices where device.provider != .homeKit {
            let excluded = native.contains(device.id)
            guard (next[device.id]?.excludedFromHomeApp ?? false) != excluded else { continue }
            var value = next[device.id] ?? DeviceCustomization()
            value.excludedFromHomeApp = excluded ? true : nil
            next[device.id] = value.isEmpty ? nil : value
        }
        if next != customizations { customizations = next }
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
            if kept.count != fields.count { overrides[id] = kept.isEmpty ? nil : kept }
        }
    }

    /// Reads the accounts again shortly, to confirm a change made elsewhere (e.g. the watch switching a TV).
    public func refreshSoon() { scheduleRefresh(after: Self.refreshAfterSend) }

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

    /// - Parameter force: send even when the list already shows that state (a widget or Siri asking for "on" from a
    ///   copy of the list that may be old: what it shows isn't proof).
    public func perform(_ command: HomeCommand, on deviceID: String, force: Bool = false) {
        guard let current = device(id: deviceID), current.isOnline || current.canSwitch else { return }
        let pending = queue.contains { $0.deviceID == deviceID && $0.command.field == command.field }
        if !force, current.applying(command) == current, !pending { return }
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

    /// Whether commands are still waiting or going out.
    public var isSending: Bool { worker != nil || !queue.isEmpty }

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
            if error == .unauthorized {
                if accounts[device.provider] != .unauthorized { onUnauthorized?(device.provider) }
                accounts[device.provider] = .unauthorized
            }
            showMessage("\(device.name): \(error.message)")
        }
    }

    /// One account's client (the iPhone reads SmartThings' access token from it, for the watch).
    public func provider(_ kind: Provider) -> (any DeviceProvider)? { providers[kind] }

    // MARK: TV

    /// The TV's remote: keys and apps go straight out (they change nothing the list keeps).
    public var tv: (any TVRemoteProvider)? { providers[.androidTV] as? any TVRemoteProvider }

    /// The remote of the device's own account (Android TVs, or a Samsung TV or soundbar through SmartThings).
    private func remote(for device: HomeDevice) -> (any TVRemoteProvider)? {
        providers[device.provider] as? any TVRemoteProvider
    }

    /// Pairing happens only where the TVs are reached directly (not from the watch).
    private var directTV: AndroidTVProvider? { providers[.androidTV] as? AndroidTVProvider }

    public func press(_ key: AndroidTVProvider.Key, on deviceID: String) {
        guard let device = device(id: deviceID), let tv = remote(for: device) else { return }
        Task {
            do {
                try await tv.press(key, on: device)
            } catch {
                showMessage(tr("TV: \((error as? ProviderError)?.message ?? error.localizedDescription)"))
            }
        }
    }

    /// A remote key that waits until it's sent (a widget's button: its process may end right after).
    public func pressAndWait(_ key: AndroidTVProvider.Key, on deviceID: String) async throws {
        guard let device = device(id: deviceID), let tv = remote(for: device) else { throw ProviderError.unsupported }
        try await tv.press(key, on: device)
    }

    /// The Xbox controller's own buttons (X, Y, Menu, View, the guide).
    public func pressXbox(_ button: XboxProvider.Button, on deviceID: String) {
        guard let device = device(id: deviceID), let xbox = providers[.xbox] as? XboxProvider else { return }
        Task {
            do {
                try await xbox.press(button, on: device)
            } catch {
                showMessage(tr("Xbox: \((error as? ProviderError)?.message ?? error.localizedDescription)"))
            }
        }
    }

    /// Types into the TV's focused field.
    public func typeOnTV(_ text: String, on deviceID: String) {
        guard let device = device(id: deviceID), let tv = remote(for: device) else { return }
        Task {
            do {
                try await tv.type(text, on: device)
            } catch {
                showMessage(tr("TV: \((error as? ProviderError)?.message ?? error.localizedDescription)"))
            }
        }
    }

    public func tvApps(on deviceID: String) async -> [AndroidTVProvider.App] {
        guard let device = device(id: deviceID), let tv = remote(for: device) else { return [] }
        return (try? await tv.apps(on: device)) ?? []
    }

    public func openApp(_ package: String, on deviceID: String) {
        guard let device = device(id: deviceID), let tv = remote(for: device) else { return }
        Task {
            do {
                try await tv.openApp(package, on: device)
                scheduleRefresh(after: .seconds(2))
            } catch {
                showMessage(tr("TV: \((error as? ProviderError)?.message ?? error.localizedDescription)"))
            }
        }
    }

    /// Makes the TV show its pairing code; the error's message when it can't.
    public func startTVPairing(_ deviceID: String) async -> String? {
        guard let tv = directTV, let device = device(id: deviceID) else { return ProviderError.unsupported.message }
        do {
            try await tv.startPairing(device)
            return nil
        } catch {
            return (error as? ProviderError)?.message ?? error.localizedDescription
        }
    }

    /// Sends the code shown on the TV; on success the TV is read again, now through the remote protocol.
    public func finishTVPairing(_ deviceID: String, code: String) async -> String? {
        guard let tv = directTV, let device = device(id: deviceID) else { return ProviderError.unsupported.message }
        do {
            try await tv.finishPairing(device, code: code)
            await refresh()
            return nil
        } catch {
            return (error as? ProviderError)?.message ?? error.localizedDescription
        }
    }

    public func cancelTVPairing(_ deviceID: String) {
        guard let tv = directTV, let device = device(id: deviceID) else { return }
        Task { await tv.cancelPairing(device) }
    }

    // MARK: Cameras

    /// A fresh live video link for a camera (they expire within minutes).
    public func liveStreamURL(for deviceID: String) async throws -> URL {
        guard let device = device(id: deviceID),
              let provider = providers[device.provider] as? any LiveVideoProvider
        else { throw ProviderError.unsupported }
        return try await provider.liveStreamURL(for: device)
    }

    /// A short message under the list (a scene with devices out of reach).
    public func showNotice(_ message: String) { showMessage(message) }

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
