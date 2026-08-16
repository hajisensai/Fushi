# The Fushi Setup Guide Even Yui Hirasawa Can Finish in 5 Minutes

**English** | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> The Simplified Chinese guide is hosted on Feishu (link above). The English guide is also available [on GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Introduction

**Fushi -- turn binge-reading and binge-watching into language input.**

Tap any word to look it up while you read novels, watch anime, or listen to audiobooks, and send new words to Anki together with the sentence they came from.

No preset word lists -- you only review the words you actually ran into. Works with any language.

- 📖 EPUB reading · tap-to-look-up
- 🎧 Audiobooks with sentence-by-sentence highlighting
- 🎬 Video subtitle lookup and card creation
- 🃏 One-tap Anki card creation + review statistics
- 📚 Manga reading · look words up straight off the page via OCR
- ⬇️ One-tap in-app downloads for anime and manga -- automatically added to your library, and playable while still downloading
- 🎮 Galgame voice mining (Windows) · the original voice line goes into the card along with the text

Platforms: Android / Windows / macOS / iOS (Linux can be built from source; no prebuilt packages yet)

### Project URL

https://github.com/hajisensai/Fushi

Actively developed — Your feedback will be addressed promptly. Bug reports and feature requests are welcome. If you find Fushi useful, sharing it with others or leaving a ⭐ on the repository is appreciated.

### Community

Join our Discord to ask questions, share setups, and follow development: https://discord.gg/WhjwyGmm7f

### Download

https://github.com/hajisensai/Fushi/releases/latest

Pick the file that matches your platform: **Android** -- the `arm64-v8a` APK (every phone from the last few years uses this; only older devices need `armeabi-v7a`, and emulators use `x86_64`); **Windows** -- `windows-setup.exe`; **macOS** -- `macos.zip`; **iOS** -- `ios.ipa`. **Linux** has no prebuilt package yet, so it has to be built from source.

The APKs whose names start with `bridge-` are migration bridges for **legacy Hibiki users**; you can ignore them.

## Configuration Tutorial

### 1. Import recommended dictionaries (word + pitch-accent + frequency dictionaries) and local audio (Japanese and English audio databases) (Highly recommended for beginners!!! · optional)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Cloudflare download (9.5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

In the app: Settings -> Sync & Backup -> tap **Import Backup**.

![Import backup screen](static-assets/user-guide/import-backup.png)

### 2. Download and configure Anki from the official Anki website

Anki -- named after 暗記 (あんき) -- is the world's most widely used [Spaced Repetition System (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition), and a very important tool.

Links: [Anki official site](https://apps.ankiweb.net/) · [Manual (Chinese)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Chinese)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Anki download page](static-assets/user-guide/anki-download.png)

You can give Anki any material you want to memorize, and it lets you achieve the best retention with the least study time.

Anki has [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) built in -- one of the best spaced-repetition algorithms in the world.

**BUT!!!** Anki's default algorithm is SM2, an algorithm from over 30 years ago that performs poorly. Please be sure to switch the algorithm Anki uses to **FSRS**.

#### Anki

##### Android

1. Install and open Anki.
2. Return to Fushi, go to Settings -> Card Creation.
3. Tap **Refresh Decks and Note Types** (marked "1" in the image); Fushi will request permission -- tap Allow.
4. Tap **Create Lapis Deck** (marked "2" in the image).
5. If there is no red warning or error, the setup succeeded.

![Anki Android setup](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Install and open Anki.
2. Click **Tools** in the top-left.

![Anki Tools menu on Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Paste the Anki add-on code below to install it: `2055492159`
4. Return to Fushi, go to Settings -> Card Creation.
5. Tap **Refresh decks and note types** (marked "1").
6. Tap **Create Lapis Deck** (marked "2").
7. If there is no red warning or error, the setup succeeded.

![Anki Windows setup](static-assets/user-guide/anki-windows-setup.png)

### 3. Go through the configuration options in Settings and see if there is anything you would like to adjust. (Optional)

Time to start immersing.

## Recommended Features

### Looking words up outside the app

**Android:** select a word, then tap **Translate** or **Fushi** in the selection menu.

**Windows:** select a word, then press **Ctrl+Alt+D** (the shortcut can be changed under Settings -> Shortcuts).

### Clipboard lookup

Anything you copy is looked up automatically. Two presentation modes are available -- the **floating panel** and the **transparent text window** -- both configurable under Settings -> Lookup.

### Browser lookup / streaming subtitle mining (Netflix)

Install the browser extension from the Fushi home page.

## Acknowledgements

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
