# Desenvolvimento

Notas técnicas para quem for mexer no código. Para usar o app, veja o [README](README.md).

## Compilar

Swift Package Manager, sem projeto do Xcode. Bastam as Command Line Tools.

```sh
scripts/test.sh                 # testes (Swift Testing)
scripts/build-app.sh            # gera build/Lar.app (assinatura ad hoc)
scripts/build-app.sh --install  # também copia para /Applications e abre
scripts/make-dmg.sh             # gera build/Lar-<versão>.dmg para a release
```

`scripts/env.sh` (carregado pelos outros scripts) escolhe o SDK do macOS 26.5 e `--build-system native`: só com as
Command Line Tools, o SDK do macOS 27 transforma o `@State` do SwiftUI numa macro cujo plugin (SwiftUIMacros) vem só
com o Xcode, e o build system novo do SwiftPM falha ao iniciar ("Unknown error parsing property list"). Para compilar
à mão: `source scripts/env.sh && swift build "${SWIFT_FLAGS[@]}"`.

### Conferir a interface

Não há previews do SwiftUI. Para ver as telas sem barra de menus nem rede:

```sh
"$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/Lar" --snapshot <pasta>
```

`<nome>.png` é fiel ao desenho próprio, mas os controles nativos aparecem como marcadores amarelos;
`<nome>-native.png` mostra os controles nativos. Com dados reais: `LAR_LIVE_SNAPSHOT=<arquivo.png>`.

### Testes com contas reais (opcionais)

Pulados por padrão. Rodam só com as variáveis de ambiente: `LAR_LIVE_LG`, `LAR_LIVE_TUYA_ID` e
`LAR_LIVE_TUYA_SECRET` (`LiveTests`); `LAR_LIVE_TV=1` (`LiveTVTests`, usa a chave ADB já aprovada e nunca mexe na
energia da TV). Nunca coloque chaves em arquivos do repositório.

## Arquitetura

Dois alvos com separação rígida:

- **LarCore** (biblioteca testada, sem interface):
  - `Home/HomeDevice.swift`: o modelo comum (`HomeDevice`, `DeviceKind`, `HomeCommand`, `ProviderError`) e os
    protocolos `DeviceProvider` / `LiveVideoProvider`. `controls` guarda o que cada provedor precisa para mandar
    comandos (códigos e faixas da Tuya, chave de operação da LG, capacidades do SmartThings, IP e MAC da TV).
  - `Providers/`: `LGProvider` (sobre o `ThinQClient`), `TuyaClient` (actor; assinatura HMAC-SHA256, token de 2 h,
    especificação de cada lâmpada em cache, link HLS das câmeras), `SmartThingsClient` (actor; token pessoal ou OAuth,
    cujo refresh token muda a cada renovação e é salvo na hora por callback; "offline" vem de
    `GET devices/{id}/health`, nunca do estado do interruptor).
  - `TV/`: `ADBKey` (RSA 2048 em `~/Library/Application Support/Lar/adbkey`, modo 0600, como o `~/.android/adbkey`
    do adb; a struct de chave pública do adbd, com n0inv e R² mod n calculados em `BigWords`), `ADBClient` (actor;
    Network.framework, uma conexão reutilizada, comandos em fila, espera de 60 s pela autorização na TV),
    `TVDiscovery` (Bonjour `_androidtvremote2._tcp` a cada atualização, resolvendo o IPv4 atual),
    `AndroidTVProvider` (todas as TVs; identificadas pelo `ro.serialno`, lembradas em `knownTVs`; energia com
    KEYCODE_POWER só quando acordada e KEYCODE_WAKEUP, mais `WakeOnLAN`), `WakeOnLAN`.
    Protocolo do controle do Google TV (o do app Google TV, sem depuração):
    `TVRemoteProtocol` (protobuf mínimo com prefixo varint; campos de polo.proto e remotemessage.proto como na
    biblioteca androidtvremote2; segredo do pareamento = SHA-256 dos módulos e expoentes das duas chaves + os 2
    últimos bytes do código, o 1º byte confere o código), `TVRemoteIdentity` (RSA 2048 + certificado X.509 v1
    autoassinado montado em DER, no Porta-chaves, achado de novo pelo nome "Lar - controle da TV"; o TLS só aceita
    certificado de cliente como identidade do Porta-chaves), `TVRemoteLink` (TLS que aceita o certificado da TV e
    guarda a chave dela), `TVRemoteClient` (porta 6466; conexão aberta, responde configure/set_active/ping, lê
    ligada/app/volume) e `TVRemotePairing` (porta 6467, em duas etapas: a TV mostra o código, o usuário digita).
    No provedor, TV pareada (`pairedTVs`, pelo nome anunciado) usa o protocolo; senão ADB quando `useADB` (Mac);
    sem ADB, a TV que responde na 6466 aparece ligada, sem interruptor e com `controls["pairable"]`.
  - `Store/HomeStore.swift`: fonte da verdade da lista. Contas lidas em paralelo; uma conta que falha mantém os
    aparelhos até `failuresBeforeOffline`. Mudanças otimistas por aparelho e campo; um comando por vez, o mais novo
    substitui o não enviado do mesmo aparelho e campo. Tempos são constantes estáticas do store.
  - `Store/ACStore.swift` + `ThinQ/`: o controle completo do ar-condicionado, vindo do Celsius, sem mudança de
    comportamento. O app só cria um enquanto a tela de um ar está aberta (`AppModel.openAirConditioner`).
  - `Store/AppSettings.swift`: Porta-chaves (serviço = bundle id; contas `thinq-pat`, `tuya-client-id`,
    `tuya-secret`, `st-token`, `st-client-id`, `st-client-secret`, `st-refresh-token`) e UserDefaults (região da Tuya,
    TVs: `tvDiscovery`, `tvHost`, `knownTVs`, `pairedTVs`).
- **Lar** (app): `AppModel` (ajustes → provedores → stores), `StatusItemController` (casinha, preenchida quando algo
  está ligado), `UI/HomeView` (rotas: lista, ajustes, ar, luz, TV), `ACDetailView`, `LightDetailView`,
  `TVDetailView`, `CameraWindow` (AVPlayer, uma janela por câmera), `SettingsView`.

### Armadilhas conhecidas

- **Mesclar contas:** `HomeStore.refresh` substitui os aparelhos pela conta gravada em cada aparelho e remove
  duplicados por id. A versão otimizada já chegou a marcar o resultado do Smart Life como da LG ao sair do task group,
  e a lista se acumulava a cada atualização; não volte a usar o rótulo da tupla para mesclar.
- **SmartThings:** dois apps (por exemplo o Lar e outro programa) nunca podem dividir o mesmo refresh token: cada
  renovação invalida o anterior. Cada app precisa da própria integração OAuth.
- **Porta-chaves e builds locais:** a assinatura ad hoc muda a cada build, e o macOS pode pedir de novo permissão
  para o app ler as chaves ("Sempre permitir").
- **TV pelo controle do Google TV:** sem pedido de lista de apps no protocolo; os apps abrem por link
  (`https://…` dos apps grandes ou `market://launch?id=<pacote>`). A TV fecha a conexão de quem não responde ao ping.
  Uma TV anunciada no Bonjour pode estar em repouso e fora do Wi-Fi: por isso o teste da porta 6466 antes de
  oferecer o pareamento.
- **Cenas, links e Siri:** `Home/HomeScene.swift` (cena = lista de `HomeCommand` por aparelho; `SceneStore`
  observável; `SceneDraft` é a lógica do editor), guardadas em UserDefaults (`scenes`). `Home/LarLink.swift` trata
  `lar://` (`application(_:open:)`); o SwiftPM não gera os metadados de App Intents, por isso o Mac usa os links.
- **Organização e avisos:** `Home/DeviceCustomization.swift` (nome, favorito, cômodo, oculto por id;
  `HomeStore.sections(grouping:)` é o agrupamento), salvo por `AccountSettings.bindListPreferences`. `Home/HomeAlert.swift` compara duas
  leituras (lavadora LG de um estado ativo para END/COMPLETE, por `controls["runState"]`); `Notifier` publica
  (`HomeStore.onAlerts`).
- **Texto na TV:** pelo protocolo do Google TV, `RemoteImeBatchEdit` (campo 21) com os contadores que a TV mandou
  por último; pelo ADB, `input text` (espaço = `%s`, entre aspas simples).
- **Mac:** atalho global por Carbon (`HotKey`, sem permissão de Acessibilidade). Sempre aberto: um agente do launchd
  dentro do app (`StartAtLogin`, `Resources/LaunchAgents`) com KeepAlive em saída inesperada. Distribuição: Developer
  ID com hardened runtime e notarização (`scripts/make-dmg.sh` com um perfil do notarytool, `lar-notary`); o
  `Updater` baixa a release do GitHub, confere o SHA-256, a notarização e o time da assinatura, e troca o app.
- **Sincronização Mac–iPhone:** `Sync/` — o Mac (`SyncServer`) anuncia `_lar-sync._tcp` com TLS ECDHE-PSK (chave de 32
  bytes no Porta-chaves, conta `sync-key`); o pareamento abre `_lar-pair._tcp` com PSK derivada do código de 6
  dígitos só enquanto o código aparece e entrega a chave. `SyncState` (cenas, personalizações, agrupamento) vence
  pelo `syncUpdatedAt`. O iPhone também entrega timers de desligar ao Mac. O teste `SyncTests` roda servidor e
  cliente reais no loopback com contas de Porta-chaves próprias.
- **Automações:** `Home/Automation.swift` (`SceneSchedule`, `HomeScene.due` com tolerância de 10 min, timers no
  `HomeStore`); o Mac confere a cada 30 s (`AppModel.startScheduler`).
- **Histórico:** `Home/History.swift` grava em `Application Support/Lar/history.json` (5 min, 30 dias);
  `ACHistoryView` (Swift Charts).
- **Porteiro VoIP:** `VoIP/` é um telefone SIP próprio (o Lar é MIT; Linphone e PJSIP são GPL): `SIPClient` (UDP para o
  servidor como proxy de saída, REGISTER com Digest MD5/SHA-256 e rport, keep-alive a cada 25 s, INVITE de entrada e
  saída, CANCEL/BYE, INFO), `RTPSession` (G.711 μ/A, 20 ms, porta par 20000–29999, envio e recepção na mesma porta,
  teclas RFC 4733), `AudioIO` (AVAudioEngine com processamento de voz) e `PhoneStore`. `SIPClientTests` testa contra
  um PABX simulado. A senha fica no Porta-chaves (`sip-password`).
- **Porta-chaves no Mac:** `Vault` guarda todas as chaves num item só (`vault`) e o `build-app.sh` assina com um
  certificado de desenvolvedor do Mac, para o "Sempre permitir" valer entre versões.
- **Extensões fora do repositório:** `Sources/*/Private/` e `Tests/*/Private/` ficam fora do git; quando existem, o
  `scripts/env.sh` compila com `LAR_PRIVATE` e o `LarApp` chama `PrivateExtensions.start`. Pontos de encaixe públicos:
  `AppModel.noticeHandlers` (os avisos), `AndroidTVProvider.adbHosts()`/`shellOn` e a seção da Alexa nos Ajustes.
- **Alexa (`Sources/LarCore/Alexa`):** sem API oficial; segue o aioamazondevices. Login: a página da Amazon
  (`/ap/signin` do site do país, com `openid.assoc_handle`/`pageId` `amzn_dp_project_dee_ios_<país>` fora dos EUA e retorno
  no próprio site: o handle dos EUA dá "página não encontrada" no amazon.com.br; PKCE, cliente `device:<hex de "serial#A2IVLV5VM2W81">`, cookies `frc`/`map-md`/`amzn-app-id` antes)
  num WKWebView com armazenamento próprio; o código vem no redirect para `/ap/maplanding` (nunca aberto). Com ele,
  `POST api.amazon.com/auth/register` registra o Lar como aparelho da conta e dá o refresh token e os cookies;
  `auth/token` (`auth_cookies`) renova os cookies quando o site responde 401/403. O site é `alexa.amazon.<domínio>`
  (`AlexaRegion`), com o cabeçalho `csrf` do cookie de mesmo nome. Echos: `api/devices-v2/device` (só com
  `MICROPHONE`), volume, não perturbe, `api/np/command`; falar, anunciar, comando em texto, volume e rotinas vão como
  sequência em `api/behaviors/preview`. Nomes dos aparelhos da casa: GraphQL `nexus/v1/graphql` (`listEndpoints`).
  `AlexaRoutineConverter` faz das rotinas cenas (`HomeScene.alexaRoutineID`/`alexaSteps`); `AlexaRoutineImport` roda
  por botão e a cada hora. A conta fica em `AccountSettings.alexa` (Porta-chaves).
- **Uma integração SmartThings por aparelho:** `SmartThingsSetup.createIntegration` cria pela API (`POST /v1/apps`,
  `API_ONLY`, `CONNECTED_SERVICE`, os escopos e o redirect do login) com um token pessoal que não fica guardado, e
  o login abre em seguida. `SmartThingsClaims`: cada aparelho guarda um `installID`; na sincronização o iPhone manda
  ao Mac a impressão (SHA-256 truncado) do Client ID dele e a do relógio (`SyncMessage.claim`), e o Mac responde com
  a sua. Entrar, salvar ou importar (`AccountsImport`, a importação de teste do iPhone) com uma integração de outro
  aparelho é recusado, e os Ajustes avisam quando a salva é a mesma de outro.
- **SmartThings sem intervenção:** a página de login usa um `WKWebsiteDataStore` próprio e persistente
  (`SmartThingsSignIn.dataStore`), então a sessão da conta Samsung fica guardada. Quando a Samsung recusa o token
  (`HomeStore.onUnauthorized`), `SmartThingsReconnect` abre o login escondido; com a sessão válida, a Samsung
  devolve o código na hora e o Lar troca por um refresh token novo. Sem sessão, uma notificação pede "Entrar de
  novo" (no máximo uma tentativa a cada 10 min).
- **LG instável:** as leituras (GET) da ThinQ tentam de novo depois de 1 s e 3 s em erros passageiros (1306, rede,
  5xx); comandos não.
- **zsh:** `log` é um comando interno do zsh; use `/usr/bin/log show --predicate 'subsystem == "<bundle id>"'`.

## Convenções

- Os testes nunca usam rede nem o Porta-chaves: provedores falsos, transporte injetável, `InMemorySettings`.
- JSON das APIs lido de forma defensiva com `JSONValue`; valores crus da API ficam crus, e o texto e os ícones são
  mapeados em `Labels` / `HomeText`.
- Popover escuro, largura fixa (`Theme.popoverWidth`), tokens em `Theme`; preferir controles nativos.
- Interface em português (o idioma de origem); código e comentários em inglês. As traduções ficam em
  `Resources/Localizable.xcstrings`: nas telas, textos literais em `Text`, `Button` etc. já entram no catálogo (uma
  função auxiliar recebe `LocalizedStringKey`, não `String`); um texto montado como `String` usa
  `String(localized:)` no app e `tr(...)` no LarCore. Depois de mudar textos, `scripts/update-strings.sh` traz o
  catálogo em dia (as pastas `Private` ficam de fora) e as traduções novas são preenchidas nele.
- Segredos: nunca imprimir, registrar no log nem gravar em arquivo do repositório.
