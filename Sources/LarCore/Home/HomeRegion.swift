import Foundation

/// Where the app is being used, from the device's region: the cloud servers, the currency and the temperature
/// unit come right without any setup, in any country.
public enum HomeRegion {
    /// The device's country (ISO 3166-1 alpha-2).
    public static var country: String { Locale.current.region?.identifier ?? "US" }

    /// The currency the energy cost is shown in.
    public static var currency: String { Locale.current.currency?.identifier ?? "USD" }
    public static var currencySymbol: String { Locale.current.currencySymbol ?? "$" }

    enum Area { case americas, europeMiddleEastAfrica, asiaPacific }

    static func area(of country: String) -> Area {
        let code = country.uppercased()
        if americas.contains(code) { return .americas }
        if asiaPacific.contains(code) { return .asiaPacific }
        return .europeMiddleEastAfrica
    }

    /// LG ThinQ Connect's server for a country: Americas (aic), Europe, Middle East and Africa (eic), Asia and
    /// the Pacific (kic).
    public static func thinQServer(for country: String = country) -> URL {
        switch area(of: country) {
        case .americas: URL(string: "https://api-aic.lgthinq.com/")!
        case .europeMiddleEastAfrica: URL(string: "https://api-eic.lgthinq.com/")!
        case .asiaPacific: URL(string: "https://api-kic.lgthinq.com/")!
        }
    }

    /// The Tuya data center a Smart Life account of that country most likely lives in (the owner can change it).
    public static func tuyaRegion(for country: String = country) -> String {
        switch country.uppercased() {
        case "CN": return "cn"
        case "IN": return "in"
        default: return area(of: country) == .europeMiddleEastAfrica ? "eu" : "us"
        }
    }

    static let americas: Set<String> = [
        "AG", "AI", "AR", "AW", "BB", "BL", "BM", "BO", "BQ", "BR", "BS", "BZ", "CA", "CL", "CO", "CR", "CU", "CW",
        "DM", "DO", "EC", "FK", "GD", "GT", "GY", "HN", "HT", "JM", "KN", "KY", "LC", "MF", "MS", "MX", "NI", "PA",
        "PE", "PM", "PR", "PY", "SR", "SV", "SX", "TC", "TT", "US", "UY", "VC", "VE", "VG", "VI",
    ]

    static let asiaPacific: Set<String> = [
        "AS", "AU", "BD", "BN", "BT", "CK", "CN", "FJ", "FM", "GU", "HK", "ID", "IN", "JP", "KH", "KI", "KR", "LA",
        "LK", "MH", "MM", "MN", "MO", "MP", "MV", "MY", "NC", "NP", "NR", "NU", "NZ", "PF", "PG", "PH", "PW", "SB",
        "SG", "TH", "TL", "TO", "TV", "TW", "VN", "VU", "WS",
    ]
}
