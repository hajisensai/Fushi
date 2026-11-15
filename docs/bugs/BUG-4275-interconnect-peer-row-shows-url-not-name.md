## BUG-4275 · 互联连接列表行标题只显示 URL、不显示对端设备名
- **报告**：2026-11-08（用户：设置 → 互联「已添加的对端」）
- **真实性**：✅ 真 bug。`FushiClientUrl.deviceName` 配对时已落库（编辑 / 启停也保留），但地址行标题只渲染 `u.url`（`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart` 行标题 `Text(u.url)`）；同文件 host 选择器（`h.deviceName ?? h.url`）和服务端「已配对设备」列表都已显示名字。BUG-1184 只把 URL 放宽成两行，没解决「认不出是哪台」。学到的备用地址本身不带名字，需借同 hostId 组的名字。
- **[x] ① 已修复** — 新增 `interconnectPeerRowName`（`interconnect_peer_addresses.dart`：本行名字 → 同 hostId 组内第一个非空名字 → null），行标题 `peerName ?? u.url`，有名字时 URL 移到副标题首行（同 host 多地址靠它区分）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_peer_row_test.dart`（helper 单测 + 面板接线源码守卫）。
- **备注**：未做真机肉眼复测（纯标题文本改动）。
