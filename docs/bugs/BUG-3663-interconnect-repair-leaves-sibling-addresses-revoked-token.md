## BUG-3663 · interconnect-repair-leaves-sibling-addresses-revoked-token
- **报告**：2026-10-23（用户：反馈 53NT7G_tSO，Android 3.0.0-debug.20644「互联 ip 内网和外网 token 不同，并且无法单独配置；整体测试连接无法得知 token 不对」，附截图：已添加对端列表每一行都看不到地址）
- **真实性**：✅ 真 bug，三处：
  1. host 按设备只认一份 per-peer token（`fushi/lib/src/sync/fushi_server_controller.dart` `_persistPairedPeer` → `upsertPairedPeer`，以 deviceId 为键），经任一地址重新配对即作废旧 token。客户端却只把新 token 写在配对用的那一行（`fushi/lib/src/sync/sync_repository.dart` `setFushiClientTokenForUrl`；调用方 `sync_settings_schema/interconnect.part.dart` `_onPairSuccess`、`_pairLegacyV1`，`interconnect_link_pairing.dart`），同一台 host 的其余地址（内网 / 外网 / IPv6）继续拿旧 token 撞 401。手动补的外网地址也不带 hostId，无法归入该 host 的组。
  2. 「测试连接」失败只显示 ✗（`interconnect.part.dart` `_testAll`）：凭据被拒、地址没记录证书（日志：外网域名 `CERTIFICATE_VERIFY_FAILED: self signed`）、超时、连不上在界面上一模一样。
  3. 已添加对端行把上移 / 下移 / 开关 / 重新配对 / 删除五个控件平铺在行尾，363dp 宽的手机上标题被挤成 0 宽，地址整行不可见。
- **[x] ① 已修复** — 新纯函数 `applyIssuedInterconnectToken`（`interconnect_peer_addresses.dart`）：新 token 写到同一台 host 的全部地址；配对时 `/api/ping` 回报的 hostId 让尚未归组的新地址按与地址学习同一指纹判据（`_anchorMayClaimHostId`）先归组，指纹对不上只改这一行。`setFushiClientTokenForUrl` 走它，手动 / 局域网发现 / 链接三条配对路径都传 hostId。地址学习（`mergeLearnedHostAddresses`）里锚点刚用自己的 token 鉴权成功，同组旧 token 一并换新，已坏的老配置也自愈。测试连接逐行显示失败原因（`interconnectTestFailureReason`：凭据被拒 → 重新配对；没记录证书的 https → 新文案指向这一行的「重新配对」；指纹不符；超时 / 连不上）。窄于 520dp 时次要动作挪到地址下方一行，只把开关留在行尾。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_host_token_propagation_test.dart`（整组同步、指纹相同归组、指纹不符不越组、仓库层、地址学习自愈、失败原因分型）；`interconnect_manual_pair_guard_test.dart` 跟随新调用形状。窄屏行布局没有 widget 测试（私有 widget 依赖完整 SettingsContext），未真机复测。
- **备注**：反馈里「第一次添加的时候没有触发首次添加事件」信息不足，日志只有一次经外网域名 `pair/v2` 的 `Software caused connection abort`，需向反馈人确认「首次添加事件」指什么（配对确认框？自动同步？）。
