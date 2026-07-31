## BUG-1274 · 反吸血身份黑名单下载期无差别封禁
- **报告**：2026-07-31（用户：内部审查）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/torrent/anti_leech.dart:438-460`（修复前）：
  `_evaluatePeer` 规则 ② 的身份黑名单（peer_id 前缀 `-SD/-XF/-DL/-BN/-DT/-QD` +
  client 关键词 `qqdownload/xfplay/dandanplay/offline` 等）**无条件全相位封禁**，
  下载期也封。封禁的收益只在「不给它上传」，下载期封 peer 只减少自己的潜在
  数据源、毫无收益。且同文件里迅雷已有相位特例（仅 `ctx.isSeeding` 才封、
  下载期放行走行为规则），证明设计者早已认识到相位问题，却没有推广到其余
  身份；另外 `ignoreByDownloadedBytes` 豁免（喂过我们 ≥100MB 数据不自动封）
  只在 ④ PCB 生效，身份黑名单不吃豁免——一直在喂数据的 -SD peer 照封。
- **[x] ① 已修复** — 把迅雷特例的相位逻辑推广为整个身份黑名单的统一规则：
  `ctx.isSeeding == false` 时跳过全部身份判定（伪造进度仍会被 ④ PCB 封）；
  身份判定前先吃 `ignoreByDownloadedBytes` 豁免（语义同 PCB，PCB 内原豁免
  位置不动）。特例分支消除，`-XL`/xunlei/thunder 命中普通
  `peerIdBlacklist`/`clientBlacklist` 路径；`BanReason.xunleiSeeding` 枚举
  保留但不再产生（全仓 grep 无引擎外消费方，保留仅为不破坏潜在序列化）。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/anti_leech_test.dart`
  group「身份黑名单相位与粒度（BUG-1274 / BUG-1275）」：下载期 -SD 放行且
  继续被 PCB 封、下载期 xfplay/dandanplay 放行、做种期同类照封、做种期
  totalDownload≥豁免阈值不封（豁免关闭时照封）、迅雷 -XL 统一路径与原特例
  等价（下载期放行/做种期封）。已做变异实测（把相位条件改坏 → 测试红）。
- **备注**：与 BUG-1275（封禁粒度）同一 PR 修复。
