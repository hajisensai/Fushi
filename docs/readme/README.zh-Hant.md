<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>讀一本書，把每個生詞都變成你的。</b></p>
<p align="center">多平台 · 多語言沉浸式閱讀器 —— EPUB 閱讀 · 劃詞查詞 · Anki 製卡 · 有聲書同步 · 影片字幕查詞</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 專案首頁 (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <b>繁體中文</b>
</p>

---

## 簡介

**hibiki** 是一款多平台沉浸式語言學習閱讀器。在 EPUB 正文裡**點按即查詞、選詞即分析**，把生詞一鍵做成 Anki 卡片；讓有聲書音訊與正文逐句同步高亮；甚至在影片字幕裡直接查詞製卡。一套工具，涵蓋你「讀 · 聽 · 看」三種沉浸式輸入。

詞典查詢涵蓋 [Yomitan](https://github.com/yomidevs/yomitan) 的**全部變換語言**（去屈折 + 查詞前文字正規化），介面在地化為 **17 種語言**，並支援 **Android / iOS / macOS / Windows / Linux** 五端。

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="書架" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="查詞" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="設定與主題" width="300">
</p>
<p align="center"><sub>書架 · 查詞 · 設定與主題</sub></p>

---

## 核心亮點

### 📖 EPUB 閱讀，點按即查

WebView 渲染的 EPUB 閱讀器（基於 [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 衍生的分頁引擎），點按任意詞即時查詞、選區即時分析。連續捲動與分頁雙模式，自訂字型與主題（明 / 暗 / 純黑 / 自訂），振假名、閱讀統計與書籤一應俱全。

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="直排閱讀 · 振假名 · 有聲書同步" width="300">
</p>
<p align="center"><sub>直排正文 · 振假名 · 劃詞高亮 · 底部有聲書同步控制列</sub></p>

### 🔍 劃詞查詞，涵蓋 Yomitan 全部變換語言

匯入 **Yomitan**（原 Yomichan）/ **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku** 多種格式詞典。多語言詞形還原（Yomitan 變換表）+ 查詞前文字正規化（大小寫 / 變音符 / 阿拉伯 harakat），按碼點驅動、無需切換語言。多詞典並行查詢、子來源優先級與啟停、音調標注與詞頻，皆在一個彈窗裡搞定。

### 🎴 一鍵 Anki 製卡

查到生詞，一步匯出至 [AnkiDroid](https://github.com/ankidroid/Anki-Android) 與 AnkiConnect。內建 [Lapis](https://github.com/donkuri/lapis) 筆記類型 schema（vendored 1.7.0），可在 App 內直接建立卡片範本與牌組；自動填充上下文句子，支援錄音與截圖裁剪、多匯出設定檔（Profile）、自訂欄位對映，以及快速操作一步製卡。

### 🎧 有聲書同步（Sasayaki）

支援 SRT / LRC / VTT / ASS 字幕，自動將字幕文字對齊到 EPUB 正文。播放時**跟讀高亮、音訊同步翻頁**，搭配播放控制列（進度、跳轉、倍速），聽書時正文逐句點亮——本頁頂部那張閱讀截圖底部的控制列即為此功能。

### 🎬 影片字幕查詞

內建基於 media_kit / libmpv 的影片播放器，支援內嵌 / 外掛字幕。播放影片時**直接在字幕上查詞、製卡**，把影視素材也納入沉浸式輸入；同時統計觀看時長與製卡數量。

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 影片播放器截圖待補 —— 需在真機/前台採集（影片畫面 + 字幕列 + 查詞彈窗，詳見下方說明）。</sub></p>

### 🔗 更多

- **17 種介面語言**，全平台在地化
- **Hibiki 互聯**：裝置間同步書籍 / 詞典 / 有聲書 / 閱讀進度
- **多使用者設定檔（Profile）**，按書自動切換
- **無痕模式**；從其他應用程式**分享文字直接查詞**

---

## 平台支援

| 平台 | 狀態 | 渲染 / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material（fork 的 `flutter_inappwebview_windows` 渲染 EPUB） |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> 最低 Android 7.0（API 24）。詞典查詞的語言由匯入的詞典與 Yomitan 變換表決定，與介面語言相互獨立。

### 介面語言（17 種）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## 安裝與建置

一鍵準備（`flutter pub get` + 打補丁），然後建置：

```bash
# 在倉庫根目錄
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把 ①`flutter pub get` 與 ②`ci/apply-patches.sh` 收斂成一條命令。本專案鎖定 Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`），部分上游依賴經 vendored 到 `third_party/` 或由 `ci/apply-patches.sh` 修補——機制細節、五平台建置、依賴與補丁清單見 [docs/agent/build.md](../agent/build.md)。

<details>
<summary><b>技術棧一覽</b></summary>

| 層 | 技術 |
|---|---|
| 框架 | Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`） |
| 平台 | Android / iOS / macOS / Windows / Linux（Material 3 + Cupertino 自適應） |
| 閱讀器 | WebView 分頁引擎（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 衍生） |
| 影片 | media_kit / libmpv |
| 儲存 | Drift（SQLite，WAL）+ hoshidicts（C++ FFI 詞典引擎） |
| NLP | Yomitan 變換表（多語言詞形還原）+ kana_kit（假名轉換）；分詞走 hoshidicts FFI |
| 製卡 | AnkiDroid API + AnkiConnect |
| 國際化 | Slang（17 種語言） |

</details>

<details>
<summary><b>專案結構</b></summary>

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
├── native/                  # hoshidicts C++ 詞典引擎（FFI）
├── third_party/             # vendored 補丁套件（dependency_overrides 指向）
├── ci/                      # 建置補丁與整合測試腳本
├── tool/                    # bootstrap / i18n_sync 等腳本
└── docs/                    # 開發文件（含 docs/agent/ agent 操作手冊）
```

</details>

---

## 致謝

| 專案 | 說明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日語沉浸式學習工具 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 日語閱讀器 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 詞典引擎 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日語閱讀器 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 有聲書同步方案 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 詞典格式與變換表來源 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 筆記類型 |

## 授權條款

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <b>繁體中文</b>
</p>
