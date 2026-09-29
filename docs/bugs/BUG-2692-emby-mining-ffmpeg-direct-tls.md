## BUG-2692 · Emby/Jellyfin 能播放但制卡三条抽取全报 I/O error
- **报告**：2026-09-26（用户转述：Emby 视频能正常播放，但制不了卡。报错日志三条同形：`extractVideoFrameViaFfmpeg` / `extractClipGifViaFfmpeg` / `extractAudioSegmentViaFfmpeg` 各自 `ffmpeg exit 1; executable=ffmpeg-kit; ... stderr=https://<emby>/Videos/<id>/stream?static=true&MediaSourceId=…&PlaySessionId=…&DeviceId=hibiki-app&api_key=…: I/O error`，移动端）
- **真实性**：✅ 真 bug。播放与制卡走的是两条不同的取流路径：
  - 播放：`video_player_controller.dart` 的 load 把地址过 `nativePlaybackUri`（`app_native_proxy.dart:96`），https 降成明文交给本机中继，由中继用 Dart 的 TLS（系统信任根）+ 应用代理（`createAppHttpClient`）升回 https 取字节。
  - 制卡：`lookup_mining.part.dart` 只对 `RemoteVideoStreamHeaders`（在线视频源扩展 / 粘贴的流，BUG-2642 残留）调 `relayFfmpegRemoteInput`；Emby / Jellyfin 的 `JellyfinVideoClient` 没有这个能力，于是 `controller.miningSource`（原始 https 地址）原样交给 ffmpeg，移动端 ffmpeg-kit 用自己编进去的 TLS 直连、也不认应用代理，打开输入即失败。旧源码守卫还特意写了「媒体服务器不能一起改道」，但媒体服务器在制卡侧并没有任何专用通道。
  - `I/O error`（`AVERROR(EIO)`）是 ffmpeg 在 TLS 握手失败或上游回非 4xx 错误码时的统一收敛；stderr 只留最后一行、具体是哪一种在用户日志里看不出来，本机也没有该用户的设备与凭据可直接复现 ffmpeg-kit 那一侧。修法不依赖区分这两者：让制卡 ffmpeg 与已经能播放的播放器走同一条路径。
  - 互联主机（`InterconnectSyncBackend`）不在此列：它有 `-tls_pin_sha256` 钉扎（只对 https 输入有效）与 host 端裁音频（BUG-1004）两条专用通道。
- **[x] ① 已修复**（PR 分支 `pr/emby-mining-https` 首个提交）— 抽出判据 `videoMiningInputUsesPlaybackRelay`（`lookup_mining.part.dart`）：网络地址且 client 是 `RemoteVideoStreamHeaders` **或 `MediaServerBrowser`** 时改走中继；互联主机 / 本地 / YouTube 不变。
- **[x] ② 已加自动化测试** — `fushi/test/mining/media_server_mining_relay_test.dart`：判据行为（媒体服务器 / 在线源命中，其它远端 client / 本地 / 无 client 不命中，生产类型的接口归属钉死）+ 端到端（真捆绑 ffmpeg-min + 真本机中继 + 自签 https 的 Emby 形状原点 `/Videos/{id}/stream?static=true&…&api_key=`，抽出句子音频与截图、查询串原样送达）。`remote_mining_relay_route_test.dart` 的源码守卫改为钉「只经这个判据改道」。
- **备注**：未在用户的真机 / 真服务器上复测（没有该设备与凭据）；需要用户更新后确认。
