## BUG-1275 · 反吸血身份黑名单命中升级整段连坐封禁
- **报告**：2026-07-31（用户：内部审查）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/torrent/anti_leech.dart:408`
  （修复前）：`evaluate()` 里 `_registerBan(verdict.cidr ?? _segmentOf(peer.ip))`，
  而身份黑名单（peerIdBlacklist/clientBlacklist/xunleiSeeding）的
  `BanVerdict.cidr` 是 null → 被段默认升级成 IPv4 /24（IPv6 /60）**整段封**，
  进 `_bannedCidrs` 后又成为 ① AutoRangeBan 连坐源，`banTimeMs` 默认 0 =
  session 内永久。CGNAT 下一个 /24 后面是成百上千真实用户：一个影音先锋
  peer 拉黑整段，段内所有正常 peer 被连坐。身份证据只指向单个 peer，
  不支撑段级爆炸半径（多拨/PCB 行为证据才支撑）。
- **[x] ① 已修复** — 身份类 ban 的 `BanVerdict` 显式携带单 IP CIDR
  （复用 `cidrOf`：IPv4 `x.x.x.x/32`、IPv6 `/128`，新 helper
  `_singleIpCidrOf`），不再落入 `_segmentOf` 段默认。行为类规则粒度不动：
  multiDialing 仍显式封段（证据强），PCB 各原因 + multiPort 仍走 null →
  段默认（有意的爆炸半径，`evaluate()` 内已补回退语义注释）。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/anti_leech_test.dart`
  group「身份黑名单相位与粒度（BUG-1274 / BUG-1275）」：身份命中
  `verdict.cidr == '1.2.3.4/32'`、`bannedCidrs` 含 /32 不含 /24、同段邻居
  下轮不被 AutoRangeBan 连坐；IPv6 身份命中登记 /128、同 /60 邻居不连坐；
  行为类（PCB）IPv6 /60 段连坐保持不变。已做变异实测（把单 IP CIDR 改回
  null → 测试红）。
- **备注**：与 BUG-1274（相位）同一 PR 修复。
