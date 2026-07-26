## BUG-1115 · Bangumi 已有想看收藏在记录进度后未切换为在看
- **报告**：2026-07-27（用户：看完中间集后 Bangumi 仍显示「想看」，要求中间集为「在看」、最后一集才为「看过」）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/tracking/media_tracking_service.dart:552` 的 `_syncEpisodeProgress` 修复前只在收藏不存在时创建「在看」，以及 `outbox.completed` 且到达末集时切「看过」；已有收藏为「想看 / 搁置 / 抛弃」时，成功写入章节后没有任何状态迁移，所以真实账号第 2 集已同步、收藏状态却仍为「想看」。实机回归还确认了第二层问题：旧事件的 outbox 已成功清空，已完成视频重开会从片头播放，不能靠用户重播可靠地产生旧完成事件。
- **[x] ① 已修复状态语义** — `hibiki/lib/src/media/tracking/media_tracking_service.dart:579` 集中决定目标状态：已「看过」不因重看前集降级；进度达到 Bangumi 当前 subject 的最后一集切「看过」；其余有效观看进度统一切「在看」。状态更新排在章节写入成功之后，章节 API 失败时不制造虚假的远端状态。
- **[x] ② 已补历史完成事实校正** — `hibiki/lib/src/media/tracking/media_tracking_repository.dart:244` 从单集或合集成员的 `completedAt` 增量重建已完成进度；`hibiki/lib/src/media/tracking/media_tracking_service.dart:437` 在正常同步前可靠入队。校正水位会随本地完成事实/映射更新时间推进，更换 Bangumi token 时归零，不会每次启动重复写远端。
- **[x] ③ 已加自动化测试** — `hibiki/test/media/tracking/media_tracking_service_test.dart:182` 覆盖想看→在看，`:216` 覆盖最后一集→看过，`:250` 覆盖重看前集不把看过降级，`:285` 覆盖 outbox 已清空的历史单集自动修复，`:333` 覆盖合集按最高已完成成员恢复进度。
- **备注**：
  - 真实账号实机验证通过：新构建启动后无需重播，第 2 集的本地完成事实自动补发；条目 `425998` 从「想看」移出并出现在「在看」，账号计数由「想看 2 / 在看 15」变为「想看 1 / 在看 16」，同步队列为 0。
