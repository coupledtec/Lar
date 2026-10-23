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
    Protocolo do controle do Google TV ("Android TV Remote v2", sem depuração; o único caminho no iPhone):
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
- **iPhone bloqueado:** o relógio e o CarPlay acordam o app do iPhone em segundo plano, muitas vezes bloqueado. As
  chaves usam `AfterFirstUnlockThisDeviceOnly` (as antigas migram em `Keychain.migrateAccessibility()` ao abrir), o
  app relê as contas ao ficar ativo (`reloadAccountsIfChanged`) e nunca manda ao relógio um pacote montado sem
  conseguir ler as chaves (apagaria as contas dele).
- **Cenas, links e Siri:** `Home/HomeScene.swift` (cena = lista de `HomeCommand` por aparelho; `SceneStore`
  observável; `SceneDraft` é a lógica dos editores do Mac e do iPhone), guardadas em UserDefaults (`scenes`) e
  levadas ao relógio no `WatchPayload`. `Home/LarLink.swift` trata `lar://` (Mac: `application(_:open:)`; iPhone:
  `onOpenURL`). Siri/Atalhos são App Intents em `Apps/Shared/LarIntents.swift` (iPhone e relógio); o Mac não tem,
  porque o SwiftPM não gera os metadados de App Intents: lá ficam os links.
- **Organização e avisos:** `Home/DeviceCustomization.swift` (nome, favorito, cômodo, oculto por id;
  `HomeStore.sections(grouping:)` é o agrupamento de todas as telas, inclusive CarPlay), salvo por
  `AccountSettings.bindListPreferences` e levado ao relógio no `WatchPayload`. `Home/HomeAlert.swift` compara duas
  leituras (lavadora LG de um estado ativo para END/COMPLETE, por `controls["runState"]`); `Notifier` publica no Mac e
  no iPhone (`HomeStore.onAlerts`); o iPhone ainda pede leituras em segundo plano (`BGAppRefreshTask`
  `com.coupled.lar.refresh`).
- **Texto na TV:** pelo protocolo do Google TV, `RemoteImeBatchEdit` (campo 21) com os contadores que a TV mandou
  por último; pelo ADB, `input text` (espaço = `%s`, entre aspas simples).
- **Widgets e grupo de Porta-chaves:** a conta grátis não tem App Groups, mas tem Keychain Sharing. No iPhone e no
  relógio, `Keychain.sharedGroup` (Info.plist `LarKeychainGroup`) põe as chaves, o certificado das TVs e as
  preferências (`Preferences`, que migra do UserDefaults na primeira leitura) no grupo
  `$(AppIdentifierPrefix)com.coupled.lar.shared`, lido pelos alvos `LarWidgets` (iOS: widgets, controles da Central
  de Controle, Atividade ao Vivo) e `LarWatchWidgets` (complicações). O widget lê o `WidgetSnapshot` salvo pelo app e
  tenta uma leitura nova; os botões rodam App Intents no processo do widget (`IntentContext.makeModel`). Como o
  widget também renova o token do SmartThings, o cliente relê o refresh token salvo antes de renovar.
- **Mac:** atalho global por Carbon (`HotKey`, sem permissão de Acessibilidade); widgets e Siri no Mac exigiriam
  assinar o app com perfil (na conta grátis vence em 7 dias), por isso o Mac segue com assinatura ad hoc e links.
- **Sincronização Mac–iPhone:** `Sync/` — o Mac (`SyncServer`) anuncia `_lar-sync._tcp` com TLS-PSK (chave de 32
  bytes no Porta-chaves, conta `sync-key`); o pareamento abre `_lar-pair._tcp` com PSK derivada do código de 6
  dígitos só enquanto o código aparece e entrega a chave. `SyncState` (cenas, personalizações, agrupamento) vence
  pelo `syncUpdatedAt`. O iPhone também entrega timers de desligar ao Mac. O teste `SyncTests` roda servidor e
  cliente reais no loopback com contas de Porta-chaves próprias.
- **Automações:** `Home/Automation.swift` (`SceneSchedule`, `HomeScene.due` com tolerância de 10 min, timers no
  `HomeStore`); o Mac confere a cada 30 s (`AppModel.startScheduler`); chegar/sair é `PresenceMonitor` no iPhone
  (região de 150 m, "Sempre").
- **Histórico:** `Home/History.swift` grava em `Application Support/Lar/history.json` (5 min, 30 dias);
  `ACHistoryView` (Swift Charts) é compilado no Mac e no iPhone.
- **Porteiro VoIP:** `VoIP/` é um telefone SIP próprio (o Lar é MIT; Linphone e PJSIP são GPL): `SIPClient` (UDP para o
  servidor como proxy de saída, REGISTER com Digest MD5/SHA-256 e rport, keep-alive a cada 25 s, INVITE de entrada e
  saída, CANCEL/BYE, INFO), `RTPSession` (G.711 μ/A, 20 ms, porta par 20000–29999, envio e recepção na mesma porta,
  teclas RFC 4733), `AudioIO` (AVAudioEngine com processamento de voz) e `PhoneStore`. `SIPClientTests` testa contra
  um PABX simulado. A senha fica no Porta-chaves (`sip-password`). O iPhone só registra com o app aberto: tocar com o
  app fechado exige PushKit (conta paga) — o Mac poderia mandar o push, sem servidor externo.
- **Porta-chaves no Mac:** `Vault` guarda todas as chaves num item só (`vault`) e o `build-app.sh` assina com um
  certificado de desenvolvedor do Mac, para o "Sempre permitir" valer entre versões.
- **Free My TV:** `TV/FreeMyTV.swift` — o Mac manda `am broadcast -a io.freemytv.LAR -n io.freemytv/.LarReceiver` pelo
  ADB (extras em base64): `kind=update` com o JSON das cenas (comandos simples: power/brightness/temperature) e das
  personalizações, a cada mudança (conferido a cada minuto, `AppModel.startTVBridge`), e `kind=doorbell|alert` para
  avisos na tela. O receptor do app exige `android.permission.DUMP` (só shell e sistema); o Lar libera
  `SYSTEM_ALERT_WINDOW` por `appops`.
- **TVs no relógio:** o watchOS não deixa abrir conexão com aparelhos da rede local; o relógio usa
  `RelayedTVProvider`, que pede ao iPhone por WatchConnectivity (`TVRelay`), e só funciona com o iPhone por perto.
- **zsh:** `log` é um comando interno do zsh; use `/usr/bin/log show --predicate 'subsystem == "<bundle id>"'`.

## Convenções

- Os testes nunca usam rede nem o Porta-chaves: provedores falsos, transporte injetável, `InMemorySettings`.
- JSON das APIs lido de forma defensiva com `JSONValue`; valores crus da API ficam crus, e o texto e os ícones são
  mapeados em `Labels` / `HomeText`.
- Popover escuro, largura fixa (`Theme.popoverWidth`), tokens em `Theme`; preferir controles nativos.
- Interface em português; código e comentários em inglês.
- Segredos: nunca imprimir, registrar no log nem gravar em arquivo do repositório.
