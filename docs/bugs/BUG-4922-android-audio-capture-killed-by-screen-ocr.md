## BUG-4922 · Android：开着 App 外内录时截屏识字会把内录停掉
- **报告**：2026-11-18（用户：应用内反馈 HuyzFGMK8E）
- **真实性**：✅ 真 bug。复现：开「App 外内录」→ 切到游戏 → 点悬浮球「截屏识字」→ 内录立刻停止。
  根因：两个功能各自向系统申请独立的 MediaProjection——内录在
  `fushi/android/app/src/main/java/app/fushi/reader/CrossAppAudioService.java:150`
  （`getMediaProjection`），截屏识字由 `ScreenCaptureRequestActivity.java:160`（develop 版本行号）
  弹确认框、`ScreenOcrService.java:305`（develop 版本行号）再 `getMediaProjection` 一次。
  系统同一时刻只留一个活的 MediaProjection，新的一到旧的就被停掉，内录的
  `MediaProjection.Callback#onStop`（`CrossAppAudioService.java:182`）随之收掉采集。
  缺的是「本 app 的投屏授权只有一份、谁在用谁借」这层所有权。
- **[x] ① 已修复** — 新增 `ProjectionShare`（`fushi/android/app/src/main/java/app/fushi/reader/ProjectionShare.java`）
  作为进程内唯一的投屏授权登记处：内录开始采集后登记自己的 projection，停止时先撤下（放掉挂在
  上面的虚拟屏）再停投屏。截屏识字发起时（`ScreenCaptureRequestActivity.launch`）先看有没有
  登记的授权，有就以 `ACTION_CAPTURE_SHARED` 起 `ScreenOcrService` 直接借它取帧——不弹确认框、
  不申请新授权、不进前台；同一 projection 上的虚拟屏只建一次（Android 14 起第二次
  `createVirtualDisplay` 抛 SecurityException），之后每次借用 `resize` + `setSurface`，收尾只摘
  surface、注销回调，不停投屏。内录停了（撤下）之后借用方不再碰已放掉的虚拟屏。
- **[x] ② 已加自动化测试** — `fushi/android/app/src/test/kotlin/app/fushi/reader/ProjectionShareTest.kt`
  （借到同一授权、虚拟屏一份反复借用、撤下先放虚拟屏且借用方失效、旧授权的迟到撤下不影响新授权）。
- **备注**：反向次序（先开「保持截屏会话」再开内录）仍是内录弹确认框拿新授权、系统停掉截屏识字
  那份保持会话；之后截屏识字借内录的授权，两边都能用，不丢功能。未在真机复测原始失败路径
  （本轮无 Android 真机），待补。反馈里的其余诉求（OCR 句子带内录音频发卡、自选截图范围、
  PC 端全局截屏 OCR + loopback 内录）是功能建议，走拍板台，不在本条范围。
