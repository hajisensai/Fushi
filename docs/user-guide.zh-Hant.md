# 平澤唯也能5分鐘設定好的 Fushi 使用指南

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | **繁體中文** | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> 簡體中文版指南託管於飛書（見上方連結）；英文版同時提供 [GitHub 版本](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md)。

## 簡介

**Fushi——把追小說、追番變成語言輸入。**

閱讀小說、觀看動畫或聆聽有聲書時，點一下任何一個詞就能查詞，並把生詞連同它出現的句子一起送進 Anki。

沒有預設詞表——你只複習自己真正遇到過的詞。適用於任何語言。

- 📖 EPUB 閱讀 · 點擊即查
- 🎧 有聲書逐句高亮
- 🎬 影片字幕查詞與製卡
- 🃏 一鍵製作 Anki 卡片 + 複習統計
- 📚 漫畫閱讀 · 透過 OCR 直接從畫面上查詞
- ⬇️ 動畫與漫畫一鍵應用內下載——自動加入你的媒體庫，下載途中即可播放
- 🎮 Galgame 語音製卡（Windows）· 原始語音與文字一同寫入卡片

支援平台：Android / Windows / macOS / iOS（Linux 可自行從原始碼建置，尚無預先建置的安裝包）

### 專案網址

https://github.com/hajisensai/Fushi

本專案正在積極開發中——你的回饋會被及時處理。歡迎提交 Bug 回報與功能建議。如果你覺得 Fushi 好用，歡迎分享給其他人，或在倉庫點一顆 ⭐。

### 下載

https://github.com/hajisensai/Fushi/releases/latest

請依你的平台選擇對應的檔案：**Android**——選 `arm64-v8a` 的 APK（近幾年的手機都用這個；只有較舊的裝置才需要 `armeabi-v7a`，模擬器則用 `x86_64`）；**Windows**——`windows-setup.exe`；**macOS**——`macos.zip`；**iOS**——`ios.ipa`。**Linux** 目前還沒有預先建置的安裝包，需要自行從原始碼建置。

檔名以 `bridge-` 開頭的 APK 是給 **舊版 Hibiki 使用者** 的遷移橋接包，可以忽略。

## 設定教學

### 1. 匯入推薦詞典（包含詞語＋聲調＋詞頻詞典）及本機音訊（包含日語及英語音訊資料庫）（極其推薦新手使用此方法！！！可選）

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Cloudflare 下載（9.5 GB）](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

在 App 中：設定 -> 同步與備份 -> 點擊 **匯入備份**。

![匯入備份畫面](static-assets/user-guide/import-backup.png)

### 2. 從 Anki 官方網站下載並設定 Anki

Anki——得名於「暗記（あんき）」——是全世界使用最廣泛的[間隔重複系統（SRS）](https://en.wikipedia.org/wiki/Spaced_repetition)，也是一個非常重要的工具。

連結：[Anki 官方網站](https://apps.ankiweb.net/) · [手冊（中文）](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [（中文）](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Anki 下載頁面](static-assets/user-guide/anki-download.png)

你可以把任何想記住的素材交給 Anki，它能讓你用最少的學習時間達到最佳的記憶效果。

Anki 內建 [FSRS](https://github.com/open-spaced-repetition/fsrs4anki)——世界上最好的間隔重複演算法之一。

**但是！！！** Anki 預設的演算法是 SM2，一個 30 多年前、效果很差的演算法。請務必把 Anki 使用的演算法切換為 **FSRS**。

#### Anki

##### Android

1. 安裝並開啟 Anki。
2. 回到 Fushi，前往 設定 -> 製卡。
3. 點擊 **重新整理牌組與筆記類型**（圖中標示「1」）；Fushi 會請求權限——點擊「允許」。
4. 點擊 **建立 Lapis 牌組**（圖中標示「2」）。
5. 如果沒有出現紅色警告或錯誤，即表示設定成功。

![Anki Android 設定](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. 安裝並開啟 Anki。
2. 點擊左上角的 **工具（Tools）**。

![Windows 上的 Anki 工具選單](static-assets/user-guide/anki-windows-tools-menu.png)

3. 貼上下方的 Anki 附加元件代碼進行安裝：`2055492159`
4. 回到 Fushi，前往 設定 -> 製卡。
5. 點擊 **重新整理牌組與筆記類型**（標示「1」）。
6. 點擊 **建立 Lapis 牌組**（標示「2」）。
7. 如果沒有出現紅色警告或錯誤，即表示設定成功。

![Anki Windows 設定](static-assets/user-guide/anki-windows-setup.png)

### 3. 瀏覽設定中的各項選項，看看有沒有想要調整的地方。（可選）

該開始沉浸了。

## 推薦功能

### APP 外查詞

**Android：** 選取一個詞，然後在選取選單中點擊 **翻譯** 或 **Fushi**。

**Windows：** 選取一個詞，然後按 **Ctrl+Alt+D**（快捷鍵可在 設定 -> 快捷鍵 中修改）。

### 剪貼簿查詞

你複製的任何內容都會被自動查詞。提供兩種呈現方式——**浮動面板** 與 **透明文字視窗**——都可以在 設定 -> 查詞 中設定。

### 瀏覽器查詞／串流字幕製卡（Netflix）

從 Fushi 首頁安裝瀏覽器擴充功能。

## 鳴謝

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
