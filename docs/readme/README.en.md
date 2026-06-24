<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Read a book, and make every new word your own.</b></p>
<p align="center">A multi-platform, multi-language immersive reader — EPUB reading · tap-to-look-up · Anki card creation · audiobook sync · video subtitle lookup</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Project Homepage (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <b>English</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduction

**hibiki** is a multi-platform immersive language-learning reader. Inside the EPUB text, **tap to look up a word, select to analyze it**, and turn unfamiliar words into Anki cards in one tap; sync audiobook audio with the text and highlight it sentence by sentence; you can even look up words and create cards straight from video subtitles. One tool that covers all three immersive inputs: read · listen · watch.

Dictionary lookup covers **all of the transformation languages of [Yomitan](https://github.com/yomidevs/yomitan)** (deinflection + pre-lookup text normalization), the interface is localized into **17 languages**, and it runs on all five platforms: **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Bookshelf" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Lookup" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Settings and themes" width="300">
</p>
<p align="center"><sub>Bookshelf · Lookup · Settings and Themes</sub></p>

---

## Highlights

### 📖 EPUB Reading, Tap to Look Up

A WebView-rendered EPUB reader (paging engine derived from [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) lets you look up any word instantly by tapping and analyze a selection on the fly. Continuous-scroll and paginated dual modes, custom fonts and themes (light / dark / pure black / custom), furigana, reading statistics and bookmarks — it has everything you need.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Vertical reading · furigana · audiobook sync" width="300">
</p>
<p align="center"><sub>Vertical text · furigana · selection highlight · bottom audiobook sync control bar</sub></p>

### 🔍 Tap-to-Look-Up, Covering All Yomitan Transformation Languages

Import dictionaries in several formats: **Yomitan** (formerly Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Multi-language lemmatization (Yomitan transformation tables) plus pre-lookup text normalization (case / diacritics / Arabic harakat), driven by code points with no need to switch languages. Parallel queries across multiple dictionaries, sub-source priority and toggling, pitch-accent annotations and word frequency — all handled in a single popup.

### 🎴 One-Tap Anki Card Creation

Once you find a new word, export it to [AnkiDroid](https://github.com/ankidroid/Anki-Android) and AnkiConnect in one step. The built-in [Lapis](https://github.com/donkuri/lapis) note-type schema (vendored 1.7.0) lets you create card templates and decks directly inside the app; it auto-fills the context sentence, supports audio recording and screenshot cropping, multiple export profiles (Profile), custom field mapping, and Quick Actions for one-step card creation.

### 🎧 Audiobook Sync (Sasayaki)

Supports SRT / LRC / VTT / ASS subtitles and automatically aligns subtitle text with the EPUB body. During playback, **follow-along highlighting and audio-synced page turning** light up the text sentence by sentence as you listen, alongside the playback control bar (progress, seek, speed) — the control bar at the bottom of the reading screenshot above is exactly this feature.

### 🎬 Video Subtitle Lookup

A built-in video player based on media_kit / libmpv supports embedded and external subtitles. While playing a video, **look up words and create cards straight from the subtitles**, bringing film and TV material into your immersive input too; it also tracks watch time and the number of cards created.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Video player screenshot coming soon — to be captured on a real / foreground device (video frame + subtitle bar + lookup popup; see the note below).</sub></p>

### 🔗 More

- **17 interface languages**, fully localized across all platforms
- **Hibiki interconnect**: sync books / dictionaries / audiobooks / reading progress across devices
- **Multi-user profiles (Profile)**, switched automatically per book
- **Incognito mode**; **share text from other apps to look up words directly**

---

## Platform Support

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (EPUB rendered by the forked `flutter_inappwebview_windows`) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Minimum Android 7.0 (API 24). The languages available for dictionary lookup are determined by the dictionaries you import and the Yomitan transformation tables, independently of the interface language.

### Interface Languages (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Installation & Building

One-command prep (`flutter pub get` + apply patches), then build:

```bash
# 在仓库根目录
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` collapse ① `flutter pub get` and ② `ci/apply-patches.sh` into a single command. This project is locked to Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); some upstream dependencies are vendored under `third_party/` or patched by `ci/apply-patches.sh` — for the mechanism details, five-platform builds, and the dependency-and-patch list, see [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Tech Stack at a Glance</b></summary>

| Layer | Technology |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platforms | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptive) |
| Reader | WebView paging engine (derived from [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Video | media_kit / libmpv |
| Storage | Drift (SQLite, WAL) + hoshidicts (C++ FFI dictionary engine) |
| NLP | Yomitan transformation tables (multi-language lemmatization) + kana_kit (kana conversion); tokenization via hoshidicts FFI |
| Card Creation | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 languages) |

</details>

<details>
<summary><b>Project Structure</b></summary>

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
├── packages/                # Internal packages + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (pointed to by dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ agent operations manual)
```

</details>

---

## Acknowledgments

| Project | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanese immersive learning tool |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android Japanese reader |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ dictionary engine |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japanese reader |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Audiobook sync solution |
| [Yomitan](https://github.com/yomidevs/yomitan) | Dictionary format and transformation-table source |
| [Lapis](https://github.com/donkuri/lapis) | Anki note type |

## License

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <b>English</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
