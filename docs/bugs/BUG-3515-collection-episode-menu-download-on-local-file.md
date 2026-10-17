## BUG-3515 · 合集详情集卡菜单对本机已有文件的集仍显示「下载本集」
- **报告**：2026-10-18（用户：本地作品《超かぐや姫!》第 1 集右键菜单出现「下载本集」，原本就在本地；希望改成打开本地文件夹并选中文件）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/media_collection_detail_page.dart` `_showEpisodeMenu` 的「下载本集」只按 `_downloadsAvailable`（浏览模块开关）门控，没看这一集是否已有本机文件（`episode.local` + `videoBookHasLocalFiles`）。
- **[x] ① 已修复** — 有本机原始文件的集不再出「下载本集」，改出「打开文件位置」（桌面端，`currentRevealHost() != null`）；定位复用视频库卡同一原语 `revealFirstOf(localVideoFileCandidates(...))`，Windows 走 `explorer /select,` 选中文件。只在对端 / 没有本机文件（流媒体 URL）的集仍给下载。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collection_episode_cards_test.dart`（本地集无下载、有打开文件位置）、`fushi/test/pages/collection_detail_remote_members_test.dart`（远端集仍有下载、无打开文件位置；本地集相反）；原两条把「本地集也有下载本集」当期望的断言改为菜单常驻项。
- **同类补齐**：在线漫画作品页已下载章节的溢出菜单补「打开文件位置」（`manga_chapter_list.dart` `onRevealDownload`，`manga_series_page.dart` `_revealChapterDownload`：选中该章 `manga.json`，退回章目录），测试 `fushi/test/media/manga/manga_chapter_list_test.dart`。本地书 / 漫画卷书架卡片本来就有该项。
- **备注**：同步扫过其它下载入口（视频库远端卡、批量下载、Media Server 详情、漫画系列页、在线源详情），均只作用于远端 / 在线条目，不存在同类问题。
