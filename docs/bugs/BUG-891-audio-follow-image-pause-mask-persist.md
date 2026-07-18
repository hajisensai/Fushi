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
- **[ ] 阶段 B（诉求3：阅读器接 DB）** — 打开书从 DB 灌 `_revealedImageKeys`；`onImageRevealed`
  归一化 + 写 DB。
- **[ ] 阶段 C（诉求4：图片库遮罩 + 双向同步）** — 图片库传 bookKey，未揭图 blur + 点开写 DB，
  两端以 DB 为真值。
- **[ ] 阶段 D（诉求1/2：运行时失效根因，需真机复现确认）**

### ② 运行时失效根因（静态排序，待真机复现确认命中哪条）
1. **独立成章的纯图片页（BUG-487 路径）**：整章无 cue → `__hoshiRevealBlurredBetween`
   （`audiobook_bridge.dart`）永不执行 → 遮罩不揭；且 `_chapterTransition`/`_imageChapterPauseActive`
   长期持真（`audiobook_controller.dart` / `audiobook.part.dart`）→ 音频走但文字不跟。同时解释①②。
2. **章首（首句之前）插图 + 跨章后 `prev==null`**（`resetImagePauseAnchor` 归零）→ 章首插图
   既不暂停也不揭。
3. **`snapReaderToAudio`/`_onCueChanged` 早退吞 `_forceNextReveal`** → 恢复后不跟随。

- **[ ] ① 未修复** — 阶段 A 地基已落；B/C/D 待。
- **[ ] ② 部分自动化测试** — 归一化 + 迁移/DAO 守卫已加（见阶段 A）；运行时守卫待阶段 D。
- **备注**：⚠️ schema v46 与 PR#224（EpubBooks.completedAt，本会话并发，也占 v46）撞版本号，
  当前 develop 仍为 45；集成时**后合者改 47**。运行时诉求 1/2 声明「修好」前必须真机复测原始
  失败路径（CLAUDE.md 验证纪律）。
