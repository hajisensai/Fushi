## BUG-1513 · 发现订阅跳过所选首集
- **报告**：2026-08-10（用户：）
- **真实性**：✅ 真 bug。发现订阅页会把用户选中的 release 集数预填为 `startAfterEpisode`，但创建订阅时不会直接下载该 release；调度器又用 `episode <= startAfterEpisode` 过滤，因此选择第 1 集会稳定地从第 2 集开始。
- **[x] ① 已修复** — 新版 `organizationPolicy == library` 订阅把该字段解释为包含式起点（“从第 N 集开始”）；旧版订阅是在当前种子已成功推送后才创建，继续保留“第 N 集之后”的兼容语义。创建页与订阅卡片文案同步改为包含式起点。
- **[x] ② 已加自动化测试** — `video_download_subscription_service_test.dart` 以第 1 集为起点，断言第 1、2、3 集都生成持久 outbox 与下载任务，同时保持分页、去重和 lease 全套回归通过。
- **备注**：该兼容分流也会修复升级前已由新版发现页创建、但尚未下载首集的订阅。
