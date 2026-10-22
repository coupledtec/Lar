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
  - `Store/HomeStore.swift`: fonte da verdade da lista. Contas lidas em paralelo; uma conta que falha mantém os
    aparelhos até `failuresBeforeOffline`. Mudanças otimistas por aparelho e campo; um comando por vez, o mais novo
    substitui o não enviado do mesmo aparelho e campo. Tempos são constantes estáticas do store.
  - `Store/ACStore.swift` + `ThinQ/`: o controle completo do ar-condicionado, vindo do Celsius, sem mudança de
    comportamento. O app só cria um enquanto a tela de um ar está aberta (`AppModel.openAirConditioner`).
  - `Store/AppSettings.swift`: Porta-chaves (serviço = bundle id; contas `thinq-pat`, `tuya-client-id`,
    `tuya-secret`, `st-token`, `st-client-id`, `st-client-secret`, `st-refresh-token`) e UserDefaults (região da Tuya,
    TVs: `tvDiscovery`, `tvHost`, `knownTVs`).
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
- **zsh:** `log` é um comando interno do zsh; use `/usr/bin/log show --predicate 'subsystem == "<bundle id>"'`.

## Convenções

- Os testes nunca usam rede nem o Porta-chaves: provedores falsos, transporte injetável, `InMemorySettings`.
- JSON das APIs lido de forma defensiva com `JSONValue`; valores crus da API ficam crus, e o texto e os ícones são
  mapeados em `Labels` / `HomeText`.
- Popover escuro, largura fixa (`Theme.popoverWidth`), tokens em `Theme`; preferir controles nativos.
- Interface em português; código e comentários em inglês.
- Segredos: nunca imprimir, registrar no log nem gravar em arquivo do repositório.
