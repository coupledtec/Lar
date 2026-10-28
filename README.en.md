# Lar

[Português](README.md) · **English**

**Your whole home in the Mac's menu bar.** Lar brings together in one list the devices of your **LG ThinQ**,
**Smart Life (Tuya)** and **SmartThings** accounts, your **Alexa Echos**, your **Xbox** and the **Google
TVs** on your network. One click on the little house shows everything: turn things on and off, set the air
conditioner, the lights' brightness and color, open live cameras and use it as a TV remote. And the Mac brings these
devices into Apple's **Home app** and Siri.

<p align="center">
  <img src="docs/list.png" alt="Lar's device list" width="320">
</p>

## Where it runs

On the **Mac**, in the menu bar. It's the one that stays on: scenes on schedule and the intercom always registered.
This repository is the Mac app.

For iPhone, iPad, Apple Watch, CarPlay, Apple TV and Apple Vision Pro, Lar is on the **App Store** (separate apps,
not part of this repository). The Mac and the iPhone sync scenes, names, favorites and rooms.

To try it without any account: **"Try a sample home"** on the first screen (or Settings → Sample home).

## What it does

- **See everything in one place:** instead of opening four apps on your phone, the list shows each device's state
  and where it comes from ("On · 60% · Smart Life", "Rinsing · 0:07 left · LG ThinQ", "Offline · SmartThings").
- **Turn things on and off with one click** on the circle on the left (it fills with color when on).
- **Air conditioners:** LG's with everything (temperature, mode, fan, airflow direction and Eco mode); SmartThings
  and Smart Life ones with power, room temperature and target temperature (− / +).
- **Lights:** brightness and color (Smart Life and SmartThings).
- **Smart Life cameras:** live video in a window, one or all of them together (grid button).
- **Home app and Siri:** the Mac becomes a HomeKit bridge on your home network (Settings → Home app). Lar's lights,
  plugs, fans, switches, air conditioners, thermometers and cameras show up in the Home app on the iPhone, iPad and
  watch, and Siri can control them. A device that's already in the Home app on its own can be kept out of the
  bridge, so it doesn't show up twice. Camera video goes through the Mac, which needs to stay on.
- **Google TVs:** turn on and off, see what's playing and a full remote (directional pad, back, home,
  play/pause, volume, channel, inputs and the TV's apps), plus typing into the TV's open search. The Mac keyboard's
  arrows and Return work too.
- **Samsung TV and soundbar (SmartThings):** remote with directional pad, back, home, volume, mute, channel, inputs
  and apps (the soundbar: volume, mute and input).
- **Scenes:** one click turns several devices on and off at once ("Bedtime", "Movie"), and can set the air
  conditioner's temperature. Create one with the "+" in Scenes, choosing Turn on, Turn off or Leave alone for each
  device (or "Use the current state"). Right-click to edit.
- **Links:** `lar://scene/Bedtime`, `lar://on/Living Room TV`, `lar://off/…`, `lar://toggle/…` and
  `lar://temperature/Bedroom AC/23` (in the Shortcuts app, with "Open URL").
- **Organize the list:** favorites on top, your own names in Lar, rooms (group by type or by room in Settings →
  List) and hidden devices, by right-clicking.
- **Alerts:** a notification when the LG washer or dryer finishes its cycle. It can be turned off in Settings → List.
- **Mac shortcuts:** ⌃⌥L opens Lar from any app, and the air conditioner's temperature can show next to the house
  (Settings → List).
- **Protected Settings:** Touch ID or your password to open Settings, where the keys are.
- **Automations:** scenes on schedule (with weekdays) and "Turn off in…" in each device's menu.
- **Mac and iPhone alike:** scenes, names, favorites and rooms sync over your home network, encrypted (Settings →
  iPhone → Pair an iPhone). The accounts' keys don't go along.
- **Air conditioner history:** temperature over the last 24 h, time on today and an estimate in kWh and money
  (power and rate in Settings → Air conditioner).
- **Diagnostics:** in Settings, each account's state, how long the last read took and the last error, with a report
  to copy that has no keys.
- **Xbox:** sign in with your Microsoft account (Settings → Xbox) and the console shows up in the list: turn it on
  (from Sleep) and off, the controller (arrows, A, B, X, Y, Menu, View and the Xbox button), volume, typing,
  opening games and apps and seeing what's playing. Unofficial integration (the same cloud the Xbox app uses):
  Microsoft may change it.
- **Alexa and Echos:** sign in with your Amazon account (Settings → Alexa, on Amazon's own page). The Echos join the
  list with volume, Do Not Disturb, music, speak, announce on all of them, "ask Alexa" (works for anything Alexa
  controls) and routines. The Mac announces the intercom and alerts (washer done) on the Echos. Alexa routines become
  Lar scenes: steps with devices Lar also has become commands; the others (speak, music, weather) Alexa does on an
  Echo when the scene runs. New routines are imported every hour. Unofficial integration (like Home Assistant's):
  Amazon may change it.
- **Intercom (VoIP/SIP):** answer the building's intercom, talk and open the gate (the keys it expects, e.g. `*1`),
  or call it. In Settings → Intercom: the extension's server, user and password, the intercom's number and the gate
  keys. The Mac stays registered and always rings. G.711 audio, which every PBX and intercom accepts.
- **Always open:** Lar starts with the Mac and comes back by itself if it stops without you quitting it (can be
  turned off in Settings → General).
- **Automatic updates:** the app is signed and notarized by Apple and updates itself from this repository's
  releases (Settings → Update automatically).
- **No server in between:** Lar talks straight to each brand's cloud and, for TVs, straight to the TV over your
  home network.

| Air conditioner | Light | TV |
|---|---|---|
| <img src="docs/air-conditioner.png" width="260"> | <img src="docs/light.png" width="260"> | <img src="docs/tv.png" width="260"> |

## Lar and other home apps

Lar doesn't replace each brand's app or a home automation hub: it **brings together in one list** what's already in
your accounts and takes it to every Apple device. No server, no hub and no Lar account needed.

| | Lar | Home Assistant | Home (Apple) | Google Home | Brand apps (LG ThinQ, SmartThings, Smart Life) |
|---|---|---|---|---|---|
| **What it is** | An app that gathers your accounts in one list | A home automation hub you host | Apple's home app (HomeKit and Matter) | Google's home app (Nest, Google Assistant, Matter) | Each manufacturer's official app |
| **What it needs** | Just the app and your accounts | An always-on computer (Raspberry Pi, server or virtual machine) and setup | Compatible devices and, for automations, a home hub (Apple TV or HomePod) | A Google account and compatible devices | The brand's account |
| **Devices** | LG ThinQ, Smart Life/Tuya, SmartThings, Alexa (Echos), Xbox, Google TVs and the Home app | Thousands of integrations | Only HomeKit or Matter compatible ones | Google's own, Matter ones and linked brands | Only the brand's own |
| **On the Mac** | In the menu bar, always open | Official app or browser | Home app | No app | Usually no app |
| **Apple Watch, CarPlay, Apple TV and Vision Pro** | All of them | Apple Watch and CarPlay, through the official app | All of them | No app for them | Varies by brand |
| **Each device's features** | The essentials: full LG air conditioner, TV remotes, cameras, washer | Depends on the integration | What HomeKit exposes | What Google exposes | Everything the brand offers |
| **Building intercom (SIP)** | Yes | With extra integrations | No | No | No |
| **Where the data lives** | On your devices (keys in the Keychain) | On your server | In iCloud | In your Google account | In the brand's account |

**Lar works with the others:** on the Mac, it becomes a **Home app** bridge (Settings → Home app) and brings your
LG, Smart Life and SmartThings devices to Home and Siri. **Alexa** routines become Lar scenes.

**When to use another app:**
- **To pair a new device**, update firmware or use a very specific feature, use the brand's app: Lar only sees what's
  already in the account.
- **For complex automations** (sensors, conditions, hundreds of integrations, all on the local network), use Home
  Assistant. Lar does scenes on schedule and "turn off in…", not "if this, then that" rules.
- **For voice commands**, use Siri (through the Home app, with Lar's bridge), Alexa or Google Assistant.

**Lar's limits:** it depends on each brand's cloud (only TVs are controlled directly over your home network), and
some integrations are unofficial (Alexa and Xbox): the company may change them without notice.

## Requirements

- A Mac with **Apple silicon (M1 or newer)** and **macOS 15 Sequoia or newer**.
- In Portuguese or English, following the system language.
- At least one of the accounts below. You set up only the ones you use.

## Install

1. Download `Lar-<version>.dmg` from the [Releases](../../releases/latest) page.
2. Open the DMG and drag **Lar** to the **Applications** folder.
3. Open Lar. It's signed and notarized by Apple, so it opens right away, with no macOS warning.
4. The little house shows up in the menu bar. With no account set up, Lar opens straight into **Settings**.
5. If macOS asks whether Lar may **find devices on your local network**, click **Allow**: that's how it finds and
   controls the TVs.

Lar already opens with the Mac. To change it: Lar's Settings → **Open at login**.

## Setting up each account

Everything is in **Settings** (the gear in the corner). Each key is stored in the **Mac's Keychain**, on this Mac
only, and is never shown on screen again. Next to each account's name, Settings shows whether it connected and how
many devices it found.

### LG ThinQ (air conditioner, washer, fridge…)

1. Go to [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com) and sign in with your LG account (the same as
   the LG ThinQ app).
2. Create a **Personal Access Token** and copy it. It starts with `thinqpat_`.
3. In Lar: Settings → **LG ThinQ** → paste the token → **Save**.

Lar uses the Americas region (accounts from Brazil). The devices need to already work in the LG ThinQ app.

### Smart Life / Tuya (lights, plugs, cameras, sensors)

Works for the **Smart Life** app and for brands built on the Tuya platform (Nova Digital, Ekaza and many others).

1. **Put everything in the Smart Life app.** Lar only sees Smart Life (or Tuya Smart) accounts. If a device is in its
   own brand's app, remove it there, reset the device and pair it again in Smart Life, on 2.4 GHz Wi-Fi.
2. **Create a Tuya project** (free, about 10 minutes):
   1. Create an account at [iot.tuya.com](https://iot.tuya.com).
   2. **Cloud → Development → Create Cloud Project**. Development Method: **Smart Home**. Data Center: **Western
      America** for accounts from Brazil and the Americas.
   3. Under **Service API**, authorize **IoT Core** and, for cameras, **IoT Video Live Stream**.
   4. On the **Devices → Link App Account** tab, a QR code shows up. In the Smart Life app: **Me → scan icon** and
      scan the code. The devices show up in the site's list.
   5. On the project page, copy the **Access ID** and the **Access Secret**.
3. In Lar: Settings → **Smart Life (Tuya)** → paste the Access ID and the Access Secret, choose the region
   (**Americas**) → **Save**.

> A specific brand's app (Nova Digital, Ekaza…) shows "Please use the designated app" when scanning the QR code:
> that's expected. Only Smart Life and Tuya Smart can be linked to the project.

> The IoT Core service comes as a free trial with an end date. When it's about to expire, Tuya's site offers to
> renew it for free for personal use. If Lar shows "Smart Life: the key was refused", that's it.

### SmartThings (Samsung TVs and soundbars, and whatever is in SmartThings)

There are three ways.

**Set up automatically (the simplest).** In Settings → **SmartThings** → **Set up automatically**, Lar opens the
Samsung sign-in in a window. Sign in and tap **Authorize**: Lar creates a temporary token (it lasts 24 hours and
isn't kept), creates this Mac's integration and fills in everything by itself. **How to create it by hand** has the
steps to do it without Lar, with the commands ready to copy.

**Personal token (for testing).** Create one at
[account.smartthings.com/tokens](https://account.smartthings.com/tokens) and paste it in Settings → **SmartThings** →
**Save**. New tokens **last only 24 hours**.

**OAuth with a personal token, one integration per device.** Lar renews access by itself, and creates the
integration for you:

1. Create a personal token at [account.smartthings.com/tokens](https://account.smartthings.com/tokens) with the
   **apps** permission (besides devices and locations). It's only used to create the integration and isn't kept.
2. In Lar: Settings → **SmartThings** → turn on **Use OAuth** → paste the token → **Create and sign in**.
3. Sign in to your Samsung account on the page that opens (check "keep me signed in", if it shows up). Done: Lar
   creates the "Lar (iPhone)", "Lar (Mac)"… integration and gets the code and the refresh token by itself.

Repeat on each device: **each one needs its own integration**. The refresh token changes at every renewal, and two
devices sharing one log each other out. Lar prevents that: a paired Mac and iPhone tell each other which integration
they use (only a fingerprint of the Client ID, never the ID or the secret), warn when it's the same and refuse to
sign in with the other's. The watch gets its own too, in Settings → **SmartThings on the watch**.

If Samsung later refuses the token (another device renewed it, for example), Lar signs in again by itself, without
you doing anything, while the Samsung account's session lasts; otherwise it tells you to sign in again.

You can still use an integration created by hand (`smartthings apps:create`, type **OAuth-In App**, scopes
`r:devices:*`, `x:devices:*` and `r:locations:*`, redirect `https://httpbin.org/get`): paste the Client ID and the
Client Secret and tap **Sign in to SmartThings**.

Lar needs to be open at least once every ~30 days so the access doesn't expire. **Don't use the same refresh token
in another program:** it changes at every renewal, and one would invalidate the other. For another program, create
another integration.

"Offline" in Lar is what SmartThings itself reports (device without a connection). A device that's connected and
off shows as "Off" and can be turned on from Lar.

### Google TVs

TVs are **found automatically** on your home network, even when the router changes their IP. There are two ways for
Lar to control a TV.

**Pairing with the code (the simplest).** It's the same remote as the Google TV app; no need to touch the TV's
settings. With the TV on, open it in Lar's list and click **Pair with the TV** (on the Mac, when the TV also accepts
ADB, the button is called **Pair without debugging**). The TV shows a 6-character code: type it in Lar and confirm.
It's once per TV and per device (the Mac and the iPhone each pair their own). Once paired, the TV turns on and off,
gets the remote's keys and opens the most common apps (Netflix, YouTube, Prime Video…).

**Through USB debugging (Mac only).** Besides the remote, it lists every app installed on the TV:

1. On the TV: Settings → **System → About** (or Device Preferences → About) → click **"Build" 7 times** until
   "You are now a developer" shows up.
2. Go back and open **Developer options** → turn on **USB debugging**. (Some TVs also have "Network debugging" or
   "ADB over network": turn it on too.)
3. Open Lar. On the first connection, the TV shows **"Allow USB debugging?"**: check **"Always allow"** and confirm
   with the remote. It's only needed once per TV.

In Settings (**Google TV**) you can turn off automatic discovery, type the IP of a TV that doesn't show up by
itself and forget TVs that aren't on the network.

**About turning the TV on from Lar:** turning off always works. To turn on, the TV needs to stay on the network
while in standby. Many TVs turn Wi-Fi off in standby; for those Lar tries Wake-on-LAN (which usually works over an
Ethernet cable) and, if that fails, tells you to use the remote.

**Security:** USB debugging gives full control of the TV to whoever the TV authorizes. Only accept the request when
it's your Mac, and turn debugging off if you stop using Lar with the TV.

### Xbox

1. In Lar: Settings → **Xbox** → **Sign in to Xbox**. A code shows up.
2. On any phone or computer, open [microsoft.com/link](https://www.microsoft.com/link), enter the code and sign in
   with the Xbox's Microsoft account (an adult's). The password stays on Microsoft's page, it never goes through Lar.
3. On the Xbox, just once:
   - Settings → **Devices & connections → Remote features**: check **Enable remote features**.
   - On the same screen, under **Xbox app preferences**: **Allow connections from any device**.
   - Settings → **General → Power options**: choose **Sleep**. In **Energy saving** the Xbox can't be turned on from
     Lar.

If the Xbox doesn't respond, restart the console: hold the Xbox button for 10 seconds and turn it on again. The same
steps are in Settings → Xbox → **How to set up the Xbox**.

## Privacy and security

- **No Lar server, no Lar account, no data collection.** The app only talks to LG, Tuya, Samsung, Amazon and
  Microsoft (with your keys), to the TVs on your network and to the Home app on your Apple devices.
- **Home app bridge:** only on your home network, with HomeKit's pairing and encryption. In Settings → Home app →
  **Remove from Home**, Lar forgets every pairing.
- **Account keys:** in the Mac's Keychain, on this Mac only (not synced with iCloud).
- **Mac ↔ iPhone sync:** only on your home network, encrypted with a key only the paired devices have. Pairing uses
  ECDHE key exchange (someone recording the network can't recover the code later), the code lasts 2 minutes and
  stops after 5 wrong attempts.
- **TV key:** in `~/Library/Application Support/Lar/adbkey`, readable only by your user, as `adb` does.
- **Remove everything:** in Settings, **Remove** on each account; to delete the TV key, delete the
  `~/Library/Application Support/Lar` folder.

Full policy: [privacy.md](docs/privacy.md).

## Common problems

| What shows up | What to do |
|---|---|
| "…: the key was refused" | The token expired or was revoked. Create another one and paste it in Settings. |
| Device "Offline" | The brand's own cloud says it has no connection. Check the brand's app, the power and the Wi-Fi. |
| TV: "Accept 'Allow USB debugging?' on the TV" | Accept it on the TV, checking "Always allow". |
| TV: "The TV didn't answer" | Check that the TV is on, on the same network and with USB debugging on. |
| macOS asks to let Lar use the Keychain | Click "Always Allow" (it happens after updating the app). |
| Xbox: "The Xbox didn't respond" | Check Sleep mode and remote features on the Xbox (see Setting up → Xbox) and restart the console. |
| Camera doesn't open | The Tuya project needs the **IoT Video Live Stream** service authorized. |

## Contributing

Lar is free and open source, made by [Coupled](https://www.coupled.com.br). In the app, the **ⓘ** button (About Lar)
gathers all of this.

- **Problems and ideas:** open an [issue](https://github.com/coupledtec/Lar/issues/new) with what happened, the
  device, the version and the Diagnostics report (no keys).
- **Code:** fork, branch and pull request; see the [contributing guide](CONTRIBUTING.md).
- **To keep Lar free** (Apple's developer fee is US$ 99 a year):
  [GitHub Sponsors](https://github.com/sponsors/coupledtec), [Buy Me a Coffee](https://buymeacoffee.com/coupled) or
  **PIX** to Coupled's CNPJ (Brazil), `41.107.909/0001-20`. In the App Store apps, tips are in Settings → About Lar.

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md). In short: `scripts/test.sh` (tests), `scripts/build-app.sh --install` (installs
to Applications) and `scripts/make-dmg.sh` (builds the release DMG). The Xcode Command Line Tools are enough.

## Credits and license

The Xbox integration follows the protocol documented by
[xbox-webapi-python](https://github.com/OpenXbox/xbox-webapi-python) (OpenXbox, MIT), the same one Home Assistant
uses. The Alexa integration follows what [aioamazondevices](https://github.com/chemelli74/aioamazondevices) (Simone
Chemelli and contributors, Apache-2.0) and [alexa-remote](https://github.com/Apollon77/alexa-remote) (Apollon77, MIT)
do. LG air conditioner control comes from [Celsius](https://github.com/gbvillarinho/celsius), by Gabriel Villarinho
(MIT license). Lar adds the other accounts, the TVs and the rest.

[MIT](LICENSE) license. Lar isn't affiliated with LG, Tuya, Samsung, Amazon, Microsoft or Google; the names are
trademarks of their owners.
