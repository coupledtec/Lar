import Foundation

/// Free My TV, the owner's home screen app on an Android TV: the Lar hands it, over ADB, its scenes and how the list
/// is organized (for the TV's Casa tab), and notices to show over whatever is on screen (the intercom calling, the
/// washer done). The app only takes these from the ADB shell (its receiver needs android.permission.DUMP).
public enum FreeMyTV {
    static let package = "io.freemytv"
    static let receiver = "io.freemytv/.LarReceiver"

    /// The TV's own icon names for the scenes' SF Symbols.
    static let symbols = ["moon.fill": "bedtime", "bed.double.fill": "bedtime", "sun.max.fill": "sunny", "house.fill": "home",
                          "door.left.hand.open": "home", "figure.walk": "home", "tv": "tv", "film": "live_tv",
                          "fork.knife": "kitchen", "book.fill": "lightbulb", "snowflake": "snowflake", "sparkles": "sparkles"]

    /// What the TV's Casa shows the Lar's way: scenes (as plain commands) and per-device names, favorites and rooms.
    public static func export(scenes: [HomeScene], customizations: [String: DeviceCustomization], grouping: DeviceGrouping) -> Data {
        var sceneList: [[String: Any]] = []
        for scene in scenes {
            var actions: [[String: Any]] = []
            for action in scene.actions {
                switch action.command {
                case .power(let on): actions.append(["device": action.deviceID, "type": "power", "value": on ? 1 : 0])
                case .brightness(let value): actions.append(["device": action.deviceID, "type": "brightness", "value": value])
                case .temperature(let value): actions.append(["device": action.deviceID, "type": "temperature", "value": value])
                case .color: break
                }
            }
            sceneList.append(["id": scene.id.uuidString, "name": scene.name, "symbol": symbols[scene.symbol] ?? "sparkles",
                              "actions": actions])
        }
        var devices: [String: Any] = [:]
        for (id, custom) in customizations {
            var entry: [String: Any] = ["favorite": custom.isFavorite, "hidden": custom.isHidden]
            if let name = custom.name { entry["name"] = name }
            if let room = custom.room { entry["room"] = room }
            devices[id] = entry
        }
        let object: [String: Any] = ["version": 1, "scenes": sceneList, "devices": devices, "grouping": grouping.rawValue]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// `am broadcast` arguments: every value base64, so nothing in it needs shell quoting.
    static func arguments(_ extras: [(String, Data)]) -> String {
        "-a io.freemytv.LAR -n \(receiver) " + extras.map { "--es \($0.0) \($0.1.base64EncodedString())" }.joined(separator: " ")
    }

    static func update(_ json: Data) -> String {
        "--es kind update " + arguments([("json", json)])
    }

    static func notice(title: String, body: String, doorbell: Bool) -> String {
        "--es kind \(doorbell ? "doorbell" : "alert") " + arguments([("title", Data(title.utf8)), ("body", Data(body.utf8))])
    }
}

extension AndroidTVProvider {
    /// Sends a broadcast to Free My TV on every TV the Mac reaches by ADB that has it; how many got it.
    @discardableResult
    public func sendToFreeMyTV(_ broadcast: String) async -> Int {
        var count = 0
        for host in freeMyTVHosts() {
            do {
                let installed = try await shellOn(host, "pm list packages \(FreeMyTV.package)")
                guard installed.contains("package:\(FreeMyTV.package)") else { continue }
                // "Display over other apps" for its notices; harmless when already allowed.
                _ = try await shellOn(host, "appops set \(FreeMyTV.package) SYSTEM_ALERT_WINDOW allow; am broadcast \(broadcast)")
                count += 1
            } catch {
                continue
            }
        }
        return count
    }

    public func sendFreeMyTVUpdate(_ json: Data) async -> Int {
        await sendToFreeMyTV(FreeMyTV.update(json))
    }

    public func sendFreeMyTVNotice(title: String, body: String, doorbell: Bool) async {
        await sendToFreeMyTV(FreeMyTV.notice(title: title, body: body, doorbell: doorbell))
    }
}
