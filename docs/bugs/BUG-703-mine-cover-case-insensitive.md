## BUG-703 · 手机(Android)书籍阅读制卡缺封面(制卡与书架对封面路径大小写解析不对称)
- **报告**：2026-07-10（用户：TODO-1388，手机 EPUB 阅读制卡出来的卡片没有书籍封面）
- **真实性**：✅ **真 bug**。沿真实代码路径复核（origin/develop `9c45e23cb`）：制卡与书架网格对封面文件的解析**不对称**——
  - 书架网格 `hibiki/lib/src/media/sources/reader_hibiki_source.dart` 的 `_resolveCoverUrl` 在直接探测落空后有大小写不敏感兜底 `resolveCaseInsensitive`（`:514`，TODO-1319/BUG-612，注释明写「case-SENSITIVE filesystem Android/Linux cover never renders」），所以书架封面在手机上正常显示。
  - 制卡路径 `hibiki/lib/src/pages/implementations/reader_hibiki/mining.part.dart:29-33` 只有裸 `File(p.join(_extractDir!, _book!.coverHref)).existsSync()`，**对大小写敏感**。`coverHref` 在大小写不敏感宿主（Windows/macOS）导入时被 `p.canonicalize` 小写化（`hibiki/lib/src/epub/epub_parser.dart` 的 `_itemRelHref`），解压出的文件却保留真实大小写（TODO-739）。到 Android/Linux（大小写敏感 FS）后，裸探测按小写路径 `oebps/images/cover.jpg` 找不到真实的 `OEBPS/Images/Cover.jpg` → `coverPath=null` → 制出的卡无封面。
  - 下游 `packages/hibiki_anki` 字段填充无平台分歧，缺口在上游制卡上下文组装（mining）就把 `coverPath` 丢成 null，与书架显示分了岔。
- **[x] ① 已修复** — 见本分支 `todo1388-mine-cover-case` 提交（commit message 带 TODO-1388 / BUG-703；提交哈希见 git log）。根因修复：把书架网格用的大小写不敏感封面解析抽成单一共享静态 `ReaderHibikiSource.resolveCoverFilePath({extractDir, coverPath})`（返回磁盘真实文件路径，内部复用现成 `resolveCaseInsensitive` + `_listDirEntries`，声明封面优先 + `cover.jpg/jpeg/png` 约定兜底，逐段精确后不敏感匹配真实文件）。
  1. `reader_hibiki_source.dart`：`_resolveCoverUrl` 的 case-insensitive 分支改调 `resolveCoverFilePath`（去掉内联 relPaths 重复，行为等价）。
  2. `mining.part.dart`：制卡 `coverPath` 改调 `ReaderHibikiSource.resolveCoverFilePath(extractDir: _extractDir!, coverPath: _book?.coverHref)`，与书架命中同一封面文件。制卡与显示从此对封面路径解析**对称**。
- **[x] ② 已加自动化测试** — `hibiki/test/media/sources/reader_hibiki_cover_case_insensitive_test.dart` 新增 3 组守卫：
  1. `resolveCoverFilePath` 真实 temp 目录端到端：coverHref 大小写失配（小写）时解析到磁盘上大小写保留的真实文件，断言返回**磁盘真实大小写**文件名（`Cover.jpg` 而非请求的 `cover.jpg`）——证明走了 case-insensitive 逐段解析而非裸大小写敏感探测（跨平台判别，Linux CI 上是真回归守卫，Windows/macOS 恒绿）；coverHref=null 回落约定 `cover.jpg`（与书架对称）；全落空返回 null。
  2. 模拟大小写敏感 FS：以 mock `listDir`（case-preserved 树）证明 `resolveCaseInsensitive`（`resolveCoverFilePath` 的核心）在按小写探测落空后仍解析到真实大小写文件。
  3. 接线守卫（源码扫描，恒定判定）：`mining.part.dart` 必须调用 `ReaderHibikiSource.resolveCoverFilePath` 且不得含裸 `File(p.join(_extractDir!, _book!.coverHref))` 探测；书架 `_resolveCoverUrl` 也须经 `resolveCoverFilePath`（两条路径同源）。若有人改回裸 existsSync，此守卫在所有平台立即变红。
  - 全量 `flutter analyze`（含 test）No issues；目标测试文件 13 例全绿。
- **备注**：
  - 行为对称的副作用（有意，与书架一致）：制卡旧逻辑 gate 在 `_book?.coverHref != null`；改后即使 `coverHref` 为 null，只要存在约定 `cover.jpg/jpeg/png` 也会命中——这与书架 `_resolveCoverUrl` 恒纳入约定兜底的行为一致，是对称化而非扩张回归（两条路径用同一候选集）。
  - **Android 真机验证门未过**：本机 adb 当前无设备（大小写敏感 FS 桌面复现不了此 bug），未能在真机制卡确认封面出现。CI/Linux（大小写敏感）上端到端测试即真回归守卫；真机肉眼复测原始失败路径待有设备时补（CLAUDE.md 验证纪律）。
