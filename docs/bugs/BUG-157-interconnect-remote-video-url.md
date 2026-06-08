## BUG-157 · Hibiki互联远端视频URL被当成本地文件加载
- **报告**：2026-06-09（用户：Hibiki 互联无法加载对端设备视频）。
- **真实性**：是 bug。沿播放路径检查后，`VideoPlayerController.load()` 旧实现无条件用 `File(videoFile.path).uri.toString()` 打开媒体；当 `videoFile.path` 已是 `http://` / `https://` 远端视频 URL 时，会被改写成无效的本地 `file:///...http...` URI，media_kit 因此不能加载。根因落点：`hibiki/lib/src/media/video/video_player_controller.dart:309`。
- **[x] ① 已修复** - 提交：`fa271bb17`。新增 `mediaUriForVideoPath()`，HTTP/HTTPS 源保持原 URL，本地路径才转成 file URI；`player.open()` 改用该 helper。
- **[x] ② 已加自动化测试** - `hibiki/test/media/video/video_player_remote_uri_test.dart` 覆盖远端 URL 原样保留、本地路径转 file URI。
- **备注**：这条修的是“远端视频 URL 已进入播放控制器后无法加载”的根因；如果后续要做完整的互联远端视频列表/浏览 API，需要另开功能或 bug 路径补端到端验证。
