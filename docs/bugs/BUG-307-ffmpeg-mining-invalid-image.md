## BUG-307 · Windows ffmpeg invalid-image breaks mining audio and GIF extraction (TODO-458)
- **报告**：2026-06-17（用户：）
- **真实性**：✅ 真 bug。Windows CLI ffmpeg 返回 `-1073741701` / `0xC000007B`
  时，`extractClipGifViaFfmpeg` 与 `extractAudioSegmentViaFfmpeg` 只把结果折叠成
  `null`/普通退出码，调用侧无法知道实际命中的 executable、fallback 过程或
  `STATUS_INVALID_IMAGE_FORMAT` 根因（`hibiki/lib/src/utils/misc/desktop_audio_clipper.dart:391`、
  `hibiki/lib/src/utils/misc/desktop_audio_clipper.dart:612`）。视频制卡继续生成缺音频卡，
  有声书制卡则只显示泛化失败，用户看到的就是“句子音频没了”。
- **[x] ① 已修复** — `FfmpegRunResult` 携带 executable、attempted chain、fallback reason
  与 `failureSummary`；CLI backend 对 bundled/override/PATH/ffmpeg-kit 统一标注上下文，
  明确识别 `STATUS_INVALID_IMAGE_FORMAT / 0xC000007B`。音频裁剪和 GIF 裁剪支持
  `onFailure` 回传诊断，视频/有声书制卡把失败原因写入日志、OSD/toast，避免静默缺失。
  复核退回后补强：Windows release workflow 在 Inno 打包前直接执行最终 bundle 里的
  `hibiki\build\windows\x64\runner\Release\ffmpeg.exe -version`，并用该最终二进制作为
  `FFMPEG_MIN` 跑 `tool/ffmpeg-min/smoke-test.sh` 覆盖内封字幕、GIF、截图、封面与句子音频裁剪；
  MP4/MKV fixture 仍由 full ffmpeg 生成，避免为了 smoke 输入生成而扩最小构建的 encoders/muxers。
  视频制卡路径改为在已请求句子音频且裁剪失败时中止本次制卡，
  不再继续创建 `{sasayaki-audio}` 为空的成功卡；阅读器/有声书原有阻断行为保持一致。
  提交：本任务分支 `codex/todo-458-ffmpeg-mining-audio`（最终哈希见 TODO-458 看板 solution）。
- **[x] ② 已加自动化测试** — 覆盖 ffmpeg `-1073741701` 诊断、bundled fallback executable
  信息、音频/GIF 裁剪失败回调，以及视频/有声书制卡路径不静默丢句子音频。复核退回后新增
  extractor 级真实产物验证：模拟 bundled `STATUS_INVALID_IMAGE_FORMAT` 后回退到可用 ffmpeg，
  实际写出 `sentence.aac` 与 `clip.gif`；新增 release workflow 守卫，确保 Windows 打包流程
  在编译 installer 前烟测最终 bundle 内 ffmpeg。
  测试文件：`test/media/video/ffmpeg_backend_test.dart`、
  `test/media/video/ffmpeg_executable_resolve_test.dart`、
  `test/utils/desktop_audio_clipper_test.dart`、
  `test/pages/video_mining_context_guard_test.dart`、
  `test/reader/reader_mining_audio_guard_test.dart`、
  `test/build/release_workflow_diagnostics_guard_test.dart`。
- **备注**：本修复只收敛 TODO-458 的 Windows ffmpeg 制卡素材链路；未处理 TODO-448 AnkiConnect、
  TODO-457/459 updater、WGC、MouseTracker。真实安装包仍需 CI release workflow 跑过后复核产物；
  本地验证覆盖 release smoke 脚本；Windows release build 在本机生成 `runner\Release` 后卡在
  CMake install 写入 `C:\Program Files\hibiki` 的权限限制，未完成 installer 编译。
