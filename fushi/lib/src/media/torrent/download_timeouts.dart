/// 下载发现链路（AniList / Nyaa / Torznab / Jimaku / OpenSubtitles）的超时常量。
///
/// 这条链路**没有自己的代理配置**：出口与全应用其它公网出站一样，由
/// `utils/net/app_proxy.dart` 统一解析（本机/局域网直连 > 用户手填 > env >
/// GUI 系统代理 > 直连），client 经 `AppModel.createDownloadHttpClient` 走
/// `createAppHttpIoClient`。它曾经有一套独立的三态（auto / direct / custom，
/// 默认 direct）——同一台机器上「更新能走代理、搜番剧不能」，用户得在两个设置页
/// 各填一次代理；2026-08-29 按用户要求合并进系统设置的唯一代理项并默认自动，
/// 旧 `download_network_proxy_mode` / `download_custom_proxy` 偏好由 schema v89
/// 迁移归并后删除。本文件只剩这条链路特有的两档超时。
library;

/// 下载网络链路（AniList / Nyaa / Jimaku）单次请求的**整体**超时上限。
///
/// 这三家都在墙外，用户常挂代理（自动模式还要先解析系统代理再建隧道），
/// 握手 + TLS + 代理转发叠起来轻松超过十几秒。旧值 20s 是按直连拍的，代理下
/// 经常在请求本来能成功的情况下先被这层 `.timeout()` 掐断，UI 只剩
/// `TimeoutException after 0:00:20` + 「请点重试」。
///
/// 与 [kDownloadConnectionTimeout] 分层，两者语义不同、不可合并：
/// 连不上由连接超时快速失败，连得上但慢的才吃满这个整体上限。
///
/// 覆盖范围除发现类 API 往返外，也包含 Jimaku 字幕文件的字节下载
/// （文件只有几十 KB，与一次 API 往返同量级；将来若要做大文件或批量字幕，
/// 应为传输另立常量而不是继续放大这一个）。
///
/// **60s 这个数值缺实测支撑**：已证实的只有「20s 这道门被用户实际打到」
/// （报错截图 `TimeoutException after 0:00:20`），但没有耗时日志、没抓过成功
/// 请求的 duration、未分链路测，所以 60/40/90 之间无可区分依据——它是基于
/// 用户真实被掐断的**定性放宽**，不是测出来的值。后续若加上耗时采样，
/// 应当用真实 p95 回填这里（并相应放开守卫测试里的下界断言）。
const Duration kDownloadDiscoveryTimeout = Duration(seconds: 60);

/// 下载网络链路**建立连接**（DNS + TCP + 代理隧道 + TLS 握手）的超时上限。
///
/// 与整体超时分层的理由：这条链路最典型的失败不是「被拒绝」而是「丢包」——
/// 目标在墙外、或用户代理进程已退出导致端口不通时，SYN 被静默丢弃，
/// socket 层不会快速报错，会一路挂到应用层超时。若不设这一层，
/// [kDownloadDiscoveryTimeout] 放宽到 60s 就意味着连不上的场景要空转一分钟；
/// 而 UI 在等待期只有一个无进度、无耗时、无取消的转圈（搜索按钮同时 disabled），
/// 那是比原 bug 更难受的体验倒退。
///
/// 10s 足够覆盖「代理可达、只是慢」的握手；连不上则在 10s 内落到错误态 +
/// 重试按钮。同仓 `sync_http.dart` / `galgame_helper_installer.dart` /
/// `magpie_installer.dart` 用的是同一范式。比 `app_http.dart` 的默认 20s 短，
/// 所以 [AppModel.createDownloadHttpClient] 必须显式把它传给
/// `createAppHttpIoClient(connectionTimeout:)`（守卫
/// `test/torrent/download_discovery_timeout_guard_test.dart`）。
const Duration kDownloadConnectionTimeout = Duration(seconds: 10);
