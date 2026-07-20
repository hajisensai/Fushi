## BUG-898 · 音频跟随遇图片暂停失效且遮罩未揭，遮罩揭开状态应持久化并与图片库双向同步
- **报告**：2026-07-18（用户：音频跟随遇图片暂停失效，图片遮罩也没去；图片遮罩点开以后应该永远消失；书内去掉遮罩，外面图片库也应该同步去掉遮罩）
- **真实性**：✅ 真（四个诉求，公共根因是一个数据结构问题）

### 根因（公共）
图片防剧透遮罩「已揭开」状态的真相源是阅读器内存字段 `_revealedImageKeys`
（`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1256`，`Set<String>`，存 JS 侧
`new URL(...).href` 绝对 URL），**不持久化、不跨页共享**：
- 关闭重开书 → 集合丢 → 遮罩恢复（诉求3：应永久消失，现状没做）。
- 图片库 `IllustrationsViewerPage` 完全独立、无遮罩、不读该集（诉求4：应双向同步，现状没做）。
- 运行时诉求1/2（音频遇图片暂停失效 + 遮罩未揭）另有边界根因，见「② 运行时」。

修法（Linus 式，修数据结构消特殊情况）：把 reveal 状态提升为持久化的
per-(bookKey, 归一化 imageKey) 真值（Drift `revealed_images` 表），阅读器 WebView 与图片库
都归一到同一 key 读写它。统一 key = extractDir 相对、decode、正斜杠路径。

### 分阶段
- **[x] 阶段 A（地基，已落，零行为破坏）**
  - 归一化纯函数 `ImageRevealKey`（`hibiki/lib/src/reader/image_reveal_key.dart`）：
    `normalize`（阅读器回传 URL/相对）+ `fromFile`（图片库磁盘 File）→ 同一稳定 key。
  - Drift `RevealedImages` 表（`packages/hibiki_core/lib/src/database/tables.dart`），
    schema 46→47，migration `if(from<47)`，DAO `markImageRevealed`/`markImagesRevealed`/
    `getRevealedImageKeys`/`watchRevealedImageKeys`（`database.dart`）。
  - JS `_hoshiImageRevealKey`（`reader_pagination_scripts.dart`）改产相对 key，三端对齐。
  - 测试：`hibiki/test/reader/image_reveal_key_test.dart`（10）+
    `packages/hibiki_core/test/migration_revealed_images_v47_test.dart`（2）+
    `migration_test.dart`/`migration_v40_collections_test.dart` 用 db.schemaVersion 活值断言（33 全绿）。
- **[x] 阶段 B（诉求3：阅读器接 DB，已落）** — `_loadRevealedImageKeys`（首次注入 revealedKeysJson
  前从 DB 灌 `_revealedImageKeys`，与 spread/audio 并行）；`onImageRevealed` handler 改
  `ImageRevealKey.normalize` + 仅新揭开写 `markImageRevealed`（含音频跨图揭开路径，经同一 handler）。
- **[x] 阶段 C（诉求4：图片库遮罩 + 双向同步，已落）** — `IllustrationsViewerPage` 加 bookKey +
  database；开页 `getRevealedImageKeys` 灌本地集，`ImageRevealKey.fromFile` 算 key，
  `ImageRevealKey.shouldBlur` 判据（缩略图 + 全屏共用）渲染模糊遮罩，点击揭开写 DB。与阅读器
  不同时活跃（图片库仅从书架进入），各自开页 get DB 即双向同步，无需 live watch。
  测试：`image_reveal_key_test.dart` 加 shouldBlur 4 用例（14 全绿）。
- **[x] 阶段 D-1 — 诉求1/2 真正根因（章节正文内联图被无视）已修** — 用户澄清：诉求1/2 是**同一件事**——
  章节正文里的内联图，音频跟随经过时既不暂停也不揭遮罩，被整个跳过。用 jsdom（真实 bridge 函数 + 真实
  highlight 序列）复现定位根因：`__hoshiSasayakiAnchorEl` 是 `if(cueRangesMap){} else if(cueWrappers){}`，
  而现代 WebView `__hoshiCssHighlightsSupported` **恒 true** 且 `cueRangesMap` **从不被填充**
  （`applySasayakiCues` 只 `set cueWrappers`，无 `cueRangesMap.set`）→ 第一分支恒进入、找不到 range、
  `return null`，cueWrappers 兜底被 `else` **永久跳过** → anchor 恒 null → `__hoshiHighlightSasayakiCueById`
  的 `if(anchor)` 守卫使 `__hoshiImagePauseAdvance` **永不调用** → 整条 sasayaki 图片暂停+揭遮罩失效。
  **修法**：cueRangesMap 未命中就无条件兜底 cueWrappers（`else if`→`if`）。jsdom 实证：修复前生产条件
  （cssHighlights=true）5 结构全 `paused=false`；修复后结构 1/2/3（段内/跨段内联图）`paused=true` + 揭遮罩。
  守卫：`test/js/audiobook_image_pause.test.mjs` 加 3 anchor 用例（17 全绿）。
  （残留次要边界：整句纯 ruby 无 wrapper → anchor 仍 null；图紧跟当前句之后 → 下一句 cue 推进才检测。）
- **[x] 阶段 D-2 — 纯图片章揭遮罩（独立次要缺口）** — 纯图片章走 `awaitImageChapterPause` 停留，不经区间
  揭遮罩原语 `__hoshiRevealBlurredBetween`。新增 `__hoshiRevealAllBlurred` + `AudiobookBridge.revealAllBlurred`
  停留前调用。与主根因正交的另一真实缺口，一并修掉。

- **[x] ① 根因修复** — 诉求1/2（`__hoshiSasayakiAnchorEl` 的 `else` 使图片暂停+揭遮罩整条失效，纯逻辑
  根因）+ 诉求3/4（reveal 状态提升为持久 per-(bookKey,归一key) 真值 + 图片库双向同步）+ 纯图片章次要缺口。
- **[x] ② 自动化测试** — 归一化 10 + 判据 shouldBlur 4 +  v47 迁移/DAO 2 + 迁移链活值断言 33 +
  JS 行为 17（含 anchor 兜底 3 + 纯图片章 revealAll 2）+ 图片章路径回归 26，全绿。
- **备注**：⚠️ schema v47 与 PR#224（EpubBooks.completedAt，占 v46）本会话并发撞版本号；集成落地时本 PR 作为后合者
  已改为 v47（`if(from<47)` createTable，develop 的 v46 completedAt 保留）。根因经 jsdom 实证复现+修复验证；声明「彻底修好」前仍建议真机复测原始
  失败路径（CLAUDE.md 验证纪律）。
