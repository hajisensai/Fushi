## BUG-891 · 音频跟随遇图片暂停失效且遮罩未揭，遮罩揭开状态应持久化并与图片库双向同步
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
    schema 45→46，migration `if(from<46)`，DAO `markImageRevealed`/`markImagesRevealed`/
    `getRevealedImageKeys`/`watchRevealedImageKeys`（`database.dart`）。
  - JS `_hoshiImageRevealKey`（`reader_pagination_scripts.dart`）改产相对 key，三端对齐。
  - 测试：`hibiki/test/reader/image_reveal_key_test.dart`（10）+
    `packages/hibiki_core/test/migration_revealed_images_v46_test.dart`（2）+
    `migration_test.dart`/`migration_v40_collections_test.dart` 的 45→46 同步（33 全绿）。
- **[x] 阶段 B（诉求3：阅读器接 DB，已落）** — `_loadRevealedImageKeys`（首次注入 revealedKeysJson
  前从 DB 灌 `_revealedImageKeys`，与 spread/audio 并行）；`onImageRevealed` handler 改
  `ImageRevealKey.normalize` + 仅新揭开写 `markImageRevealed`（含音频跨图揭开路径，经同一 handler）。
- **[x] 阶段 C（诉求4：图片库遮罩 + 双向同步，已落）** — `IllustrationsViewerPage` 加 bookKey +
  database；开页 `getRevealedImageKeys` 灌本地集，`ImageRevealKey.fromFile` 算 key，
  `ImageRevealKey.shouldBlur` 判据（缩略图 + 全屏共用）渲染模糊遮罩，点击揭开写 DB。与阅读器
  不同时活跃（图片库仅从书架进入），各自开页 get DB 即双向同步，无需 live watch。
  测试：`image_reveal_key_test.dart` 加 shouldBlur 4 用例（14 全绿）。
- **[x] 阶段 D — 诉求2「遮罩没揭」的确定根因已修** — 纯图片章走 `_pauseThroughImageOnlyChapters`
  → `awaitImageChapterPause` 停留，**不经**区间揭遮罩原语 `__hoshiRevealBlurredBetween`（需 prev→el
  两 cue 锚点），音频停在模糊图上。新增 JS `__hoshiRevealAllBlurred`（揭整章全部 blurred 图 +
  回传 key 持久化，跳过 gaiji）+ Dart `AudiobookBridge.revealAllBlurred`，在图片章停留前调用。
  测试：`test/js/audiobook_image_pause.test.mjs` 加 2 用例（14 全绿），既有图片章路径 26 全绿。
- **[ ] 诉求1「音频跟随失效」** — 需真机复现确认命中「② 运行时失效根因」哪条。推测：用户很可能
  把「停在纯图片章模糊图上」误感为跟随失效；修遮罩缺口后停留展示清晰图、结束继续跟随，感知或随之
  缓解。若真机复测仍有独立跟随失效，再按候选 1（`_chapterTransition` 收尾未干净释放）/ 3
  （`snapReaderToAudio` 早退吞 `_forceNextReveal`）针对性根因修（未经真机确认前不盲改有声书时序）。

### ② 运行时失效根因（静态排序，待真机复现确认命中哪条）
1. **独立成章的纯图片页（BUG-487 路径）**：整章无 cue → `__hoshiRevealBlurredBetween`
   （`audiobook_bridge.dart`）永不执行 → 遮罩不揭；且 `_chapterTransition`/`_imageChapterPauseActive`
   长期持真（`audiobook_controller.dart` / `audiobook.part.dart`）→ 音频走但文字不跟。同时解释①②。
2. **章首（首句之前）插图 + 跨章后 `prev==null`**（`resetImagePauseAnchor` 归零）→ 章首插图
   既不暂停也不揭。
3. **`snapReaderToAudio`/`_onCueChanged` 早退吞 `_forceNextReveal`** → 恢复后不跟随。

- **[x] ① 根因修复** — 诉求2/3/4 已根因修（reveal 状态提升为持久 per-(bookKey,归一key) 真值 +
  纯图片章揭遮罩缺口）；诉求1「音频跟随失效」独立部分待真机复现确认后针对性修（见阶段 D）。
- **[x] ② 自动化测试** — 归一化 10 + 判据 shouldBlur 4 + v46 迁移/DAO 2 + 迁移链 45→46 同步 33 +
  JS 揭遮罩行为（含纯图片章 revealAll）14 + 图片章路径回归 26，全绿。
- **备注**：⚠️ schema v46 与 PR#224（EpubBooks.completedAt，本会话并发，也占 v46）撞版本号，
  当前 develop 仍为 45；集成时**后合者改 47**。诉求1（音频跟随失效）声明「彻底修好」前必须真机复测
  原始失败路径（CLAUDE.md 验证纪律）——本轮已修确定的遮罩缺口，跟随失效的独立部分留真机确认。
