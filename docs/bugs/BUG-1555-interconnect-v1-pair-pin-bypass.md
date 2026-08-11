## BUG-1555 · v1 /api/pair 绕过 PIN 强制：公网入站一次「允许」即拿到权限最大的共享 token
- **报告**：2026-08-12（互联配对与安全链路审计）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/fushi_sync_server.dart:674`（`_handlePair`）。
  v2 对公网 / 跨网段入站强制 PIN + 双 nonce HMAC + 爆破限速（`_handlePairV2` / `_handlePairConfirm`），
  而旧的 `/api/pair`（v1）在**同一条入站链路**上只做一件事：弹一个普通审批框，host 点「允许」
  就把**共享** token（权限最大、不可逐台吊销）发出去。攻击者改发 v1 即可把「公网必须 PIN」这条
  策略整个废掉，而 host 屏上看不出与正常配对的任何区别，误点一次即永久失守。
- **[x] ① 已修复** — v1 用与 v2 **同一判据**（`FushiPairingProtocol.computePinRequired`）前置拦截：
  本会话必须 PIN 时直接 403 `upgrade_required`，**压根不弹审批框**（不给用户误点的机会）；
  client 把该 reason 翻成「对方需要升级」而非「对方拒绝」。
  `fushi/lib/src/sync/fushi_sync_server.dart:698`、
  `fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart`（`_pairDeniedMessage`）。
  **兼容性**：LAN 内且 host 未开「LAN 也要 PIN」（默认）时 v1 行为逐字不变，旧 client 继续可配对；
  变的只是「本就该要 PIN 的会话」——那些会话以前能拿到共享 token 本身就是漏洞。Hibiki 自带的
  client 总是先试 v2，只在对端不支持 v2 时才回落 v1。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_sync_server_pair_v1_pin_bypass_test.dart`（真实 HTTP
  handler 层：要 PIN 会话 403 upgrade_required 且审批回调零调用、免 PIN LAN 会话仍 200、未接供给器
  时不误判）；已变异实测（去掉拦截 → 403 断言变红）。同时更新了
  `fushi_sync_server_pair_v2_test.dart` 里那条旧契约断言（它断言的正是本漏洞）。
- **备注**：本轮互联配对安全链路六修之一（BUG-1555~1559）。
