## BUG-1357 · 同步导入 Mokuro 配置后已打开 Sources 行仍显示旧状态
- **报告**：2026-07-29（PR #582 独立审查）
- **真实性**：✅ 真 bug。同步导入沿
  `hibiki/lib/src/sync/interconnect_service_config.dart:82` 写入允许项，并由
  `hibiki/lib/src/models/app_model.dart:656` 刷新偏好缓存和通知监听者；断点位于
  `hibiki/lib/src/pages/implementations/media_sources_view.dart:146`：旧实现只在
  `initState` 缓存 Mokuro 状态，已挂载行不会读取通知后的新值。
- **[x] ① 已修复** — 本提交（自含修复、测试与条目；哈希由本提交确定）让已挂载
  Sources 视图在 `build` 同步 watch `appProvider`，偏好完成初始化后使用实时开关和
  base URL；保留现有 setter、持久化路径及未初始化测试回退，也不在异步间隙持有 ref。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/media_sources_dialog_test.dart` 以真实
  `PreferencesRepository` 模拟 service-config 导入和 `refreshAfterSyncRun`，验证同一
  已挂载 Sources 行立即更新开关与 base URL；同时保留 BUG-513 的 ref 生命周期源码守卫。
- **备注**：禁用态仍为零 fetch，用户本地持久开关语义不变。真实双端同步后的 UI
  操作与 CI 仍由最新 develop 集成线程补齐；不扩张到未被本报告证明的相邻弹窗生命周期。
