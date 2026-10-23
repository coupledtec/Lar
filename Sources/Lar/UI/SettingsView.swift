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
    @State private var lockSettings = SettingsLock.isEnabled
    @State private var tuyaID = ""
    @State private var tuyaSecret = ""
    @State private var tuyaRegion = "us"
    @State private var stToken = ""
    @State private var stClientID = ""
    @State private var stSecret = ""
    @State private var stRefresh = ""
    @State private var showOAuth = false
    @State private var tvHost = ""
    @State private var limits = TemperatureLimits.standard
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    lgSection
                    tuyaSection
                    smartThingsSection
                    tvSection
                    listSection
                    if settings.token != nil { temperatureSection }
                    generalSection
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            limits = settings.temperatureLimits
            tuyaRegion = settings.tuya?.region ?? "us"
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

    private var smartThingsSection: some View {
        section("SmartThings", provider: .smartThings) {
            hint("Token pessoal (os novos valem 24 h, bom para testar) ou, para não expirar, uma integração OAuth.")
            Toggle("Usar OAuth", isOn: $showOAuth)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            if showOAuth {
                field("Client ID", text: $stClientID, placeholder: "Client ID")
                secret("Client secret", text: $stSecret)
                secret("Refresh token", text: $stRefresh)
                HStack {
                    Spacer()
                    Button("Salvar") {
                        save {
                            settings.smartThings = .oauth(clientID: stClientID.trimmed, secret: stSecret.trimmed, refreshToken: stRefresh.trimmed)
                            stClientID = ""; stSecret = ""; stRefresh = ""
                        }
                    }
                    .disabled(stClientID.trimmed.isEmpty || stSecret.trimmed.isEmpty || stRefresh.trimmed.isEmpty)
                }
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
        }
    }

    // MARK: TV

    private var tvSection: some View {
        section("TVs Android", provider: .androidTV) {
            hint("O Lar encontra sozinho as TVs Android e Google TV da rede de casa, mesmo quando o IP muda. Para controlar uma TV, abra-a na lista e toque em “Parear”: ela mostra um código para digitar aqui, uma vez só. Com a depuração USB ligada na TV, o Lar também usa o ADB (lista todos os apps) e pede “Permitir depuração USB?” na primeira vez.")
            Toggle("Encontrar TVs automaticamente", isOn: Binding(
                get: { settings.tvDiscovery },
                set: { on in save { settings.tvDiscovery = on } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            hint("IP manual, só para uma TV que não aparece sozinha:")
            HStack(spacing: 6) {
                field("IP da TV", text: $tvHost, placeholder: settings.tvHost ?? "Opcional")
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

    // MARK: List

    private var listSection: some View {
        section("Lista") {
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
        }
        .onChange(of: limits) { _, new in settings.temperatureLimits = new }
    }

    private func limitRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
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
            }
            HStack {
                Text("Versão \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Sair do Lar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, provider: Provider? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
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
        case .connected: badge("\(count) \(count == 1 ? "aparelho" : "aparelhos")", icon: "checkmark.circle", color: .green)
        case .unauthorized: badge("Chave recusada", icon: "key", color: Theme.warning)
        case .failed: badge("Sem resposta", icon: "wifi.slash", color: Theme.warning)
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10))
            .foregroundStyle(color)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
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

    private func link(_ title: String, _ url: String) -> some View {
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
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Não deu para mudar: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
