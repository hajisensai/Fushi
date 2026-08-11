## BUG-1556 · 配对会话 TTL 从审批前起算：host 审批慢就必配不上，且过期被报成「对端拒绝」
- **报告**：2026-08-12（互联配对与安全链路审计）
- **真实性**：✅ 真 bug。两个根因同源，都在 `fushi/lib/src/sync/fushi_sync_server.dart`：
  1. `_handlePairV2`：会话 `createdAt` 在**请求入口**取，而 pinRequired 会话随后还要
     `await onPairRequest`（host 人手审批，完全可能超过整个 90s TTL）。审批一慢，会话写进
     `_pairSessions` 的那一刻就已过期，client 紧接着的 confirm 必被 prune。
  2. `_handlePairConfirm` 先 prune 再查，过期会话在查之前就没了 → 一律报 403 `declined`
     「对端拒绝」，而 host 分明刚点了允许，用户排查方向全错。
- **[x] ① 已修复** — TTL 改从**审批通过（会话真正可用）**那一刻起算（`fushi_sync_server.dart:824`
  一带：`stored` 在审批后才构造，`createdAt: _now()`）；confirm 改成**先查再 prune**，过期返回专用
  reason `expired`（`fushi_sync_server.dart:855`），并顺手收起 host 那个已经没用的常驻 PIN 弹窗；
  client 把 `expired` 分型显示为「配对会话已超时，请重新发起配对」（挂在 BUG-1553 的失败分型基建上，
  `_pairV2FailureMessage`）。
  **兼容性**：过期仍是 403，只是 body 里的 reason 从 `declined` 变成 `expired`；认不得新 reason 的旧
  client 回落到通用失败文案，不会报错。伪造 / 早已被清走的 sessionId 仍报 `declined`，不多给攻击者信息。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_sync_server_pair_ttl_approval_test.dart`（可控时钟 +
  真实 HTTP：审批耗时 120s > TTL 仍能配成、审批后超时报 expired、免 PIN 会话语义不变、伪造 sessionId
  仍报 declined）；已变异实测（createdAt 改回入口时刻 + 去掉 expired 分支 → 3 条变红）。
- **备注**：本轮互联配对安全链路六修之二（BUG-1555~1559）。
