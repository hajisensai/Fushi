<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | **繁體中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![下載最新版本](https://img.shields.io/badge/%E2%AC%87%20%E4%B8%8B%E8%BC%89%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![加入 Discord 社群](https://img.shields.io/badge/%E5%8A%A0%E5%85%A5%20Discord%20%E7%A4%BE%E7%BE%A4-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## 平台支援

| 平台 | 狀態 | 說明 |
|---|---|---|
| Android | ✅ | Android 7.0（API 24）及以上 |
| Windows | ✅ | Galgame 文字 / 語音 Hook 僅限 Windows |
| macOS | ✅ | 僅 Apple Silicon，不支援 Intel Mac |
| iOS | ✅（[TestFlight](https://testflight.apple.com/join/j88d69jx)） | 依 App Store 審核指南不含發現、線上來源與下載中心 |
| Linux | 🔧 需從原始碼建置 | 暫無預編譯套件；EPUB 閱讀器需要 WPE WebKit |
| Fushi Server | 🧪 Beta（[fushi-server](https://github.com/hajisensai/fushi-server/releases)） | 無頭伺服端，支援 Linux / Windows / macOS，附 Web 管理介面，見 [packages/fushi_server](../../packages/fushi_server/README.md) |

**設計系統**：所有平台預設 **Material 3 Expressive**；可在「設定 › 外觀 › 設計系統」切換為 **Cupertino**（Apple 風格）。選用 Cupertino 時，Windows 11 視窗背景使用 Mica、macOS 使用 vibrancy（系統開啟「降低透明度」或「增強對比」時除外）。

> 詞典查詞的語言由匯入的詞典與 Yomitan 變換表決定，與介面語言相互獨立。iOS 版透過 TestFlight 更新，會比其他平台晚幾天。

### 介面語言（17 種）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## 安裝

從 [Fushi 官網](https://fushi.moe/) 下載最新版本，提供 Android APK、Windows 安裝包與 macOS 建置（僅 Apple Silicon，不支援 Intel Mac）；iOS 透過 [TestFlight](https://testflight.apple.com/join/j88d69jx) 安裝。Linux 暫無預編譯的 App 安裝包，需自行從原始碼建置。無頭伺服端 Fushi Server 另在 [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases) 發佈。

> 最低 Android 7.0（API 24）。

## 建置

一鍵準備（`flutter pub get` + 打補丁），然後建置：

```bash
# 在倉庫根目錄
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# 桌面
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# 無頭伺服端（在 packages/fushi_server 下；用 `dart build cli`，不要用 `dart compile exe`）
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把 `flutter pub get` 與 `ci/apply-patches.sh` 收斂成一條命令。本專案鎖定 Flutter 3.47.6（Dart SDK `>=3.8.0 <4.0.0`）；Material 與 Cupertino 改走 `material_ui` / `cupertino_ui` 套件，更早的 Flutter 版本編譯不過。部分上游依賴經 vendored 到 `third_party/` 或由 `ci/apply-patches.sh` 修補——機制細節與 Linux 桌面建置依賴見 [docs/agent/build.md](../agent/build.md)。

<details>
<summary><b>技術棧一覽</b></summary>

| 層 | 技術 |
|---|---|
| 框架 | Flutter 3.47.6（Dart SDK `>=3.8.0 <4.0.0`），Riverpod |
| 平台 | Android / Windows / macOS / iOS / Linux，外加無頭伺服端 |
| UI | `material_ui`（Material 3 Expressive）/ `cupertino_ui`（Cupertino） |
| 閱讀器 | WebView 分頁引擎（衍生自 Hoshi Reader 系列） |
| 影片 | media_kit（libmpv 核心）+ libplacebo |
| 儲存 | Drift（SQLite，WAL）+ fushidicts（C++ FFI 詞典引擎） |
| NLP | Yomitan 變換表（多語言詞形還原）+ kana_kit（假名轉換）；分詞走 fushidicts FFI |
| 裝置端 AI | ONNX Runtime 執行語音辨識（產生字幕）與漫畫 OCR；演算法在 [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| 下載 | libtorrent 2.x（C ABI FFI 橋），外接 qBittorrent 作後備 |
| 同步 | 雲端後端 + Fushi Interconnect（區域網路、遠端位址、iroh P2P 隧道） |
| 共享引擎 | `fushi_engine`：App 與 Fushi Server 共用的純 Dart 核心 |
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
│   │   │   ├── pages/       # 頁面（庫頁、閱讀器、影片播放器、設定等）
│   │   │   ├── reader/      # 閱讀器 WebView JS/CSS 腳本
│   │   │   ├── media/       # 書、漫畫、影片、有聲書、線上來源
│   │   │   ├── lookup/      # 查詞彈窗與浮窗
│   │   │   ├── mining/      # 製卡（含 galgame 製卡）
│   │   │   ├── sync/        # 雲端同步、互聯、媒體伺服器
│   │   │   └── models/      # 資料模型與狀態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android 工程
├── packages/                # Dart 套件
│   ├── fushi_core/          #   資料庫 schema、偏好
│   ├── fushi_engine/        #   與伺服端共用的純 Dart 引擎
│   ├── fushi_server/        #   無頭伺服端 CLI + Web 介面
│   ├── fushi_cli/           #   桌面命令列用戶端
│   ├── fushi_dictionary/    #   詞典引擎綁定與匯入
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent / iroh FFI 綁定
│   └── …                    #   vendored fork（inappwebview Windows/Linux、gamepads）
├── native/                  # 原生原始碼：fushidicts、fushi_torrent、fushi_p2p（Rust）、galgame_hook 等
├── services/                # 日誌接收端與排行榜後端（獨立部署）
├── tools/browser-extension/ # 瀏覽器查詞擴充功能
├── third_party/             # vendored 補丁套件（dependency_overrides 指向）
├── ci/                      # 建置補丁與 CI 腳本
├── tool/                    # bootstrap / setup_worktree / bug 記錄等腳本
└── docs/                    # 開發文件（含 docs/agent/ agent 操作手冊）
```

</details>

影片匯入支援依作品或資料夾分組。使用方式見[影片組織與刮削流程](../specs/2026-09-07-video-library-workflow.md)及[MAL/TMDB 資料與 AniDB 檔案雜湊辨識](../specs/2026-09-07-mal-tmdb-anidb-hash.md)。

[選用線上服務設定](../specs/2026-09-07-online-services-setup.md)說明內建的應用程式身分、個人憑據，以及可關閉的影片設定提醒。

## 隱私與資料

Fushi 將匯入的書籍、詞典、字型、有聲書資料、影片、閱讀進度、高亮、統計和設定儲存在 App 本機儲存中。

- **同步**：Google Drive / OneDrive / Dropbox 走 OAuth 登入；WebDAV / FTP / SFTP / Fushi Server 使用你提供的伺服器位址與憑據。Fushi Interconnect 在已配對裝置間直連（區域網路、IPv6、組網或公網位址），直連全部失敗時退到端到端的 iroh P2P 隧道；配對連結一律先彈出確認。
- **Anki**：製卡只與 AnkiDroid 或你設定的 AnkiConnect 位址通訊。
- **使用統計**：桌面端與 Android 每天最多一次，向 fushi.moe 傳送隨機安裝 ID、App 版本、平台與更新通道，用於統計活躍使用者；不含帳戶、書庫或閱讀資料，伺服端不存 IP。可在更新設定裡關閉「傳送使用統計」。iOS 不傳送。
- **僅在你主動操作時**：日誌上傳（首次需確認同意）、應用內回饋、排行榜（預設關閉；開啟並同意後才上傳書架標題與進度）。
- **漫畫 OCR**：預設引擎是 Google Lens，會把頁面圖片傳給 Google；想讓圖片留在本機，請在設定裡改用裝置端模型或系統 OCR。
- **AI 功能**：只向你設定並指派給該功能的 LLM 提供者發送請求；未指派時不傳送任何請求。
- **第三方服務**：中繼資料、字幕與線上來源功能只在使用時存取[內容來源與整合](#內容來源與整合)中列出的服務。

## 開發活躍度

[![開發活躍度](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

日常開發都提交在 `develop`，`main` 只接收發佈合併。上圖雖然顯示在 `main` 上，資料取自 `develop`，所以反映的是真實開發量，而不是合併流水。

下方三條泳道就是 App 內提供的三個更新通道，每條依各自峰值縮放——debug 建置數比正式版高兩個數量級，用同一把標尺會把後兩條壓到看不見。

| 泳道 | 統計對象 | 取得方式 |
|---|---|---|
| **Debug（滾動）** | [release.yml](../../.github/workflows/release.yml) 中成功的 push 建置 | 滾動預發佈，每次 push 覆蓋重發 |
| **Beta** | `v<版本>-beta.<seq>` 預發佈 | 手動觸發的測試版 |
| **Stable** | `v<版本>` 正式發佈 | 正式版（Latest） |

> 上圖由本倉庫內的腳本自動產生（不依賴任何第三方服務），並由 [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml) 工作流程每日更新。

## Star 趨勢

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star 趨勢圖](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> 上圖由本倉庫內的腳本自動產生（不依賴任何第三方服務），並由 [Update Star History](../../.github/workflows/star-history.yml) 工作流程每日更新。

## 致謝

Fushi 基於以下專案與生態：

### 學習工具與前作參考

| 專案 | 說明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日語沉浸式學習工具 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日語閱讀器，閱讀器分頁引擎參考 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 原生日語閱讀器 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 詞典引擎 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 有聲書同步方案 |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | 字幕依參考軌對時間軸的演算法（GPL-3.0）；下載字幕依內嵌軌自動對齊的演算法參照 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 詞典格式、變換表與查詞體驗參考 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 筆記類型 |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android 製卡整合 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | 本機音訊與 AnkiDroid 互動參考 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | 閱讀器、統計與同步相容性參考 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 影片播放框架（libmpv 核心） |
| [Niratan](https://github.com/W1ght/Niratan) | macOS 沉浸式語言學習套件 |

### 引擎與原生元件

| 專案 | 說明 |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | galgame 文字 hook 引擎（vendored DLL，由注入器載入） |
| [MinHook](https://github.com/TsudaKageyu/minhook) | galgame 注入器使用的 inline hook 函式庫 |
| [libtorrent](https://github.com/arvidn/libtorrent) | 內建 torrent 下載引擎 |
| [mpv](https://github.com/mpv-player/mpv) | media_kit 背後的 libmpv 播放核心 |
| [FFmpeg](https://ffmpeg.org) | 媒體探測、剪輯與音訊擷取 |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU 影片著色器與 HDR 色調映射 |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | 渲染 EPUB 閱讀器的 WebView 引擎 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 語音辨識與 OCR 的裝置端推論 |
| [iroh](https://github.com/n0-computer/iroh) | Fushi Interconnect 遠端連線用的 P2P 隧道 |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | 詞典引擎相依套件 |

### 裝置端模型

| 專案 | 說明 |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer 語音辨識模型包與 VAD 建置 |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | 日語語音辨識模型 |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | 日語語音辨識模型 |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | 日語語音辨識模型（CC BY-NC 4.0，從其 Hugging Face 倉庫直接下載） |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | 多語言 CTC 語音辨識模型 |
| [Silero VAD](https://github.com/snakers4/silero-vad) | 人聲活動偵測模型 |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | 漫畫文字與對話框偵測模型 |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | 漫畫分格偵測模型，基於 [Manga109-s](http://www.manga109.org/en/download_s.html) 訓練 |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | 文字行偵測與辨識；漫畫調校的 rec（以 [Manga109-s](http://www.manga109.org/en/download_s.html) 與 [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText) 訓練）驅動逐欄 CTC 本機 OCR 模型 |

> 漫畫分格偵測模型與 PP-OCRv6_manga 使用 Manga109-s 資料集（Matsui et al. 2017; Aizawa et al. 2020）訓練，其條款要求明確標示對該資料集的使用。PP-OCRv6_manga（Apache-2.0）另以 AnimeText 資料集訓練，該資料集採用 CC BY-NC-SA 4.0 授權；App 從模型的 Hugging Face 倉庫下載，本專案不轉發該模型。

### 內容來源與整合

| 專案 | 說明 |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | 漫畫來源擴充生態 |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | 動畫來源擴充生態（extensions-lib 14–16，與漫畫共用同一執行環境） |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | 桌面端漫畫擴充執行環境（vendored，MPL-2.0） |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Mihon / Aniyomi 擴充適配參考 |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | 輕小說來源外掛生態 |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | 可在影片庫中瀏覽的媒體伺服器 |
| [asbplayer](https://github.com/asbplayer/asbplayer) | 瀏覽器擴充功能串流字幕橋接參考 |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | 動畫辨識與刮削架構參考 |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | galgame 庫資訊架構參考 |
| [AniDB](https://anidb.net) | 動畫、分集與檔案身分 |
| [MyAnimeList](https://myanimelist.net)（經 [Jikan](https://jikan.moe)） | 動畫中繼資料 |
| [TMDB](https://www.themoviedb.org) | 補充中繼資料與圖片 |
| [VNDB](https://vndb.org) | 視覺小說中繼資料 |
| [Jimaku](https://jimaku.cc) | 日語字幕來源 |
| [OpenSubtitles](https://www.opensubtitles.com) | 字幕來源 |

> 本應用程式使用 TMDB 及 TMDB API，但未獲得 TMDB 的認可、認證或以其他方式批准。

## 授權條款

本專案基於 GNU General Public License v3.0 發佈。詳情見 [LICENSE](../../LICENSE)。

## 維護者

Fushi 由 [hajisensai](https://github.com/hajisensai) 維護。官網：[fushi.moe](https://fushi.moe)。聯絡：[contact@fushi.moe](mailto:contact@fushi.moe)。

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | **繁體中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
