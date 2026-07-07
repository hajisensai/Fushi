## BUG-588 · 互联LAN token成功仍连失败+公网无pin

- **报告**：2026-07-07（用户报 TODO-1296）
- **真实性**：✅ 真 bug（两个症状同一根因）

### 症状
1. 公网连接：配对界面**根本不显示 PIN 码**，无法完成配对。
2. 点击局域网设备配对，填 token 显示成功却仍连接失败（当 host 把连入端判为非同网段 / 开启「LAN 也要 PIN」时，走的是同一条 PIN 路径）。

### 根因（同一处时序死锁）
`hibiki/lib/src/sync/hibiki_sync_server.dart` v2 配对握手里，**唯一显示 PIN 的地方是 host 审批弹窗**（经 `onPairRequest` → `HibikiSyncServerController._promptPairApproval`，`hibiki/lib/src/sync/hibiki_server_controller.dart:398-416` 仅在 `request.pinRequired` 时渲染 PIN）。但该审批弹窗原先只在 `/api/pair/v2/confirm` 且 **pinProof 校验通过之后** 才被调用（旧 `_handlePairConfirm` 的 `await approve(...)`）。

对 pinRequired 会话（公网恒 true；LAN 在 host 判定连入端非私有地址或 `lanRequiresPin=true` 时也 true，见 `hibiki_pairing_protocol.dart` `computePinRequired` / `isPrivateLanAddress`）形成鸡生蛋死锁：client 必须先提交**正确** PIN 才能过 proof 校验 → 才会弹审批 → 才显示 PIN；但 client 想知道 PIN 必须 host 先显示。于是 PIN 永远不显示、pinProof 永远错、配对永远走不通。client 侧 TODO-1273 已把 PIN 输入下沉为「收到 host `pinRequired` 后才弹输入框」，但 host 端始终不显示 PIN，输入框成了「让你输一个从没出现过的数字」。

- host 显示 PIN 的唯一入口：`hibiki_server_controller.dart:398-416`（`_promptPairApproval` 内，仅 `request.pinRequired` 时）。
- 死锁点（修复前）：`hibiki_sync_server.dart` `_handlePairConfirm` 在 pinProof 校验通过后才 `await approve(...)`。

### [x] ① 已修复 — commit f309c79e7
`hibiki/lib/src/sync/hibiki_sync_server.dart`：把 **pinRequired 会话的 host 审批（含 PIN 显示）提前到 `/api/pair/v2` CREATE 阶段**（`_handlePairV2`：生成 PIN 后、存会话前 `await onPairRequest(pinRequired: true)`；拒绝则 403 declined，会话不落）。`_handlePairConfirm` 对 pinRequired 会话不再二次弹审批（会话存在即已被 host 允许），只校验 pinProof；免 PIN 会话审批仍留在 confirm（无 PIN 可显示，行为零变化）。双重确认仍成立：CREATE 阶段人工允许 + confirm 阶段 pinProof 校验。client / UI / per-peer token 路径无需改动。

### [x] ② 已加自动化测试 — `hibiki/test/sync/hibiki_sync_server_pair_v2_test.dart`
- `PIN-required approval fires at CREATE not confirm (BUG-588)`：断言 pinRequired 会话在 `/api/pair/v2` 时 host 审批（=PIN 显示）即被调用（`pinRequired=true`），confirm 正确 proof 不再二次弹审批仍派 token。
- `PIN-free approval fires at CONFIRM not create (BUG-588)`：免 PIN 会话 CREATE 阶段不弹审批，仍在 confirm 弹（行为不变）。
- `PIN-required host declines at CREATE yields 403 declined (BUG-588)`：pinRequired 会话 host 在 CREATE 拒绝 → 403 declined。

### 备注
- 公网真机验证需可路由到 host 的公网/端口转发环境，无法在纯离屏单测里端到端复现；协议层握手时序已由上述单测覆盖（host 审批+PIN 显示发生在 client 被要求输入 PIN 之前）。真机需二设备验证：公网添加对端 URL → host 屏出现 PIN + 允许/拒绝 → client 输入 host 屏 PIN → 配对成功 → 同步生效。
- TLS 目前无 UI 入口（`setServerTlsEnabled` 无调用方，见 `.vibe-coxswain/notes/TODO-961-tls-investigation-20260706.md`），故默认明文；本修复不依赖 TLS。
