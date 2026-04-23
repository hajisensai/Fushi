<h3 align="center">hibiki</h3>
<p align="center">Android 日语沉浸式阅读器 — EPUB + 词典 + Anki + 有声书同步</p>

---

## 概述

**hibiki** 是一款面向日语学习者的 Android 阅读应用，目标对标 iOS [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)，基于 [jidoujisho](https://github.com/arianneorpilla/jidoujisho) 重构而来。

核心功能：

- 内嵌 [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) 渲染 EPUB，点按即查词
- Yomitan 格式词典，支持音调与词频信息
- 一键导出 AnkiDroid 制卡（含上下文句子与音频）
- 有声书同步（Sasayaki）：SMIL / SRT / LRC / VTT / ASS 字幕对齐 EPUB 文本，跟读高亮

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.41.6 / Dart 3.11.4 |
| 阅读器 | ttu Ebook Reader（WebView，[独立 fork](https://github.com/hdjsadgfwtg/ttu-fork)） |
| 存储 | Drift (SQLite) |
| NLP | MeCab + Ve（分词 / 词形还原） |
| 制卡 | AnkiDroid API |
| 最低版本 | Android 8.0（API 26） |

## 构建

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --debug
```

> **首次构建前需打 pub cache 补丁**，若 pub cache 被清除或重新 `pub get`，所有补丁需重新应用。

## 依赖与补丁

本项目锁定 Flutter 3.41.6，许多上游依赖尚未适配此版本，需手动修补 pub cache 中的源码。

### Flutter API 变更补丁

| 包 | 改动 |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`；`DecoderCallback` → `ImageDecoderCallback`；`hashValues` → `Object.hash`；`instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`；替换已移除的 `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | 同上 `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`；`subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | 内部 import 加 `hide CarouselController` 避免命名冲突 |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable 修复 |

### v1 Embedding 移除补丁

Flutter 3.41.6 完全移除了 v1 embedding API（`PluginRegistry.Registrar`），以下插件需删除相关引用：

| 包 | 备注 |
|---|---|
| `flutter_plugin_android_lifecycle` 2.0.15 | |
| `file_picker` 5.3.0 | |
| `flutter_inappwebview` (git) | 还需移除 FlutterView 字段，修改 Util / InAppWebViewChromeClient / FlutterWebView |
| `fluttertoast` 8.2.1 | |
| `image_picker_android` 0.8.6+16 | |
| `mecab_dart` 0.1.3 | |
| `permission_handler_android` 10.2.1 | |
| `url_launcher_android` 6.0.34 | |
| `path_provider_android` 2.0.27 | |
| `sqflite` 2.2.8+4 | |
| `record_mp3_plus` 1.2.0 | |

### Gradle / Kotlin 补丁

| 目标 | 改动 |
|---|---|
| `android/build.gradle` afterEvaluate | 子项目强制 `compileSdkVersion 34`（解决 `lStar not found`）；移除 `-Werror` |
| `audio_session` 0.1.14 build.gradle | 移除自带的 `-Werror`、`-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null 安全：`applicationInfo?.loadLabel`、`versionName ?: ""` |
| `receive_intent` (git) | Kotlin null 安全：`signingInfo` null check、`?: emptyArray()` |

### Git 依赖

以下依赖通过 git 引用，均来自 jidoujisho 作者的 fork 或社区维护版：

| 包 | 来源 |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) (branch: jidoujisho) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) (branch: jidoujisho) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

## 项目结构

```
hibiki/
├── hibiki/            # Flutter app 主目录
│   ├── lib/src/
│   │   ├── pages/     # 页面（书架、阅读器等）
│   │   ├── media/     # 有声书桥接、字幕解析
│   │   └── dictionary/# 词典查询
│   └── assets/
│       └── ttu-ebook-reader/  # ttu fork 构建产物
├── chisa/             # jidoujisho 早期版本参考
├── legacy/            # 遗留参考代码
└── docs/              # 开发文档
```

## 致谢

| 项目 | 说明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 本项目基于 jidoujisho 重构而来，大部分代码与架构源自该项目 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 端日语阅读器，hibiki 的功能对标目标 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Hoshi Reader 的有声书同步方案，hibiki 音频同步功能的参考蓝本 |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB 渲染引擎，hibiki 通过 WebView 嵌入其 fork |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu Ebook Reader 社区维护版（SvelteKit v2），hibiki fork 的上游基准 |
| [MeCab](https://taku910.github.io/mecab/) | 日语分词引擎 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 词典格式来源（原 Yomichan 社区续作） |

## 许可

GNU General Public License 3.0

---

<details>
<summary><h2>English</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Android immersive Japanese reader — EPUB + Dictionary + Anki + Audiobook sync</p>

---

### Overview

**hibiki** is an Android reading app for Japanese learners, aiming to match the feature set of [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) on iOS. It is rebuilt from [jidoujisho](https://github.com/arianneorpilla/jidoujisho).

Key features:

- Embedded [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) for EPUB rendering with tap-to-look-up
- Yomitan-format dictionaries with pitch accent and frequency data
- One-tap AnkiDroid card export (with context sentence and audio)
- Audiobook sync (Sasayaki): SMIL / SRT / LRC / VTT / ASS subtitle alignment to EPUB text with follow-along highlighting

### Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.41.6 / Dart 3.11.4 |
| Reader | ttu Ebook Reader (WebView, [custom fork](https://github.com/hdjsadgfwtg/ttu-fork)) |
| Storage | Drift (SQLite) |
| NLP | MeCab + Ve (tokenization / deinflection) |
| Flashcards | AnkiDroid API |
| Minimum | Android 8.0 (API 26) |

### Building

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --debug
```

> **Pub cache patches are required before the first build.** If the pub cache is cleared or `pub get` is re-run, all patches must be reapplied.

### Dependencies & Patches

This project is pinned to Flutter 3.41.6. Many upstream dependencies have not been updated for this version and require manual patching of their source in the pub cache.

#### Flutter API Migration Patches

| Package | Changes |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; replace removed `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | Same `loadImage` / `hashValues` / `ImmutableBuffer` changes |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Add `hide CarouselController` to internal import to avoid naming conflict |
| `fading_edge_scrollview` 3.0.0 | Fix `PageView.controller` nullable |

#### v1 Embedding Removal Patches

Flutter 3.41.6 fully removed the v1 embedding API (`PluginRegistry.Registrar`). The following plugins need their v1 registration code deleted:

| Package | Notes |
|---|---|
| `flutter_plugin_android_lifecycle` 2.0.15 | |
| `file_picker` 5.3.0 | |
| `flutter_inappwebview` (git) | Also remove FlutterView field; modify Util / InAppWebViewChromeClient / FlutterWebView |
| `fluttertoast` 8.2.1 | |
| `image_picker_android` 0.8.6+16 | |
| `mecab_dart` 0.1.3 | |
| `permission_handler_android` 10.2.1 | |
| `url_launcher_android` 6.0.34 | |
| `path_provider_android` 2.0.27 | |
| `sqflite` 2.2.8+4 | |
| `record_mp3_plus` 1.2.0 | |

#### Gradle / Kotlin Patches

| Target | Changes |
|---|---|
| `android/build.gradle` afterEvaluate | Force `compileSdkVersion 34` on subprojects (fixes `lStar not found`); remove `-Werror` |
| `audio_session` 0.1.14 build.gradle | Remove `-Werror` and `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null safety: `applicationInfo?.loadLabel`, `versionName ?: ""` |
| `receive_intent` (git) | Kotlin null safety: `signingInfo` null check, `?: emptyArray()` |

#### Git Dependencies

The following dependencies are referenced via git, mostly from the jidoujisho author's forks:

| Package | Source |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) (branch: jidoujisho) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) (branch: jidoujisho) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

### Project Structure

```
hibiki/
├── hibiki/            # Flutter app root
│   ├── lib/src/
│   │   ├── pages/     # Screens (bookshelf, reader, etc.)
│   │   ├── media/     # Audiobook bridge, subtitle parsers
│   │   └── dictionary/# Dictionary lookup
│   └── assets/
│       └── ttu-ebook-reader/  # ttu fork build output
├── chisa/             # Early jidoujisho version reference
├── legacy/            # Legacy reference code
└── docs/              # Development docs
```

### Acknowledgements

| Project | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | hibiki is rebuilt from jidoujisho; most code and architecture originates from this project |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japanese reader that hibiki aims to match in features |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Hoshi Reader's audiobook sync system, the reference design for hibiki's audio sync |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB rendering engine, embedded via WebView fork |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Community-maintained ttu Ebook Reader (SvelteKit v2), upstream base for hibiki's fork |
| [MeCab](https://taku910.github.io/mecab/) | Japanese morphological analyzer |
| [Yomitan](https://github.com/yomidevs/yomitan) | Dictionary format source (community successor to Yomichan) |

### License

GNU General Public License 3.0

</details>
