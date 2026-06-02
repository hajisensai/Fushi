<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Immersive Japanese Reader for Android</p>
<p align="center">EPUB · Dictionaries · Anki · Audiobook Sync</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <b>English</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduction

**hibiki** is an Android reading app designed for Japanese learners.

## Features

### EPUB Reading
- Render EPUB in WebView (paging engine derived from [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Tap to look up words, select text for analysis
- Custom fonts, themes (light/dark)
- Reading statistics and bookmarks
- Continuous scroll / paginated modes

### Dictionaries
- Import [Yomitan](https://github.com/yomidevs/yomitan) format dictionaries (formerly Yomichan)
- Pitch accent and word frequency information
- Multi-dictionary parallel lookup, search history
- Ve lemmatization

### Anki Card Creation
- One-tap export to [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Auto-fill context sentences
- Audio recording and screenshot cropping support
- Multiple export profiles, custom field mapping
- Quick Actions for one-step card creation

### Audiobook Sync (Sasayaki)
- Subtitle formats: SRT / LRC / VTT / ASS
- Automatic subtitle-to-EPUB text alignment
- Follow-along highlighting, audio-synced page turning
- Playback controls (progress, seek, speed)

### Other
- 17 interface languages
- Multiple user profiles
- Incognito mode
- Share text from other apps to look up words directly

## Supported Languages

The interface supports the following languages:

| Language | Code |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptive) |
| Reader | WebView paging engine (derived from [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Storage | Drift (SQLite, WAL) + hoshidicts (C++ FFI dictionary engine) |
| NLP | Ve (lemmatization) |
| Card Creation | AnkiDroid API |
| i18n | Slang (17 languages) |
| Minimum Version | Android 7.0 (API 24) |

## Building

One-command prep (`flutter pub get` + apply patches), then build:

```bash
# From the repository root
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # or (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` collapse two steps into one command: ① `flutter pub get`; ② run `ci/apply-patches.sh`. `melos bootstrap` does the same via a post hook (on Windows melos has a CJK encoding bug, so use `tool/bootstrap.ps1`).

> **Patch note:** `ci/apply-patches.sh` overlays the changes under `ci/patches/` onto the actual pub cache. It must be re-run after every pub cache clear or `flutter pub get` (bootstrap already includes this step). When the script finds no patch targets, it skips and warns rather than pretending to succeed.

## Dependencies & Patches

This project is locked to Flutter 3.41.6, and some upstream dependencies have not been adapted yet. Patching follows two mechanisms: ① packages that need to be build inputs and reproduce consistently across machines are vendored directly under `third_party/` and pointed to via `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **no** pub-cache patching needed); ② the remaining packages are patched in the pub cache source by `ci/apply-patches.sh`. See [docs/agent/build.md](../agent/build.md) for mechanism details. The folding tables below are a historical list grouped by change; for packages that overlap with mechanism ①, the vendored version takes precedence.

<details>
<summary><b>Flutter API Change Patches</b></summary>

| Package | Changes |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; replace removed `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | Same `loadImage` / `hashValues` / `ImmutableBuffer` changes |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Added `hide CarouselController` to internal imports to avoid naming conflicts |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable fix |

</details>

<details>
<summary><b>v1 Embedding Removal Patches</b></summary>

Flutter 3.41.6 completely removed the v1 embedding API (`PluginRegistry.Registrar`). The following plugins require removal of related references:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin Patches</b></summary>

| Target | Changes |
|---|---|
| `android/build.gradle` afterEvaluate | Force `compileSdk` for subprojects (default 36, some 34); remove `-Werror` |
| `audio_session` 0.1.14 | Remove `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null safety fix |
| `receive_intent` (git) | Kotlin null safety fix |

</details>

<details>
<summary><b>Git Dependencies</b></summary>

| Package | Source |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## Project Structure

```
hibiki/                      # Repository root (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native hoshidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── third_party/             # Vendored patched packages (pointed to by dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ agent operations manual)
```

## Acknowledgments

| Project | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanese immersive learning tool |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android Japanese reader |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ dictionary engine |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japanese reader |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Audiobook sync solution |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB rendering engine |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu community-maintained version (SvelteKit v2), upstream base for hibiki fork |
| [Yomitan](https://github.com/yomidevs/yomitan) | Dictionary format source |

## License

[GNU General Public License v3.0](../../LICENSE)
