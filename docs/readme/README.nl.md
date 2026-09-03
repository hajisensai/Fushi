<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="fushi-logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | **Nederlands** | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Nieuwste versie downloaden](https://img.shields.io/badge/%E2%AC%87%20Nieuwste%20versie%20downloaden-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Word lid van Discord](https://img.shields.io/badge/Word%20lid%20van%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Platformondersteuning

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Minimaal Android 7.0 (API 24). Welke talen beschikbaar zijn om op te zoeken, wordt bepaald door de geïmporteerde woordenboeken en de Yomitan-transformatietabellen, onafhankelijk van de interfacetaal.

### Interfacetalen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installatie & Bouwen

Voorbereiding met één commando (`flutter pub get` + patches toepassen), dan bouwen:

```bash
# Vanuit de hoofdmap van de repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows-desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` bundelen `flutter pub get` en `ci/apply-patches.sh` tot één enkel commando. Dit project is vastgezet op Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); sommige upstream-afhankelijkheden zijn meegeleverd onder `third_party/` of gepatcht door `ci/apply-patches.sh` — zie [docs/agent/build.md](../agent/build.md) voor details.

<details>
<summary><b>Technologiestack</b></summary>

| Laag | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platforms | Android / Windows / macOS / iOS (Material Design 3) |
| Reader | WebView-paginamotor (afgeleid van de Hoshi Reader-familie) |
| Video | media_kit (libmpv-kern) |
| Opslag | Drift (SQLite, WAL) + fushidicts (C++-FFI-woordenboekengine) |
| NLP | Yomitan-transformatietabellen (meertalige lemmatisering) + kana_kit (kana-conversie); tokenisatie via fushidicts-FFI |
| Kaarten maken | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 talen) |

</details>

<details>
<summary><b>Projectstructuur</b></summary>

```
Fushi/                      # Hoofdmap van de repository (Melos-workspace: fushi_workspace)
├── fushi/                  # Hoofdmap van de Flutter-app
│   ├── lib/
│   │   ├── i18n/            # Internationalisatie (17 talen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagina's (boekenplank, lezer, woordenboek, instellingen enz.)
│   │   │   ├── reader/      # Reader-WebView-JS-/CSS-scripts
│   │   │   ├── media/       # Audioboek, ondertitel-parsing, reader-bron
│   │   │   └── models/      # Datamodellen en toestandsbeheer (AppModel)
│   │   └── main.dart
│   └── android/             # Android-project (manifest, native fushidicts)
├── packages/                # Interne pakketten + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # fushidicts C++-woordenboekengine (FFI)
├── third_party/             # Meegeleverde gepatchte pakketten (dependency_overrides)
├── ci/                      # Build-patches en integratietestscripts
├── tool/                    # bootstrap / i18n_sync en andere scripts
└── docs/                    # Ontwikkeldocumentatie (incl. docs/agent/ bedieningshandleiding)
```

</details>

## Privacy & Gegevens

Fushi slaat geïmporteerde boeken, woordenboeken, lettertypen, audioboekgegevens, video's, leesvoortgang, markeringen, statistieken en instellingen op in de lokale opslag van de app.

Cloud-synchronisatie (Google Drive / OneDrive / Dropbox) gebruikt door de gebruiker geconfigureerde OAuth-referenties; WebDAV / FTP / SFTP gebruikt door de gebruiker opgegeven serveradressen en referenties; Fushi Interconnect verbindt rechtstreeks via een door de gebruiker geconfigureerd adres. Het maken van Anki-kaarten communiceert met AnkiDroid of een geconfigureerd AnkiConnect-adres.

## Dankbetuigingen

Fushi bouwt voort op de volgende projecten en het volgende ecosysteem:

| Project | Beschrijving |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanse immersieve leertool |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanse lezer; referentie voor de reader-paginamotor |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Native Japanse lezer voor Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++-woordenboekengine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Oplossing voor audioboeksynchronisatie |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referentie voor woordenboekformaat, transformatietabellen en opzoekervaring |
| [Lapis](https://github.com/donkuri/lapis) | Anki-notitietype |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android-integratie voor kaarten maken |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referentie voor lokale audio en AnkiDroid-interactie |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referentie voor lezer, statistieken en sync-compatibiliteit |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter-videoweergaveframework (libmpv-kern) |
| [Niratan](https://github.com/W1ght/Niratan) | Immersieve taalleersuite voor macOS |

## Licentie

Gedistribueerd onder de GNU General Public License v3.0. Zie [LICENSE](../../LICENSE) voor details.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | **Nederlands** | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
