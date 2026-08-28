<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="fushi-Logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Neueste Version herunterladen](https://img.shields.io/badge/%E2%AC%87%20Neueste%20Version%20herunterladen-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord beitreten](https://img.shields.io/badge/Discord%20beitreten-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Plattform-Unterstützung

| Plattform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Mindestens Android 7.0 (API 24). Welche Sprachen zum Nachschlagen verfügbar sind, hängt von den importierten Wörterbüchern und den Yomitan-Transformationstabellen ab — unabhängig von der Oberflächensprache.

### Oberflächensprachen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation & Build

Vorbereitung mit einem Befehl (`flutter pub get` + Patches anwenden), dann bauen:

```bash
# Vom Repository-Stammverzeichnis aus
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows-Desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` fassen `flutter pub get` und `ci/apply-patches.sh` zu einem einzigen Befehl zusammen. Dieses Projekt ist auf Flutter 3.44.0 festgelegt (Dart SDK `>=3.5.0 <4.0.0`); einige Upstream-Abhängigkeiten sind unter `third_party/` mitgeliefert oder werden durch `ci/apply-patches.sh` gepatcht — Details siehe [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Technologie-Stack</b></summary>

| Schicht | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plattformen | Android / Windows / macOS / iOS (Material Design 3) |
| Reader | WebView-Seitenmaschine (abgeleitet von der Hoshi-Reader-Familie) |
| Video | media_kit (libmpv-Kern) |
| Speicher | Drift (SQLite, WAL) + fushidicts (C++-FFI-Wörterbuch-Engine) |
| NLP | Yomitan-Transformationstabellen (mehrsprachige Lemmatisierung) + kana_kit (Kana-Konvertierung); Tokenisierung über fushidicts-FFI |
| Kartenerstellung | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 Sprachen) |

</details>

<details>
<summary><b>Projektstruktur</b></summary>

```
Fushi/                      # Repository-Stammverzeichnis (Melos-Workspace: fushi_workspace)
├── fushi/                  # Hauptverzeichnis der Flutter-App
│   ├── lib/
│   │   ├── i18n/            # Internationalisierung (17 Sprachen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Seiten (Bücherregal, Reader, Wörterbuch, Einstellungen usw.)
│   │   │   ├── reader/      # Reader-WebView-JS-/CSS-Skripte
│   │   │   ├── media/       # Hörbuch, Untertitel-Parsing, Reader-Quelle
│   │   │   └── models/      # Datenmodelle und Zustandsverwaltung (AppModel)
│   │   └── main.dart
│   └── android/             # Android-Projekt (Manifest, natives fushidicts)
├── packages/                # Interne Pakete + flutter_inappwebview_windows (Fork) + gamepads_android_stub
├── native/                  # fushidicts C++-Wörterbuch-Engine (FFI)
├── third_party/             # Mitgelieferte gepatchte Pakete (dependency_overrides)
├── ci/                      # Build-Patches und Integrationstest-Skripte
├── tool/                    # bootstrap / i18n_sync und weitere Skripte
└── docs/                    # Entwicklungsdokumentation (inkl. docs/agent/ Betriebshandbuch)
```

</details>

## Datenschutz & Daten

Fushi speichert importierte Bücher, Wörterbücher, Schriften, Hörbuchdaten, Videos, Lesefortschritt, Markierungen, Statistiken und Einstellungen im lokalen Speicher der App.

Cloud-Sync (Google Drive / OneDrive / Dropbox) verwendet vom Benutzer konfigurierte OAuth-Anmeldedaten; WebDAV / FTP / SFTP verwendet vom Benutzer angegebene Serveradressen und Anmeldedaten; Fushi Interconnect verbindet sich direkt über eine vom Benutzer konfigurierte Adresse. Die Anki-Kartenerstellung kommuniziert mit AnkiDroid oder einer konfigurierten AnkiConnect-Adresse.

## Danksagungen

Fushi baut auf den folgenden Projekten und dem folgenden Ökosystem auf:

| Projekt | Beschreibung |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanisches immersives Lernwerkzeug |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanisch-Reader; Referenz für die Reader-Seitenmaschine |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Nativer japanischer Reader für Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++-Wörterbuch-Engine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Lösung für die Hörbuch-Synchronisation |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referenz für Wörterbuchformat, Transformationstabellen und Nachschlage-Erlebnis |
| [Lapis](https://github.com/donkuri/lapis) | Anki-Notiztyp |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android-Kartenerstellungs-Integration |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referenz für lokales Audio und AnkiDroid-Interaktion |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referenz für Reader, Statistiken und Sync-Kompatibilität |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter-Videowiedergabe-Framework (libmpv-Kern) |
| [Niratan](https://github.com/W1ght/Niratan) | Immersive Sprachlern-Suite für macOS |

## Lizenz

Vertrieben unter der GNU General Public License v3.0. Details siehe [LICENSE](../../LICENSE).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
