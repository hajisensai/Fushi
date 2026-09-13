## BUG-2234 · 下载任务按来源分裂导致筛选排序遗漏且不能按合集折叠
- **报告**：2026-09-07（用户：游戏下载不同源 UI 不一致，排序分类不能覆盖全部，也不能按合集折叠）
- **真实性**：✅ 真 bug。原 `fushi/lib/src/pages/implementations/downloads_page.dart:315` 将持久任务、旧 JSON 计划、直链与漫画队列拆成独立列表；`video_download_jobs_panel.dart:483` 的筛选排序只消费持久任务，旧计划另占固定高度。另 `video_download_legacy_importer.dart:342` 无视 contentKind，硬写 tv/anime。
- **[x] ① 根因修复** — 下载中心将四个来源适配为 DownloadTaskEntry，统一搜索、类型/状态筛选、正反排序及合集/类型/状态分组。共享紧凑卡片显式展开，组可单独或批量收起；状态保留到页面会话。真实合集/作品身份缺席的任务归入未归属合集，不按文件名猜测。旧计划存储写入/删除通知驱动刷新，generation 防止乱序读取回退。尚未迁移的明确游戏/书籍/有声书计划保留其所属域和入库策略。
- **[x] ② 自动化测试** — `fushi/test/pages/download_task_browser_test.dart`、`anime_download_task_entry_test.dart`、`fushi/test/media/downloads/download_queue_entries_test.dart`、`fushi/test/media/torrent/video_download_legacy_importer_test.dart`。覆盖跨来源筛选排序、合集折叠、窄屏大字、外部写入刷新、乱序读取、重试身份、选择性清理及分类迁移；与已有任务卡片、直链动作、旧入口、队列和 i18n 守卫去重合计 260 条通过；`unified_download_jobs_panel_test.dart` 额外验证混合来源去重、空库/错误隔离、实时暂停筛选和安全删除动作。全量 flutter analyze 通过。
- **验证边界**：尚未完成用户原始 Windows 任务数据的真机复测。历史 auto 计划没有可靠域信息，保留兼容分类；已归档的旧迁移不在本轮重新写库。
