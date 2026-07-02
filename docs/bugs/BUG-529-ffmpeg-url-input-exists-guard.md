## BUG-529 · 制卡 ffmpeg 抽取器 existsSync 守卫拦 http(s) 流 URL + 无网络韧性致 GIF 间歇失败
- **报告**：2026-07-02（TODO-1000 油管制卡链路验证时发现）
- **真实性**：✅ 真 bug（真网络+真 ffmpeg 复现）。两重根因：
  1. `desktop_audio_clipper.dart` 的三个制卡抽取器（`extractClipGifViaFfmpeg` / `extractAudioSegmentViaFfmpeg` / `extractVideoFrameViaFfmpeg`）开头都 `if (!File(inputPath).existsSync()) return null;`。YouTube 分离流的 inputPath 是 http(s) 流 URL，文件系统里当然不存在 → **直接早退 return null，从流 URL 抽 GIF/音频/帧永远失败**（制卡拿不到媒体）。
  2. 从 googlevideo 流抽取无网络韧性：ffmpeg 打开 googlevideo URL 会**间歇性丢连**（实测 `Error number -138` opening input，多帧 GIF 读取更易撞上），无重连 → GIF 间歇失败，制卡降级成静帧（甚至无媒体）。
- **根因** `hibiki/lib/src/utils/misc/desktop_audio_clipper.dart` 三处 `existsSync` 早退 + 三个 `buildFfmpeg*Args` 无网络重连开关。
- **[x] ① 已修复** — 提交 `<pending>`：
  - 加 `_isRemoteFfmpegInput(inputPath)` 谓词，三个抽取器的 existsSync 守卫改为「仅对本地路径」检查，http(s) URL 放行给 ffmpeg（ffmpeg 自吃 http 输入）。
  - 加 `buildFfmpegRemoteInputArgs(inputPath)`：http(s) 输入在 `-i` 前注入 `-user_agent Mozilla/5.0 -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5`（本地返回空、不影响既有本地路径）。三个 `buildFfmpeg*Args` 都注入。实测：间歇失败的 muxed GIF 抽取变成稳定 277KB 产出。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/utils/desktop_audio_clipper_url_input_test.dart`：断言 `debugIsRemoteFfmpegInput` 判定、URL 输入不被当缺失文件早退、三个 builder 对 http 输入注入 `-reconnect`（且在 `-i` 之前）、本地输入无网络开关（保持原 arg 形状）。
  - `hibiki/test/mining/youtube_immersion_live_engine_test.dart`（opt-in HIBIKI_YT_LIVE_ITEST=1）：真引擎从直播流抽 GIF+音频。**实测通过：cover=immersion_clip.gif（真 GIF 非降级静帧）+ 真音频**。
- **备注**：与 [[BUG-528]] 同属 TODO-1000 油管制卡链路。既有 `buildFfmpeg*Args` 单测用本地路径，remote args 对本地返回空、位置不移，无回归。
