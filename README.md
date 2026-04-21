<h3 align="center">hibiki</h3>
<p align="center">Android 日语沉浸式阅读器 — EPUB + 词典 + Anki + 有声书同步</p>

---

# 概述

**hibiki** 是一款面向日语学习者的 Android 阅读应用，目标对标 iOS [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)。

核心功能：
- 📖 内嵌 ッツ Ebook Reader 渲染 EPUB，点按即查词
- 📘 Yomitan 格式词典，支持音调与词频信息
- 🃏 一键导出 AnkiDroid 制卡（含上下文句子与音频）
- 🎧 有声书同步（Sasayaki）：SMIL / SRT / LRC / VTT / ASS 字幕 → EPUB 文本对齐 → 跟读高亮

# 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.41.6 / Dart 3.11.4 |
| 阅读器 | ッツ Ebook Reader（WebView，[独立 fork](https://github.com/hdjsadgfwtg/ttu-fork)） |
| 存储 | Isar + Hive |
| NLP | MeCab + Ve（分词 / deinflection）（预计修改） |
| 制卡 | AnkiDroid API |
| 最低版本 | Android 8.0（API 26） |

# 构建

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --debug
```

> **首次构建前需打 pub cache 补丁**，若 pub cache 被清除或重新 `pub get`，所有补丁需重新应用。

### Flutter API 变更补丁

| 包 | 改动 |
|---|---|
| `network_to_file_image-4.0.1` | `load`→`loadImage`、`DecoderCallback`→`ImageDecoderCallback`、`hashValues`→`Object.hash`、`instantiateImageCodec`→`ImmutableBuffer+ImageDescriptor`；替换已移除的 `imageCache.putIfAbsent` |
| `flutter_blurhash-0.7.0` | 同上 `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride`→`boldTextOf` |
| `material_floating_search_bar` (git) | `headline6`→`titleLarge`、`subtitle1`→`titleMedium` |
| `win32-4.1.4` | `UnmodifiableUint8ListView`→`Uint8List` |
| `carousel_slider-4.2.1` | 内部 import 加 `hide CarouselController` |
| `fading_edge_scrollview-3.0.0` | `PageView.controller` nullable 修复 |

### v1 Embedding 移除补丁

Flutter 3.41.6 完全移除了 v1 embedding API（`PluginRegistry.Registrar`），以下插件需删除相关引用：

| 包 | 备注 |
|---|---|
| `flutter_plugin_android_lifecycle-2.0.15` | |
| `file_picker-5.3.0` | |
| `flutter_inappwebview` (git) | 还需移除 FlutterView 字段，修改 Util / InAppWebViewChromeClient / FlutterWebView |
| `fluttertoast-8.2.1` | |
| `image_picker_android-0.8.6+16` | |
| `mecab_dart-0.1.3` | |
| `permission_handler_android-10.2.1` | |
| `url_launcher_android-6.0.34` | |
| `path_provider_android-2.0.27` | |
| `sqflite-2.2.8+4` | |
| `record_mp3_plus-1.2.0` | |

### Gradle / Kotlin 补丁

| 目标 | 改动 |
|---|---|
| `android/build.gradle` afterEvaluate | 子项目强制 `compileSdkVersion 34`（解决 `lStar not found`）；移除 `-Werror` |
| `audio_session-0.1.14` build.gradle | 移除自带的 `-Werror`、`-Xlint:deprecation` |
| `package_info_plus-4.0.2` | Kotlin null 安全：`applicationInfo?.loadLabel`、`versionName ?: ""` |
| `receive_intent` (git) | Kotlin null 安全：`signingInfo` null check、`?: emptyArray()` |

# 项目结构

```
hibiki/
├── hibiki/            # Flutter app 主目录
│   ├── lib/src/
│   │   ├── pages/     # 页面（书架、阅读器等）
│   │   ├── media/     # 有声书桥接、字幕解析
│   │   └── dictionary/# 词典查询
│   └── assets/
│       └── ttu-ebook-reader/  # ttu fork 构建产物
├── legacy/            # 遗留参考代码
├── docs/              # 开发文档
└── CLAUDE.md          # 详细开发指南
```

# 致谢

| 项目 | 说明 | 链接 |
|---|---|---|
| jidoujisho | 本项目基于 jidoujisho 重构而来 | [arianneorpilla/jidoujisho](https://github.com/arianneorpilla/jidoujisho) |
| Hoshi Reader | iOS 端日语阅读器，hibiki 的对标目标 | [Manhhao/Hoshi-Reader](https://github.com/Manhhao/Hoshi-Reader) |
| Sasayaki | Hoshi Reader 的有声书同步方案，hibiki 的音频同步参考 | [Sasayaki 文档](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) |
| ッツ Ebook Reader | EPUB 渲染引擎（WebView） | [ttu-ebook-reader](https://github.com/ttu-ttu/ebook-reader) |

# 许可

GNU General Public License 3.0
