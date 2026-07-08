## BUG-616 · 老 {book-cover} 模板视频制卡也产 GIF（向后兼容超集，无需手改）
- **报告**：2026-07-08（用户：卡组里 Picture 字段还是 {book-cover}，担心必须手改成 {card-image}）
- **真实性**：❌ 非代码 bug（已验证行为正确）。用户诉求「老 {book-cover} 模板视频制卡也要出图、不想手改」在 origin/develop 上**已满足**。沿真实代码路径核对：
  - `{card-image}` / `{book-cover}` / `{video-clip}` 三键都读同一个 `context.coverPath`：`packages/hibiki_anki/lib/src/anki_models.dart:462-469`。
  - 视频制卡时 `context.coverPath` 就是 GIF/降级帧：`hibiki/lib/src/mining/immersion_mining_engine.dart:76`（GIF）→ `:94`（单帧降级）→ `:106`（截图兜底）→ `:162`（组进 `AnkiMiningContext.coverPath`）。
  - 两 backend 都是**按值不按名**把 coverPath 落盘成媒体引用、回填同一 coverPath 字段再渲染，与 handlebar 名无关：AnkiConnect `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:551-581`；AnkiDroid `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart:288-311` + `:566-574`。
  - 结论：老 note-type 的 `Picture -> {book-cover}` 在视频卡上产出与 `{card-image}` **逐字节相同**的 `<img src="hibiki_cover_<sha>.gif">`，**用户不用手改模板**。`{card-image}`（TODO-1298 / commit 63b0685f9）只是把名不副实的默认键重命名成语义中性键，属**纯展示层重命名**，功能零变化。
- **[x] ① 无需代码修复** — 行为已正确（见上根因链）。TODO-1298 的重命名保留了 `{book-cover}`/`{video-clip}` 作完整功能别名，Never break userspace。未改任何运行时代码。
- **[x] ② 已加自动化测试** — `packages/hibiki_anki/test/card_image_video_mining_e2e_test.dart`：走完整 `mineEntry` 落卡链（真 `.gif` → 存媒体 → 渲染字段），断言映射到 `{book-cover}` 的 Picture 字段在视频卡上真拿到 `<img src="hibiki_cover_<sha>.gif">`，且与 `{card-image}`/`{video-clip}` 逐字节相同；AnkiConnect + AnkiDroid 两后端对称，含 coverPath=null 留空守卫。此前 `handlebar_card_image_test`/`handlebar_video_clip_test` 只覆盖孤立 renderer，未覆盖真实落卡链——本测补上这一环，锁死「老模板视频卡出图」不回归。5 tests green。
- **备注**：给用户的答复——不用手动改，`{book-cover}` 与 `{card-image}` 完全等效（书内产书封、视频内产 GIF/截图）。真机验收步骤见提交说明。
