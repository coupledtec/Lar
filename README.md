# Lar

**A casa inteira na barra de menus do Mac.** O Lar junta numa lista só os aparelhos da sua conta **LG ThinQ**, do
**Smart Life (Tuya)**, do **SmartThings** e as **TVs Android / Google TV** da sua rede. Um clique na casinha mostra
tudo: liga e desliga, ajusta o ar-condicionado, o brilho e a cor das lâmpadas, abre as câmeras ao vivo e vira
controle remoto da TV.

<p align="center">
  <img src="docs/list.png" alt="A lista de aparelhos do Lar" width="320">
</p>

## Para que serve

- **Ver tudo num lugar só:** em vez de abrir quatro apps no celular, a lista mostra o estado de cada aparelho e de
  onde ele vem ("Ligada · 60% · Smart Life", "Enxaguando · faltam 0:07 · LG ThinQ", "Offline · SmartThings").
- **Ligar e desligar com um clique** no círculo à esquerda (fica colorido quando está ligado).
- **Ar-condicionado LG:** temperatura, modo, ventilação, direção do ar e modo Eco.
- **Lâmpadas:** brilho e cor (Smart Life e SmartThings).
- **Câmeras Smart Life:** vídeo ao vivo numa janela do Mac.
- **TVs Android / Google TV:** ligar e desligar, ver o que está passando e um controle remoto completo (direcional,
  voltar, início, play/pause, volume, entradas e os apps da TV). As setas e o Enter do teclado do Mac também
  funcionam.
- **Cenas:** um toque liga e desliga vários aparelhos de uma vez ("Dormir", "Cinema"). Crie no "+" de Cenas,
  escolhendo para cada aparelho Ligar, Desligar ou não mexer (ou "Usar o estado atual"). Clique com o botão direito
  (no iPhone, toque e segure) para editar.
- **Atalhos e Siri:** no iPhone e no relógio, "E aí Siri, executar Dormir no Lar", "Ligar TV da Sala no Lar". No app
  Atalhos aparecem as ações "Executar cena", "Ligar aparelho" e "Desligar aparelho". No Mac e no iPhone, a ação
  "Abrir URL" também funciona com `lar://cena/Dormir`, `lar://ligar/TV da Sala`, `lar://desligar/…` e
  `lar://alternar/…`.
- **Organizar a lista:** favoritos no topo, nome próprio no Lar, cômodos (agrupe por tipo ou por cômodo em
  Ajustes → Lista) e aparelhos ocultos. Botão direito no Mac; no iPhone, toque e segure. O relógio e o CarPlay
  seguem a organização do iPhone.
- **Avisos:** notificação quando a lavadora ou a secadora LG termina o ciclo (no Mac e no iPhone; o relógio
  repete a do iPhone). Dá para desligar em Ajustes → Lista.
- **Mais na TV:** canal +/−, nível do volume e digitar texto na busca aberta da TV.
- **Widgets (iPhone):** "Cenas" e "Favoritos" na tela inicial e na de bloqueio, com botões que funcionam ali mesmo;
  na Central de Controle, os controles "Cena do Lar" e "Aparelho do Lar" (também no Botão de Ação). No relógio,
  complicações com quantos aparelhos estão ligados e as cenas.
- **Atividade ao Vivo:** o ciclo da lavadora LG com a contagem regressiva na tela de bloqueio e na Dynamic Island.
- **Câmeras juntas:** todas ao vivo numa janela (Mac) ou numa tela (iPhone), pelo botão de grade.
- **Mac:** ⌃⌥L abre o Lar de qualquer app, e a temperatura do ar pode aparecer ao lado da casinha (Ajustes → Lista).
- **Ajustes protegidos:** Face ID (iPhone) ou Touch ID/senha (Mac) para abrir os Ajustes, onde ficam as chaves.
- **TV Samsung e soundbar (SmartThings):** controle remoto com direcional, voltar, início, volume, mudo, canal,
  entradas e apps (a soundbar: volume, mudo e entrada).
- **Ar-condicionado em todo lugar:** cenas podem definir a temperatura; Siri ("Ajustar o ar no Lar"), widget com
  − / + e o link `lar://temperatura/Ar do quarto/23`.
- **Automações:** cenas no horário (com dias da semana; executadas pelo Mac, que fica ligado), ao chegar e ao sair de
  casa (iPhone, marque a casa em Ajustes → Casa) e "Desligar em…" no menu de cada aparelho.
- **Mac e iPhone iguais:** cenas, nomes, favoritos e cômodos sincronizam pela rede de casa, com criptografia. No Mac,
  Ajustes → iPhone → Parear um iPhone; no iPhone, Ajustes → Mac. As chaves das contas não passam.
- **Histórico do ar:** temperatura das últimas 24 h, tempo ligado hoje e estimativa de kWh e R$ (potência e tarifa
  em Ajustes → Ar-condicionado).
- **Diagnóstico:** em Ajustes, o estado de cada conta, quanto demorou a última leitura e o último erro, com um
  relatório para copiar sem nenhuma chave.
- **Touchpad da TV** no iPhone (deslizar navega, tocar é OK).
- **Porteiro (VoIP/SIP):** atenda o porteiro, fale e abra o portão (as teclas que ele espera, ex.: `*1`), ou ligue
  para ele. Em Ajustes → Porteiro: servidor, usuário e senha do ramal, número do porteiro e as teclas do portão.
  O Mac fica registrado e toca sempre; o iPhone toca com o Lar aberto (com o app fechado, só com a conta paga de
  desenvolvedor da Apple). Áudio G.711, como todo PABX e porteiro aceita.
- **Sem servidor no meio:** o Lar conversa direto com a nuvem de cada marca e, no caso das TVs, direto com a TV pela
  rede de casa.

| Ar-condicionado | Lâmpada | TV |
|---|---|---|
| <img src="docs/air-conditioner.png" width="260"> | <img src="docs/light.png" width="260"> | <img src="docs/tv.png" width="260"> |

## Requisitos

- Mac com **chip Apple (M1 ou mais novo)** e **macOS 15 Sequoia ou mais novo**.
- Pelo menos uma das contas abaixo. Você configura só as que usa.

## Instalar

1. Baixe o `Lar-<versão>.dmg` na página de [Releases](../../releases/latest).
2. Abra o DMG e arraste o **Lar** para a pasta **Aplicativos**.
3. **Primeira abertura:** o Lar não é distribuído pela App Store nem notarizado pela Apple, então o macOS avisa que
   não consegue verificar o app. Para abrir:
   - clique com o botão direito no Lar em Aplicativos → **Abrir** → **Abrir**; ou
   - Ajustes do Sistema → **Privacidade e Segurança** → role até o aviso do Lar → **Abrir Mesmo Assim**.

   Só é preciso fazer isso uma vez. (Pelo Terminal: `xattr -dr com.apple.quarantine /Applications/Lar.app`.)
4. A casinha aparece na barra de menus. Sem nenhuma conta configurada, o Lar abre direto nos **Ajustes**.
5. Se o macOS perguntar se o Lar pode **encontrar dispositivos na rede local**, clique em **Permitir**: é assim que
   ele acha e controla as TVs.

Para abrir junto com o Mac: Ajustes do Lar → **Abrir ao iniciar o Mac**.

## Configurar cada conta

Tudo fica em **Ajustes** (a engrenagem no canto). Cada chave é guardada no **Porta-chaves do Mac**, só neste Mac, e
nunca aparece de volta na tela. Ao lado do nome de cada conta, os Ajustes mostram se ela conectou e quantos aparelhos
encontrou.

### LG ThinQ (ar-condicionado, lavadora, geladeira…)

1. Acesse [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com) e entre com a sua conta LG (a mesma do app
   LG ThinQ).
2. Crie um **Personal Access Token** e copie. Ele começa com `thinqpat_`.
3. No Lar: Ajustes → **LG ThinQ** → cole o token → **Salvar**.

O Lar usa a região das Américas (contas do Brasil). Os aparelhos precisam já funcionar no app LG ThinQ.

### Smart Life / Tuya (lâmpadas, tomadas, câmeras, sensores)

Vale para o app **Smart Life** e para marcas que usam a plataforma Tuya (Nova Digital, Ekaza e muitas outras).

1. **Junte tudo no app Smart Life.** O Lar só enxerga contas do Smart Life (ou do Tuya Smart). Se um aparelho estiver
   no app da própria marca, remova-o de lá, resete o aparelho e pareie de novo no Smart Life, no Wi-Fi de 2,4 GHz.
2. **Crie um projeto na Tuya** (grátis, uns 10 minutos):
   1. Crie uma conta em [iot.tuya.com](https://iot.tuya.com).
   2. **Cloud → Development → Create Cloud Project**. Development Method: **Smart Home**. Data Center: **Western
      America** para contas do Brasil e das Américas.
   3. Em **Service API**, autorize **IoT Core** e, para as câmeras, **IoT Video Live Stream**.
   4. Na aba **Devices → Link App Account**, aparece um QR code. No app Smart Life: **Eu → ícone de escanear** e leia
      o código. Os aparelhos aparecem na lista do site.
   5. Na página do projeto, copie o **Access ID** e o **Access Secret**.
3. No Lar: Ajustes → **Smart Life (Tuya)** → cole o Access ID e o Access Secret, escolha a região (**Américas**) →
   **Salvar**.

> O app de uma marca específica (Nova Digital, Ekaza…) mostra "Please use the designated app" ao ler o QR code: é
> esperado. Só o Smart Life e o Tuya Smart podem ser vinculados ao projeto.

> O serviço IoT Core vem como teste gratuito com prazo. Quando estiver perto de vencer, o próprio site da Tuya oferece
> renovar de graça para uso pessoal. Se o Lar mostrar "Smart Life: a chave foi recusada", é isso.

### SmartThings (TVs e soundbars Samsung, e o que estiver no SmartThings)

Há dois jeitos.

**Token pessoal (para testar).** Crie em [account.smartthings.com/tokens](https://account.smartthings.com/tokens) e
cole em Ajustes → **SmartThings** → **Salvar**. Os tokens novos **valem só 24 horas**.

**OAuth (para usar sempre).** O Lar renova o acesso sozinho. Leva uns 10 minutos, no Terminal do Mac:

1. Instale a ferramenta oficial: `brew install smartthingscommunity/smartthings/smartthings`
2. Crie a integração: `smartthings apps:create`
   - Entre na sua conta Samsung no navegador que abrir.
   - Tipo: **OAuth-In App**. Nome: `Lar` (descrição qualquer; ícone e Target URL em branco).
   - Escopos: `r:devices:*`, `x:devices:*` e `r:locations:*`.
   - Redirect URI: `https://httpbin.org/get`
   - Copie o **Client ID** e o **Client Secret**: eles não aparecem de novo.
3. Autorize a sua conta abrindo no navegador (troque `SEU_CLIENT_ID`):
   ```
   https://api.smartthings.com/oauth/authorize?client_id=SEU_CLIENT_ID&response_type=code&redirect_uri=https://httpbin.org/get&scope=r:devices:*+x:devices:*+r:locations:*
   ```
   Depois de autorizar, a página mostra um `code`.
4. Troque o código pelo **refresh token** (o código vale uma vez só e por poucos minutos):
   ```sh
   curl -s -u 'SEU_CLIENT_ID:SEU_CLIENT_SECRET' -X POST https://api.smartthings.com/oauth/token \
     -d grant_type=authorization_code -d client_id=SEU_CLIENT_ID \
     -d code=SEU_CODE -d redirect_uri=https://httpbin.org/get
   ```
5. No Lar: Ajustes → **SmartThings** → ligue **Usar OAuth** → cole o Client ID, o Client Secret e o Refresh token →
   **Salvar**.

O Lar precisa ficar aberto pelo menos uma vez a cada ~30 dias para o acesso não expirar. **Não use o mesmo refresh
token em outro programa:** ele muda a cada renovação, e um invalidaria o outro. Para outro programa, crie outra
integração.

"Offline" no Lar é o que o próprio SmartThings informa (aparelho sem conexão). Um aparelho conectado e desligado
aparece como "Desligado" e pode ser ligado pelo Lar.

### TVs Android / Google TV

As TVs são **encontradas sozinhas** na rede de casa, mesmo quando o roteador muda o IP delas. Há dois jeitos de o
Lar controlar uma TV.

**Pareando com o código (o mais simples, e o do iPhone).** É o mesmo controle do app Google TV; não precisa mexer nas
configurações da TV. Com a TV ligada, abra-a na lista do Lar e clique em **Parear com a TV** (no Mac, quando a TV
também aceita o ADB, o botão se chama **Parear sem depuração**). A TV mostra um código de 6 letras e números: digite
no Lar e confirme. É uma vez por TV e por aparelho (Mac e iPhone pareiam cada um o seu). Pareada, a TV liga e
desliga, recebe as teclas do controle e abre os apps mais comuns (Netflix, YouTube, Prime Video…).

**Pela depuração USB (só no Mac).** Além do controle, lista todos os apps instalados na TV:

1. Na TV: Configurações → **Sistema → Sobre** (ou Preferências do dispositivo → Sobre) → clique **7 vezes em
   "Build"** até aparecer "Você é um desenvolvedor".
2. Volte e abra **Opções do desenvolvedor** → ligue **Depuração USB**. (Em algumas TVs há também "Depuração pela
   rede" ou "ADB pela rede": ligue também.)
3. Abra o Lar. Na primeira conexão, a TV mostra **"Permitir depuração USB?"**: marque **"Sempre permitir"** e
   confirme com o controle. Só é preciso uma vez por TV.

Nos Ajustes (**TVs Android**) dá para desligar a busca automática, digitar o IP de uma TV que não aparece sozinha e
esquecer as TVs que não estão na rede.

**Sobre ligar a TV pelo Lar:** desligar sempre funciona. Para ligar, a TV precisa continuar na rede em repouso.
Muitas TVs desligam o Wi-Fi em repouso; nelas o Lar tenta o Wake-on-LAN (que costuma funcionar com cabo de rede) e,
se não der, avisa para usar o controle.

**Segurança:** a depuração USB dá controle total da TV a quem a TV autorizar. Só aceite o pedido quando for o seu
Mac, e desligue a depuração se não for mais usar o Lar na TV.

## Privacidade e segurança

- **Sem servidor do Lar, sem conta do Lar, sem coleta de dados.** O app só fala com a LG, a Tuya e a Samsung (com as
  suas chaves) e com as TVs da sua rede.
- **Chaves das contas:** no Porta-chaves do Mac, só neste Mac (sem sincronizar com o iCloud).
- **Chave das TVs:** em `~/Library/Application Support/Lar/adbkey`, legível só pelo seu usuário, como o `adb` do
  Android faz.
- **Remover tudo:** em Ajustes, **Remover** em cada conta; para apagar a chave das TVs, apague a pasta
  `~/Library/Application Support/Lar`.

## Problemas comuns

| O que aparece | O que fazer |
|---|---|
| "A chave foi recusada" | O token expirou ou foi revogado. Crie outro e cole em Ajustes. |
| Aparelho "Offline" | A própria nuvem da marca diz que ele está sem conexão. Confira no app da marca, a energia e o Wi-Fi. |
| TV: "Aceite 'Permitir depuração USB?' na TV" | Aceite na TV, marcando "Sempre permitir". |
| TV: "A TV não respondeu" | Confira se a TV está ligada, na mesma rede e com a depuração USB ligada. |
| O macOS pede para o Lar usar o Porta-chaves | Clique em "Sempre permitir" (acontece depois de atualizar o app). |
| Câmera não abre | O projeto da Tuya precisa do serviço **IoT Video Live Stream** autorizado. |

## Compilar a partir do código

Veja [DEVELOPMENT.md](DEVELOPMENT.md). Resumo: `scripts/test.sh` (testes), `scripts/build-app.sh --install` (instala
em Aplicativos) e `scripts/make-dmg.sh` (gera o DMG da release). Bastam as Command Line Tools do Xcode.

## Créditos e licença

O controle do ar-condicionado LG vem do [Celsius](https://github.com/gbvillarinho/celsius), de Gabriel Villarinho
(licença MIT). O Lar acrescenta as outras contas, as TVs e o restante.

Licença [MIT](LICENSE). O Lar não é afiliado à LG, à Tuya, à Samsung nem ao Google; os nomes são marcas dos seus
donos.
