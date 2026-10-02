## BUG-2866 · Windows 上 SMB/NAS 共享（UNC 路径）里的视频打不开
- **报告**：2026-10-02（用户群反馈：2.9.0 放在 NAS 上、经 SMB 访问的视频一打开就报「播放器打不开该视频。文件可能被占用……」，拷到本机硬盘才能播）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_player_controller.dart` 的 `mediaUriForVideoPath` 对本地路径一律 `File(path).uri.toString()`：UNC 路径 `\\NAS\Video\x.mkv` 变成 `file:///NAS/Video/x.mkv`（或 `file://NAS/…`，主机名都会丢——media_kit 依赖的 uri_parser 会把 `file://` 后的斜杠统一改成三斜杠）。media_kit `Media.normalizeURI` 再把它还原成 `\NAS\Video\x.mkv`，`_sanitizeUri` → `addPrefix` 又补 `\\?\`，libmpv 实际打开的是本机当前盘根下不存在的目录，报 `Cannot open file … Invalid argument`；duration/position 恒 0，页面 BUG-2441 的 15 秒宽限到点判「打不开」。与「占用」无关，文案里的「可能被占用」只是兜底猜测。
  - 实测（随包 libmpv v0.41.0-923，本机共享 `\\localhost\smb`）：只有反斜杠裸 UNC `\\host\share\file` 能开；`//host/…`、`file:///host/…`、`file://host/…`、`file:////host/…` 全部失败。裸 UNC 交给 media_kit 后被 uri_parser 归一为 `//host/…`、`addPrefix` 识别网络前缀还原为 `\\host\…` 且不加 `\\?\`，libmpv 正常打开。
  - 真链路探针（临时 `flutter test`，真 media_kit `Player` + 随包 libmpv）：修前 `file://localhost/smb/fushi_probe.mp4` 8 秒内 duration 恒 0；修后 `\\localhost\smb\fushi_probe.mp4` → 2.79 s，正常打开。
- **[x] ① 已修复** — `mediaUriForVideoPath` 对 Windows UNC 路径（`isWindowsUncPath`：`\\server\…` / `//server/…`，排除 `\\?\` / `\\.\` 设备命名空间）原样返回裸路径；盘符路径与其它平台行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_remote_uri_test.dart`（UNC 裸路径透传 + UNC 判据负例）。
- **备注**：映射成盘符（`Z:\`）的网络盘本来就能播，只有直接用 `\\NAS\…` 路径添加的媒体库受影响。Android / Apple 的 SMB 走各自挂载路径，不经此分支。
