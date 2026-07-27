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
  torrent 传输本身归 qBittorrent / 内置引擎，不受此常量影响。

  **审查后补修（同一提交链）**：初版注释写「真断网仍由 socket 层先报错，不会真的
  干等一分钟」，这句站不住——`buildDownloadHttpClient` 根本没设 `connectionTimeout`。
  这条链路最典型的失败是**丢包而非拒绝**（目标在墙外、或用户代理进程已退出导致端口
  不通），SYN 被静默丢弃时 socket 层不会快速报错，会一路挂到应用层超时；而 UI 等待期
  只有一个无进度、无耗时、**无取消**的转圈（`buildLoading()`，搜索按钮同时 disabled）。
  即放宽到 60s 后，失败场景反而从「20s 拿到错误 + 可重试」退化成「60s 不可取消的空转圈」，
  比原 bug 更难受。
  修法是**按语义分层**而不是只放大总量：新增 `kDownloadConnectionTimeout = 10s` 并在
  `buildDownloadHttpClient` 里赋给 `HttpClient.connectionTimeout`（同仓 `sync_http.dart` /
  `galgame_helper_installer.dart` / `magpie_installer.dart` 已是同一范式），
  连不上 10s 内快速失败，连得上但慢的才吃满 60s 整体上限。那句不成立的注释一并改对。

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

- **已知局限 / 后续跟进**（审查留痕，本轮有意不修）：
  1. **60s 缺实测支撑**。已证实的只有「20s 这道门被用户实际打到」（报错截图
     `TimeoutException after 0:00:20`），但没有耗时日志、没抓过成功请求的 duration、
     未分链路（AniList / Nyaa / Jimaku）分别测，所以 60 / 40 / 90 之间没有可区分的依据——
     它是基于用户真实被掐断的**定性放宽**，不是测出来的值。而守卫 A 把 60s 钉成了永久下界，
     将来用实测 p95 回填时必须同时放开该断言。建议后续在这条链路加一次性耗时采样。
  2. **同链路仍有无超时入口**。`hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
     与 `jimaku_batch_dialog.dart` 同样消费 `JimakuClient`，但完全没有 `.timeout()`
     （即无限等待，比 20s 太短更糟）。非本 PR 引入，但它让「发现链路超时收敛成唯一真相源」
     的说法打折——真正的统一还差这两处。守卫 B 只扫写死的两个消费方，也盖不住它们。
  3. **两处真实的慢没碰**。对话框每次搜索都 `await createDownloadHttpClient()` **新建
     `HttpClient`**，代理解析（`applyUpdateProxy` 读环境变量 / 系统代理）+ TLS 握手每次
     从零重来，无连接复用；一次会话连打 AniList → Nyaa → Jimaku 三家，握手成本乘 3。
     放宽超时解决的是「本可成功却被掐断」，但这块是可指认、可优化的真实延迟，未处理。
