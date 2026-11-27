## BUG-5564 · 发布目录里正片旁并排 OVA 时，SPs 特典（NCOP / NCED / Menu）一个都不挂到正片作品下
- **报告**：2026-11-27（应用内反馈 yMd0aT-fLN，Windows 3.4.0+32563：To LOVE-Ru 的 NCOP / NCED / Menu 在「系列」页逐个成卡）
- **真实性**：✅ 真 bug（用反馈附件 f0 的目录清单做夹具，修前在一次性导入与常驻来源两条路上都复现）。旧总结的「墙上增量没更新」与「同 BUG-5418」都不成立：
  32563 已含 BUG-5418 的修复，差别在目录结构——根目录里正片 26 集旁并排 `[OVA01]`～`[OVA06]`。
  `[OVA01]` 解不出集号（`parseVideoFilename` → episode null），`VideoSourceWorkPlanner.plan`
  （`packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart`，`parsed.episode == null && !discMember` 分支）
  把 6 个 OVA 各自立成单部作品，作品根与正片合集作品相同（发布目录）。本地索引给 `SPs\` 里的路径型特典找父作品时
  （`video_source_metadata_indexer.dart` 原 `_candidatesByDirectory` + 「前两名根目录等长即二义」判定）同根有 7 部作品 → 判二义 → `continue`，
  13 个特典一个都不绑；系列墙只排除已绑定的特典（`home_video_page.dart` `_passesLocalFilters` 的 `_localExtraBookUids`），于是逐个成卡。
- **[x] ① 已修复** — 父作品判定改为 `_ownerByDirectory`：取根目录离特典最近的那一层作品；只有一部就是它；有几部时由其中**唯一的剧集作品**（多集合集，
  `VideoSourceScrapeWork.isEpisodic`）认领——发布目录里的 NCOP / NCED / Menu 属于那部剧集；同层有两部以上剧集作品、或只有几部单片时仍判二义不绑，
  不随便挑一个。OVA 照旧是各自的单部作品（资料源上常是独立条目），计划器不动。蓝光特典按「含父标题的作品」认领的分支语义不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_ova_sibling_extras_test.dart`：按 f0 的目录结构（26 集 + OVA01～06，各带 .nfo，
  `SPs\` 13 个 Menu / NCED / NCOP，另有 CDs / Scans）走一次性导入与常驻来源两条真实扫描 → 索引，断言 13 个特典都挂到正片合集作品下、正片与 OVA 不被当特典。
- **备注**：「全部视频」里逐条列出特典是设计（该页有「特典」筛选），不在修复范围；详情页「花絮」能看到它们是按路径分类的特典筛选。
