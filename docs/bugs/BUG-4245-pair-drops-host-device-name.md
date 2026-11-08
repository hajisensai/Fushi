## BUG-4245 · 配对收尾丢掉主机展示名，已配对设备只显示 IP
- **报告**：2026-11-08（服务端 Fushi 复习端到端测试：复习页「已配对设备」把服务端显示成 IP 地址，而服务端 `/api/ping` 报了设备名）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart` 的 `_runPairingV2` 拿到 host 在 `/api/ping` 报的 `deviceName`，只用于身份确认框；成功收尾 `_onPairSuccess` 调 `addFushiClientUrl(baseUrl, ..., deviceName: null)`（修复前写死 null），名字没落库。`InterconnectHostTarget.displayName`（`video_remote_targets.dart` 的 `_displayNameOf`）没有设备名就退回地址的主机部分。链接配对（`interconnect_link_pairing.dart`）本来就存名字，只有手动 IP / 发现列表这条丢。
- **[x] ① 已修复** — `_runPairingV2` 把展示名交给 `_onPairSuccess`（`interconnect.part.dart:1079`），后者去空白后写进这条地址（`:1227`）；学到的其它地址沿用锚点的名字。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_pair_device_name_test.dart`：源码切片守卫钉住名字一路传到落库（收尾是设置页 part 的私有 State，没有低成本行为入口，同 BUG-1557 的做法）；仓库层用例确认存下的名字不会被后续不带名字的更新抹掉。
- **备注**：修复前配对的地址不会自动补名字，重新配对（或在地址编辑框里填名字）后显示设备名。
