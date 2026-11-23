## BUG-5224 · 互联流媒体书：等 host 清单期间本机删掉的仍被注册给 host
- **报告**：2026-11-22（第三方审查 HBK-AUDIT-213，[#4094](https://github.com/hajisensai/Fushi/pull/4094) 引入）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/sync_orchestrator/videos.part.dart:84`（修前）在 `await backend.listRemoteVideos()` 之前就读了本机 `allVideoBooks()` 快照；`stream_videos.part.dart:107`（修前）`_pushStreamVideosLive` 直接拿这份快照逐条 `putRemoteStreamVideo`，中间还隔着能力探测、host 墓碑 GET 和前面几条 PUT 的网络往返。这段时间里用户删掉的本机独有流媒体书（仅本机删除不写墓碑；「从所有设备删除」的墓碑也还没送到 host）照样被注册给 host，随后在别的设备上被拉成新书（复活）。
- **[x] ① 已修复** — 先等 host 清单、再读本机快照；推送前按 uid 逐条重读当下的行（`getVideoBookByBookUid`），没了就不发、还在就用当下内容注册。只有待推的行才多读，两端已对齐的稳态一轮 SQL 条数不变。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_stream_video_sync_test.dart`：「清单 GET 期间本机删掉的流媒体书不注册给 host」「本机快照之后、注册 PUT 之前删掉的流媒体书不注册给 host」（真实 server / host，后端子类在网络往返中途删行，断言零 PUT、host 无行）。
- **备注**：
