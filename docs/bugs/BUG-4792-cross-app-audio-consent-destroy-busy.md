## BUG-4792 · 跨应用语音授权页被系统以非 finishing 方式销毁后，start 永远挂着，之后每次开启都回 busy
- **报告**：2026-11-17（#3621 合入后的只读核实遗留项）
- **真实性**：✅ 真 bug。`fushi/android/app/src/main/java/app/fushi/reader/CrossAppAudioRequestActivity.java:135`（修前）`onDestroy` 只在 `owesResult && isFinishing()` 时 `completeStart`。系统回收 / 从最近任务划掉等非 finishing 销毁之后 Activity 未必重建，`CrossAppAudioChannel.pendingStart` 不清空，`CrossAppAudioChannel.java:129-130`（修前行号）之后每次 `start` 都直接回 `busy`，直到进程重启。
- **[x] ① 已修复** — 判据抽成纯函数 `CrossAppAudioPolicy.releasesPendingStartOnDestroy(owesResult, isChangingConfigurations())`：只有配置变更重建（同进程马上有新实例接着等回调）才不结账，其余销毁一律 `completeStart(false, "denied")`（`CrossAppAudioRequestActivity.java:134-142`）。重复结账无害：`completeStart` 没有挂起请求时什么都不做；授权结果若之后仍到达并起了服务，状态经 StateListener 的 `onState` 推给 Dart。
- **[x] ② 已加自动化测试** — `fushi/android/app/src/test/kotlin/app/fushi/reader/CrossAppAudioPolicyTest.kt` 的 `nonConfigChangeDestroyReleasesPendingStart` / `configChangeRecreateKeepsWaiting` / `nothingOwedNothingReleased`（JVM 单测，CI 由 `main.yml` 的 `:app:testDebugUnitTest` 步骤执行）。
- **备注**：未做真机验证（需在授权框弹出时由系统回收 Activity）。
