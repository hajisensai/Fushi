## BUG-4139 · 互联主机版本卡写「只能在局域网内让主机更新」，异地已配对设备被信任区门拒
- **报告**：2026-11-05（用户：开发者自报，应用内反馈 d639PMD5mS，Android 客户端）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/sync/fushi_sync_server/host_update.part.dart` 的 `_hostUpdateTriggerGate` 在开关与 nonce 之间多了一道 `_isLanPeerRequest(...)` 信任区门（原第 63-65 行），P2P 隧道 / 公网 / 组网进来的已配对设备 POST `/api/host/update` 一律回 `zone_not_allowed`，客户端 `fushi/lib/src/sync/interconnect_host_update_tile.dart:60` 把它显示成「只能在局域网内让主机更新」。这道门是 2026-10-13 首版（Pp8XPyve0N）自加的限制；鉴权本已由「配对专属 token（异地配对强制 PIN / 票据）+ 主机开关 + 一次性 nonce」承担，信任区门只是把异地已配对设备挡在外面。开放 PR #2943（无头服务端远程自更新）沿用同一道门，没覆盖。
- **[x] ① 已修复** — 去掉触发门里的信任区判断；`HostUpdateDenial.zone` 只留给旧版 host 的回包，文案改成「主机版本较旧，只接受局域网内发起的更新；在主机上手动更新一次后，异地也能让它更新」，主机端开关说明改为「局域网或异地连接」。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_sync_server_host_update_test.dart`：P2P 隧道进来的已配对设备能触发更新（200，`starts == 1`）、仍受主机开关约束（`remote_update_disabled`）。
- **备注**：PR #2943 的 `packages/fushi_server/README.md` 写了「只收局域网」，两边合并后需要改掉那句。
