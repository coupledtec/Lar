import Foundation

/// A robot or lock brand's account, as its cloud handed it back at sign-in: the e-mail it was made with and what
/// the brand needs to come back (tokens, keys, region), as text. Kept in the keychain with the others' (one item),
/// never shown again. Unofficial integrations: each brand can change its cloud without notice.
public struct BrandAccount: Codable, Sendable, Equatable {
    public var email: String
    public var values: [String: String]

    public init(email: String, values: [String: String] = [:]) {
        self.email = email
        self.values = values
    }

    public subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// A value kept as JSON (a device list cached between reads, a token's details).
    public func decoded<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        values[key].flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    public mutating func encode<T: Encodable>(_ value: T?, _ key: String) {
        values[key] = value.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Signing in to a brand: e-mail (and the password, for the brands that take one), then a code sent by e-mail or
/// SMS when the brand asks for one.
public enum BrandSignInStep: Sendable {
    case done(BrandAccount)
    /// The brand sent a code; `finish` takes it.
    case code(hint: String, finish: @Sendable (String) async throws -> BrandAccount)
}

/// What each brand's sign-in asks and does.
public struct BrandSignIn: Sendable {
    public var provider: Provider
    /// What it controls and from which app's account, for the settings.
    public var hint: String
    public var needsPassword: Bool
    /// The brand's own app, where the devices must be set up first.
    public var appName: String
    /// The brand has no renewal token: the password stays in the keychain to sign in again (Eufy).
    public var keepsPassword = false
    public var start: @Sendable (_ email: String, _ password: String) async throws -> BrandSignInStep

    public init(provider: Provider, hint: String, needsPassword: Bool, appName: String, keepsPassword: Bool = false,
                start: @escaping @Sendable (_ email: String, _ password: String) async throws -> BrandSignInStep) {
        self.provider = provider
        self.hint = hint
        self.needsPassword = needsPassword
        self.appName = appName
        self.keepsPassword = keepsPassword
        self.start = start
    }
}

extension Provider {
    /// How to sign in to this brand (nil for the accounts that aren't brands).
    public var signIn: BrandSignIn? {
        switch self {
        case .roborock: RoborockClient.signIn
        case .xiaomi: XiaomiClient.signIn
        case .dreame: DreameClient.signIn
        case .ecovacs: EcovacsClient.signIn
        case .yale: YaleClient.signIn
        case .irobot: IRobotClient.signIn
        case .eufy: EufyClient.signIn
        default: nil
        }
    }

    /// The brand's client for a saved account. `save` keeps what the brand renews (tokens, the cached device list).
    func brandProvider(_ account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void) -> (any DeviceProvider)? {
        switch self {
        case .roborock: RoborockProvider(client: RoborockClient(account: account, save: save))
        case .xiaomi: XiaomiProvider(client: XiaomiClient(account: account, save: save))
        case .dreame: DreameProvider(client: DreameClient(account: account, save: save))
        case .ecovacs: EcovacsProvider(client: EcovacsClient(account: account, save: save))
        case .yale: YaleProvider(client: YaleClient(account: account, save: save))
        case .irobot: IRobotProvider(client: IRobotClient(account: account, save: save))
        case .eufy: EufyProvider(client: EufyClient(account: account, save: save))
        default: nil
        }
    }

    /// The brands whose control needs a connection of its own (MQTT), which the watch can't open.
    public var needsSockets: Bool { [.roborock, .irobot, .eufy].contains(self) }
}

extension AppSettings {
    /// The robot and lock brands' accounts, by provider (one keychain item).
    public static var brandAccounts: [String: BrandAccount] {
        get {
            Keychain.read("brand-accounts").flatMap { try? JSONDecoder().decode([String: BrandAccount].self, from: Data($0.utf8)) } ?? [:]
        }
        set {
            if newValue.isEmpty {
                Keychain.delete("brand-accounts")
            } else if let data = try? JSONEncoder().encode(newValue) {
                Keychain.write(String(decoding: data, as: UTF8.self), account: "brand-accounts", label: "Lar – robôs e fechaduras")
            }
        }
    }

    public static func brandAccount(_ provider: Provider) -> BrandAccount? { brandAccounts[provider.rawValue] }

    public static func setBrandAccount(_ account: BrandAccount?, for provider: Provider) {
        var all = brandAccounts
        all[provider.rawValue] = account
        brandAccounts = all
    }

    /// What a brand renewed, kept only while the account is still there (not after signing out meanwhile).
    static func renewBrandAccount(_ account: BrandAccount, for provider: Provider) {
        guard brandAccount(provider)?.email == account.email else { return }
        setBrandAccount(account, for: provider)
    }
}

/// Intelbras locks (the Izy line) run on Tuya's platform and Intelbras has no API of its own: they reach Lar through
/// the Smart Life account, once paired there.
public enum IntelbrasGuide {
    public static let steps = [
        tr("As fechaduras Intelbras (linha Izy) usam a plataforma Tuya, a mesma do Smart Life. A Intelbras não libera acesso para outros apps, então o caminho é o Smart Life:"),
        tr("1. No app Izy Smart, remova a fechadura (ou o hub dela). Ela deixa de aparecer no Izy."),
        tr("2. No app Smart Life, toque em + e adicione a fechadura, ou o hub e depois a fechadura."),
        tr("3. No Lar, a fechadura aparece pela conta Smart Life (Ajustes → Smart Life), com a porta e a bateria."),
        tr("Se o Smart Life não reconhecer o modelo, ele só funciona no app da Intelbras."),
    ]
}

