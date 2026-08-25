## BUG-1865 · 剧集整理把带编号的特典当正片，与真正片撞号整批失败
- **报告**：2026-08-25（用户：Windows 2.2.1-debug.12346）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/download/video_download_organizer.dart:129`（修复前）——`plan()` 对每个视频文件**只按 basename 解析集号**，完全不看它在种子里躺在哪个目录。发布组把特典收进 `EXTRA/` `SPs/` `Previews/` 时，那些文件名同样以 `- 05` / `[SP05]` 结尾，于是「特典」和「正片」抢同一个 `Season NN/<标题> - SNNENN.mkv`。

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

  同类第二例：`job_id=0250057d…`（`[VCB-Studio] Hibike! Euphonium 2`），`Previews/` `SPs/` 下 `[SP01]`–`[SP07]` / `[Menu01]`–`[Menu07]` / `[WEB Preview02]`–`[13]` 与根目录正片 `[01]`–`[13]` 同形。

- **[x] ① 已修复** — `d8e89d7eb4`：把「先解析集号、撞了再说」翻成**先按目录判正片/特典、再解析集号**。新增 `_isInExtraDirectory()` + `_extraDirectoryNames` 词表（`extra/extras/sp/sps/previews/menu/nc/ncop/nced/pv/cm/scan/bdscan/…`），**只查目录段、不查文件名段**——正片文件名天然带 `S3` `BD` `FLACx3`，同一张表扫文件名迟早误伤真番剧标题（`Extra Olympia Kyklos`）。词表没收录的目录名只会退回旧口径（按集号判），不会把正片错判成特典。撞号检查保留给**真**重复（同集 v1/v2），并把消息改成点名两个源文件，否则用户无从判断该删哪个。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_organizer_test.dart`：
  - `numbered specials in an EXTRA directory never claim episode targets (BUG-1865)` — 语料是用户原始种子的真实文件名。
  - `numbered specials in SPs/Previews directories stay out of Season (BUG-1865)` — VCB 布局（编号写在方括号里）。
  - `a Season subdirectory is not mistaken for an extras directory` — 反向守卫：`Season 1/` 不在词表，必须继续走集号解析，否则整季种子会被整批扫进 Extras（比撞号更糟）。
  - `a genuine duplicate still fails, and names both source files` — 真冲突仍显式失败。

  变异实测：删掉 `!_isInExtraDirectory(…)` 判定 → 前两条同时红，且报出的正是用户那条 `S03E05` 冲突；把冲突消息改回只有目标名 → 第四条红。两次还原均以 sha256 校验。
- **备注**：存量卡住的任务（`f46faffa` / `0250057d`）修复后需要用户在下载页手动重试一次；`needsAttention` 会在重试时清掉 `last_error`。词表是增量的——遇到新发布组的特典目录名（不在表里）会退回旧口径，此时症状仍是撞号或错命名，补词表即可。
