import LarCore
import SwiftUI

/// The accounts' keys (kept in the iPhone's keychain, never shown back), the TVs, the temperature range and the watch.
struct SettingsView: View {
    var model: LarModel
    var link: WatchLink

    @Environment(\.dismiss) private var dismiss
    @State private var lgToken = ""
    @State private var tuyaID = ""
    @State private var tuyaSecret = ""
    @State private var tuyaRegion = "us"
    @State private var stToken = ""
    @State private var stClientID = ""
    @State private var stSecret = ""
    @State private var stRefresh = ""
    @State private var useOAuth = false
    @State private var tvHost = ""
    @State private var notifyLaundry = Notifier.laundryEnabled
    @State private var lockSettings = SettingsLock.isEnabled
    @State private var limits = TemperatureLimits.standard
    /// Bumped after a save, so the "salvo" state re-reads the keychain.
    @State private var version = 0

    private var settings: LarSettings { model.settings }
    private var home: HomeStore { model.home }

    var body: some View {
        NavigationStack {
            Form {
                lgSection
                tuyaSection
                smartThingsSection
                tvSection
                listSection
                if settings.token != nil { temperatureSection }
                watchSection
                Section { NavigationLink("Diagnóstico") { DiagnosticsView(model: model) } }
                Section {
                    Text("As chaves ficam no Porta-chaves deste iPhone e só vão para o seu Apple Watch. O Lar não tem servidor nem coleta dados.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .id(version)
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .onAppear {
                limits = settings.temperatureLimits
                tuyaRegion = settings.tuya?.region ?? "us"
                if case .oauth? = settings.smartThings { useOAuth = true }
            }
        }
    }

    // MARK: Accounts

    private var lgSection: some View {
        Section {
            SecureField(settings.token != nil ? "•••••• salvo" : "thinqpat_…", text: $lgToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Salvar") { save { settings.token = lgToken.trimmed; settings.deviceID = nil; lgToken = "" } }
                .disabled(lgToken.trimmed.isEmpty)
            Link("Criar token (connect-pat.lgthinq.com)", destination: URL(string: "https://connect-pat.lgthinq.com")!)
            if settings.token != nil {
                Button("Remover", role: .destructive) { save { settings.token = nil; settings.deviceID = nil } }
            }
        } header: {
            header("LG ThinQ", .lg)
        } footer: {
            Text("Token pessoal da sua conta LG: ar-condicionado, lavadora, geladeira e outros aparelhos.")
        }
    }

    private var tuyaSection: some View {
        Section {
            TextField(settings.tuya != nil ? "Access ID · salvo" : "Access ID", text: $tuyaID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(settings.tuya != nil ? "Access Secret · salvo" : "Access Secret", text: $tuyaSecret)
            Picker("Região", selection: $tuyaRegion) {
                Text("Américas").tag("us")
                Text("Europa").tag("eu")
                Text("China").tag("cn")
                Text("Índia").tag("in")
            }
            Button("Salvar") {
                save {
                    let current = settings.tuya
                    let id = tuyaID.trimmed.isEmpty ? current?.clientID ?? "" : tuyaID.trimmed
                    let secret = tuyaSecret.trimmed.isEmpty ? current?.secret ?? "" : tuyaSecret.trimmed
                    settings.tuya = id.isEmpty || secret.isEmpty ? nil : TuyaClient.Credentials(clientID: id, secret: secret, region: tuyaRegion)
                    tuyaID = ""
                    tuyaSecret = ""
                }
            }
            .disabled(tuyaID.trimmed.isEmpty && tuyaSecret.trimmed.isEmpty && tuyaRegion == (settings.tuya?.region ?? "us"))
            if settings.tuya != nil {
                Button("Remover", role: .destructive) { save { settings.tuya = nil } }
            }
        } header: {
            header("Smart Life (Tuya)", .tuya)
        } footer: {
            Text("Access ID e Access Secret de um projeto Cloud em iot.tuya.com com a conta do Smart Life vinculada. O passo a passo está no README do Lar.")
        }
    }

    private var smartThingsSection: some View {
        Section {
            Toggle("Usar OAuth (não expira)", isOn: $useOAuth)
            if useOAuth {
                TextField("Client ID", text: $stClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client secret", text: $stSecret)
                SecureField("Refresh token", text: $stRefresh)
                Button("Salvar") {
                    save {
                        settings.smartThings = .oauth(clientID: stClientID.trimmed, secret: stSecret.trimmed, refreshToken: stRefresh.trimmed)
                        stClientID = ""; stSecret = ""; stRefresh = ""
                    }
                }
                .disabled(stClientID.trimmed.isEmpty || stSecret.trimmed.isEmpty || stRefresh.trimmed.isEmpty)
            } else {
                SecureField(settings.smartThings != nil ? "•••••• salvo" : "Token pessoal", text: $stToken)
                Button("Salvar") { save { settings.smartThings = .personalToken(stToken.trimmed); stToken = "" } }
                    .disabled(stToken.trimmed.isEmpty)
            }
            if settings.smartThings != nil {
                Button("Remover", role: .destructive) { save { settings.smartThings = nil } }
            }
        } header: {
            header("SmartThings", .smartThings)
        } footer: {
            Text("Use uma autorização OAuth própria para o iPhone: o refresh token muda a cada renovação e não pode ser dividido com o Lar do Mac.")
        }
    }

    private var tvSection: some View {
        Section {
            Toggle("Encontrar TVs automaticamente", isOn: Binding(
                get: { settings.tvDiscovery },
                set: { on in save { settings.tvDiscovery = on } }
            ))
            TextField(settings.tvHost ?? "IP da TV (opcional)", text: $tvHost)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
            Button("Salvar IP") { save { settings.tvHost = tvHost.trimmed; tvHost = "" } }
                .disabled(tvHost.trimmed.isEmpty)
            if settings.tvHost != nil {
                Button("Remover IP", role: .destructive) { save { settings.tvHost = nil } }
            }
            if !settings.knownTVs.isEmpty {
                Button("Esquecer TVs desligadas") { save { settings.knownTVs = [] } }
            }
        } header: {
            header("TVs Android", .androidTV)
        } footer: {
            Text("O Lar encontra sozinho as TVs Android e Google TV da rede de casa, mesmo quando o IP muda. Para controlar uma TV, abra-a na lista e toque em “Parear com a TV”: ela mostra um código para digitar aqui, uma vez só. O IP manual é só para uma TV que não aparece sozinha.")
        }
    }

    private var listSection: some View {
        Section {
            Picker("Agrupar por", selection: Binding(get: { home.grouping }, set: { home.grouping = $0 })) {
                ForEach(DeviceGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Pedir Face ID para abrir os Ajustes", isOn: Binding(
                get: { lockSettings }, set: { lockSettings = $0; SettingsLock.isEnabled = $0 }
            ))
            Toggle("Avisar quando a lavadora terminar", isOn: Binding(
                get: { notifyLaundry },
                set: { on in
                    notifyLaundry = on
                    Notifier.laundryEnabled = on
                    if on { Notifier.start() }
                }
            ))
            ForEach(home.hiddenDevices) { device in
                HStack {
                    Text(device.name)
                    Spacer()
                    Button("Mostrar") { home.customize(device.id) { $0.isHidden = false } }
                }
            }
        } header: {
            Text("Lista")
        } footer: {
            Text("Toque e segure um aparelho na lista para favoritar, mudar o nome, o cômodo ou ocultar.")
        }
    }

    private var temperatureSection: some View {
        Section("Ar-condicionado") {
            Stepper("Mínima: \(Labels.temperature(limits.minimum))°C", value: $limits.minimum, in: 16...(limits.maximum - 1))
            Stepper("Máxima: \(Labels.temperature(limits.maximum))°C", value: $limits.maximum, in: (limits.minimum + 1)...32)
            Toggle("Meio grau", isOn: $limits.halfDegrees)
        }
        .onChange(of: limits) { _, new in
            settings.temperatureLimits = new
            link.sendAccounts()
        }
    }

    private var watchSection: some View {
        Section {
            LabeledContent("Pareado", value: link.isPaired ? "Sim" : "Não")
            LabeledContent("Lar instalado no relógio", value: link.isWatchAppInstalled ? "Sim" : "Não")
            if let sent = link.lastSent {
                LabeledContent("Enviado", value: sent.formatted(date: .omitted, time: .shortened))
            }
            Button("Enviar contas para o relógio") { link.sendAccounts() }
                .disabled(!link.isWatchAppInstalled)
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("O relógio recebe as contas deste iPhone. Do SmartThings ele recebe só um acesso de 24 h, renovado pelo iPhone.")
        }
    }

    private func header(_ title: String, _ provider: Provider) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch home.accounts[provider] ?? .notConfigured {
            case .notConfigured: EmptyView()
            case .loading: Text("Conectando…")
            case .connected:
                let count = home.devices.filter { $0.provider == provider }.count
                Label("\(count) \(count == 1 ? "aparelho" : "aparelhos")", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .unauthorized: Label("Chave recusada", systemImage: "key").foregroundStyle(.orange)
            case .failed: Label("Sem resposta", systemImage: "wifi.slash").foregroundStyle(.orange)
            }
        }
    }

    /// Writes the keys, rebuilds the clients, reads every account again and updates the watch.
    private func save(_ change: () -> Void) {
        change()
        model.accountsChanged()
        version += 1
        link.sendAccounts()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
