## BUG-657 · 书架/视频进度「好像没了」——非数据丢失，显示短板已修（TODO-1346）

- **报告**：2026-07-09（用户：「书架、视频的进度好像没了」，怀疑近期 sync 改动 TODO-1340 pruneRootSpill / TODO-1332 / TODO-1291 误删进度）。
- **真实性**：✅ **真 bug，但根因是显示短板不是数据丢失**。沿真实代码路径 + 直接比对用户本机 DB（`D:/APP/HIBIKI_date/support/hibiki.db`，只读）逐条证伪「数据丢失」与「近期 sync 改动误删」（进度真值全在、键匹配、正被活跃写入）；用户抱怨的真实来源 = **数据在却显示不出**（书架进度条只按章节粒度忽略章内 charOffset、视频卡根本不画观看进度条）——对用户等于「没了」。已修显示。

### 排查证据（进度真值全部健在）

- **书阅读进度** = Drift `reader_positions` 表（键 `book_key` = `sanitizeTtuFilename(title)` = `epub_books` 主键，`upsertReaderPosition` 按 `book_key` upsert）。用户 DB：7 行，`char_offset` 有真实值（21965 / 12981 / 11120…），7 行 `book_key` **全部匹配** `epub_books` 现存书（无 orphan），且 DB 今天 00:51–01:10 仍在活跃写入。→ 没删。
- **视频观看进度**：单视频存 `video_books.last_position_ms`（Kimi no Na wa=2106875 / ReZero=495412 都在）；**多集播放列表进度按集存在 `video_books.playlist_json` 各集 `positionMs` + `current_episode`，`last_position_ms` 对播放列表恒为 0 是设计使然**（`m3u8_playlist.dart:24-26` 明注「取代旧的『整书一个 lastPositionMs、换集归零』」）。用户 DB：K-ON! `current_episode=47` 且 playlist_json ep47 `positionMs=633174`、Dragon Maid ep4=948746、BanG Dream! 多集都在。→ 21 行 `last_position_ms=0` 是正常，不是丢。另镜像存 `preferences.video_remote_position_video/...#ep<N>`（LAN 同步用）也都在且与 playlist_json 一致。
- **有声书进度** = `preferences.audiobook_pos_*`，用户 DB 全部真实值健在。
- **schema 无破坏性迁移**：代码 `schemaVersion=37`（`database.dart:343`）== DB `user_version=37`，打开时不跑任何 onUpgrade；删 `reader_positions` / `deleteTable('video_books')` 的迁移步骤都在 `from<16` / `from<17` 区间（v37 库早已跨过，绝不重跑）。

### 根因判定（不是数据丢失）

- **TODO-1340 `pruneRootSpill`（首要嫌疑）无罪**：`sync_orchestrator.dart:1470` 只 `listChildren(root)` 列**云端** root 的直接子项，删「非文件夹且匹配 `^(?:progress|statistics|audioBook|cover)_1_6[._]`」者。它 **只操作云端后端、从不触碰本地 Drift**；`e.isFolder` 守卫先于名字，书文件夹 / `__dictionaries__` / `__local_audio__` / `__aggregate__`（都是文件夹）一律跳过；被删的只可能是溢出到根的裸文件（冗余副本），而本地才是进度真相源，即便云端副本被清，下次同步本地照常重传，**不会造成本地进度丢失**。
- **TODO-1332（冷却时间戳）/ TODO-1291（自动下书解耦）** 不涉及删进度。视频 live 同步 `resolveVideoPositionSync`「较新时间戳胜 / 时间戳相等取较大位置」+ 备份合并是 INSERT-MISSING（只插本地没有的书、从不 UPDATE 已存在行），**远端 0 不会覆盖本地非零进度**。
- **显示短板（长期存在、非近期回归）**：书架进度条 `card_widgets.part.dart:458 _progressBar` = `item.position/item.duration`；`item` 由 `reader_hibiki_source.dart:266 _bookToMediaItem` 构造，**position 只累加 `section_index` 之前各章的 `chapters_json.characters`，完全忽略 `char_offset` 章内进度**；分母 = 全书 `characters` 之和（缺该字段的老书 → 分母 0 → 恒 0%）。故一本书读到某章开头（`char_offset` 再大也不计入）时书架显示很低%（用户 DB 里安達としまむら2 sec12/char12981 → 书架仅 0.2%）。**视频卡片 `home_video_page.dart:1684 _buildCard` 根本不画观看进度条**，视频「进度」只体现在重开续播（读 playlist_json / last_position_ms，均健在）。这两点都可能造成「进度好像没了」的观感，但都不是数据丢失、也不是近期改动引入。

### 修复（数据未丢——修的是「数据在却显示不出=对用户等于没了」的显示短板）

- **[x] ① 已修显示短板** — 三处显示改动：
  1. **书架进度条纳入章内 `char_offset`**（`reader_hibiki_source.dart`）：抽纯函数 `computeBookProgress`，`_bookToMediaItem` 改调它。`position = Σ前面各章 characters + clamp(charOffset,0,本章 characters)`，分母=全书字数，clamp 到 [0,全书字数]（绝不 >100%）。**单位已核实**：读用户 DB 比对，每条真实进度 `charOffset ≤ 当前章 characters`（11120≤23707、21965≤31382、428≤14918、12981≤15521…）→ `charOffset` 与 `characters` **确为同一字符计数单位、可直接相加**；`charOffset==-1`（仅章节、章内未知哨兵）当 0。**分母 0 回退**：老书 `chaptersJson` 无 `characters`（全书字数=0）时回退章级 `sectionIndex/章数` 粗粒度，不再恒显 0%。安達としまむら2（sec12/char12981）书架从 0.2% → ≈(184+12981)/94990 ≈ 13.9%。
  2. **视频卡加观看进度条**（`home_video_page.dart:_buildCard` + 纯函数 `m3u8_playlist.dart:videoWatchFraction`）：封面底部 YouTube 式 3px 进度条。**`VideoBooks` 无持久化总时长**（duration 仅播放期从 controller 得），故单视频无法算 `lastPositionMs/duration`；规则=已看完(`completedAt!=null`)满格、多集播放列表按「看到第几集」到集粒度(`currentEpisode/episodeCount`，用户 21/23 是播放列表如 K-ON! 47/59≈80% 立即生效)、单视频/流未看完无总时长时不画(不误导)。老数据/无进度回退 `null`（不画、不崩）。
  3. clamp 全部到 [0,1]/[0,总数]，越界/坏数据不炸。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/sources/reader_hibiki_source_test.dart`：`computeBookProgress` 6 例（章内 charOffset 计入并使进度前进、超章 clamp 不 >100%、-1 哨兵当 0、老书分母 0 回退章级 5/10=50%、无位置=0%、无章结构=(0,1) 不除零）。
  - `hibiki/test/media/video/m3u8_playlist_test.dart`：`videoWatchFraction` 4 例（多集 47/59 + 越界 clamp≤1、completed 满格压过集数、第一集未看完=null、单视频/流未看完=null）。
  - `hibiki/test/sync/sync_root_spill_prune_test.dart`（保留原 pruneRootSpill 安全守卫）：名字撞 per-book 谓词的**文件夹**因 `isFolder` 绝不被删 + 一次 `pruneRootSpill` 后本地 DB `reader_positions`(charOffset=12981)/`video_books`(ep47+playlist 633174) 一字不动。
  - 三文件 `flutter test` 全绿（76 例）；`flutter analyze` 6 个改动文件净。

- **备注**：
  - **待真机验收**：Windows/Android 开书架 → 有真实进度的书（安達としまむら2）进度条不再近 0%、随章内推进增长；开视频库 → 多集播放列表卡封面底部有进度条（K-ON! ≈80%）、已看完满格、未看不画。
  - **未做（超本次范围）**：单视频/流的**章内**观看百分比需持久化视频总时长（新增列+写入+迁移，且老数据须重开才有），成本/收益不匹配（用户单视频仅 2 个、播放列表占绝大多数已覆盖），留后续。
  - 数据完整性结论不变：`reader_positions` / `video_books.playlist_json` / `preferences` 进度真值全在、键匹配、schema 37==37 无破坏性迁移；TODO-1340 `pruneRootSpill` 只清云端 root 溢出、从不碰本地，无罪。
