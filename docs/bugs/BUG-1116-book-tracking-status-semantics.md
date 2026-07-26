## BUG-1116 · Bangumi 小说/漫画阅读进度未按语义切换在读与读过
- **报告**：2026-07-27（用户：番剧状态语义修复后，要求小说部分同样支持）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/tracking/media_tracking_service.dart:635` 修复前只有 `outbox.completed` 才尝试切「读过」，任何未完成阅读都不会把已有「想读 / 搁置 / 抛弃」切为「在读」；volume 模式又把“当前本地卷读完”直接当成“整个 Bangumi 条目读完”，多卷小说/漫画会过早变成「读过」。此外，已清空 outbox 的历史阅读位置没有补偿路径。
- **[x] ① 已修复** — `hibiki/lib/src/media/tracking/media_tracking_service.dart:229` 在卷模式开始阅读时只上报此前已读卷；`:635` 让 chapter 模式整本完成才切「读过」、volume 模式按 Bangumi 总卷数判断最后一卷，其余阅读事件统一切「在读」，既有「读过」不降级。`hibiki/lib/src/media/tracking/bangumi_api_client.dart:271` 通过官方 `GET /v0/subjects/{subject_id}` 读取 `volumes`；`hibiki/lib/src/media/tracking/media_tracking_repository.dart:322` 与 service `:476` 从历史阅读位置/完成标记增量恢复可靠事件，更换 token 时重置独立校正水位。
- **[x] ② 已加自动化测试** — `hibiki/test/media/tracking/media_tracking_service_test.dart:455` 覆盖首章未结束即想读→在读，`:484` 覆盖既有读过不降级，`:514` 覆盖完成中间卷仍在读，`:554` 覆盖最后一卷→读过，`:594` 覆盖 outbox 已清空的历史小说进度恢复；`hibiki/test/media/tracking/bangumi_api_client_test.dart:81` 覆盖官方条目详情的章节/卷数解析。
- **备注**：
  - 当前真实库没有 `media_type='book'` 的 Bangumi 映射，因此本轮没有可直接写入真实账号的小说候选；不为测试凭空创建映射，避免污染用户收藏。
  - Windows debug 应用已通过 Computer Use 启动到现有小说阅读页；启动校正水位已写入，小说映射与待同步队列均为 0，没有产生意外的远端写入。
