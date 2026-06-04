# media_kit 真实 API 笔记（spike 锁定）

> 状态：骨架已建，待真实设备/模拟器逐项验证。
> 本会话探测到可用设备（Android emulator-5554 / Windows / 真机 CPH2747），
> 但完整 spike 需构建部署 app + 准备测试视频素材 + 写临时探针入口，属独立验证工作，
> 不在 Phase 0 / Task 0 范围内展开；保持骨架，逐项结论留待专门设备 spike 填写。
> 已确认版本：media_kit 1.2.6 / media_kit_video 2.0.1 / media_kit_libs_video 1.0.7。
> 全平台 video 原生库已随依赖引入（android/ios/linux/macos/windows_video 均为 transitive）。
> 测试宿主（纯 flutter test）无 libmpv-2.dll，`MediaKit.ensureInitialized()` 与
> `Player()` 构造必抛 "Cannot find libmpv-2.dll" —— 已知平台限制，smoke 测试已对真实
> 构造用 `skip:` 降级（见 hibiki/test/media/video/media_kit_smoke_test.dart）。

## 待验证清单
- [ ] 打开本地视频：`Player().open(Media('file:///<abs>'), play: false)` — URI 前缀/转义
- [ ] 当前位置：`player.state.position`（类型）；`player.stream.position` 更新频率
- [ ] 时长：`player.state.duration`
- [ ] 播放态：`player.state.playing` / `player.stream.playing`
- [ ] 控制：`play()` / `pause()` / `playOrPause()` / `seek(Duration)` / `setRate(double)` / `setVolume(?)`（确认音量范围 0-100 还是 0-1）
- [ ] 字幕轨枚举：`player.state.tracks.subtitle` -> `List<SubtitleTrack>`（字段 id/title/language）
- [ ] 切字幕轨：`setSubtitleTrack(SubtitleTrack)`；外挂 `SubtitleTrack.uri('file://...')`；关闭 `SubtitleTrack.no()`
- [ ] 当前显示字幕文本：`player.stream.subtitle` -> `List<String>`?（Phase 1 内嵌字幕查词关键）
- [ ] 截图（Phase 2 用）：`player.screenshot(format: 'image/jpeg')` -> `Uint8List?`，各端是否支持
- [ ] `VideoController(player)` 构造 + `Video(controller:)` 渲染
- [ ] dispose 时序：controller 与 player 谁先

## 验证结论
（设备验证后填写真实签名与行为，后续 Task 3/9 以此为准）
