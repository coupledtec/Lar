import StoreKit
import SwiftUI

/// Who makes Lar and how to help: the site, issues, the code and contributions.
public enum LarAbout {
    public static let site = URL(string: "https://www.coupled.com.br")!
    public static let repository = URL(string: "https://github.com/coupledtec/Lar")!
    public static let newIssue = URL(string: "https://github.com/coupledtec/Lar/issues/new")!
    public static let contributing = URL(string: "https://github.com/coupledtec/Lar/blob/main/CONTRIBUTING.md")!
    public static let sponsors = URL(string: "https://github.com/sponsors/coupledtec")!
    public static let buyMeACoffee = URL(string: "https://buymeacoffee.com/coupled")!
    /// Coupled's PIX key (its CNPJ), as shown and as copied.
    public static let pixKey = "41.107.909/0001-20"
    public static let pixKeyDigits = "41107909000120"

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

/// What a version may offer for contributions: the store ones only App Store tips (App Review 3.1.1); the GitHub
/// one, GitHub Sponsors, Buy Me a Coffee and PIX.
public enum ContributionOptions: Sendable {
    case appStoreTips, external
}

public struct AboutView: View {
    let contributions: ContributionOptions
    @State private var tips = TipJar()
    @State private var copied = false
    @Environment(\.purchase) private var purchase

    public init(contributions: ContributionOptions) {
        self.contributions = contributions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lar \(LarAbout.version)").font(.title3.weight(.semibold))
                Text("Feito pela Coupled").foregroundStyle(.secondary)
                link("coupled.com.br", LarAbout.site)
            }
            Text("O Lar é gratuito e de código aberto (licença MIT): sem servidor, sem conta e sem coleta de dados.")
                .fixedSize(horizontal: false, vertical: true)

            section("Ajude o Lar a continuar gratuito") {
                Text("Manter o Lar custa a anuidade de desenvolvedor da Apple (US$ 99 por ano) e muitas horas de trabalho. Qualquer contribuição ajuda.")
                    .fixedSize(horizontal: false, vertical: true)
                switch contributions {
                case .appStoreTips: tipButtons
                case .external: externalOptions
                }
            }

            section("Problemas e ideias") {
                Text("Encontrou um problema ou tem uma ideia? Abra uma issue no GitHub contando o que aconteceu, o aparelho e a versão do Lar. O relatório do Diagnóstico (nos Ajustes) ajuda e não tem nenhuma chave.")
                    .fixedSize(horizontal: false, vertical: true)
                link("Abrir uma issue no GitHub", LarAbout.newIssue)
            }

            section("Contribuir com código") {
                Text("O código do Lar está no GitHub. Faça um fork, crie um branch com a mudança e mande um pull request; o guia de contribuição explica como.")
                    .fixedSize(horizontal: false, vertical: true)
                link("Ver o código no GitHub", LarAbout.repository)
                link("Guia de contribuição", LarAbout.contributing)
            }
        }
        .task { if contributions == .appStoreTips { await tips.load() } }
    }

    // MARK: Contributions

    /// The store's screenshots (`-LarScreenshots YES`, where the simulator has no products): the three tips as
    /// they look in Brazil, or in dollars in English.
    private static var screenshotTips: [(String, String)] {
        let brazil = Locale.current.language.languageCode?.identifier == "pt"
        return [(tr("Um café"), brazil ? "R$ 5,90" : "$0.99"), (tr("Um lanche"), brazil ? "R$ 14,90" : "$1.99"),
                (tr("Um jantar"), brazil ? "R$ 29,90" : "$4.99")]
    }

    @ViewBuilder
    private var tipButtons: some View {
        // In the screenshots always these: the simulator's sandbox answers as the US store, whatever the language.
        if UserDefaults.standard.bool(forKey: "LarScreenshots") {
            HStack(spacing: 10) {
                ForEach(Self.screenshotTips, id: \.0) { name, price in
                    Button {} label: {
                        VStack(spacing: 2) {
                            Text(name).font(.callout.weight(.semibold))
                            Text(price).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.bordered)
                    #endif
                }
            }
        } else if tips.products.isEmpty {
            if tips.loaded {
                Text("As gorjetas não estão disponíveis agora.").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } else {
            HStack(spacing: 10) {
                ForEach(tips.products) { product in
                    Button {
                        Task {
                            guard let result = try? await purchase(product) else { return }
                            await tips.finish(result)
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(product.displayName).font(.callout.weight(.semibold))
                            Text(product.displayPrice).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.bordered)
                    #endif
                }
            }
        }
        if let message = tips.message {
            Text(message).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var externalOptions: some View {
        link("GitHub Sponsors", LarAbout.sponsors)
        link("Buy Me a Coffee", LarAbout.buyMeACoffee)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PIX (CNPJ da Coupled)").font(.callout.weight(.semibold))
                Text(LarAbout.pixKey).font(.body.monospacedDigit())
            }
            Spacer()
            #if os(macOS) || os(iOS) || os(visionOS)
            Button(copied ? "Copiada" : "Copiar a chave") {
                copy(LarAbout.pixKeyDigits)
                copied = true
            }
            #endif
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    /// A link; on the Apple TV (no browser) the address, to open on another device.
    @ViewBuilder
    private func link(_ title: LocalizedStringKey, _ url: URL) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(url.absoluteString.replacingOccurrences(of: "https://", with: "")).font(.caption).foregroundStyle(.secondary)
        }
        #else
        Link(destination: url) { Label(title, systemImage: "arrow.up.right.square") }
        #endif
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS) || os(visionOS)
        UIPasteboard.general.string = text
        #endif
    }
}
