## BUG-722 · 互联服务端模式仍显示测试连接按钮
- **报告**：2026-07-11（用户：hibiki 互联作为服务端不应该有测试连接按钮）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/sync/sync_settings_schema/interconnect.part.dart:497`（`_HibikiServerConfigWidgetState.build` 里「测试连接」按钮无条件渲染，未被 `lockedByServer` 门控）。
  互联后端（`SyncBackendType.hibikiServer`）的设置里，客户端配置区 `_HibikiServerConfigWidget` 与服务端开关区 `_ServerModeWidget` 同屏显示，靠 role-locking 互斥。当本机启用服务端（`serverEnabled == true` → `lockedByServer == true`）时，客户端区的地址增改虽已被禁用，但「测试连接」按钮（`_testAll` → 探测出站地址可达性）仍显示且可点。本机作为服务端时是一台被动数据源，没有出站客户端连接可测——此按钮既无意义又误导（与 BUG-084「服务端隐藏 sync now / compare」是同一类问题）。
- **[x] ① 已修复** — 用 `if (!lockedByServer) ...<Widget>[ ... ]` 门控「测试连接」按钮块（含其上方 `SizedBox(height:12)` 与 `_isTesting` spinner），服务端模式下整块隐藏；客户端模式行为零变化。见 `hibiki/lib/src/sync/sync_settings_schema/interconnect.part.dart` 提交 <PENDING>。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/interconnect_pairing_fixes_guard_test.dart` 新增源码切片守卫「BUG-722：服务端模式隐藏「测试连接」按钮」：断言 `t.sync_test_connection` 全语料仅一处、且其前存在 `if (!lockedByServer) ...<Widget>[` 门控（`guardIdx < buttonIdx`）。这类私有客户端 UI widget 无低成本 widget 测试可落地，沿用同文件既有源码守卫风格。
- **备注**：号段与另一未合并分支（PR#28 多基字注音重叠）撞号——722 在 develop 上是空号，两分支各自独立取了 722，落地时由 integration owner 改号其一。
