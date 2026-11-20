## BUG-4906 · 内置网页播放器渲染进程死亡后回到起始页且重放循环不知情
- **报告**：2026-11-20（路线图 #3722 gap-webvideo-8，c29）
- **真实性**：✅ 真 bug（沿代码路径确认，基准 develop `7745effa2e`）。内置网页播放器页的死亡守卫
  （`fushi/lib/src/pages/implementations/web_video_fushi_page.dart:375` `WebViewDeathGuard(surface: 'web_video', …)`）
  只传了 `afterRebuild: setState`，没有 `flushBeforeRebuild`：
  - 重建出来的 WebView 用 `initialUrlRequest: URLRequest(url: WebUri(row.videoPath))`（`:3550`）回到书的起始页，
    站内换过集 / 看到一半的位置全丢；
  - 宿主 State 不随表面重建，死表面的 `_web` / `_viewId` / 最后一拍 `_state` / `_shaderActive` /
    静音预起 `_preStartedAudio`（绑在死前浏览器进程上）都留着当活的用；`_js`（`:1020`）对死控制器的
    `evaluateJavascript` 可能永不返回；
  - 可捕获档环境 `_capturableEnv` 是进程级单例（`fushi/lib/src/media/video/web_video_session.dart:63`），
    没有重建入口：浏览器进程死了以后新 WebView 仍建在废环境上（窗口宿主档在 `WebVideoSession` 里已有
    `discardWebVideoWindowedEnvironment`，内置档页没接）；
  - 重放循环不知情：`_navigateForMining`（`:1543`）在死页面上等满 30 秒后报 `timedOut`，
    `runWebMineQueueRows`（`fushi/lib/src/mining/web_mine_queue_run.dart:105`）把这一行标
    `navigate_timeout`、把视频记成「到不了」；正在录的那一句拿着死页面的停帧 / 空音频照样落成卡，
    后面的行接着在重建回起始页的页面上录。
- **[x] ① 已修复** — 页面接 `flushBeforeRebuild: _recoverFromProcessGone`：作废死表面的控制器 / 播放态 /
  超分确认 / 静音预起，记下死前页面（重建打开 `_surfaceUrl`），非重放时按死前快照 `_beginRestore`
  恢复集 / 轨 / 位置；`_surfaceGone` 让在途 `_js` 随表面作废；可捕获档补
  `discardWebVideoCapturableEnvironment()` 环境重建入口（旧单例不释放，见注释）。重放循环：
  `runWebMineQueueRows` 新增 `surfaceLost` 判据与 `WebMineQueueRowsEnd.surfaceLost`，表面换代时在途行
  留待办、不标 `navigate_timeout`、不报到不了；页面以 `WebViewDeathGuard.deathCount` 作表面的代，
  录完先验表面再落卡；自动跑遇到表面换代本次空闲放弃这本书。
- **[x] ② 已加自动化测试** — `fushi/test/mining/web_mine_queue_run_test.dart`
  「runWebMineQueueRows：重放表面进程死亡（BUG-4906）」4 条（行为规则）；
  `fushi/test/media/video/web_video_mine_queue_guard_test.dart`「BUG-4906」3 条（页面接线）。
- **备注**：没做桌面真机验证（杀 WebView2 渲染进程 / 浏览器进程后继续播、重放中途杀进程后行留在待办），
  本轮所有者定不做设备验证。
