## BUG-4906 · 漫画分镜检测：暂时性失败被两层缓存、检测器并发创建泄漏 ONNX session
- **报告**：2026-11-20（路线图 #3722 gap-mangamisc-7，组 c38 复核）
- **真实性**：✅ 真 bug，两处根因（行号为 develop `7745effa2e`）：
  1. 失败结果被两层缓存：`packages/fushi_engine/lib/media/manga/panel_detection.dart:432` 把 prepare / 推理途中
     抛的异常收成 `failed` 结果，`:366` 不分青红皂白写进检测器 LRU；页面
     `fushi/lib/src/media/manga/reader/manga_fushi_page.dart:3766` 再把它写进 `_panelResults`。读页 IO 抖动、
     推理途中的一次异常之后，这一页在本次会话里再也翻不了分镜（按键直接退回整页翻页），只有重开书才恢复。
  2. 检测器创建没有在途去重：`manga_fushi_page.dart:3711` 每个调用方各自 `await factory()`（对 9.8 MB 模型算
     sha256 再建 ONNX session，秒级），`:3718` 后落地的覆盖先落地的，被覆盖的那份 session 永不关闭。分镜导航
     按键与制卡裁切（`_miningPanels`）同时触发就会撞上；本组同时加了翻页预热（manga-21），撞上的概率更高。
- **[x] ① 已修复** — `PanelDetectionResult` 加 `retryable`：抛错得来的失败标 `retryable: true`，检测器 LRU 与页面
  `_panelResults` 都不留它；解码失败（prepare 返回 null）是确定结论，照常缓存。新增 `PanelDetectorSlot`
  （检测器所有权槽）：在途创建只有一份，并发调用方等同一个 Future；槽关闭后才落地的检测器当场关掉；
  模型不可用 / 创建抛错不占槽。页面改持有槽，`dispose` 关槽。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/panel_detection_test.dart`：「抛错得来的失败不进缓存，下一次
  重试」「解码失败是确定结论，照常缓存」与 `PanelDetectorSlot` 组三条（并发只建一份、建造途中关槽当场关掉、
  不可用 / 抛错不占槽）。去掉修复后前者第二次调用仍拿到缓存的 failed、后者 `creates == 2`。
- **备注**：页面层 `_panelResults` 不缓存 retryable 的那一行没有独立的行为测试（入口要整个阅读页 State），
  靠检测器层测试 + 同一字段契约覆盖。
