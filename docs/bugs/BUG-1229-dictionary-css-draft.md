## BUG-1229 · 自定义 CSS 遮罩退出丢失草稿且关闭即保存
- **报告**：2026-07-29（用户反馈）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:568`
  的范围切换会调用持久化 setter，旧 footer 的“关闭”也会直接保存；对话框被遮罩关闭时
  state/controller 随路由销毁，没有任何跨实例草稿。后续审查还在旧 exact
  `497d209376db17703861254eeb705ccdb284196f` 发现第二层竞态：delete/import
  先用 `ProfileUiState.activeProfileId` 在协调器锁外判断目标是否 active，再执行
  repository 操作；并发 switch 已改 repository 身份但尚未回写 state 时会走错分支，
  绕过与 CSS Save 共用的临界区。
- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:498`
  增加与当前 `AppModel + profileDraftScope` 绑定的会话草稿，范围切换和非按钮退出只暂存；
  footer 改为“取消 / 保存”，取消清空草稿，保存一次性提交所有已编辑范围并清空草稿。
  审查补强还在保存前复核 Profile 草稿作用域：真正应用 Profile 时旧草稿精确失效，
  不会把 A Profile 的 CSS 写进 B Profile；首次异步加载从 `-1` 取得真实 Profile id
  不轮换作用域，避免误杀首开草稿并导致 Save 静默丢弃。Profile 应用和 Save 还通过
  同一协调器串行：Profile 先开始时 Save 等待完成后拒绝旧 scope，Save 先开始时
  Profile 等待全部 CSS setter 完成，封住异步交叉写入窗口。
  `hibiki/lib/src/profile/profile_view_model.dart:204` 与 `:256` 现在让所有
  delete/import 无条件先进入 `ProfileDraftCoordinator` 临界区，再从 repository
  重读 active id，并在锁内决定是否轮换 scope、apply 当前 Profile。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/dictionary_css_editor_dialog_test.dart:564` 覆盖遮罩退出不持久化、
  重开恢复、取消丢弃；`:600` 覆盖切换范围不写入以及保存统一提交；Profile 回归覆盖
  “首次懒加载后 Save”、“关闭后切换再打开”和“编辑器打开期间切换后点击保存”三条路径；
  `:321` 以真实 database/repository/ViewModel seam 固定复现
  switch→delete-target→stale-Save，`:397` 固定复现
  Save 持锁→switch→overwrite-import；另有双向并发锁测试及
  create/switch/delete-active/import-overwrite-active 真路径覆盖。
- **备注**：旧 `497d` 两条 gated 反例均准确 RED，新实现整份定向测试 13/13、
  相邻 Profile/database 测试 52/52 通过；移除协调器临界区的可回滚 mutation
  会使两条反例重新 RED，恢复后 2/2 GREEN。默认 SQLite native asset 下载曾因
  GitHub 网络超时而在测试执行前失败，随后仅在本地临时使用系统 `winsqlite3`
  完成 headless 验证；该 hook 不入库。真实 UI 仍未验，不据此宣称真机通过。
