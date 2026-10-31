import Foundation

#if !os(watchOS)

/// The SmartThings integration made by hand, for whoever prefers it to "Criar e entrar": the personal token, the
/// integration (client ID and secret) and the refresh token, with the exact redirect and scopes Lar signs in with.
/// Every Settings screen shows the same steps; the commands are ready to copy, with the parts to fill in capitals.
public enum SmartThingsManualGuide {
    public struct Step: Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let text: String
        /// A command or link to copy, when the step has one.
        public let command: String?
    }

    public static var scopes: [String] { SmartThingsSignIn.scopes.split(separator: " ").map(String.init) }

    /// The sign-in page for an integration made by hand (the code shows up in the address it returns to).
    public static func authorizeLink(clientID: String = "CLIENT_ID") -> String {
        var components = URLComponents(string: "https://api.smartthings.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SmartThingsSignIn.redirect),
            URLQueryItem(name: "scope", value: SmartThingsSignIn.scopes),
        ]
        return components.url!.absoluteString
    }

    public static var createCommand: String {
        let scopeList = scopes.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            curl -X POST https://api.smartthings.com/v1/apps \\
              -H "Authorization: Bearer TOKEN_PESSOAL" -H "Content-Type: application/json" \\
              -d '{"appName":"lar-NOME-DO-APARELHO","displayName":"Lar (NOME DO APARELHO)","description":"Lar",\
            "appType":"API_ONLY","classifications":["CONNECTED_SERVICE"],"singleInstance":true,\
            "oauth":{"clientName":"Lar","scope":[\(scopeList)],"redirectUris":["\(SmartThingsSignIn.redirect)"]}}'
            """
    }

    public static var tokenCommand: String {
        """
        curl -X POST https://api.smartthings.com/oauth/token -u "CLIENT_ID:CLIENT_SECRET" \\
          -d grant_type=authorization_code -d client_id=CLIENT_ID -d code=CODIGO \\
          -d redirect_uri=\(SmartThingsSignIn.redirect)
        """
    }

    public static var steps: [Step] {
        [
            Step(id: 1, title: tr("1. Token pessoal"),
                 text: tr("Em account.smartthings.com/tokens, toque em “Generate new token”, dê um nome (Lar) e marque a permissão Apps (todas as opções). Copie o token: ele aparece uma vez só. Ele serve só para criar a integração; o Lar não o guarda."),
                 command: SmartThingsSetup.tokensPage.absoluteString),
            Step(id: 2, title: tr("2. Client ID e Client Secret"),
                 text: tr("Num computador, rode o comando abaixo no Terminal, trocando TOKEN_PESSOAL pelo token e NOME-DO-APARELHO por um nome sem espaços (iphone, mac, relogio). A resposta traz “oauthClientId” (o Client ID) e “oauthClientSecret” (o Client Secret): guarde os dois, o secret não aparece de novo. Pelo SmartThings CLI dá no mesmo: “smartthings apps:create”, tipo OAuth-In App, com as permissões \(scopes.joined(separator: ", ")) e o redirect \(SmartThingsSignIn.redirect)."),
                 command: createCommand),
            Step(id: 3, title: tr("3. Entrar e pegar o código"),
                 text: tr("Abra o link abaixo no navegador, trocando CLIENT_ID pelo seu. Entre na conta Samsung e autorize. A página que abre depois mostra, em “args”, o “code”: copie (vale poucos minutos)."),
                 command: authorizeLink()),
            Step(id: 4, title: tr("4. Refresh token"),
                 text: tr("Rode o comando abaixo com o Client ID, o Client Secret e o código (CODIGO). A resposta traz o “refresh_token”."),
                 command: tokenCommand),
            Step(id: 5, title: tr("5. No Lar"),
                 text: tr("SmartThings → Usar OAuth: cole o Client ID, o Client Secret e o refresh token e toque em Salvar. Sem o refresh token, toque em “Entrar no SmartThings” e o Lar faz os passos 3 e 4 sozinho. No relógio, use a seção “SmartThings no relógio” do iPhone. Uma integração para cada aparelho (iPhone, Mac, relógio, TV): com a mesma, um desconecta o outro, porque o refresh token muda a cada renovação (o Lar guarda o novo sozinho)."),
                 command: nil),
        ]
    }
}
#endif
