## BUG-1174 · 数据根迁移漏改 6 处路径 + 非幂等 + 无事务
- **报告**：2026-07-27（用户：内部审计，走「设置 → 数据存储位置 → 选目录」即可触发）
- **真实性**：✅ 真 bug（四组独立缺陷，均在 develop `5af29b2da` 上存在）
  1. **漏改的持久化路径**（迁移后指向已搬空的旧位置）：
     - `galgames.cover_path`（`tables.dart:1201`，落盘 `galgame_cover_resolver.dart:300-320`
       → `<documents>/game_covers`）—— 迁移器全文无 `galgames` 字样，整个游戏库封面退化成默认手柄图标。
       与 TODO-1255 修过的 `video_books.cover_path` **完全同型**。
     - `video_books.subtitle_source` / `secondary_subtitle_source`（`tables.dart:487,492`）——
       四态编码的「外挂绝对路径」态落 `<documents>/video_subtitles`，该目录在搬移白名单里
       （`app_paths.dart:389-406`）会被物理搬走；旧迁移器的 UPDATE 只有
       `video_path,playlist_json,cover_path` 三列 → 所有外挂字幕失效，查词与双字幕一并失效。
     - `media_items.image_url`（`tables.dart:13`）—— 本地书封面存 `file://<绝对路径>`
       （`reader_hibiki_source.dart` 的 `Uri.file(candidate)`）→ 书架/首页「最近」卡片封面全空白。
     - pref `galgame_library`（v55 legacy JSON 的 `coverPath`）、`video_remote_subtitle`
       （远端视频手选字幕 map，**原调研清单未列出、本次实查补入**）、`download_save_root`
       与 `download_save_root_history`、`local_audio_db_path`。
  2. **`profile_settings` 快照回滚（最阴的一条）**：`profile_repository.dart:129-140`
     把**每一条**非排除 Drift pref 原样复制进 `profile_settings`，`:243-249` 的
     `applyProfile` 再原样 `setPref` 写回。迁移只改 `preferences` → 用户切一次 Profile
     就把刚 rebase 好的路径整体退回旧值。**迁移当天一切正常，几天后突然坏**。
  3. **路径改写非幂等**：判据是 `startsWith(oldRoot)`（`backup_service.dart:98-114`）。
     新根落在旧根**内部**时（`<Documents>` → `<Documents>/Hibiki/data`，BUG-1115 之后
     `isSafeNestedTargetInSharedDocuments` 明确放行这种目标），跑第二遍产出
     `Documents/Hibiki/data/Hibiki/data/…`，**不抛任何异常、静默毁全库**。
     同型坑在 iOS 容器重定位上已踩过一次（BUG-1115）。
     ⚠️ 修的过程中**幂等测试真实抓到一条旁路**：字体目录 pref 走
     `rebaseFontCatalogJson` / `rebaseFontListJson`（`backup_service.dart:126,150`），
     那两个函数内部直接调裸 `rebasePath`，绕过了新加的作用域谓词 → 字体路径仍被改写两遍。
  4. **DB 路径改写无事务**：旧 `_rebaseDatabasePaths` 是逐行 `UPDATE`，中途失败留下
     「一半指新根、一半指旧根」的库，而外层回滚只把**文件**搬回旧位置，救不了半改的 DB。

- **[x] ① 已修复** — `fix(storage): close data-root migration path-rewrite gaps`
  - 新增 `hibiki/lib/src/storage/path_rebase_coverage.dart`：把「哪些列/pref 承载绝对路径、
    迁移要不要改写、为什么」变成**声明式单一真相源**（55 列 + 17 个 pref key，逐条带理由）。
  - `data_root_migrator.dart` 补齐上述全部漏项，并按表拆成 `_rebase<Table>` 入口。
  - **③ 幂等**：新增 `DocumentsPathRebaser`，判据从 `startsWith(oldRoot)` 收窄为
    **「相对旧根的首段 ∈ 本次搬移真正会动的顶层项集合」**（与
    `DataRootMigrationRequest.documentsTopLevelIncludeNames` 同源）。已改写过的路径首段是
    `Hibiki`（不在白名单里）→ 天然跳过，函数**本质幂等**，「跑没跑过」这个问题消失而不是被
    条件判断掩盖。字体旁路从根上修：给 `rebaseFontCatalogJson` / `rebaseFontListJson` 加
    可选 `rewritePath` 注入点，迁移侧传作用域改写器，**备份恢复侧不传、行为逐字节不变**。
  - **② profile_settings**：迁移时用与 `preferences` **同一个**纯函数
    `rebaseMigratedPrefValue(key, value, ...)` 改写**所有 Profile** 的快照行。
    选这条而不是「让路径 pref 不进快照」，是因为后者会改掉 Profile 的既有语义
    （字体目录/发音库配置现在确实是每 Profile 的），为修迁移去动无关功能契约，爆炸半径大得多。
  - **④ 事务化**：整段 DB 改写包进 `db.transaction()`；`wal_checkpoint(TRUNCATE)` 留在事务外
    （SQLite 不允许在活动事务里 checkpoint）。
  - 未触碰：`anime_downloads` 的搬移/fast-resume/活跃句柄逻辑（另议）、一键整理按钮、
    BUG-1115 文档给老用户的指引、备份恢复侧的同源漏项（R8，另立项）。

- **[x] ② 已加自动化测试** —
  - `hibiki/test/storage/data_root_migrator_path_gaps_test.dart`（行为）：
    ① 全漏项改写 + 外部路径纹丝不动；② **迁移后真正跑一次 `ProfileRepository.applyProfile`
    （= 用户切 Profile），断言路径仍是新值**；③ 同一改写**连跑两次**逐字节 no-op +
    显式断言不出现 `Hibiki/data/Hibiki/data`；③b/③c 作用域谓词边界（前缀撞名、大小写、
    整树模式）；④ 事务中途失败整体回滚。
  - `hibiki/test/storage/path_rebase_coverage_guard_test.dart`（源码守卫）：
    tables.dart 里路径形 TextColumn 必须登记（双向，含陈旧声明）+ 每条声明必须有理由 +
    must-rebase 列必须真的接进迁移器 + **每张表必须有 `_rebase<Table>` 入口且在事务里被调用** +
    pref key 侧同规则 + 字体 key 字面值与 `dbSourcePrefKey` 编码器一致 +
    **「所有 documents 路径改写必须过同一个作用域谓词（无旁路）」**。
  - 负向验证（改回旧逻辑 → 对应用例转红 → 还原）：①③④ 与四条守卫全部确认可转红。
- **备注**：`schema` 未改动；持久化 key 未改名。
