## BUG-1416 · Netflix 沉浸捕获选静态帧时取的是片段首帧，不是制卡那一刻的帧

- **报告**：2026-08-02（用户：TODO-2521 后半，用户拍板「肯定是按制卡时候的时间来，不要后续点击再回来制卡」）
- **真实性**：✅ 真 bug（两层根因）
  - 根因 A（偏好被结构性吞掉）：`hibiki/lib/src/models/app_model.dart:6172-6207` 的 Netflix 段恒经
    `buildImmersionRequest` 下发 `providedCoverBytes`，而引擎的 `imageMode` 阶梯在
    `hibiki/lib/src/mining/immersion_mining_engine.dart:296-320` 藏在 `if (coverPath == null)` 里
    —— 有 provided 字节时那个 switch **根本不会被求值**。所以「动图 / 制卡时截图 / 字幕开头截图」
    这个偏好在 Netflix 这条链路上恒被吞成动图（TODO-2519 只接了 YouTube 那一半，Netflix 半边留到本条）。
  - 根因 B（时刻信息压根没传下来）：浏览器扩展 `tools/browser-extension/content.js` 的
    `hibikiEnqueue` 只把字幕 cue 窗 `startV/endV`（±200ms 录制边距）存进队列，**不记录用户按下
    制卡键那一刻的 `video.currentTime`**；`background.js` 的 `mineClip` 也只发
    `clipBase64/clipDurationMs/documentTitle`。因此即使修好 A，也只能取到片段首帧（= 句首 −200ms
    −起播推进量），而不是制卡那一刻的帧。这不是「加个参数」能了的，必须把那一刻沿链路传下来。
- **[x] ① 已修复** — 三段一起改（同一 PR，wire 两侧同时落地）：
  - 扩展：入队时就地采样制卡时刻视频时间（只在它落在本句 cue 窗内时才记，面板行查词停在别句的
    情况不记）；批量录制在 `beginClip` **前后各采一次** `v.currentTime` 取中点，实测下发片段的
    时间基锚点 + 其误差上界；`mineClip` 新增 `clipAnchorMs` / `clipAnchorUncertaintyMs` /
    `cueStartMs` / `mineAtMs` 四个可选字段（老版扩展不发 → 全 null，向后兼容）。
  - Dart：`ImmersionMinePayload` 解析四字段；新纯函数 `resolveClipStillTarget` 把「视频时间」
    换算成片段内偏移；`transcodeClipToCapture` 在静态帧模式下不编动图、改抽单帧；
    `ImmersionCaptureResult.coverIsStill` 让封面名走 `netflix_frame.jpg`（Anki 按扩展名判 MIME）。
  - ffmpeg：`buildFfmpegFrameArgs` 新增 `decodeFromStart` —— 录制片段是 `MediaRecorder` 产出的
    **无 Cues 索引** webm，`-ss` 放 `-i` 前的输入定位会落到最近关键帧（正是本条明令禁止的糊弄）；
    静态帧走输出定位（`-ss` 在 `-i` 后，从 0 解码丢弃到目标时刻）。长视频/书架封面保持默认输入定位。
  - 误差账（正面回答，不含糊）：锚点误差 = 扩展实测的 `clipAnchorUncertaintyMs`（`recorder.start()`
    必落在两次采样之间，故真值必在 `锚点 ± 该值` 内），随请求下发并写进诊断日志；不可约项是
    **采集帧率量化** —— `offscreen.js` 的 `maxFrameRate: 12` 决定片段里最多每 83ms 才有一帧，
    ffmpeg 取「pts ≥ 目标」的第一帧，故 **做不到一帧（源 ~42ms）以内**，总偏差约
    `实测锚点不确定度 + ≤83ms(采集帧量化) + ≤42ms(源帧采样)`。相对现状（首帧 = 句首，可差数秒）
    是数量级改善，但「一帧内」做不到，如实记在此。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/netflix_still_frame_mine_time_test.dart`（19 用例）：
  静态帧只出单帧不进动图链 / 取的是制卡时刻而非首帧 / 锚点与句首有偏移时仍取对 / 动图偏好零回归 /
  `decodeFromStart` / wire 解析与向后兼容 / ffmpeg 定位方式 / 两条源码扫描守卫（app_model 的 Netflix
  段必须真解析并下发 stillTarget；扩展两侧必须采样并转发）。11 处变异实测逐条转红。
- **备注**：本条只做「clipBytes（扩展录制片段）」这条**真实可达**的路径。同文件里
  `ImmersionCaptureChannel.capture`（native 后台软解实例）分支要求 `netflixVideoId + clipStartMs
  + clipEndMs`，而扩展的 `mineClip` 从不发 `netflixVideoId` → 那条分支从扩展侧不可达（TODO-2521
  前半，用户未表态，本轮按建议保留不删）。`screenshotBase64`/`timestampMs` 在本仓无任何生产者，
  `buildImmersionRequest` 里的 2A 截图降级同样只在测试里被触达。
  用户要真正用上本条修复需**更新浏览器扩展**（app 启动会把内置副本刷到 `<appSupport>` 并自更新，
  见 `background.js` 的 `maybeSelfReload`）；只更新 app 不更新扩展时，静态帧仍出片段首帧并在诊断
  日志里标 `exact=false`。
