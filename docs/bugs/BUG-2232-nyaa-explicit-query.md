## BUG-2232 · Nyaa资源搜索会用隐藏别名替换或扩展明确查询词
- **报告**：2026-09-07（用户要求重整发现与刮削，附件报告 Nyaa 双入口查询不一致）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart:728` 把可见文本框作为明确 query 传入，但 `fushi/lib/src/media/torrent/nyaa_resource_provider.dart:116` 的候选选择将其与隐藏 aliases/originalTitle 混排，中文输入甚至被丢弃。旧下载对话框与通用发现源直接使用输入词，因此相同词在不同入口产生不同请求。
- **[x] ① 已修复** — 非空明确 query 只发送 trim 后的原词；没有明确 query 才按原名、别名选择默认候选。提交由本轮集成统一记录。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/external_provider_adapters_test.dart` 通过 MockClient 验证中文、日文、带资源过滤条件的查询，在有/无媒体别名时只发同一个 HTTP q；保留无 query 自动别名候选与去重覆盖。
- **备注**：定向测试已通过，未做设备 E2E。订阅轮询使用持久化 searchQuery，任务恢复使用已选资源标题，均不再被别名隐式扩展。此项不合并旧下载 UI、不修改数据库 schema，不增加刮削 provider；同分支的目录组织功能另有 schema 迁移。
