# hibiki 使用指南

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | **繁體中文** | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> 簡體中文版指南託管於飛書（見上方連結）；英文版同時提供 [GitHub 版本](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md)。

## 簡介

這是一款適用於 Android / Windows（iOS / macOS 計劃中）的免費軟體——一款劃時代的跨平台開源應用，集小說閱讀、有聲書播放、影片播放與詞典查詢於一體。

### 專案網址

https://github.com/hajisensai/hibiki

本專案正在積極開發中——你的回饋會被及時處理。歡迎提交 Bug 回報與功能建議。如果你覺得 Hibiki 好用，歡迎分享給其他人，或在倉庫點一顆 ⭐。

### 下載

https://github.com/hajisensai/hibiki/releases/latest

Android：選擇 **arm64**。Windows：選擇 **.exe** 檔案。

## 設定教學

### 1. 匯入推薦詞典與本機音訊（可選）

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

在 App 中：設定 -> 同步與備份 -> 點擊 **匯入備份**。

**注意：匯入備份會清除本機資料。此流程將在未來版本中改進。**

![匯入備份畫面](static-assets/user-guide/import-backup.png)

### 2. 從 Anki 官方網站下載並設定 Anki

Anki——得名於「暗記（あんき）」——是全世界使用最廣泛的[間隔重複系統（SRS）](https://en.wikipedia.org/wiki/Spaced_repetition)，也是一個非常重要的工具。

連結：[Anki 官方網站](https://apps.ankiweb.net/) · [手冊（中文）](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [（中文）](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[圖片：示意 / 圖例]*

你可以把任何想記住的素材交給 Anki，它能讓你用最少的學習時間達到最佳的記憶效果。

Anki 內建 [FSRS](https://github.com/open-spaced-repetition/fsrs4anki)——世界上最好的間隔重複演算法之一。

**但是！！！** Anki 預設的演算法是 SM2，一個 30 多年前、效果很差的演算法。請務必把 Anki 使用的演算法切換為 **FSRS**。

#### Anki

##### Android

1. 安裝並開啟 Anki。
2. 回到 hibiki，前往 設定 -> 製卡。
3. 點擊 **重新整理牌組與筆記類型**（圖中標示「1」）；hibiki 會請求權限——點擊「允許」。
4. 點擊 **建立 Lapis 牌組**（圖中標示「2」）。
5. 如果沒有出現紅色警告或錯誤，即表示設定成功。

![Anki Android 設定](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. 安裝並開啟 Anki。
2. 點擊左上角的 **工具（Tools）**。

![Windows 上的 Anki 工具選單](static-assets/user-guide/anki-windows-tools-menu.png)

3. 貼上下方的 Anki 附加元件代碼進行安裝：`2055492159`
4. 回到 hibiki，前往 設定 -> 製卡。
5. 點擊 **重新整理牌組與筆記類型**（標示「1」）。
6. 點擊 **建立 Lapis 牌組**（標示「2」）。
7. 如果沒有出現紅色警告或錯誤，即表示設定成功。

![Anki Windows 設定](static-assets/user-guide/anki-windows-setup.png)

### 3. 瀏覽設定中的各項選項，看看有沒有想要調整的地方。（可選）

## 鳴謝

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
