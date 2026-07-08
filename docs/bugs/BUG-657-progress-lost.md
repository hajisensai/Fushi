## BUG-657 · 书架/视频进度「好像没了」排查（TODO-1346，疑似数据丢失）

- **报告**：2026-07-09（用户：「书架、视频的进度好像没了」，怀疑近期 sync 改动 TODO-1340 pruneRootSpill / TODO-1332 / TODO-1291 误删进度）。
- **真实性**：❌ **未复现为数据丢失——进度数据全在，且键都匹配、正被活跃写入**。沿真实代码路径 + 直接比对用户本机 DB（`D:/APP/HIBIKI_date/support/hibiki.db`，只读）逐条证伪「数据丢失」，也证伪「近期 sync 改动误删」。同时定位到一个**长期存在（非回归）的显示短板**（书架进度条只按章节粒度）可能造成「进度看起来变小/没了」的观感。

### 排查证据（进度真值全部健在）

- **书阅读进度** = Drift `reader_positions` 表（键 `book_key` = `sanitizeTtuFilename(title)` = `epub_books` 主键，`upsertReaderPosition` 按 `book_key` upsert）。用户 DB：7 行，`char_offset` 有真实值（21965 / 12981 / 11120…），7 行 `book_key` **全部匹配** `epub_books` 现存书（无 orphan），且 DB 今天 00:51–01:10 仍在活跃写入。→ 没删。
- **视频观看进度**：单视频存 `video_books.last_position_ms`（Kimi no Na wa=2106875 / ReZero=495412 都在）；**多集播放列表进度按集存在 `video_books.playlist_json` 各集 `positionMs` + `current_episode`，`last_position_ms` 对播放列表恒为 0 是设计使然**（`m3u8_playlist.dart:24-26` 明注「取代旧的『整书一个 lastPositionMs、换集归零』」）。用户 DB：K-ON! `current_episode=47` 且 playlist_json ep47 `positionMs=633174`、Dragon Maid ep4=948746、BanG Dream! 多集都在。→ 21 行 `last_position_ms=0` 是正常，不是丢。另镜像存 `preferences.video_remote_position_video/...#ep<N>`（LAN 同步用）也都在且与 playlist_json 一致。
- **有声书进度** = `preferences.audiobook_pos_*`，用户 DB 全部真实值健在。
- **schema 无破坏性迁移**：代码 `schemaVersion=37`（`database.dart:343`）== DB `user_version=37`，打开时不跑任何 onUpgrade；删 `reader_positions` / `deleteTable('video_books')` 的迁移步骤都在 `from<16` / `from<17` 区间（v37 库早已跨过，绝不重跑）。

### 根因判定（不是数据丢失）

- **TODO-1340 `pruneRootSpill`（首要嫌疑）无罪**：`sync_orchestrator.dart:1470` 只 `listChildren(root)` 列**云端** root 的直接子项，删「非文件夹且匹配 `^(?:progress|statistics|audioBook|cover)_1_6[._]`」者。它 **只操作云端后端、从不触碰本地 Drift**；`e.isFolder` 守卫先于名字，书文件夹 / `__dictionaries__` / `__local_audio__` / `__aggregate__`（都是文件夹）一律跳过；被删的只可能是溢出到根的裸文件（冗余副本），而本地才是进度真相源，即便云端副本被清，下次同步本地照常重传，**不会造成本地进度丢失**。
- **TODO-1332（冷却时间戳）/ TODO-1291（自动下书解耦）** 不涉及删进度。视频 live 同步 `resolveVideoPositionSync`「较新时间戳胜 / 时间戳相等取较大位置」+ 备份合并是 INSERT-MISSING（只插本地没有的书、从不 UPDATE 已存在行），**远端 0 不会覆盖本地非零进度**。
- **显示短板（长期存在、非近期回归）**：书架进度条 `card_widgets.part.dart:458 _progressBar` = `item.position/item.duration`；`item` 由 `reader_hibiki_source.dart:266 _bookToMediaItem` 构造，**position 只累加 `section_index` 之前各章的 `chapters_json.characters`，完全忽略 `char_offset` 章内进度**；分母 = 全书 `characters` 之和（缺该字段的老书 → 分母 0 → 恒 0%）。故一本书读到某章开头（`char_offset` 再大也不计入）时书架显示很低%（用户 DB 里安達としまむら2 sec12/char12981 → 书架仅 0.2%）。**视频卡片 `home_video_page.dart:1684 _buildCard` 根本不画观看进度条**，视频「进度」只体现在重开续播（读 playlist_json / last_position_ms，均健在）。这两点都可能造成「进度好像没了」的观感，但都不是数据丢失、也不是近期改动引入。

### 修复

- **[x] ① 无需删数据类根因修复（数据未丢）** — 逐条证伪数据丢失与 pruneRootSpill 误删；进度真值全部健在且键匹配。遵循「数据在就别瞎改」，不改读取/续播/书架百分比逻辑（改书架百分比去纳入 `char_offset` 属独立增强，且 `char_offset` 与 `characters` 计数口径未必同单位，冒然相加有 >100%/口径错乱风险，另案审慎评估，不在本次排查范围）。
- **[x] ② 已加自动化守卫** — `hibiki/test/sync/sync_root_spill_prune_test.dart` 新增 TODO-1346 守卫用例：把 pruneRootSpill 的安全契约钉死——(1) 名字恰好撞 per-book 谓词的**文件夹**（书文件夹）因 `isFolder` 守卫绝不被删；(2) 一次 `pruneRootSpill` 后本地 DB 的 `reader_positions`（章内精确 charOffset=12981）与多集视频 `video_books`（current_episode=47 + playlist_json ep 进度 633174）一字不动。`flutter test test/sync/sync_root_spill_prune_test.dart` 5 例全绿；`flutter analyze` 该文件净。

- **备注**：
  - **待用户/真机确认**：请用户确认「进度没了」具体指哪一种——(A) 书架进度条变空/变小（=上文显示短板，数据在，重开书能续读到原位）？(B) 重开书/视频回不到上次位置（=续播读取问题，但 DB 续播源健在，需真机复现）？(C) 云盘里的进度文件被清（=pruneRootSpill 清的是根目录溢出冗余，本地不受影响）？据答复再决定是否做 (A) 的书架百分比增强或排查 (B) 的续播路径。
  - 排查期间观察到用户 app 正**活跃运行并写入** `reader_positions`（安達としまむら2 的 `char_offset` 在 01:02→01:10 期间被写成 0，section 保持 12）——属实时用户操作，非数据被删；若用户反馈「重开书章内位置回退到章首」，再单独按续播恢复路径复现排查（本次未复现，未改续播代码）。
