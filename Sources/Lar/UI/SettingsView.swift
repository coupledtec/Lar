import AppKit
import LarCore
import ServiceManagement
import SwiftUI

/// The accounts' keys (kept in the keychain, never shown back), the air conditioner's temperature range and
/// launch at login.
struct SettingsView: View {
    var model: AppModel
    var canGoBack: Bool
    var onDiagnostics: () -> Void = {}
    var onBack: () -> Void

    @State private var lgToken = ""
    @State private var notifyLaundry = Notifier.laundryEnabled
    @State private var publishAlerts = CloudSync.publishesAlerts
    @State private var lockSettings = SettingsLock.isEnabled
    @State private var acWatts = EnergyEstimate.watts
    @State private var tariff = EnergyEstimate.tariff
    @State private var tuyaID = ""
    @State private var tuyaSecret = ""
    @State private var tuyaRegion = HomeRegion.tuyaRegion()
    @State private var stToken = ""
    @State private var stClientID = ""
    @State private var stSecret = ""
    @State private var stRefresh = ""
    @State private var showOAuth = false
    @State private var stError: String?
    /// A personal token used once to create this Mac's own integration (not kept).
    @State private var stSetupToken = ""
    @State private var stCreating = false
    @State private var alexaError: String?
    @State private var xboxError: String?
    @State private var xboxGuide = false
    @State private var alexaImport = AlexaRoutineImport.autoImport
    @State private var importNote: String?
    /// "Anunciar o porteiro e os avisos nos Echos" (the Mac is the one that announces: it's always on).
    @State private var alexaAnnounce = Preferences.bool(forKey: "alexaAnnounce") ?? true
    @State private var tvHost = ""
    @State private var limits = TemperatureLimits.standard
    @State private var launchAtLogin = StartAtLogin.isEnabled
    #if !LAR_APPSTORE
    @State private var autoUpdate = Updater.installsByItself
    #endif
    @State private var loginError: String?

    private var settings: AllSettings { model.settings }
    private var home: HomeStore { model.home }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if canGoBack { BackButton(action: onBack) }
                Text("Ajustes")
                    .font(.system(size: 15, weight: .semibold))
            }
            PagedScroll(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 14) {
                    lgSection
                    tuyaSection
                    smartThingsSection
                    alexaSection
                    tvSection
                    xboxSection
                    listSection
                    phoneSection
                    homeAppSection
                    if Features.intercom { PorteiroSection(phone: model.phone) }
                    if settings.token != nil { temperatureSection }
                    generalSection
                }
            }
        }
        .onAppear {
            limits = settings.temperatureLimits
            tuyaRegion = settings.tuya?.region ?? HomeRegion.tuyaRegion()
            if case .oauth? = settings.smartThings { showOAuth = true }
        }
    }

    // MARK: LG

    private var lgSection: some View {
        section("LG ThinQ", provider: .lg) {
            hint("Token pessoal da sua conta LG. Ar-condicionado, lavadora, geladeira e outros aparelhos.")
            HStack(spacing: 6) {
                secret(settings.token != nil ? "•••••• salvo" : "thinqpat_…", text: $lgToken)
                pasteButton { lgToken = $0 }
                Button("Salvar") { save { settings.token = lgToken; settings.deviceID = nil; lgToken = "" } }
                    .disabled(lgToken.trimmed.isEmpty)
            }
            HStack {
                link("Criar token (connect-pat.lgthinq.com)", "https://connect-pat.lgthinq.com")
                Spacer()
                if settings.token != nil { removeButton { settings.token = nil; settings.deviceID = nil } }
            }
        }
    }

    // MARK: Tuya

    private var tuyaSection: some View {
        section("Smart Life (Tuya)", provider: .tuya) {
            hint("Access ID e Access Secret de um projeto Cloud em iot.tuya.com com a conta do Smart Life vinculada. Vale para Nova Digital, Ekaza e outras marcas Tuya.")
            field("Access ID", text: $tuyaID, placeholder: settings.tuya != nil ? "•••••• salvo" : "Access ID")
            HStack(spacing: 6) {
                secret(settings.tuya != nil ? "•••••• salvo" : "Access Secret", text: $tuyaSecret)
                pasteButton { tuyaSecret = $0 }
            }
            HStack {
                Text("Região").font(.system(size: 12))
                PopUpButton(
                    options: [("Américas", "us"), ("Europa", "eu"), ("China", "cn"), ("Índia", "in")],
                    selection: $tuyaRegion
                )
                .frame(width: 110)
                Spacer()
                Button("Salvar") {
                    save {
                        let current = settings.tuya
                        let id = tuyaID.trimmed.isEmpty ? current?.clientID ?? "" : tuyaID.trimmed
                        let secret = tuyaSecret.trimmed.isEmpty ? current?.secret ?? "" : tuyaSecret.trimmed
                        settings.tuya = id.isEmpty || secret.isEmpty ? nil
                            : TuyaClient.Credentials(clientID: id, secret: secret, region: tuyaRegion)
                        tuyaID = ""
                        tuyaSecret = ""
                    }
                }
                .disabled(tuyaID.trimmed.isEmpty && tuyaSecret.trimmed.isEmpty && tuyaRegion == (settings.tuya?.region ?? "us"))
            }
            HStack {
                link("Abrir iot.tuya.com", "https://iot.tuya.com")
                Spacer()
                if settings.tuya != nil { removeButton { settings.tuya = nil } }
            }
        }
    }

    // MARK: SmartThings

    /// The integration to sign in with: the one typed, or the one saved.
    private var savedOAuth: (clientID: String, secret: String)? {
        if case .oauth(let id, let secret, _)? = settings.smartThings { return (id, secret) }
        return nil
    }

    private var signInCredentials: (clientID: String, secret: String)? {
        if !stClientID.trimmed.isEmpty, !stSecret.trimmed.isEmpty { return (stClientID.trimmed, stSecret.trimmed) }
        return stClientID.trimmed.isEmpty && stSecret.trimmed.isEmpty ? savedOAuth : nil
    }

    private func signInToSmartThings() {
        guard let (clientID, secret) = signInCredentials else { return }
        signIn(clientID: clientID, secret: secret)
    }

    /// Creates an integration only this Mac uses, then signs in with it.
    private func createSmartThingsIntegration() {
        let token = stSetupToken.trimmed
        stError = nil
        stCreating = true
        Task {
            defer { stCreating = false }
            do {
                let made = try await SmartThingsSetup.createIntegration(personalToken: token, deviceName: "Mac")
                stSetupToken = ""
                signIn(clientID: made.clientID, secret: made.secret)
            } catch {
                stError = (error as? ProviderError)?.message ?? error.localizedDescription
            }
        }
    }

    private func signIn(clientID: String, secret: String) {
        // Never another device's integration: the two would log each other out at every renewal.
        if let problem = SmartThingsClaims.problem(with: clientID) {
            stError = problem
            return
        }
        stError = nil
        let request = SmartThingsSignInRequest(clientID: clientID, secret: secret)
        SignInWindow.show(request) { result in
            switch result {
            case .success(let refresh):
                save {
                    settings.smartThings = .oauth(clientID: request.clientID, secret: request.secret, refreshToken: refresh)
                    stClientID = ""; stSecret = ""
                }
            case .failure(let error):
                stError = (error as? ProviderError)?.message ?? error.localizedDescription
            case nil:
                break
            }
        }
    }

    private var alexaSection: some View {
        section("Alexa (Echo)", provider: .alexa) {
            hint("Entre com a sua conta Amazon: os Echos aparecem na lista (volume, não perturbe, música, falar, anunciar, pedir à Alexa e as rotinas). Integração não oficial: a Amazon pode mudá-la.")
            HStack {
                if let alexaError {
                    Text(alexaError).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(3)
                }
                Spacer()
                Button(AppSettings.alexaAccount == nil ? "Entrar na Amazon" : "Entrar de novo") {
                    alexaError = nil
                    SignInWindow.showAlexa { result in
                        switch result {
                        case .success(let account):
                            save { AppSettings.alexaAccount = account }
                        case .failure(let error):
                            alexaError = (error as? ProviderError)?.message ?? error.localizedDescription
                        case nil:
                            break
                        }
                    }
                }
                if AppSettings.alexaAccount != nil { removeButton { AppSettings.alexaAccount = nil } }
            }
            if AppSettings.alexaAccount != nil {
                Toggle("Anunciar o porteiro e os avisos nos Echos", isOn: $alexaAnnounce)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .onChange(of: alexaAnnounce) { _, on in Preferences.set(on, forKey: "alexaAnnounce") }
                #if LAR_PRIVATE
                PrivateExtensions.alexaSettings()
                #endif
                Toggle("Importar rotinas novas da Alexa a cada hora", isOn: $alexaImport)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .onChange(of: alexaImport) { _, on in AlexaRoutineImport.autoImport = on }
                HStack {
                    if let importNote { Text(importNote).font(.system(size: 11)).foregroundStyle(Theme.secondaryText) }
                    Spacer()
                    Button("Importar rotinas agora") {
                        importNote = "Importando…"
                        Task {
                            do {
                                let count = try await AlexaRoutineImport.run(home: home, scenes: model.scenes, onlyNew: false)
                                importNote = count == 0 ? "Nenhuma rotina ativa na Alexa." : "\(count) rotina(s) viraram cenas."
                            } catch {
                                importNote = (error as? ProviderError)?.message ?? error.localizedDescription
                            }
                        }
                    }
                }
                hint("Os passos com aparelhos que o Lar também tem (pelo nome) viram comandos da cena; os outros (falar, música, clima…) a Alexa faz num Echo quando a cena roda.")
            }
        }
    }

    private var xboxSection: some View {
        section("Xbox", provider: .xbox) {
            hint("Entre com a conta Microsoft do Xbox: o console aparece na lista para ligar, desligar, usar como controle, abrir jogos e apps e ver o que está passando. Integração não oficial: a Microsoft pode mudá-la.")
            HStack {
                if let xboxError {
                    Text(xboxError).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(3)
                } else if let account = AppSettings.xboxAccount {
                    Text("Conta: \(account.gamertag)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button(AppSettings.xboxAccount == nil ? "Entrar no Xbox" : "Entrar de novo") {
                    xboxError = nil
                    SignInWindow.showXbox { result in
                        switch result {
                        case .success(let account): save { AppSettings.xboxAccount = account }
                        case .failure(let error): xboxError = (error as? ProviderError)?.message ?? error.localizedDescription
                        case nil: break
                        }
                    }
                }
                if AppSettings.xboxAccount != nil { removeButton { AppSettings.xboxAccount = nil } }
            }
            DisclosureGroup("Como preparar o Xbox", isExpanded: $xboxGuide) {
                XboxConsoleSetup().padding(.top, 4)
            }
            .font(.system(size: 12))
        }
    }

    /// Another device (an iPhone) signs in with the integration saved here.
    private var sharedWith: String? {
        guard case .oauth(let clientID, _, _)? = settings.smartThings else { return nil }
        return SmartThingsClaims.user(of: clientID)
    }

    private var smartThingsSection: some View {
        section("SmartThings", provider: .smartThings) {
            HStack {
                Button("Configurar automaticamente") {
                    SignInWindow.showAutoSetup { results in
                        guard let mine = results.first else { return }
                        save { settings.smartThings = .oauth(clientID: mine.clientID, secret: mine.secret, refreshToken: mine.refreshToken) }
                        showOAuth = true
                    }
                }
                .font(.system(size: 11))
                Spacer()
            }
            hint("Entre na conta Samsung e toque em “Authorize”: o Lar cria e preenche a integração deste Mac.")
            hint("Token pessoal (os novos valem 24 h, bom para testar) ou, para não expirar, uma integração OAuth.")
            Toggle("Usar OAuth", isOn: $showOAuth)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            if showOAuth {
                if let other = sharedWith {
                    Text("Esta integração é a mesma do \(other): os dois se desconectam a cada renovação. Crie uma só para este Mac.")
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
                hint("Crie a integração deste Mac: cole um token pessoal com a permissão de apps (Apps). O Lar cria a integração e abre o login; o token não fica guardado.")
                HStack(spacing: 6) {
                    secret("Token pessoal (só para criar)", text: $stSetupToken)
                    pasteButton { stSetupToken = $0 }
                    Button(stCreating ? "Criando…" : "Criar e entrar") { createSmartThingsIntegration() }
                        .disabled(stSetupToken.trimmed.isEmpty || stCreating)
                }
                hint("Ou use uma integração que você já criou para este Mac:")
                field("Client ID", text: $stClientID, placeholder: "Client ID")
                secret("Client secret", text: $stSecret)
                secret("Refresh token (opcional)", text: $stRefresh)
                HStack {
                    if let stError {
                        Text(stError).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
                    }
                    Spacer()
                    if stRefresh.trimmed.isEmpty {
                        Button(savedOAuth != nil && stClientID.trimmed.isEmpty ? "Entrar de novo" : "Entrar no SmartThings") {
                            signInToSmartThings()
                        }
                        .disabled(signInCredentials == nil)
                    } else {
                        Button("Salvar") {
                            if let problem = SmartThingsClaims.problem(with: stClientID.trimmed) {
                                stError = problem
                                return
                            }
                            save {
                                settings.smartThings = .oauth(clientID: stClientID.trimmed, secret: stSecret.trimmed, refreshToken: stRefresh.trimmed)
                                stClientID = ""; stSecret = ""; stRefresh = ""
                            }
                        }
                        .disabled(stClientID.trimmed.isEmpty || stSecret.trimmed.isEmpty)
                    }
                }
                hint("Uma integração para cada aparelho (Mac, iPhone, TV): com a mesma, um desconecta o outro.")
            } else {
                HStack(spacing: 6) {
                    secret(settings.smartThings != nil ? "•••••• salvo" : "Token pessoal", text: $stToken)
                    pasteButton { stToken = $0 }
                    Button("Salvar") { save { settings.smartThings = .personalToken(stToken.trimmed); stToken = "" } }
                        .disabled(stToken.trimmed.isEmpty)
                }
            }
            HStack {
                link("Criar token (account.smartthings.com)", "https://account.smartthings.com/tokens")
                Spacer()
                if settings.smartThings != nil { removeButton { settings.smartThings = nil } }
            }
            DisclosureGroup("Como criar à mão (Client ID, secret e refresh token)") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SmartThingsManualGuide.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.system(size: 12, weight: .semibold))
                            Text(step.text).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if let command = step.command {
                                HStack(alignment: .top) {
                                    Text(command).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Button("Copiar") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(command, forType: .string)
                                    }
                                    .font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
    }

    // MARK: TV

    private var tvSection: some View {
        section("Google TV", provider: .androidTV) {
            hint("O Lar encontra sozinho as TVs com Google TV da rede de casa, mesmo quando o IP muda. Para controlar uma TV, abra-a na lista e toque em “Parear”: ela mostra um código para digitar aqui, uma vez só. Com a depuração USB ligada na TV, o Lar também usa o ADB (lista todos os apps) e pede “Permitir depuração USB?” na primeira vez.")
            Toggle("Encontrar TVs automaticamente", isOn: Binding(
                get: { settings.tvDiscovery },
                set: { on in save { settings.tvDiscovery = on } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            hint("IP manual, só para uma TV que não aparece sozinha:")
            HStack(spacing: 6) {
                field("IP da TV", text: $tvHost, placeholder: settings.tvHost.map { LocalizedStringKey(stringLiteral: $0) } ?? "Opcional")
                Button("Salvar") { save { settings.tvHost = tvHost.trimmed; tvHost = "" } }
                    .disabled(tvHost.trimmed.isEmpty)
            }
            HStack {
                if !settings.knownTVs.isEmpty {
                    Button("Esquecer TVs desligadas") { save { settings.knownTVs = [] } }
                        .font(.system(size: 11))
                        .help("Tira da lista as TVs que não estão na rede agora; as ligadas voltam sozinhas")
                }
                Spacer()
                if settings.tvHost != nil { removeButton { settings.tvHost = nil } }
            }
        }
    }

    // MARK: iPhone

    private var phoneSection: some View {
        section("iPhone") {
            hint("Cenas, nomes, favoritos e cômodos ficam iguais no Mac e no iPhone pela rede de casa (as chaves das contas não passam). No iPhone: Ajustes → Mac → Parear.")
            if let code = model.pairingCode {
                HStack {
                    Text(code.prefix(3) + " " + code.suffix(3))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    Spacer()
                    Button("Fechar") { model.hidePairingCode() }.font(.system(size: 11))
                }
                hint("Digite este código no iPhone. Vale por 2 minutos e para depois de 5 tentativas erradas.")
            } else {
                HStack {
                    Button("Parear um iPhone") { model.showPairingCode() }.font(.system(size: 11))
                    Spacer()
                    Button("Esquecer iPhones", role: .destructive) { model.forgetPairedPhones() }
                        .font(.system(size: 11))
                        .help("Os iPhones pareados param de sincronizar até parear de novo")
                }
            }
            if CloudSync.isAvailable { cloudRows }
        }
    }

    /// iCloud (App Store version): the same, anywhere, with the iPhones and iPads of the same Apple account.
    @ViewBuilder
    private var cloudRows: some View {
        HStack {
            Text("iCloud").font(.system(size: 12))
            Spacer()
            if let last = model.lastCloudSync {
                Text(last.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Sincronizar agora") { Task { await model.syncWithCloud() } }.font(.system(size: 11))
        }
        if let problem = model.cloudProblem {
            Text(problem).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Mandar os avisos para o iPhone pelo iCloud", isOn: Binding(
            get: { publishAlerts },
            set: { publishAlerts = $0; CloudSync.publishesAlerts = $0 }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        hint("Pelo iCloud, as cenas e a lista ficam iguais também fora de casa, com o iPhone e o iPad da mesma conta Apple. Os avisos (lavadora pronta, porteiro) chegam no iPhone mesmo com o Lar fechado.")
    }

    // MARK: Home app

    private var homeAppSection: some View {
        section("App Casa") {
            hint("Luzes, tomadas, ventiladores, interruptores, ares-condicionados, termômetros e câmeras do Lar no app Casa da Apple e na Siri, com o Mac como ponte HomeKit na rede de casa. O vídeo das câmeras passa pelo Mac, que precisa ficar ligado.")
            Toggle("Mostrar os aparelhos no app Casa", isOn: Binding(
                get: { model.usesHomeKitBridge },
                set: { model.usesHomeKitBridge = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            if let bridge = model.homeKitBridge {
                if model.homeKitPaired {
                    HStack {
                        Text("Adicionado ao app Casa").font(.system(size: 12))
                        Spacer()
                        Button("Remover da Casa", role: .destructive) { model.resetHomeKitBridge() }
                            .font(.system(size: 11))
                            .help("Esquece o pareamento; para usar de novo, adicione o Lar outra vez no app Casa")
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        if let qr = HomeKitCode.image(bridge.setupURI) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(bridge.setupCode)
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            hint("No iPhone: app Casa → + → Adicionar Acessório, e aponte para o código (ou toque em “Mais opções” e digite os números). O app avisa que o acessório não é certificado: toque em “Adicionar Mesmo Assim”.")
                        }
                    }
                }
            }
        }
    }

    // MARK: List

    private var listSection: some View {
        section("Lista") {
            Toggle("Casa de exemplo (sem contas)", isOn: Binding(
                get: { DemoHome.isOn }, set: { DemoHome.isOn = $0; model.accountsChanged() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            Toggle("Pedir Touch ID ou senha para abrir os Ajustes", isOn: Binding(
                get: { lockSettings }, set: { lockSettings = $0; SettingsLock.isEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            Toggle("Temperatura do ar na barra de menus", isOn: Binding(
                get: { model.showsTemperatureInMenuBar }, set: { model.showsTemperatureInMenuBar = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            Toggle("Abrir o Lar com \(HotKey.display) em qualquer app", isOn: Binding(
                get: { model.usesHotKey }, set: { model.usesHotKey = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            HStack {
                Text("Agrupar por").font(.system(size: 12))
                Spacer()
                Picker("Agrupar por", selection: Binding(get: { model.home.grouping }, set: { model.home.grouping = $0 })) {
                    ForEach(DeviceGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            hint("Botão direito num aparelho: favoritos (ficam no topo), nome, cômodo ou ocultar.")
            Toggle("Avisar quando a lavadora terminar", isOn: Binding(
                get: { notifyLaundry },
                set: { on in
                    notifyLaundry = on
                    Notifier.laundryEnabled = on
                    if on { Notifier.start() }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            ForEach(model.home.hiddenDevices) { device in
                HStack {
                    Text(device.name).font(.system(size: 12))
                    Spacer()
                    Button("Mostrar") { model.home.customize(device.id) { $0.isHidden = false } }
                        .font(.system(size: 11))
                }
            }
        }
    }

    // MARK: Air conditioner and general

    private var temperatureSection: some View {
        section("Ar-condicionado") {
            limitRow("Mínima", value: $limits.minimum, in: 16...(limits.maximum - 1))
            limitRow("Máxima", value: $limits.maximum, in: (limits.minimum + 1)...32)
            Toggle("Meio grau", isOn: $limits.halfDegrees)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            HStack {
                Text("Potência do ar").font(.system(size: 12))
                Spacer()
                TextField("W", value: $acWatts, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit { EnergyEstimate.watts = acWatts }
                Text("W").font(.system(size: 12))
            }
            HStack {
                Text("Tarifa de energia").font(.system(size: 12))
                Spacer()
                TextField(HomeRegion.currencySymbol, value: $tariff, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit { EnergyEstimate.tariff = tariff }
                Text("\(HomeRegion.currencySymbol)/kWh").font(.system(size: 12))
            }
            hint("Para a estimativa de consumo no histórico do ar (Enter para salvar).")
        }
        .onChange(of: limits) { _, new in settings.temperatureLimits = new }
    }

    private func limitRow(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text("\(Labels.temperature(value.wrappedValue))°C")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            Stepper(title, value: value, in: range, step: 1)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var generalSection: some View {
        section("Geral") {
            Button("Diagnóstico…", action: onDiagnostics)
                .font(.system(size: 12))
            Toggle("Abrir ao iniciar o Mac", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginError {
                Text(loginError).font(.system(size: 11)).foregroundStyle(Theme.warning)
            } else if launchAtLogin, StartAtLogin.needsApproval {
                Button("Permitir em Ajustes do Sistema → Itens de Início") { SMAppService.openSystemSettingsLoginItems() }
                    .font(.system(size: 11))
            }
            #if LAR_APPSTORE
            hint("Ligado, o Lar abre sozinho quando você entra no Mac e fica na barra de menus.")
            #else
            hint("Com o Mac ligado, o Lar fica sempre aberto: se ele parar sem você mandar sair, volta sozinho.")
            #endif
            HStack {
                Text("Versão \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Sair do Lar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .font(.system(size: 12))
            }
            #if !LAR_APPSTORE
            updateRow
            #endif
        }
    }

    #if !LAR_APPSTORE
    @ViewBuilder
    private var updateRow: some View {
        Toggle("Atualizar sozinho", isOn: $autoUpdate)
            .onChange(of: autoUpdate) { _, on in Updater.installsByItself = on }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        switch model.updater.state {
        case .idle:
            Button("Procurar atualização") { Task { await model.updater.check() } }
                .font(.system(size: 11))
        case .available(let next):
            Button("Instalar a versão \(next)") { Task { await model.updater.install() } }
                .font(.system(size: 11))
        case .installing(let next):
            Text("Instalando a versão \(next)…").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.warning)
        }
    }
    #endif

    // MARK: Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, provider: Provider? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if let provider { accountBadge(provider) }
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    @ViewBuilder
    private func accountBadge(_ provider: Provider) -> some View {
        let count = home.devices.filter { $0.provider == provider }.count
        switch home.accounts[provider] ?? .notConfigured {
        case .notConfigured: EmptyView()
        case .loading: badge("Conectando…", icon: "arrow.triangle.2.circlepath", color: Theme.secondaryText)
        case .connected: badge(count == 1 ? "1 aparelho" : "\(count) aparelhos", icon: "checkmark.circle", color: .green)
        case .unauthorized: badge("Chave recusada", icon: "key", color: Theme.warning)
        case .failed: badge("Sem resposta", icon: "wifi.slash", color: Theme.warning)
        }
    }

    private func badge(_ text: LocalizedStringKey, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10))
            .foregroundStyle(color)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: LocalizedStringKey) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            .accessibilityLabel(label)
    }

    private func secret(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }

    private func pasteButton(_ set: @escaping (String) -> Void) -> some View {
        Button {
            if let text = NSPasteboard.general.string(forType: .string) { set(text.trimmed) }
        } label: {
            Image(systemName: "doc.on.clipboard")
        }
        .help("Colar")
        .accessibilityLabel("Colar")
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button("Remover", role: .destructive) { save(action) }
            .font(.system(size: 11))
    }

    private func link(_ title: LocalizedStringKey, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Label(title, systemImage: "arrow.up.right.square").font(.system(size: 11))
        }
        .foregroundStyle(Theme.accent)
    }

    /// Writes the keys, then rebuilds the clients and reads every account again.
    private func save(_ change: () -> Void) {
        change()
        model.accountsChanged()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != StartAtLogin.isEnabled else { return }
        do {
            try StartAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = String(localized: "Não deu para mudar: \(error.localizedDescription)")
            launchAtLogin = StartAtLogin.isEnabled
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
