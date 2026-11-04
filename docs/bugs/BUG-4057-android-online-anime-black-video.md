## BUG-4057 · Android 在线动画源视频全部黑屏（只有播放器界面）
- **报告**：2026-11-03（反馈 l0Cygl4B2X，标题「all anime」，正文印尼语：「所有动画视频都没有画面，换成 skia 或 default 也一样全黑，只有播放器界面」；vivo V2157 / Android 14（SDK 34）/ arm64 / app 3.0.0+1001976302，界面语言 en、系统 ja_JP，0 张截图）
- **真实性**：❓ 未复现，证据不足以定位，不改代码。
  - 本条被分到「刮削」组是误分：诉求是**播放**（在线动画源取流后的画面），与刮削 provider / AniDB 限流无关。
  - 日志（最后 400 行）里与视频相关的只有两条 `VideoFushi.remoteSubtitle`：在线动画源
    （Mihon 动画扩展，`AnimeSourceVideoClient.getRemoteVideoSubtitle`
    `fushi/lib/src/media/video/online/anime_source_video_client.dart:483`）的外挂 `.vtt` 字幕下载
    HTTP 403——只影响字幕，不会让画面变黑。其余是 Google Drive 同步断网、Mihon 漫画源 523 /
    InterruptedIOException、`getLatestAnime` UnsupportedOperationException（某扩展不支持「最新」列表），
    都与画面无关。日志里**没有任何 `[VIDEO-DIAG]` 行、没有 mpv 打开 / 首帧 / 纹理握手记录**，
    无法区分下面几种互斥的根因：
    1. **渲染合成层**（BUG-535 / BUG-597 那一类：解码出帧但 Flutter 纹理不出画）。用户说「换 skia /
       default 也一样」——app 内已无渲染后端开关（五端全线 Impeller，`docs/agent/rules-detail.md#impeller`），
       这里大概率指 Android 开发者选项里的 HWUI 渲染器，它不改变 Flutter 引擎自己的后端，所以这句话
       排除不了也坐实不了合成层问题。
    2. **取流 / 分片层**：伪装成图片的 HLS 分片（BUG-2609，中继剥前缀
       `fushi/lib/src/utils/net/hls_relay_normalizer.dart`）或分片扩展名白名单
       （BUG-2630，FFmpeg `extension_picky`）在某个扩展 / CDN 上没覆盖到时，表现是起播即 EOF 或无画面。
    3. **只发生在某一个扩展**：日志里的 CDN 只有一个（字幕域名同一家），「所有动画」可能就是「这个扩展的所有集」。
  - 无同型号真机、无该扩展的真流，本轮无法复测。
- **[ ] ① 未修复** — 需要的证据（任一即可推进）：同一集播放时的完整诊断日志（含 `[VIDEO-DIAG]`
  texture id / wid / vo / 首帧行）、有没有声音、进度条是否走动 / 是否一开就到片尾、所用扩展名称；
  本地视频文件是否同样黑屏（区分合成层与取流层）。
- **[ ] ② 未加自动化测试** — 根因未定位。
- **备注**：未复现；不属于刮削域。
