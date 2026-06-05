<h3 align="center">hibiki</h3>
<p align="center">
  <img src="docs/static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">多平台 · 多语言沉浸式阅读器</p>
<p align="center">EPUB 阅读 · 划词查词 · Anki 制卡 · 有声书同步</p>

<p align="center">
  <a href="docs/readme/README.en.md">English</a> · <a href="docs/readme/README.ja.md">日本語</a> · <a href="docs/readme/README.ko.md">한국어</a> · <a href="docs/readme/README.es.md">Español</a> · <a href="docs/readme/README.fr.md">Français</a> · <a href="docs/readme/README.de.md">Deutsch</a> · <a href="docs/readme/README.pt-BR.md">Português</a> · <a href="docs/readme/README.ru.md">Русский</a> · <a href="docs/readme/README.it.md">Italiano</a> · <a href="docs/readme/README.nl.md">Nederlands</a> · <a href="docs/readme/README.tr.md">Türkçe</a> · <a href="docs/readme/README.vi.md">Tiếng Việt</a> · <a href="docs/readme/README.th.md">ภาษาไทย</a> · <a href="docs/readme/README.id.md">Bahasa Indonesia</a> · <a href="docs/readme/README.ar.md">العربية</a> · <a href="docs/readme/README.zh-Hant.md">繁體中文</a>
</p>

---

## 简介

**hibiki** 是一款多平台沉浸式阅读应用：在 EPUB 正文里点按即查词、选词即分析，并把生词一键做成 Anki 卡片。它以日语沉浸式学习起家，词典查询现已覆盖 [Yomitan](https://github.com/yomidevs/yomitan) 的全部变换语言（去屈折 + 查词前文本归一化），界面本地化为 17 种语言。

## 截图

<p align="center">
  <img src="docs/static-assets/screenshots/hibiki-readme-home.png" alt="书架" width="240">
  &nbsp;
  <img src="docs/static-assets/screenshots/hibiki-readme-dictionaries.png" alt="词典管理" width="240">
  &nbsp;
  <img src="docs/static-assets/screenshots/hibiki-readme-settings.png" alt="设置与主题" width="240">
</p>
<p align="center"><sub>书架 · 词典管理 · 设置与主题</sub></p>

## 功能

### EPUB 阅读
- WebView 渲染 EPUB（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 衍生的分页引擎）
- 点按即查词，选词即分析
- 连续滚动 / 分页两种模式
- 自定义字体、主题（明 / 暗 / 纯黑 / 自定义）
- 阅读统计与书签

### 词典
- 导入多种格式词典：**Yomitan**（原 Yomichan）/ **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **StarDict** / **Migaku**
- 多语言词形还原（Yomitan 变换表）+ 查词前文本归一化（大小写 / 变音符 / 阿拉伯 harakat），按码点驱动、无需切换语言
- 音调标注与词频信息
- 多词典并行查询、子来源优先级与启停、搜索历史

### Anki 制卡
- 一键导出至 [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- 内置 [Lapis](https://github.com/donkuri/lapis) 笔记类型 schema（vendored 1.7.0），可在 App 内直接创建对应卡片模板与牌组
- 自动填充上下文句子，支持录音、截图裁剪
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
- 设备间同步（书籍 / 词典 / 有声书 / 阅读进度）

## 支持语言

界面本地化为以下 17 种语言：

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

> 词典查词的语言由导入的词典与 Yomitan 变换表决定，与界面语言相互独立。

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.41.6（Dart SDK `>=3.5.0 <4.0.0`） |
| 平台 | Android / Windows（iOS / macOS / Linux 后续支持；Material 3 + Cupertino 自适应） |
| 阅读器 | WebView 分页引擎（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 衍生） |
| 存储 | Drift（SQLite，WAL）+ hoshidicts（C++ FFI 词典引擎） |
| NLP | Ve（日语分词）/ Yomitan 变换表（多语言词形还原） |
| 制卡 | AnkiDroid API |
| 国际化 | Slang（17 种语言） |
| 最低版本 | Android 7.0（API 24） |

## 构建

一键准备（`flutter pub get` + 打补丁），然后构建：

```bash
# 在仓库根目录
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把两件事收敛成一条命令：①`flutter pub get`；②运行
`ci/apply-patches.sh`。`melos bootstrap` 经 post hook 做同样的事（Windows 上
melos 有 CJK 编码 bug，改用 `tool/bootstrap.ps1`）。

> **补丁说明：** `ci/apply-patches.sh` 会将 `ci/patches/` 下的修改覆盖到实际 pub cache。每次清除 pub cache 或重新 `flutter pub get` 后必须重新执行（bootstrap 已包含这步）。脚本找不到任何补丁目标时会跳过并警告，而不是假装成功。

## 依赖与补丁

本项目锁定 Flutter 3.41.6，部分上游依赖尚未适配。修补分两条路：① 需作为构建输入、跨机一致复现的包直接 vendor 到 `third_party/` 并用 `dependency_overrides` 指向（`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`，**无需**打 pub-cache 补丁）；② 其余包由 `ci/apply-patches.sh` 修补 pub cache 源码。机制细节见 [docs/agent/build.md](docs/agent/build.md)。下方折叠表是按改动归类的历史清单，与机制 ① 重叠的包以 vendored 版本为准。

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
| `android/build.gradle` afterEvaluate | 子项目强制 `compileSdk`（默认 36，个别 34）；移除 `-Werror` |
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
hibiki/                      # 仓库根（Melos workspace: hibiki_workspace）
├── hibiki/                  # Flutter 应用主目录
│   ├── lib/
│   │   ├── i18n/            # 国际化（17 种语言，Slang）
│   │   ├── src/
│   │   │   ├── pages/       # 页面（书架、阅读器、词典、设置等）
│   │   │   ├── reader/      # 阅读器 WebView JS/CSS 脚本
│   │   │   ├── media/       # 有声书、字幕解析、reader source
│   │   │   └── models/      # 数据模型与状态管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android 工程（manifest、native hoshidicts）
├── packages/                # 内部 package + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ 词典引擎（FFI）
├── third_party/             # vendored 补丁包（dependency_overrides 指向）
├── ci/                      # 构建补丁与集成测试脚本
├── tool/                    # bootstrap / i18n_sync 等脚本
└── docs/                    # 开发文档（含 docs/agent/ agent 操作手册）
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
| [Yomitan](https://github.com/yomidevs/yomitan) | 词典格式与变换表来源 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 笔记类型 |

## 许可证

[GNU General Public License v3.0](LICENSE)
