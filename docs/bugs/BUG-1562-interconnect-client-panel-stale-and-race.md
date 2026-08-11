## BUG-1562 · 互联客户端面板：已连接状态不刷新、手动配对探测窗口无忙态可并发、弹窗返回后无 mounted 守卫
- **报告**：2026-08-12（用户：互联 UI 层审计）
- **真实性**：✅ 真 bug，三处同属 `_FushiServerConfigWidgetState`（`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart`）：
  - ①「已连接 ✓」不刷新：build 在旧 `:499-511` 直接读 `_tokenController.text.trim().isNotEmpty`，却从未 `addListener`；手动填写路径 `_saveToken`（旧 `:116-124`）只落库不 `setState`。用户贴完/清空 token，那一行原地不动。
  - ② 手动配对忙态窗口：`_attemptManualPair`（旧 `:233-272`）在进 `_runPairingV2`（它才置 `_pairingManual`）之前还有 `FushiTofuProbe.captureFingerprint` + `/api/ping` 两次秒级网络往返；那段窗口里「添加」与各行「重新配对」按钮全亮，可并发起两条配对流程，两条都走 `_onPairSuccess` 写 token，后写覆盖先写。
  - ③ async gap 无守卫：`_addOrEditUrl`（旧 `:200`）弹窗返回后直接 `setState`；期间关掉「启用互联」会让宿主 section 被门控隐藏、widget dispose → dispose 后 setState 崩溃。
- **[x] ① 已修复** — ① token 提成 State 字段 `_tokenPresent`，由 `_tokenController` 监听驱动（`interconnect.part.dart:51/72/84/535`），`_load`/`_reloadFromStore` 在自己的 setState 里同步该字段故不嵌套；② `_attemptManualPair`（`:259`）入口先 `if (_pairingManual) return;` 自查，`_setPairV2Busy(true)` 提到 TOFU/ping 之前，全程 `try/finally` 清忙态（LAN 路径 `_pairingUrl` 的现成范式）；③ `_addOrEditUrl`（`:148`）弹窗后补 `if (!mounted) return;`。随本轮 `fix(interconnect)` 提交。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_client_panel_guard_test.dart`（同步设置 schema 合并语料源码守卫，与既有 `interconnect_token_display_guard_test.dart` 同范式）：token 监听 + build 读 State 字段且禁回旧写法、忙态先于两次探测且有 finally、mounted 守卫夹在弹窗与 setState 之间。
- **备注**：三条都是私有 State 的时序，最强可落地层是语料守卫（该 widget 无法从测试直接构造）。
