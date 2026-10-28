#if canImport(CloudKit)
import CloudKit
import Foundation

/// The scenes and the list's organization through iCloud, anywhere (not only on the home network). Only in the App
/// Store apps: on when the app's Info.plist names the container (`LarCloudContainer`), which the notarized Mac doesn't.
/// Never the accounts' keys. Sits beside the home network sync with the Mac: both bring everything to the newer state.
///
/// One record (`HomeState`) in a zone of its own, which its owner can share with someone else in the house (a
/// zone-wide share); a device that joined someone's house syncs with that zone instead of its own.
public enum CloudSync {
    public static let containerID: String? = (Bundle.main.object(forInfoDictionaryKey: "LarCloudContainer") as? String)
        .flatMap { $0.isEmpty ? nil : $0 }

    public static var isAvailable: Bool { containerID != nil }

    /// Only called when available.
    public static var container: CKContainer { CKContainer(identifier: containerID ?? "") }

    static let zoneName = "Lar"
    static let ownZone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    static let stateRecordName = "home-state"
    static let stateType = "HomeState"
    static let alertType = "Alert"
    /// Silent pushes when the shared state changes (in this account's zone or in a joined house).
    static let changesSubscription = "lar-changes"
    /// A notification for each alert the Mac publishes (the washer done, the intercom calling).
    static let alertsSubscription = "lar-alerts"

    // MARK: Where the state lives

    /// The house someone else shared with this device (their zone), once joined.
    public static var joinedZone: CKRecordZone.ID? {
        get {
            guard let owner = Preferences.string(forKey: "cloudJoinedOwner") else { return nil }
            return CKRecordZone.ID(zoneName: Preferences.string(forKey: "cloudJoinedZone") ?? zoneName, ownerName: owner)
        }
        set {
            Preferences.set(newValue?.ownerName, forKey: "cloudJoinedOwner")
            Preferences.set(newValue?.zoneName, forKey: "cloudJoinedZone")
        }
    }

    public static var hasJoinedHouse: Bool { joinedZone != nil }

    /// Whose house it is, as iCloud names them.
    public static var joinedOwnerName: String? { Preferences.string(forKey: "cloudJoinedName") }

    static var zone: CKRecordZone.ID { joinedZone ?? ownZone }
    static var database: CKDatabase { hasJoinedHouse ? container.sharedCloudDatabase : container.privateCloudDatabase }

    // MARK: Sync

    /// Brings this device and iCloud to the newer state. Returns which way it went (nil: already the same).
    @MainActor
    @discardableResult
    public static func sync(_ settings: AccountSettings) async throws -> SyncState.Direction? {
        guard isAvailable else { return nil }
        try await requireAccount()
        try await prepareZone()
        await subscribeToChanges()
        await checkPublisher()
        // A second try when someone else saved in between.
        for attempt in 0..<2 {
            let record = try await fetchState()
            let local = SyncState.capture(settings)
            guard let record, let remote = decode(record) else {
                try await save(local, over: record)
                return .push
            }
            switch SyncState.direction(local: local, remote: remote) {
            case .pull?:
                remote.apply(to: settings)
                return .pull
            case .push?:
                do {
                    try await save(local, over: record)
                    return .push
                } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                    continue
                }
            case nil:
                return nil
            }
        }
        return nil
    }

    static func requireAccount() async throws {
        let status = try await container.accountStatus()
        guard status == .available else { throw CloudSyncError.noAccount }
    }

    /// This account's zone, made once.
    static func prepareZone() async throws {
        guard !hasJoinedHouse, Preferences.bool(forKey: "cloudZoneReady") != true else { return }
        let (results, _) = try await container.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: ownZone)], deleting: [])
        if case .failure(let error)? = results[ownZone] { throw error }
        Preferences.set(true, forKey: "cloudZoneReady")
    }

    static func fetchState() async throws -> CKRecord? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: stateRecordName, zoneID: zone))
        } catch let error as CKError {
            switch error.code {
            case .unknownItem:
                return nil
            case .zoneNotFound, .userDeletedZone:
                if hasJoinedHouse {
                    // The owner stopped sharing (or removed this person): back to this account's own.
                    joinedZone = nil
                    throw CloudSyncError.houseGone
                }
                Preferences.set(nil, forKey: "cloudZoneReady")
                try await prepareZone()
                return nil
            default:
                throw error
            }
        }
    }

    static func decode(_ record: CKRecord) -> SyncState? {
        (record["state"] as? Data).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) }
    }

    static func save(_ state: SyncState, over existing: CKRecord?) async throws {
        let record = existing ?? CKRecord(recordType: stateType, recordID: CKRecord.ID(recordName: stateRecordName, zoneID: zone))
        record["state"] = try JSONEncoder().encode(state) as NSData
        record["updatedAt"] = state.updatedAt as NSDate
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        if case .failure(let error)? = results[record.recordID] { throw error }
    }

    /// Silent pushes on every change, in this account's zones and in the houses shared with it (made once each).
    static func subscribeToChanges() async {
        for (database, key) in [(container.privateCloudDatabase, "cloudSubscribedPrivate"),
                                (container.sharedCloudDatabase, "cloudSubscribedShared")] {
            guard Preferences.bool(forKey: key) != true else { continue }
            let subscription = CKDatabaseSubscription(subscriptionID: changesSubscription)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            if let (results, _) = try? await database.modifySubscriptions(saving: [subscription], deleting: []),
               case .success? = results[changesSubscription] {
                Preferences.set(true, forKey: key)
            }
        }
    }

    /// Whether a remote notification is iCloud saying the shared state changed (then sync), as opposed to an alert.
    public static func isChange(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == changesSubscription
    }

    // MARK: Sharing the house

    /// The share of this account's house, made the first time: who else is in it, and the invitation to send.
    public static func houseShare() async throws -> CKShare {
        try await requireAccount()
        try await prepareZone()
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ownZone)
        if let existing = try? await container.privateCloudDatabase.record(for: id) as? CKShare { return existing }
        let share = CKShare(recordZoneID: ownZone)
        share[CKShare.SystemFieldKey.title] = tr("Casa no Lar") as NSString
        share.publicPermission = .none
        let (results, _) = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
        if case .failure(let error)? = results[share.recordID] { throw error }
        return share
    }

    /// Whether this account's house is shared with anyone (false when it can't tell).
    public static func isSharingHouse() async -> Bool {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ownZone)
        guard let share = try? await container.privateCloudDatabase.record(for: id) as? CKShare else { return false }
        return share.participants.contains { $0.role != .owner }
    }

    /// Joins the house of the invitation this device was opened with. What's in that house replaces this device's
    /// scenes and organization (its own stay in iCloud, back when it leaves).
    @MainActor
    public static func join(_ metadata: CKShare.Metadata, settings: AccountSettings) async throws {
        if metadata.participantRole != .owner {
            _ = try await container.accept(metadata)
            joinedZone = metadata.share.recordID.zoneID
            let name = metadata.ownerIdentity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }
            Preferences.set(name, forKey: "cloudJoinedName")
        }
        settings.syncUpdatedAt = .distantPast
        try await sync(settings)
    }

    /// Leaves the house someone shared, back to this account's own.
    @MainActor
    public static func leaveHouse(_ settings: AccountSettings) async throws {
        guard let zone = joinedZone else { return }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        _ = try? await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [id])
        joinedZone = nil
        Preferences.set(nil, forKey: "cloudJoinedName")
        settings.syncUpdatedAt = .distantPast
        try await sync(settings)
    }

    // MARK: Alerts from the Mac

    /// The iPhone, the iPad and the watch get the Mac's alerts as notifications, with Lar closed (on unless turned off).
    public static var receivesAlerts: Bool {
        get { Preferences.bool(forKey: "cloudAlerts") ?? true }
        set { Preferences.set(newValue, forKey: "cloudAlerts") }
    }

    /// Subscribes to (or drops) the Mac's alerts, as `receivesAlerts` says. Only for this account's own house.
    public static func updateAlertSubscription() async {
        #if os(tvOS)
        // No banners on the Apple TV.
        return
        #else
        guard isAvailable, !hasJoinedHouse, (try? await requireAccount()) != nil else { return }
        let database = container.privateCloudDatabase
        guard receivesAlerts else {
            _ = try? await database.modifySubscriptions(saving: [], deleting: [alertsSubscription])
            Preferences.set(nil, forKey: "cloudAlertsSubscribed")
            return
        }
        guard Preferences.bool(forKey: "cloudAlertsSubscribed") != true, (try? await prepareZone()) != nil else { return }
        let subscription = CKQuerySubscription(recordType: alertType, predicate: NSPredicate(value: true),
                                               subscriptionID: alertsSubscription, options: .firesOnRecordCreation)
        subscription.zoneID = ownZone
        let info = CKSubscription.NotificationInfo()
        // The texts are the record's own: a key with no translation is shown as is.
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        subscription.notificationInfo = info
        if let (results, _) = try? await database.modifySubscriptions(saving: [subscription], deleting: []),
           case .success? = results[alertsSubscription] {
            Preferences.set(true, forKey: "cloudAlertsSubscribed")
        }
        #endif
    }

    /// Whether the Mac's alerts reach this device: then it doesn't post the same ones itself (the washer done).
    public static var alertsComeFromMac: Bool {
        guard isAvailable, !hasJoinedHouse, receivesAlerts,
              let seen = Preferences.object(forKey: "cloudPublisherSeen") as? Date else { return false }
        return Date().timeIntervalSince(seen) < publisherLifetime
    }

    /// A Mac that stopped saying it publishes (closed, turned off) for this long no longer counts.
    static let publisherLifetime: TimeInterval = 2 * 3600
    static let publisherRecordName = "alert-publisher"

    /// The Mac's side, every hour while it runs: "the alerts come from here".
    public static func announcePublisher() async {
        guard isAvailable, publishesAlerts, !hasJoinedHouse, (try? await prepareZone()) != nil else { return }
        let id = CKRecord.ID(recordName: publisherRecordName, zoneID: ownZone)
        let record = (try? await container.privateCloudDatabase.record(for: id)) ?? CKRecord(recordType: "AlertPublisher", recordID: id)
        record["seenAt"] = Date() as NSDate
        _ = try? await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
    }

    /// The other devices' side, at each sync: whether a Mac publishes the alerts now.
    static func checkPublisher() async {
        guard !hasJoinedHouse else { return }
        let id = CKRecord.ID(recordName: publisherRecordName, zoneID: ownZone)
        let seen = (try? await container.privateCloudDatabase.record(for: id))?["seenAt"] as? Date
        Preferences.set(seen, forKey: "cloudPublisherSeen")
    }

    /// The Mac publishes its alerts for the other devices (Ajustes → iPhone; on unless turned off).
    public static var publishesAlerts: Bool {
        get { Preferences.bool(forKey: "cloudPublishAlerts") ?? true }
        set { Preferences.set(newValue, forKey: "cloudPublishAlerts") }
    }

    /// The Mac's side: one record per alert, which the others' subscriptions turn into notifications. The older
    /// ones are deleted as new ones come (they've been delivered by then).
    public static func publish(_ alerts: [HomeAlert]) async {
        guard isAvailable, publishesAlerts, !hasJoinedHouse, !alerts.isEmpty, (try? await prepareZone()) != nil else { return }
        let records = alerts.map { alert in
            let record = CKRecord(recordType: alertType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: ownZone))
            record["title"] = alert.title as NSString
            record["body"] = alert.body as NSString
            record["kind"] = alert.id as NSString
            return record
        }
        var published = Preferences.object(forKey: "cloudPublishedAlerts") as? [String] ?? []
        let stale = published.count > 20 ? Array(published.prefix(published.count - 20)) : []
        guard (try? await container.privateCloudDatabase.modifyRecords(
            saving: records, deleting: stale.map { CKRecord.ID(recordName: $0, zoneID: ownZone) })) != nil else { return }
        published.removeFirst(stale.count)
        published += records.map(\.recordID.recordName)
        Preferences.set(published, forKey: "cloudPublishedAlerts")
    }
}

public enum CloudSyncError: Error, Equatable, Sendable {
    case noAccount
    case houseGone

    public var message: String {
        switch self {
        case .noAccount: tr("Entre no iCloud nos Ajustes do aparelho para sincronizar.")
        case .houseGone: tr("A casa compartilhada não está mais disponível. Voltando para a sua.")
        }
    }
}
#endif
