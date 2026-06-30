<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | **English** | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[User Guide](../user-guide.md) | [Download Latest](https://github.com/hajisensai/hibiki/releases)

> **Watch what you want to watch, and pick up the language along the way.**

hibiki turns the novels you read, the shows you follow, and the audiobooks you listen to into your language input — tap any unknown word to look it up, then turn it into an Anki card with original context in one tap. It doesn't hand you a preset word list; it just helps you catch the words you **actually read and hear**.

The most effective way to learn a language is heavy exposure to real content, not memorizing isolated words from a vocabulary book. But "immersion" has always had two annoyances: looking up a word breaks your flow, and you forget it the moment you look away. hibiki closes that loop —

📖 **Read**: tap a word in the EPUB reader to look it up, without leaving the current page.<br>
🎧 **Listen**: audiobooks highlight along sentence by sentence and turn pages automatically.<br>
🎬 **Watch**: look up words and make cards right on the video subtitles — following a show *is* input.<br>
🃏 **Retain**: send any word you looked up, anywhere, straight to Anki, and review only the words you actually met.

Every scenario shares the same dictionaries, statistics, and review workflow. It works for any language (Japanese, English, …), and is especially suited to immersion learners who believe in **heavy input + only self-made cards**. Available for Android and Windows (iOS and macOS planned).

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Bookshelf" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Video Library" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Desktop vertical reading with lookup popup" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Video lookup (nested popups)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Video lookup (subtitle list)" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-mobile.png" alt="Out-of-app text-selection lookup (mobile)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-desktop.png" alt="Out-of-app text-selection lookup (desktop)" width="100%"></td>
  </tr>
</table>

**One-tap Anki mining demo**

<video src="https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4" controls muted width="100%"></video>

</div>

## Features

### Bookshelf

- Import EPUBs individually, in bulk, or recursively by folder; view reading progress on the shelf.
- Organize books with custom bookshelves, tag filtering, and drag-to-reorder.
- Drag-and-drop files to import books, subtitles, or videos (desktop).
- Automatically associate same-name subtitle / audio files on import.

### Reading

- Read in vertical or horizontal layout; switch between paginated and continuous-scroll modes.
- Customize themes (light / dark / pure black / custom), fonts, paragraph spacing, and reader controls.
- Furigana (ふりがな) annotations.
- Adjustable UI scale; bottom bar controls follow the scale.
- Multi-user profiles (Profile), auto-switched per book.

### Lookup

- Import [Yomitan](https://github.com/yomidevs/yomitan) (formerly Yomichan), ABBYY Lingvo (DSL), MDict (MDX), and Migaku dictionaries.
- Tap text in the reader to look up words, search on the dictionary page, or share text from other apps.
- Deinflection covering **all Yomitan transformation languages** + pre-lookup text normalization (case / diacritics / Arabic harakat), driven by code points with no language switching.
- Tap words inside definitions for recursive lookup (nested popups).
- Parallel multi-dictionary queries, sub-source priority and toggling, pitch-accent and frequency annotations.
- Online and local word audio.
- Inject custom CSS.

### Highlights & Statistics

- Add five-color highlights while reading; jump to any highlight at any time.
- Reading statistics: characters read, duration, reading speed — displayed in real time while reading.
- Video statistics: watch time, cards created, and favorites.

### Anki Card Creation

- Create cards via [AnkiDroid](https://github.com/ankidroid/Anki-Android) or AnkiConnect.
- Built-in [Lapis](https://github.com/donkuri/lapis) note type (vendored 1.7.0); create card templates and decks inside the app with one tap.
- Auto-fill context sentences; audio recording and screenshot cropping.
- Multiple export profiles (Profile) and custom field mapping.
- Favorite words; cards created and favorites are counted in statistics.

### Audiobook Sync (Sasayaki)

- SRT / LRC / VTT / ASS subtitle support; automatically aligns subtitle text to the EPUB body.
- Follow-along sentence highlighting and auto page-turning during playback.
- Playback speed, seek actions, and system media controls.
- "Play from this sentence" with seamless cross-chapter continuation.

### Video Subtitle Lookup

- Built-in video player based on [media_kit](https://github.com/media-kit/media-kit) (libmpv core).
- Embedded (text + graphic tracks) and external subtitles; .m3u8 playlist import.
- Look up words and create cards directly from subtitles during playback.
- Video library management, tag filtering, series grouping, and batch operations.

### Data Sync

- Seven sync backends: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP, and Hibiki P2P.
- Sync reading progress, statistics, and books.

### More

- **17 interface languages**, fully localized across all platforms.
- Share text from other apps to look up words directly.

## Platform Support

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |
| iOS | Planned | Cupertino |
| macOS | Planned | Material |

> Minimum Android 7.0 (API 24). The languages available for dictionary lookup are determined by the imported dictionaries and Yomitan transformation tables, independently of the interface language.

### Interface Languages (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation

Download the latest release from [GitHub Releases](https://github.com/hajisensai/hibiki/releases) — Android APK and Windows installer are available.

> Requires Android 7.0 (API 24) or higher.

## Building

One-command prep (`flutter pub get` + apply patches), then build:

```bash
# From the repository root
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` collapse `flutter pub get` and `ci/apply-patches.sh` into a single command. This project is locked to Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); some upstream dependencies are vendored under `third_party/` or patched by `ci/apply-patches.sh` — see [docs/agent/build.md](../agent/build.md) for details.

<details>
<summary><b>Tech Stack</b></summary>

| Layer | Technology |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platforms | Android / Windows (Material Design 3) |
| Reader | WebView paging engine (derived from the Hoshi Reader family) |
| Video | media_kit (libmpv core) |
| Storage | Drift (SQLite, WAL) + hoshidicts (C++ FFI dictionary engine) |
| NLP | Yomitan transformation tables (multilingual lemmatization) + kana_kit (kana conversion); tokenization via hoshidicts FFI |
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
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## Privacy & Data

hibiki stores imported books, dictionaries, fonts, audiobook data, videos, reading progress, highlights, statistics, and settings in the app's local storage.

Cloud sync (Google Drive / OneDrive / Dropbox) uses user-configured OAuth credentials; WebDAV / FTP / SFTP uses user-provided server addresses and credentials; Hibiki P2P connects directly via a user-configured address. Anki card creation communicates with AnkiDroid or a configured AnkiConnect address.

## Acknowledgments

hibiki builds on the following projects and ecosystem:

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

## License

Distributed under the GNU General Public License v3.0. See [LICENSE](../../LICENSE) for details.

<div align="center">

<br>

[简体中文](../../README.md) | **English** | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
