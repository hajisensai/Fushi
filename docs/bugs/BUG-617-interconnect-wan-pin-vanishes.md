## BUG-617 · 公网配对 host 点允许即关窗抹掉 PIN·client 还没输就看不到

- **报告**：2026-07-08（用户：TODO-1330 子问题②「公网连接，先显示 pin 码和同意，我才能输入 pin 码，但是 pin 码已经消失了」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/sync/hibiki_server_controller.dart` 的 `_promptPairApproval`（修复前 line ~341-447）。
  公网 / 跨网段（pinRequired）会话的 host 审批 + PIN 显示在 `/api/pair/v2` CREATE 阶段（`hibiki_sync_server.dart:618`）。审批弹窗显示 PIN + 允许/拒绝；host 点「允许」立刻 `Navigator.pop` 关窗，`finally` 又把 `_pendingPairPin` 清 null。而 client 要等 pair/v2 收到审批结果**之后**才弹「输入对方 PIN」框——于是 client 要输 PIN 时，host 屏上的 PIN 早随关窗消失。BUG-592 把审批前移到 CREATE 让 PIN「能显示」，但没解决「显示完随允许即被抹掉」的时序。
- **[x] ① 已修复** — 把「审批结果」与「弹窗生命周期」解耦：
  - server 加 `onPairSessionResolved` 回调（`hibiki_sync_server.dart`），在 `_handlePairConfirm` 里 pinRequired 会话一旦 client 提交 confirm（PIN 已被读到并算了 proof）即触发一次。
  - controller `_promptPairApproval` 改两阶段：host 点「允许」立刻用 `Completer` 把结果交回 server（好让 client 拿到会话去弹 PIN 框），但对 pinRequired 会话**不关窗**，转成「等对方输入此 PIN」常驻显示，直到 client confirm 到达（`onPairSessionResolved` → `_dismissPendingPairPinDialog`）、用户手动关、或会话 TTL（≈90s）超时才收起。免 PIN 会话行为零变化（无 PIN 可显示，点选即关）。
  见分支 `todo1330-interconnect-pairing`。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/hibiki_sync_server_pair_v2_test.dart` 新增 3 例：pinRequired confirm 触发 `onPairSessionResolved` 一次 / 错 PIN 的 confirm 也触发（PIN 已消费）/ 免 PIN 会话不触发。源码守卫 `hibiki/test/sync/interconnect_pairing_fixes_guard_test.dart`（controller 接 `onPairSessionResolved` + 存在 `_pendingPairPinDismiss` + `t.sync_pair_pin_waiting` 等待态）。
- **备注**：PIN 仍只在 host 屏幕显示、绝不过线（client 只回传 HMAC proof），`pin_no_plaintext_guard_test` 仍绿。重试要走新会话拿新 PIN（会话单次消费不变）。控制器弹窗为纯 UI 接线，无低成本 widget 测试，故以源码守卫钉住。
