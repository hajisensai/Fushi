<div align="center">

# hibiki

<img src="docs/static-assets/hibiki-logo.png" alt="hibiki logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[English](docs/readme/README.en.md) | **简体中文** | [繁體中文](docs/readme/README.zh-Hant.md) | [日本語](docs/readme/README.ja.md) | [한국어](docs/readme/README.ko.md) | [Español](docs/readme/README.es.md) | [Français](docs/readme/README.fr.md) | [Deutsch](docs/readme/README.de.md) | [Português](docs/readme/README.pt-BR.md) | [Русский](docs/readme/README.ru.md) | [Tiếng Việt](docs/readme/README.vi.md) | [ภาษาไทย](docs/readme/README.th.md) | [Bahasa Indonesia](docs/readme/README.id.md) | [Italiano](docs/readme/README.it.md) | [Nederlands](docs/readme/README.nl.md) | [Türkçe](docs/readme/README.tr.md) | [العربية](docs/readme/README.ar.md)

hibiki 是一款多语言沉浸式语言学习工具，把读 EPUB、听有声书、看视频三种输入收进一套查词、制卡与统计流程。

<table>
  <tr>
    <td><img src="docs/static-assets/screenshots/hibiki-readme-bookshelf-zh.png" alt="书架（中文）" width="100%"></td>
    <td><img src="docs/static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="书架（English）" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="桌面竖排阅读 · 划词查词弹窗" width="100%"></td>
  </tr>
  <tr>
    <td><img src="docs/static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="视频查词（嵌套弹窗）" width="100%"></td>
    <td><img src="docs/static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="视频查词（字幕列表）" width="100%"></td>
  </tr>
  <tr>
    <td><img src="docs/static-assets/screenshots/hibiki-readme-video-library-zh.png" alt="视频库（中文）" width="100%"></td>
    <td><img src="docs/static-assets/screenshots/hibiki-readme-video-library-en.png" alt="视频库（English）" width="100%"></td>
  </tr>
</table>

</div>

## 功能

### 书架

- 单本、批量或按文件夹递归导入 EPUB，并在书架查看阅读进度。
- 使用自定义书架整理书籍，支持标签筛选与拖拽排序。
- 拖放文件即可导入书籍、字幕或视频（桌面端）。
- 导入时自动关联同名字幕 / 音频文件。

### 阅读

- 以竖排（縦書き）或横排（横書き）阅读日文书籍，并在分页和连续滚动之间切换。
- 自定义主题（明 / 暗 / 纯黑 / 自定义）、字体、段落间距和阅读器控件。
- 振假名（ふりがな）标注，阅读器内全屏查看图片。
- 界面大小可调，底栏控件跟随缩放。
- 多用户配置（Profile），按书自动切换；无痕模式。

### 查词

- 导入 [Yomitan](https://github.com/yomidevs/yomitan)（原 Yomichan）、ABBYY Lingvo (DSL)、MDict (MDX)、Migaku 多种格式词典。
- 阅读器中点按文本查词，词典页搜索，或从其他 App 分享文本查词。
- 覆盖 Yomitan **全部变换语言**的词形还原（去屈折）+ 查词前文本归一化（大小写 / 变音符 / 阿拉伯 harakat），按码点驱动、无需切换语言。
- 点击释义中的生词进行递归查询（嵌套弹窗）。
- 多词典并行查询、子来源优先级与启停、音调标注与词频。
- 使用在线或本地单词音频。
- 注入自定义 CSS 样式。

### 标注与统计

- 阅读时添加五色高亮标注，并随时跳转。
- 阅读数据统计：字符数、时长、阅读速度，可在阅读时实时显示。
- 视频统计：观看时长、制卡与收藏数量。

### Anki 制卡

- 通过 [AnkiDroid](https://github.com/ankidroid/Anki-Android) 或 AnkiConnect 制卡。
- 内置 [Lapis](https://github.com/donkuri/lapis) 笔记类型（vendored 1.7.0），可在 App 内一键创建卡片模板与牌组。
- 自动填充上下文句子，支持录音与截图裁剪。
- 多导出配置（Profile）、自定义字段映射。
- 收藏生词，制卡与收藏计入统计。

### 有声书跟读（Sasayaki）

- 支持 SRT / LRC / VTT / ASS 字幕，自动将字幕文本对齐到 EPUB 正文。
- 播放时正文逐句高亮，自动翻页。
- 控制播放速度、跳转动作和系统媒体控制。
- 「从本句播放」跨章节无缝衔接。

### 视频字幕查词

- 内置基于 [media_kit](https://github.com/media-kit/media-kit)（libmpv 内核）的视频播放器。
- 支持内嵌（文本轨 + 图形轨）和外挂字幕，.m3u8 播放列表导入。
- 播放视频时直接在字幕上查词、制卡，把影视素材也纳入沉浸式输入。
- 视频库管理、标签筛选、系列分组与批量操作。

### 数据同步

- 通过 Google Drive 同步阅读进度、统计和书籍。

### 更多

- **17 种界面语言**，全平台本地化。
- **桌面拖放导入**：直接拖入书籍、字幕、音频或视频文件。
- 从其他应用分享文本直接查词。

## 为什么选择 hibiki

- **读 · 听 · 看，一个 App：** EPUB 阅读、有声书同步、视频字幕查词、Anki 制卡在同一个 App 里完成，不需要在多个工具之间切换。
- **真正的多语言查词：** 词形还原覆盖 Yomitan 全部变换语言（不仅仅是日语），大小写 / 变音符 / 阿拉伯 harakat 归一化按码点驱动，导入对应词典即可查词，无需切换语言。
- **C++ 原生词典引擎：** 底层使用 [hoshidicts](https://github.com/Manhhao/hoshidicts) C++ FFI，词典导入与查词速度远超纯 Dart 实现。
- **视频也是输入：** 不止于 EPUB —— 视频播放器内置字幕查词与制卡，影视素材直接成为学习素材。
- **桌面与移动端统一体验：** Android 与 Windows 共用同一代码库，Material Design 3 自适应布局，宽屏 master-detail、拖放导入一应俱全。
- **释义内递归查词：** 点击词典释义里的生词即可打开嵌套查词弹窗，不需要复制文本或离开当前上下文。
- **有声书深度整合：** 字幕对齐到正文、逐句高亮、自动翻页、跨章节播放、句子音频制卡 —— 有声书不是附加功能，而是阅读体验的一部分。

## 平台支持

| 平台 | 状态 | 渲染 / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material（fork 的 `flutter_inappwebview_windows` 渲染 EPUB） |

> 最低 Android 7.0（API 24）。词典查词的语言由导入的词典与 Yomitan 变换表决定，与界面语言相互独立。

### 界面语言（17 种）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## 安装与构建

一键准备（`flutter pub get` + 打补丁），然后构建：

```bash
# 在仓库根目录
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows 桌面
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把 `flutter pub get` 与 `ci/apply-patches.sh` 收敛成一条命令。本项目锁定 Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`），部分上游依赖经 vendored 到 `third_party/` 或由 `ci/apply-patches.sh` 修补——机制细节见 [docs/agent/build.md](docs/agent/build.md)。

<details>
<summary><b>技术栈一览</b></summary>

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`） |
| 平台 | Android / Windows（Material Design 3） |
| 阅读器 | WebView 分页引擎（衍生自 Hoshi Reader 系列） |
| 视频 | media_kit（libmpv 内核） |
| 存储 | Drift（SQLite，WAL）+ hoshidicts（C++ FFI 词典引擎） |
| NLP | Yomitan 变换表（多语言词形还原）+ kana_kit（假名转换）；分词走 hoshidicts FFI |
| 制卡 | AnkiDroid API + AnkiConnect |
| 国际化 | Slang（17 种语言） |

</details>

<details>
<summary><b>项目结构</b></summary>

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

</details>

## 隐私与数据

hibiki 将导入的书籍、词典、字体、有声书数据、视频、阅读进度、高亮、统计和设置保存在 App 本地存储中。

Google Drive 同步使用由用户配置的 Google Cloud OAuth。Anki 制卡会与 AnkiDroid 或已配置的 AnkiConnect 地址通信。

## 鸣谢

hibiki 基于以下项目与生态：

| 项目 | 说明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日语沉浸式学习工具，hibiki 的前身参考 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日语阅读器，阅读器分页引擎参考 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 原生日语阅读器 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 词典引擎 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 有声书同步方案 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 词典格式、变换表与查词体验参考 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 笔记类型 |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android 制卡集成 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | 本地音频与 AnkiDroid 交互参考 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | 阅读器、统计与同步兼容性参考 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 视频播放框架（libmpv 内核） |

## 许可证

本项目基于 GNU General Public License v3.0 发布。详情见 [LICENSE](LICENSE)。

<div align="center">

<br>

[English](docs/readme/README.en.md) | **简体中文** | [繁體中文](docs/readme/README.zh-Hant.md) | [日本語](docs/readme/README.ja.md) | [한국어](docs/readme/README.ko.md) | [Español](docs/readme/README.es.md) | [Français](docs/readme/README.fr.md) | [Deutsch](docs/readme/README.de.md) | [Português](docs/readme/README.pt-BR.md) | [Русский](docs/readme/README.ru.md) | [Tiếng Việt](docs/readme/README.vi.md) | [ภาษาไทย](docs/readme/README.th.md) | [Bahasa Indonesia](docs/readme/README.id.md) | [Italiano](docs/readme/README.it.md) | [Nederlands](docs/readme/README.nl.md) | [Türkçe](docs/readme/README.tr.md) | [العربية](docs/readme/README.ar.md)

</div>
