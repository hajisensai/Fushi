<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Android 日語沉浸式閱讀器</p>
<p align="center">EPUB · 詞典 · Anki · 有聲書同步</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <b>繁體中文</b>
</p>

---

## 簡介

**hibiki** 是一款面向日語學習者的 Android 閱讀應用。

## 功能

### EPUB 閱讀
- WebView 渲染 EPUB（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 衍生的分頁引擎）
- 點按即查詞，選取即分析
- 自訂字型、主題（明/暗）
- 閱讀統計與書籤
- 連續捲動 / 分頁兩種模式

### 詞典
- 匯入 [Yomitan](https://github.com/yomidevs/yomitan) 格式詞典（原 Yomichan）
- 支援音調標注與詞頻資訊
- 多詞典並行查詢、搜尋歷史
- Ve 詞形還原

### Anki 製卡
- 一鍵匯出至 [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- 自動填充上下文句子
- 支援錄音、截圖裁剪
- 多匯出設定檔（Profile）、自訂欄位對映
- 快速操作（Quick Actions）一步製卡

### 有聲書同步（Sasayaki）
- 字幕格式：SRT / LRC / VTT / ASS
- 字幕文字自動對齊 EPUB 正文
- 跟讀高亮，音訊同步翻頁
- 播放控制列（進度、跳轉、倍速）

### 其他
- 17 種介面語言
- 多使用者設定檔（Profile）
- 無痕模式
- 從其他應用程式分享文字直接查詞

## 支援語言

介面支援以下語言：

| 語言 | 代碼 |
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

## 技術棧

| 層 | 技術 |
|---|---|
| 框架 | Flutter 3.41.6（Dart SDK `>=3.5.0 <4.0.0`） |
| 平台 | Android / iOS / macOS / Windows / Linux（Material 3 + Cupertino 自適應） |
| 閱讀器 | WebView 分頁引擎（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 衍生） |
| 儲存 | Drift (SQLite，WAL) + hoshidicts（C++ FFI 詞典引擎） |
| NLP | Ve（詞形還原） |
| 製卡 | AnkiDroid API |
| 國際化 | Slang（17 種語言） |
| 最低版本 | Android 7.0（API 24） |

## 建置

一鍵準備（`flutter pub get` + 打補丁），然後建置：

```bash
# 在倉庫根目錄
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把兩件事收斂成一條命令：①`flutter pub get`；②執行 `ci/apply-patches.sh`。`melos bootstrap` 經 post hook 做同樣的事（Windows 上 melos 有 CJK 編碼 bug，改用 `tool/bootstrap.ps1`）。

> **補丁說明：** `ci/apply-patches.sh` 會將 `ci/patches/` 下的修改覆蓋到實際 pub cache。每次清除 pub cache 或重新 `flutter pub get` 後必須重新執行（bootstrap 已包含這步）。腳本找不到任何補丁目標時會跳過並警告，而不是假裝成功。

## 依賴與補丁

本專案鎖定 Flutter 3.41.6，部分上游依賴尚未適配。修補分兩條路：① 需作為建置輸入、跨機一致重現的套件直接 vendor 到 `third_party/` 並用 `dependency_overrides` 指向（`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`，**無需**打 pub-cache 補丁）；② 其餘套件由 `ci/apply-patches.sh` 修補 pub cache 原始碼。機制細節見 [docs/agent/build.md](../agent/build.md)。下方折疊表是按改動歸類的歷史清單，與機制 ① 重疊的套件以 vendored 版本為準。

<details>
<summary><b>Flutter API 變更補丁</b></summary>

| 套件 | 改動 |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`；`DecoderCallback` → `ImageDecoderCallback`；`hashValues` → `Object.hash`；`instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`；替換已移除的 `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | 同上 `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`；`subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | 內部 import 加 `hide CarouselController` 避免命名衝突 |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable 修復 |

</details>

<details>
<summary><b>v1 Embedding 移除補丁</b></summary>

Flutter 3.41.6 完全移除了 v1 embedding API（`PluginRegistry.Registrar`），以下外掛需刪除相關引用：

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin 補丁</b></summary>

| 目標 | 改動 |
|---|---|
| `android/build.gradle` afterEvaluate | 子專案強制 `compileSdk`（預設 36，個別 34）；移除 `-Werror` |
| `audio_session` 0.1.14 | 移除 `-Werror`、`-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null 安全修復 |
| `receive_intent` (git) | Kotlin null 安全修復 |

</details>

<details>
<summary><b>Git 依賴</b></summary>

| 套件 | 來源 |
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

## 專案結構

```
hibiki/                      # 倉庫根（Melos workspace: hibiki_workspace）
├── hibiki/                  # Flutter 應用程式主目錄
│   ├── lib/
│   │   ├── i18n/            # 國際化（17 種語言，Slang）
│   │   ├── src/
│   │   │   ├── pages/       # 頁面（書架、閱讀器、詞典、設定等）
│   │   │   ├── reader/      # 閱讀器 WebView JS/CSS 腳本
│   │   │   ├── media/       # 有聲書、字幕解析、reader source
│   │   │   └── models/      # 資料模型與狀態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android 工程（manifest、native hoshidicts）
├── packages/                # 內部 package + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # vendored 補丁套件（dependency_overrides 指向）
├── ci/                      # 建置補丁與整合測試腳本
├── tool/                    # bootstrap / i18n_sync 等腳本
└── docs/                    # 開發文件（含 docs/agent/ agent 操作手冊）
```

## 致謝

| 專案 | 說明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日語沉浸式學習工具 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 日語閱讀器 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 詞典引擎 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日語閱讀器 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 有聲書同步方案 |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB 渲染引擎 |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu 社群維護版（SvelteKit v2），hibiki fork 的上游基準 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 詞典格式來源 |

## 授權條款

[GNU General Public License v3.0](../../LICENSE)
