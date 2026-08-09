## BUG-1473 · gal 制卡慢：画面与语音串行 + 静态截图全分辨率 PNG 直送 Anki
- **报告**：2026-08-09（用户：只能逃跑了）
  - 原话：gal 制卡很慢。
- **真实性**：✅ 真 bug（两处独立缺陷叠加）。先排除了两个常见嫌疑：词典富化不在
  制卡路径上（`fields` 是查词阶段就构造好的 Map，`gal_hook_mining_coordinator.dart`
  只透传），Anki 写入已是 `Future.wait` + 一次 `addNote`（[[BUG-166]] 已修且有守卫）。
  - **① 画面与语音串行**：`gal_hook_mining_coordinator.dart` 里封面阶梯与
    `_captureAudio` 是两个先后 `await`，而两者之间**没有任何数据依赖**。
    [[BUG-1205]] 的并行修复只落在 `immersion_mining_engine.dart:285-295`，而 gal 走的是
    `providedCoverBytes` / `providedAudioBytes` 分支 —— 进引擎时两者都已经在协调器里
    串行做完了，**引擎里的并行对 gal 完全是空转**。真正该并行的位置在协调器。
  - **② 静态截图零压缩**：`imageMode.isStill` 分支把 `still.pngBytes` **原样**送出，
    绕过了视频侧用的 `downsampleCardScreenshotAsync`（[[BUG-933]] 已把 decode/resize/
    encode 卸到后台 isolate）。1080p/4K 无压缩 PNG 通常 1.5~4 MB，而 `compression`
    参数明明已经从 `texthooker_page.dart` 传进来了却没被用上。GIF 失败后的降级路径
    同样如此。
- **[x] ① 已修复** — 语音抓取改成先启动、拿到封面后才 `await`（照抄视频侧 BUG-1205
  的 `catchError` 暂存 + 末尾重抛，保持与串行版逐字一致的抛出语义，避免封面先抛时
  在途 Future 变成 unhandled async error）；两处单帧截图统一走
  `_downsampleStill`。**文件名按实际产出字节定**（嗅 JPEG 魔数 FF D8 FF），
  不按意图定 —— 降采样器在「图本来就小 / 解不开」时原样返回入参 PNG，硬拼 `.jpg`
  会让 Anki 按扩展名判成「.jpg 里装 PNG」→ 图不显示。这与同文件动图那处
  「文件名一律取实际产出格式」是同一条规矩。
- **[x] ② 已加自动化测试** — 新建
  `fushi/test/mining/gal_hook_mining_parallel_capture_test.dart`：两条捕获都用
  Completer 挂住，要求两个 Started 都亮才放行。⚠️ 判据必须是「两条同时在途」，
  单向挂住是假绿（视频侧那条守卫已用变异实测证过两个方向的假绿）。
  已做变异实测：把协调器改回串行即红。既有
  `gal_hook_mining_coordinator_test.dart` 一并复跑，15 tests PASSED。
- **备注**：⚠️ **还有两块没动，是本条的已知剩余成本**：
  - **封面抓帧循环**：`galgame_window_gif.dart:36-38` 默认 `frames=10, intervalMs=120`，
    而调用方 `_defaultCaptureGif` 一个都不传 → 9×120ms = **1080ms 纯 sleep**；
    更贵的是 native 侧**每帧全量重建整套捕获栈**（`window_capture.cpp` 的
    `CreateD3DDevice` → 新建 FramePool → StartCapture → 等首帧(超时 1500ms) →
    全分辨率 WIC PNG 编码，跨帧零复用，`RoInitialize`/`RoUninitialize` 都在单帧函数里）。
    根治要 native 加 burst 接口复用 D3D 设备与 FramePool；单纯调小 `frames`
    是改产品行为不是修根因，故本轮不动。
  - **ffmpeg 冷启动 2~3 次/卡**：`resolveFfmpegBackend()` 只缓存**后端选择**不缓存进程；
    动图默认 avif，编码器缺失时必然先失败一次再降 GIF。可一次性探测 avif 可用性缓存起来。
  - 量级均为**推测**（单帧 WGC 60~150ms、ffmpeg 冷启 50~200ms、1080p PNG 1.5~4MB），
    未实测。继续优化前建议在 `_mineLineNow` 各阶段插 `Stopwatch` 实测确认排序。
