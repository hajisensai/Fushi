## BUG-1058 · 入库精简 ffmpeg 缺 movtext 编码器，桌面片段导出永远封不进字幕
- **报告**：2026-07-24（用户：wrds）
- **真实性**：✅ 真 bug。根因不在代码逻辑，在**构建产物与构建配方脱钩**。
  - 配方 `tool/ffmpeg-min/build-ffmpeg-min.sh:55` 在 PR#369（`d9a1b438f`，2026-07-23）
    把 `movtext` 加进 `ENCODERS`；
  - smoke-test `tool/ffmpeg-min/smoke-test.sh:274-305` 同时加了 `mov_text` 编码器断言 +
    真封装校验；
  - 但入库二进制 `third_party/ffmpeg-min/windows/ffmpeg.exe`（最后一次更新
    `f443ca2a8`，早于 PR#369）**没有重新生成**。它内嵌的 configure 串是
    `--enable-encoder='gif,aac,mjpeg,png,libx264,ass,ssa,subrip,webvtt,pcm_s16le'`
    —— 无 `movtext`。
  - 结构性缺口：smoke-test 只在 `ffmpeg-min` workflow 里跑，且只跑**当场刚编出来的**
    二进制，从不跑入库的那个；没有任何检查把配方和 vendored 产物绑在一起。所以
    「改了配方 / 加了 smoke 断言」和「用户实际拿到的 exe」可以无限期漂开而 CI 全绿。
- **用户可见症状**：Windows 桌面端（用随包 ffmpeg 而非系统 ffmpeg 时）导出视频片段，
  勾了封入字幕也永远得到无字幕的 mp4。`-c:s mov_text` 直接 `Unknown encoder`，
  `exportVideoClipViaFfmpeg`（`hibiki/lib/src/media/video/video_clip_exporter.dart:355`）
  的降级重试静默吞掉，改跑无字幕的一轮 → 导出"成功"，字幕没了。
  该降级本身是对的（不能让增强把能成功的导出变成失败），坏的是它掩盖的前提。
- **[x] ① 已修复** — 重跑 `ffmpeg-min` workflow（run 30081667026，`ffmpeg_ref=n7.1.5`，
  三平台 smoke-test 全绿）并把 `ffmpeg-min-windows-x64` artifact 重新 vendor 到
  `third_party/ffmpeg-min/windows/ffmpeg.exe`。新二进制的 configure 串含
  `movtext`，`-encoders` 列出 `mov_text`，本地实跑 smoke-test 的字幕封装段通过。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/ffmpeg_min_vendored_recipe_guard_test.dart`。
  ffmpeg 把完整 configure 命令行以明文存进二进制，守卫据此**静态**（不执行 exe，
  Linux CI 同样有效）抠出它，与 `build-ffmpeg-min.sh` 的
  DEMUXERS/DECODERS/ENCODERS/MUXERS/FILTERS/PARSERS/BSFS/PROTOCOLS 八组清单逐项
  比对，外加 `--enable-gpl/libx264/network/schannel` 独立开关与 movtext 专项断言。
  今后任何「改配方不换二进制」都会当场变红，并在失败信息里给出重新 vendor 的步骤。
  修复前实测该守卫红（movtext 缺失 + 清单不一致），修复后绿。
- **备注**：同类风险面 = 所有手工 vendored 的构建产物。本守卫只覆盖 Windows 的
  ffmpeg-min（Linux/macOS 产物不入库，发布时现编，不存在漂移）。
