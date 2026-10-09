## BUG-3191 · Emby 外挂 ASS 字幕加载失败
- **报告**：2026-10-09（群截图：选 Emby 条目的外挂「….ass / ass」轨弹「无法加载该字幕（可能是图形或不支持的字幕轨）」）
- **真实性**：⚠️ 部分复现。本机没有用户那台 Emby 与那份 ASS 样本，未能拿到真实字节。沿代码路径能确认的两处缺口：
  1. `fushi/lib/src/sync/jellyfin_video_client.dart` 取字幕一律手拼 `/Videos/{id}/{src}/Subtitles/{n}/Stream.{ext}`，从不用服务器在 PlaybackInfo 里为外挂交付签发的 `DeliveryUrl`（Emby 官方客户端取原格式字幕就用它）；
  2. `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` 的 `_showRemoteEmbeddedTrackViaPlayer` 对外挂文件轨（`isExternalFile`）直接返回 false：下载失败或本仓 ASS 解析器解不出 cue 时没有任何回落，只能报「无法加载」。截图里同一集的默认外挂字幕下载成功（「Fushi 互联服务端字幕」行在）却选不出来，最可能是后者（解析出 0 条 cue）。
- **[x] ① 已修复** — 本 PR：PlaybackInfo 解析字幕流的 `DeliveryUrl`，取流 / 下载优先用它（补成绝对地址并带令牌），失败再回落手拼端点；外挂文件轨下载失败或解析为空时，把它的 URL 原格式交给 libmpv（`sub-add`，libass 认的 ASS 写法比本仓解析器宽），只解码不画，文本回流成可点 cue（与 BUG-2648 同一条回流）；起播恢复 `embedded:<n>` 同样回落。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_emby_compat_test.dart`（DeliveryUrl 解析、轨 URL 用 DeliveryUrl、DeliveryUrl 失败回落手拼端点）；`fushi/test/pages/video_remote_embedded_subtitle_player_fallback_guard_test.dart` 钉外挂轨回落。
- **备注**：拿到用户的 ASS 样本 / 服务器后再确认解析为空的具体写法，必要时补 `ass_parser.dart` 的兼容。真机未复测。
