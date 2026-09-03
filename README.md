<div align="center">

# Fushi

<img src="docs/static-assets/fushi-logo.png" alt="Fushi logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

**English** | [简体中文](README.zh-CN.md) | [繁體中文](docs/readme/README.zh-Hant.md) | [日本語](docs/readme/README.ja.md) | [한국어](docs/readme/README.ko.md) | [Español](docs/readme/README.es.md) | [Français](docs/readme/README.fr.md) | [Deutsch](docs/readme/README.de.md) | [Português](docs/readme/README.pt-BR.md) | [Русский](docs/readme/README.ru.md) | [Tiếng Việt](docs/readme/README.vi.md) | [ภาษาไทย](docs/readme/README.th.md) | [Bahasa Indonesia](docs/readme/README.id.md) | [Italiano](docs/readme/README.it.md) | [Nederlands](docs/readme/README.nl.md) | [Türkçe](docs/readme/README.tr.md) | [العربية](docs/readme/README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Download Latest](https://img.shields.io/badge/%E2%AC%87%20Download%20Latest-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Join our Discord](https://img.shields.io/badge/Join%20our%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Platform Support

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Minimum Android 7.0 (API 24). Galgame voice mining is Windows-only. The languages available for dictionary lookup are determined by the imported dictionaries and Yomitan transformation tables, independently of the interface language.

### Interface Languages (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation

Download the latest release from the [Fushi website](https://fushi.moe/) — Android APK, Windows installer, macOS, and iOS builds are available. Linux has no prebuilt release yet; build it from source.

> Requires Android 7.0 (API 24) or higher.

## Building

One-command prep (`flutter pub get` + apply patches), then build:

```bash
# From the repository root
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` collapse `flutter pub get` and `ci/apply-patches.sh` into a single command. This project is locked to Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); some upstream dependencies are vendored under `third_party/` or patched by `ci/apply-patches.sh` — see [docs/agent/build.md](docs/agent/build.md) for details.

<details>
<summary><b>Tech Stack</b></summary>

| Layer | Technology |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platforms | Android / Windows / macOS / iOS (Material Design 3) |
| Reader | WebView paging engine (derived from the Hoshi Reader family) |
| Video | media_kit (libmpv core) |
| Storage | Drift (SQLite, WAL) + fushidicts (C++ FFI dictionary engine) |
| NLP | Yomitan transformation tables (multilingual lemmatization) + kana_kit (kana conversion); tokenization via fushidicts FFI |
| Downloads | libtorrent 2.x via a C-ABI FFI bridge |
| Card Creation | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 languages) |

</details>

<details>
<summary><b>Project Structure</b></summary>

```
Fushi/                      # Repository root (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native fushidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # C++ sources: fushidicts (dictionary engine), fushi_torrent, galgame_hook
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## Privacy & Data

Fushi stores imported books, dictionaries, fonts, audiobook data, videos, reading progress, highlights, statistics, and settings in the app's local storage.

Cloud sync (Google Drive / OneDrive / Dropbox) uses user-configured OAuth credentials; WebDAV / FTP / SFTP uses user-provided server addresses and credentials; Fushi Interconnect connects directly to a user-configured address on your own network. Anki card creation communicates with AnkiDroid or a configured AnkiConnect address.

## Development Activity

[![Development Activity](docs/assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Day-to-day work lands on `develop`; `main` only receives release merges. The chart is displayed here on `main` but is generated from `develop`, so it reflects actual development rather than merge traffic.

The three lanes are the update channels the app itself offers, and each is scaled to its own peak — debug builds outnumber stable releases by two orders of magnitude, so a shared scale would flatten the other two lanes to nothing.

| Lane | What it counts | How you get it |
|---|---|---|
| **Debug (rolling)** | Successful push builds of [release.yml](.github/workflows/release.yml) | Rolling prerelease, republished on every push |
| **Beta** | `v<version>-beta.<seq>` prereleases | Manually dispatched test build |
| **Stable** | `v<version>` releases | Latest release |

> The chart above is generated inside this repository (no third-party service) and refreshed daily by the [Update Dev Activity Chart](.github/workflows/dev-activity.yml) workflow.

## Star History

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star History](docs/assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> The chart above is generated inside this repository (no third-party service) and refreshed daily by the [Update Star History](.github/workflows/star-history.yml) workflow.

## Acknowledgments

Fushi builds on the following projects and ecosystem:

| Project | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanese immersive learning tool |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japanese reader; reader paging engine reference |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android native Japanese reader |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ dictionary engine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Audiobook sync solution |
| [Yomitan](https://github.com/yomidevs/yomitan) | Dictionary format, transformation tables, and lookup experience reference |
| [Lapis](https://github.com/donkuri/lapis) | Anki note type |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android card creation integration |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Local audio and AnkiDroid interaction reference |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Reader, statistics, and sync compatibility reference |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter video playback framework (libmpv core) |
| [Niratan](https://github.com/W1ght/Niratan) | Immersion language learning suite for macOS |

## License

Distributed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

<div align="center">

<br>

**English** | [简体中文](README.zh-CN.md) | [繁體中文](docs/readme/README.zh-Hant.md) | [日本語](docs/readme/README.ja.md) | [한국어](docs/readme/README.ko.md) | [Español](docs/readme/README.es.md) | [Français](docs/readme/README.fr.md) | [Deutsch](docs/readme/README.de.md) | [Português](docs/readme/README.pt-BR.md) | [Русский](docs/readme/README.ru.md) | [Tiếng Việt](docs/readme/README.vi.md) | [ภาษาไทย](docs/readme/README.th.md) | [Bahasa Indonesia](docs/readme/README.id.md) | [Italiano](docs/readme/README.it.md) | [Nederlands](docs/readme/README.nl.md) | [Türkçe](docs/readme/README.tr.md) | [العربية](docs/readme/README.ar.md)

</div>
