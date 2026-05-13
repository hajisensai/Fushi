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
- Built-in [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) for EPUB rendering (WebView)
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
| Framework | Flutter 3.41.6 / Dart 3.11.4 |
| Reader | ttu Ebook Reader (WebView, [fork](https://github.com/hdjsadgfwtg/ttu-fork)) |
| Storage | Isar + Drift (SQLite) + hoshidicts (C++ FFI dictionary engine) |
| NLP | Ve (lemmatization) |
| Card Creation | AnkiDroid API |
| i18n | Slang |
| Minimum Version | Android 8.0 (API 26) |

## Building

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **Pub cache patches are required before the first build.** If the pub cache is cleared or `pub get` is re-run, all patches must be re-applied. See [Dependencies & Patches](#dependencies--patches) below.

## Dependencies & Patches

This project is locked to Flutter 3.41.6. Some upstream dependencies have not been updated for this version and require manual patching in the pub cache.

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
| `android/build.gradle` afterEvaluate | Force `compileSdkVersion 34` for subprojects; remove `-Werror` |
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
hibiki/
├── hibiki/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── media/       # Audiobook bridge, subtitle parsing
│   │   │   ├── dictionary/  # Dictionary lookup engine
│   │   │   ├── models/      # Data models and state management
│   │   │   └── language/    # Language abstraction layer
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # ttu fork build artifacts
│   └── android/
│       └── app/src/main/cpp/ # hoshidicts C++ dictionary engine
├── docs/                    # Development documentation
└── chisa/                   # jidoujisho early version reference
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
