## BUG-1865 · 剧集整理把带编号的特典当正片，与真正片撞号整批失败
- **报告**：2026-08-25（用户：Windows 2.2.1-debug.12346）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/download/video_download_organizer.dart:129`（修复前）——`plan()` 对每个视频文件**只按 basename 解析集号**，完全不看它在种子里躺在哪个目录。发布组把特典收进 `EXTRA/` `SPs/` `Previews/` 时，那些文件名同样以 `- 05` 结尾，于是「特典」和「正片」抢同一个 `Season NN/<标题> - SNNENN.mkv`。

  用户原始报错（生产库 `video_download_jobs.job_id=f46faffa…`，`last_error`）：
  ```
  organization target collision: 響け！ユーフォニアム３ (2024)/Season 03/響け！ユーフォニアム３ (2024) - S03E05.mkv
  ```
  种子 `[Moozzi2] Hibike! Euphonium S3 … - TV + SP`（69 文件 / 61 视频）里，解析成第 5 集的有 **7 个**，真正片只占其中一个：
  ```
  EXTRA/…[SP05] Making Video Collection - 05 .mkv
  EXTRA/…[SP08] Extra Episode - 05 .mkv
  EXTRA/…[SP06] Unused Movie in Main Story Collection - 05 .mkv
  EXTRA/…[SP07] Web Yokoku - 05 .mkv
  EXTRA/…[SP00] Menu - 05 [ Ver.01 ] .mkv
  EXTRA/…[SP00] Menu - 05 [ Ver.02 ] .mkv
  …[Moozzi2] Hibike! Euphonium S3 - 05 .mkv          ← 唯一的正片
  ```
  EXTRA 文件的 backend index 是 7–54、正片是 55–67，**先到先得**，赢下 S03E05 的根本不是正片。

  BUG-1785 只补了「**解不出**集号的进 Extras」，带编号的特典照样冒充正片。撞号只是响的那一半：**不响的那一半是 Menu/PV 被静默改名成正片入库**，那个更贵。

  触发集号解析的是文件名里的 `- 05` 这类**裸编号**；方括号编号（`[SP05]` `[Menu05]` `[WEB Preview05]`）实测 `parseVideoFilename` 解不出集号（`episode=null`），BUG-1785 之后本来就进 Extras，不在本 bug 的触发面里。

- **[x] ① 已修复** — `d8e89d7eb4` + 审查后追加：把「先解析集号、撞了再说」翻成**先按目录判正片/特典、再解析集号**。
  - 新增 `_isInExtraDirectory()` + `_extraDirectoryNames` 词表（`extra/extras/sp/sps/previews/menu/nc/ncop/nced/pv/cm/scan/bdscan/…`，另含中日文的 `特典` / `特典映像` / `映像特典` / `メニュー` / `予告` / `菜单`），**只查目录段、不查文件名段**——正片文件名天然带 `S3` `BD` `FLACx3`，同一张表扫文件名迟早误伤真番剧标题（`Extra Olympia Kyklos`）。
  - `_normalizedSegment` 归一化去的是**标点**而不是「非 ASCII」（`[^\p{L}\p{N}]`，`unicode: true`）。写成 `[^a-z0-9]` 会把中日文目录名整段删成空串，`特典` / `映像特典` / `メニュー` 在词表里永远不可能命中——而这恰恰是本仓最常见的发布组命名。
  - **纯特典种子不再硬失败**：所有视频都落在特典目录时（用户单独下的 SP 盘），先分类会一集都认不出，这不是「种子与 kind 不符」。`plan()` 此时退回旧口径（不看目录、只按文件名解集号）再排一趟，两趟都认不出才抛 `unable to determine episode number`。排布逻辑抽成 `_planFiles(..., classifyExtraDirectories:)`，两趟共用同一份代码，返回 `_OrganizationPass{files, recognizedEpisodes}`。
  - 撞号检查保留给**真**重复（同集 v1/v2），消息改成点名两个源文件，否则用户无从判断该删哪个。

- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_organizer_test.dart`：
  - `numbered specials in an EXTRA directory never claim episode targets (BUG-1865)` — 语料是用户原始种子的真实文件名。
  - `numbered specials in SPs/Previews directories stay out of Season (BUG-1865)` — VCB 布局。**注意**：该布局里的 `[SP05]` / `[Menu05]` / `[WEB Preview05]` 本来就解不出集号，只拿它们当语料这条用例修复前后同绿；所以用例里额外放了一个**解得出**集号的特典（`… [SP] Bonus Interview - 05 …`），它才是负向对照的承重件。
  - `a specials-only torrent falls back to filename parsing instead of failing (BUG-1865)` — 纯特典种子退回旧口径，仍得到 `Season 01/… S01E01`、`S01E02`。
  - `a CJK-named extras directory is classified like EXTRA (BUG-1865)` — `【特典映像】/` `メニュー/` 下与正片同集号的文件进 Extras 且不撞号。
  - `a Season subdirectory is not mistaken for an extras directory` — 反向守卫：`Season 1/` 不在词表，必须继续走集号解析。
  - `a genuine duplicate still fails, and names both source files` — 真冲突仍显式失败。

  **变异实测（审查复核后的事实）**：
  - 去掉 `!_isInExtraDirectory(…)` 判定 → `numbered specials in an EXTRA directory …`（报出用户原始那条 `S03E05` 冲突）、`numbered specials in SPs/Previews …`（补了承重语料之后）、`a CJK-named extras directory …` 三条红。**修正**：在补承重语料之前，这一变异只红第一条——原文写的「前两条同时红」不成立。
  - 把 `_normalizedSegment` 改回 `[^a-z0-9]` → `a CJK-named extras directory …` 红。
  - 去掉纯特典种子的旧口径回退 → `a specials-only torrent falls back …` 红。
  - 把冲突消息改回只有目标名 → `a genuine duplicate still fails, and names both source files` 红。
  - 每次还原均以 sha256 与变异前比对一致。

- **备注**：
  - 存量卡住的任务 `f46faffa` 修复后需要用户在下载页手动重试一次；`needsAttention` 会在重试时清掉 `last_error`。
  - 另一个卡住的任务 `0250057d`（`[VCB-Studio] Hibike! Euphonium 2`）**未取证**：没有抓它的 `last_error`，而按实测解析行为，它那批 `[SP01]`–`[SP07]` / `[Menu01]`–`[Menu07]` / `[WEB Preview02]` 方括号编号解不出集号、修复前就已经进 Extras。所以「它是同一个根因」只是推断，不能据此断言重试即可恢复；需要用户再报一次错误文本才能定性。
  - 词表是增量的——遇到新发布组的特典目录名（不在表里）会退回旧口径，此时症状仍是撞号或错命名，补词表即可。
