<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | **繁體中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![下載最新版本](https://img.shields.io/badge/%E2%AC%87%20%E4%B8%8B%E8%BC%89%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![加入 Discord 社群](https://img.shields.io/badge/%E5%8A%A0%E5%85%A5%20Discord%20%E7%A4%BE%E7%BE%A4-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## 平台支援

| 平台 | 狀態 | 渲染 / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> 最低 Android 7.0（API 24）。詞典查詞的語言由匯入的詞典與 Yomitan 變換表決定，與介面語言相互獨立。

### 介面語言（17 種）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## 安裝

從 [Fushi 官網](https://fushi.moe/) 下載最新版本，支援 Android APK 和 Windows 安裝包。

> 最低 Android 7.0（API 24）。

## 建置

一鍵準備（`flutter pub get` + 打補丁），然後建置：

```bash
# 在倉庫根目錄
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows 桌面
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把 `flutter pub get` 與 `ci/apply-patches.sh` 收斂成一條命令。本專案鎖定 Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`），部分上游依賴經 vendored 到 `third_party/` 或由 `ci/apply-patches.sh` 修補——機制細節見 [docs/agent/build.md](../agent/build.md)。

<details>
<summary><b>技術棧一覽</b></summary>

| 層 | 技術 |
|---|---|
| 框架 | Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`） |
| 平台 | Android / Windows / macOS / iOS（Material Design 3） |
| 閱讀器 | WebView 分頁引擎（衍生自 Hoshi Reader 系列） |
| 影片 | media_kit（libmpv 核心） |
| 儲存 | Drift（SQLite，WAL）+ fushidicts（C++ FFI 詞典引擎） |
| NLP | Yomitan 變換表（多語言詞形還原）+ kana_kit（假名轉換）；分詞走 fushidicts FFI |
| 製卡 | AnkiDroid API + AnkiConnect |
| 國際化 | Slang（17 種語言） |

</details>

<details>
<summary><b>專案結構</b></summary>

```
Fushi/                      # 倉庫根（Melos workspace: fushi_workspace）
├── fushi/                  # Flutter 應用程式主目錄
│   ├── lib/
│   │   ├── i18n/            # 國際化（17 種語言，Slang）
│   │   ├── src/
│   │   │   ├── pages/       # 頁面（書架、閱讀器、詞典、設定等）
│   │   │   ├── reader/      # 閱讀器 WebView JS/CSS 腳本
│   │   │   ├── media/       # 有聲書、字幕解析、reader source
│   │   │   └── models/      # 資料模型與狀態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android 工程（manifest、native fushidicts）
├── packages/                # 內部 package + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # fushidicts C++ 詞典引擎（FFI）
├── third_party/             # vendored 補丁套件（dependency_overrides 指向）
├── ci/                      # 建置補丁與整合測試腳本
├── tool/                    # bootstrap / i18n_sync 等腳本
└── docs/                    # 開發文件（含 docs/agent/ agent 操作手冊）
```

</details>

## 隱私與資料

Fushi 將匯入的書籍、詞典、字型、有聲書資料、影片、閱讀進度、高亮、統計和設定儲存在 App 本機儲存中。

雲端同步（Google Drive / OneDrive / Dropbox）使用由使用者設定的 OAuth 憑據；WebDAV / FTP / SFTP 使用使用者提供的伺服器位址與憑據；Fushi Interconnect 透過使用者設定的位址直連。Anki 製卡會與 AnkiDroid 或已設定的 AnkiConnect 位址通訊。

## 致謝

Fushi 基於以下專案與生態：

| 專案 | 說明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日語沉浸式學習工具 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日語閱讀器，閱讀器分頁引擎參考 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 原生日語閱讀器 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 詞典引擎 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 有聲書同步方案 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 詞典格式、變換表與查詞體驗參考 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 筆記類型 |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android 製卡整合 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | 本機音訊與 AnkiDroid 互動參考 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | 閱讀器、統計與同步相容性參考 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 影片播放框架（libmpv 核心） |
| [Niratan](https://github.com/W1ght/Niratan) | macOS 沉浸式語言學習套件 |

## 授權條款

本專案基於 GNU General Public License v3.0 發佈。詳情見 [LICENSE](../../LICENSE)。

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | **繁體中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
