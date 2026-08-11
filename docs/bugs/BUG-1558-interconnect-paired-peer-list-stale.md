## BUG-1558 · 配对成功后已配对设备列表不刷新（controller 落库不通知）
- **报告**：2026-08-12（互联配对与安全链路审计）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/fushi_server_controller.dart` `_persistPairedPeer`：
  host 审批通过新设备后 per-peer 凭据已落 `fushi_paired_peers`，但 controller（ChangeNotifier）一声
  不响；设置页的「已配对设备」列表只在 `_loadSettings` / `_revokePeer` 后重拉，于是用户开着设置页
  看对方配对成功，列表里压根没这台，以为没配上又配一遍。
  同一文件还有一条低危悬挂：`_promptPairApproval` 取代旧审批框时等它 teardown 的 2s 超时**无兜底**
  ——超时后仍往下走，把新会话的 PIN 写进仍属于旧弹窗的共享单值态，并把一个永不会完成的 completer
  留在字段里（旧弹窗真 teardown 时又去 complete 下一个请求的 completer）。
- **[x] ① 已修复** — 配对表的**任何**变动都从 controller 广播：`_persistPairedPeer`
  （`fushi_server_controller.dart:435`）与 `revokePeer`（:457）各补 `notifyListeners()`，设置页
  `_onServerChanged` 收到通知即重拉列表（`interconnect.part.dart`）。顺手把 supersede 超时改成
  **按失败收尾**：先把自己的 completer 从共享字段摘掉，再直接拒绝本次配对，不开新框、不碰共享单值态
  （`fushi_server_controller.dart:532`）。
  **兼容性**：纯客户端内部状态广播，无协议 / 存储变更；对端无感。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_paired_peer_notify_test.dart`（真 in-memory DB
  驱动 controller：落库 / 吊销 / 重复配对都广播，吊销不存在的设备不广播）+ 接线半边与 supersede 超时
  兜底的源码守卫。已变异实测（去 notifyListeners + 注释掉超时兜底 → 4 条变红）。
- **备注**：本轮互联配对安全链路六修之四（BUG-1555~1559）。
