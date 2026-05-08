<h3 align="center">hibiki</h3>
<p align="center">
  <img src="docs/static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Android 日语沉浸式阅读器</p>
<p align="center">EPUB · 词典 · Anki · 有声书同步</p>

<p align="center">
  <a href="docs/readme/README.en.md">English</a> · <a href="docs/readme/README.ja.md">日本語</a> · <a href="docs/readme/README.ko.md">한국어</a> · <a href="docs/readme/README.es.md">Español</a> · <a href="docs/readme/README.fr.md">Français</a> · <a href="docs/readme/README.de.md">Deutsch</a> · <a href="docs/readme/README.pt-BR.md">Português</a> · <a href="docs/readme/README.ru.md">Русский</a> · <a href="docs/readme/README.it.md">Italiano</a> · <a href="docs/readme/README.nl.md">Nederlands</a> · <a href="docs/readme/README.tr.md">Türkçe</a> · <a href="docs/readme/README.vi.md">Tiếng Việt</a> · <a href="docs/readme/README.th.md">ภาษาไทย</a> · <a href="docs/readme/README.id.md">Bahasa Indonesia</a> · <a href="docs/readme/README.ar.md">العربية</a> · <a href="docs/readme/README.zh-Hant.md">繁體中文</a>
</p>

---

## 简介

**hibiki** 是一款面向日语学习者的 Android 阅读应用。

## 功能

### EPUB 阅读
- 内嵌 [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) 渲染 EPUB（WebView）
- 点按即查词，选词即分析
- 自定义字体、主题（明/暗）
- 阅读统计与书签
- 连续滚动 / 分页两种模式

### 词典
- 导入 [Yomitan](https://github.com/yomidevs/yomitan) 格式词典（原 Yomichan）
- 支持音调标注与词频信息
- 多词典并行查询、搜索历史
- Ve 词形还原

### Anki 制卡
- 一键导出至 [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- 自动填充上下文句子
- 支持录音、截图裁剪
- 多导出配置（Profile）、自定义字段映射
- 快速操作（Quick Actions）一步制卡

### 有声书同步（Sasayaki）
- 字幕格式：SRT / LRC / VTT / ASS
- 字幕文本自动对齐 EPUB 正文
- 跟读高亮，音频同步翻页
- 播放控制栏（进度、跳转、倍速）

### 其他
- 17 种界面语言
- 多用户配置（Profile）
- 无痕模式
- 从其他应用分享文本直接查词

## 支持语言

界面支持以下语言：

| 语言 | 代码 |
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

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.41.6 / Dart 3.11.4 |
| 阅读器 | ttu Ebook Reader（WebView，[fork](https://github.com/hdjsadgfwtg/ttu-fork)） |
| 存储 | Isar + Drift (SQLite) + hoshidicts (C++ FFI 词典引擎) |
| NLP | Ve（词形还原） |
| 制卡 | AnkiDroid API |
| 国际化 | Slang |
| 最低版本 | Android 8.0（API 26） |

## 构建

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **首次构建前需打 pub cache 补丁。** 若 pub cache 被清除或重新 `pub get`，所有补丁需重新应用。详见下方[依赖与补丁](#依赖与补丁)。

## 依赖与补丁

本项目锁定 Flutter 3.41.6，部分上游依赖尚未适配，需手动修补 pub cache 中的源码。

<details>
<summary><b>Flutter API 变更补丁</b></summary>

| 包 | 改动 |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`；`DecoderCallback` → `ImageDecoderCallback`；`hashValues` → `Object.hash`；`instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`；替换已移除的 `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | 同上 `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`；`subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | 内部 import 加 `hide CarouselController` 避免命名冲突 |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable 修复 |

</details>

<details>
<summary><b>v1 Embedding 移除补丁</b></summary>

Flutter 3.41.6 完全移除了 v1 embedding API（`PluginRegistry.Registrar`），以下插件需删除相关引用：

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin 补丁</b></summary>

| 目标 | 改动 |
|---|---|
| `android/build.gradle` afterEvaluate | 子项目强制 `compileSdkVersion 34`；移除 `-Werror` |
| `audio_session` 0.1.14 | 移除 `-Werror`、`-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null 安全修复 |
| `receive_intent` (git) | Kotlin null 安全修复 |

</details>

<details>
<summary><b>Git 依赖</b></summary>

| 包 | 来源 |
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

## 项目结构

```
hibiki/
├── hibiki/                  # Flutter 应用主目录
│   ├── lib/
│   │   ├── i18n/            # 国际化（17 种语言）
│   │   ├── src/
│   │   │   ├── pages/       # 页面（书架、阅读器、词典、设置等）
│   │   │   ├── media/       # 有声书桥接、字幕解析
│   │   │   ├── dictionary/  # 词典查询引擎
│   │   │   ├── models/      # 数据模型与状态管理
│   │   │   └── language/    # 语言抽象层
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # ttu fork 构建产物
│   └── android/
│       └── app/src/main/cpp/ # hoshidicts C++ 词典引擎
├── docs/                    # 开发文档
└── chisa/                   # jidoujisho 早期版本参考
```

## 致谢

| 项目 | 说明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日语沉浸式学习工具 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 日语阅读器 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 词典引擎 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日语阅读器 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 有声书同步方案 |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB 渲染引擎 |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu 社区维护版（SvelteKit v2），hibiki fork 的上游基准 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 词典格式来源 |

## 许可证

[GNU General Public License v3.0](LICENSE)

