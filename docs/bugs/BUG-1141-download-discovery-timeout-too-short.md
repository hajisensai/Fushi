## BUG-1141 · 代理下「发现」搜索 20s 超时太短，请求本可成功却被掐断

- **报告**：2026-07-27（用户：已开代理，下载代理模式为「自动」）
- **现象**：下载页 →「发现」→ 搜 Nyaa（`Watashi wo Tabetai, Hitodenashi`），页面只出
  「搜索失败或超时，请点重试」+ `TimeoutException after 0:00:20.000000: Future not completed`。
- **真实性**：✅ 真 bug（超时值定得不合实际，非网络故障）。
  根因 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:237/328/438/443/496`
  与 `hibiki/lib/src/media/torrent/anime_download_subscription.dart:407/436/445`：
  发现链路（AniList / Nyaa / Jimaku）的每次请求都套了 `.timeout(const Duration(seconds: 20))`。
  这三家都在墙外，用户普遍挂代理；`DownloadNetworkProxyMode.auto` 还要先经
  `applyUpdateProxy` 解析环境变量/系统代理，再建代理隧道 + TLS 握手，叠起来轻松超过 20s。
  于是**请求本身能成功，却先被这层应用层 `.timeout()` 掐断**，UI 直接落到重试态。
  20s 是按直连口径拍的值，且以魔法数字散落在 8 个调用点，改一次要动八处，必然漂。

- **[x] ① 已修复** — 提交 `314bea466`。
  收敛成唯一真相源 `kDownloadDiscoveryTimeout`
  （`hibiki/lib/src/media/torrent/download_network_proxy.dart:17`，与该链路的代理策略同文件同作用域），
  值从 20s 放宽到 60s；8 个调用点全部改为消费该常量，不再有裸 `Duration`。
  真断网/连接被拒仍由 socket 层先报错，不会真的干等一分钟。
  torrent 传输本身归 qBittorrent / 内置引擎，不受此常量影响。

- **[x] ② 已加自动化测试** — `hibiki/test/torrent/download_discovery_timeout_guard_test.dart`。
  A：`kDownloadDiscoveryTimeout.inSeconds >= 60`，钉住不被调回直连口径的短值。
  B：源码语料层扫两个消费方，断言不再出现 `.timeout(const Duration(` 且都引用了该常量，
  防止以后新增调用点又散落魔法数字把常量架空。
  负向验证：把常量改回 20s 并还原一处裸 `Duration`，两条断言均转红。

- **改号**：本条开工时取到的下一个空号是 1138，随后连撞两轮——
  1138 归 PR #463、1139 归 PR #462、1140 归 PR #461（均早于本条完成认领），
  故本条最终定为 **BUG-1141**。
  历史提交 `314bea466` / `a1ee91630` 的提交信息里仍写着改号前的旧编号，
  是改号前留下的陈述——分支已推送、不做 force-push，一律以本文件的 H2 标题为准。

- **备注**：本轮只调默认值，未做成用户可配置项——发现链路是「点一次等一会」的交互，
  多一个设置项的收益不抵认知成本；若后续出现 60s 仍不够的真实链路，再考虑暴露设置。
