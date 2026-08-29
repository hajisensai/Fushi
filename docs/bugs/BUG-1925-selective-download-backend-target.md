## BUG-1925 · 选择性下载仍调用已删除的后端身份接口导致 Windows 构建失败
- **报告**：2026-08-29（集成 CoreAudio 选择性下载后首次 Windows Debug 构建发现）
- **真实性**：✅ 真 bug。`download_actions.dart` 仍构造
  `VideoDownloadManualEnqueueRequest(backendIdentity: ...)`，但 BUG-1879 已把新任务
  接口收口为带分类快照的 `backendTarget`，并删除了公开的
  `currentVideoDownloadBackendIdentity()`。真实 `flutter build windows --debug`
  因这两个不存在的符号编译失败。
- **[x] ① 已修复** — 选择性下载先读
  `currentVideoDownloadBackendTarget()`，再通过 `backendTarget` 传入手动任务，
  同时保留后端实例与当前分类的快照语义。
- **[x] ② 已加自动化测试** —
  `downloads_center_contract_guard_test.dart` 钉死新 target API/参数，并禁止旧
  identity API/参数回流。
- **备注**：按用户要求不运行测试套件；本轮以 Windows Debug 真实构建作编译验证。
