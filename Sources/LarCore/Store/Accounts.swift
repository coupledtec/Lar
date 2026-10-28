import Foundation

/// Everything the app keeps: the LG token and air conditioner settings, plus the other accounts.
public typealias LarSettings = SettingsStorage & AccountSettings

/// Builds the clients for the accounts that have keys. Shared by the Mac, iPhone and Watch apps.
public enum Accounts {
    /// - Parameters:
    ///   - includeTVs: Android TVs need raw local network access, which the watch doesn't allow.
    ///   - tvADB: reach TVs not paired with the remote protocol through ADB (the Mac).
    ///   - tvClientName: how this device shows on a TV while pairing.
    ///   - saveRefreshToken: where a renewed SmartThings refresh token is saved (it replaces the old one at once).
    public static func providers(
        _ settings: LarSettings, includeTVs: Bool, tvADB: Bool = true, tvClientName: String = "Lar",
        saveRefreshToken: @escaping @Sendable (String) -> Void = { AppSettings.saveSmartThingsRefreshToken($0) },
        loadRefreshToken: @escaping @Sendable () -> String? = { Keychain.read("st-refresh-token") },
        includeAlexa: Bool = true
    ) -> [any DeviceProvider] {
        if DemoHome.isOn { return DemoHome.providers() }
        var out: [any DeviceProvider] = []
        if let token = settings.token, !token.isEmpty {
            out.append(LGProvider(client: ThinQClient(token: token, clientID: settings.clientID)))
        }
        if let tuya = settings.tuya {
            out.append(TuyaClient(credentials: tuya))
        }
        if includeAlexa, let alexa = settings.alexa {
            out.append(AlexaProvider(client: AlexaClient(account: alexa, save: { AppSettings.alexaAccount = $0 })))
        }
        if let xbox = settings.xbox {
            // Microsoft renews the refresh token at each use; not after signing out meanwhile.
            out.append(XboxProvider(client: XboxClient(account: xbox, save: { account in
                if AppSettings.xboxAccount != nil { AppSettings.xboxAccount = account }
            })))
        }
        if includeTVs, settings.tvDiscovery || settings.tvHost != nil {
            let discover: @Sendable () async -> [TVDiscovery.Found]
            if settings.tvDiscovery {
                discover = { await TVDiscovery.scan() }
            } else {
                discover = { [] }
            }
            out.append(AndroidTVProvider(
                manualHosts: settings.tvHost.map { [$0] } ?? [],
                known: settings.knownTVs,
                discover: discover,
                remember: { AppSettings.saveKnownTVs($0) },
                useADB: tvADB,
                paired: settings.pairedTVs,
                rememberPaired: { AppSettings.savePairedTVs($0) },
                clientName: tvClientName,
                pins: settings.tvPins,
                rememberPins: { AppSettings.saveTVPins($0) }
            ))
        }
        if let smartThings = settings.smartThings {
            out.append(SmartThingsClient(credentials: smartThings, saveRefreshToken: saveRefreshToken,
                                         loadRefreshToken: loadRefreshToken))
        }
        return out
    }
}
