## BUG-2694 · AI 下视频入口在未指派 AI 时整颗隐藏，Windows/Mac 都找不到
- **报告**：2026-09-26（用户：Mac 上「没看到有」、Windows「也找不到，修复一下」）
- **真实性**：✅ 真 bug。入口门 `fushi/lib/src/pages/implementations/home_page.dart` `_canAiAcquire` 要求 `resolveVideoAcquireAiProvider(...) != null` 且 `videoResourceRegistry` / `videoDownloadPipelineService` 已起，任一不满足 `onAiAcquire` 就是 null，发现页搜索行（`video_discovery_page.dart`）整颗按钮不渲染；`AiFeatureAssignments.resolve`（`fushi/lib/src/ai/ai_feature.dart:101`）对未单独指派的功能直接返回 null、不借用别的功能的提供商。新装用户两个条件都不满足，入口永远不存在，也没有任何线索提示要先去「设置 › AI」指派。
- **[x] ① 已修复** — 入口门只剩「偏好就绪 + downloads / externalDiscovery 两道合规门」；`_openAiVideoAcquisition` 点击时若未指派 AI → snackbar 说明 + 推「设置 › AI」页（`_pushAiSettings`），返回后已指派即继续进对话页；runtime 没起沿用原有 `_promptDownloadBackendSetup` 引导。
- **[x] ② 已加自动化测试** — `fushi/test/pages/ai_video_acquire_entry_guard_test.dart`（源码扫描：入口门不含 AI / runtime 判据；点击路径推 AI 设置并重判）；`fushi/test/build/ios_store_compliance_guard_test.dart` 同步改钉新入口门形态。
- **备注**：未在真 app 里点过（入口渲染由 `video_discovery_page_test.dart` 的 onAiAcquire 非空即渲染测试覆盖）。
