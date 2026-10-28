import Foundation
import Observation
import StoreKit

/// Tips through the App Store (consumable purchases), the only way the store versions may take a contribution.
/// The GitHub version shows the other ways instead (LarAbout).
@MainActor
@Observable
public final class TipJar {
    /// A coffee, a snack, a dinner: R$ 5,90, R$ 14,90 and R$ 29,90 in Brazil.
    public static let productIDs = ["br.com.coupled.lar.ios.tip.coffee", "br.com.coupled.lar.ios.tip.snack",
                                    "br.com.coupled.lar.ios.tip.dinner"]

    public private(set) var products: [Product] = []
    public private(set) var loaded = false
    public var message: String?

    public init() {}

    public func load() async {
        products = ((try? await Product.products(for: Self.productIDs)) ?? []).sorted { $0.price < $1.price }
        loaded = true
    }

    /// What the purchase sheet answered.
    public func finish(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            message = tr("Obrigado pela gorjeta! Ela ajuda o Lar a continuar gratuito.")
        case .success(.unverified):
            message = tr("A App Store não confirmou a compra.")
        case .pending:
            message = tr("A compra está esperando aprovação (Compartilhamento Familiar ou banco).")
        case .userCancelled:
            break
        @unknown default:
            break
        }
    }

    /// Tips finished elsewhere or interrupted (an approval, a crash) are closed at launch, as the App Store expects.
    public static func listen() {
        Task.detached {
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
            }
        }
    }
}
