## BUG-2233 · 手动重刮遇后台任务时全屏禁用且无法查看或撤回排队作品
- **报告**：2026-09-07（用户要求重做后台任务和重新刮削 UI）
- **真实性**：✅ 真 bug。`video_source_scrape_task.dart` 原手动入口在 `_active != null` 时直接拒绝请求；两个弹窗以单个 busy 标记禁用全屏。`video_source_scrape_coordinator.dart` 原 `_plannedWorkOrNull` 仅以标题取第一个作品，允许同名条目误绑定。
- **[x] ① 已修复** — 复用并校正附件的 FIFO 控制器，每条请求持有自身 Future；提供排队快照和逐条撤回，取消发布 cancelled 而不是失败。手动入口贯通 workStableKey，旧历史同名歧义拒绝写入。面板分当前、待确认、历史三页，列表懒加载，异步刷新只接收最新结果。提交：`2fb9e0641a`。
- **[x] ② 已加自动化测试** — `video_source_scrape_task_test.dart` 覆盖串行、批次接棒、取消/释放和同名不同键；`video_source_scrape_coordinator_test.dart` 验证只给指定同名条目写 NFO；`video_manual_binding_ui_test.dart` 验证标题/ID模式、候选预览与键透传；`video_task_center_ui_test.dart` 覆盖1500待确认项窄屏懒加载及错误重载。
- **备注**：显式切换AniDB后还需丢弃旧TMDB关联，身份冲突NFO不并入新作品且保留原文件；coordinator回归覆盖此路径。验证记录见 `docs/specs/2026-09-07-video-library-workflow.md`；控件渲染截图不等于安装版设备 E2E。附件原队列测试使用已不存在的 media kind `series`，已修为 `tv`，不能沿用附件的静态通过结论。
