/// BUG-2950：内置 torrent 引擎的网络诊断（纯函数）。
///
/// 任务长时间 0 peer 时，用户看到的只有「0 做种 / 0 下载者」，分不清是种子死了还是
/// 本机网络把 BT 掐断了。这里只回答后者：引擎会话级的连通性是否异常、异常属于哪种，
/// 由 UI（下载页横幅、种子详情的网络行）照结论展示，不在各处自己拼判据。
library;

/// 会话级网络问题。
enum TorrentNetworkIssue {
  /// 无可报告的问题（或还没到能下结论的时候）。
  none,

  /// 系统 DNS 处在 fake-ip 模式（Clash / mihomo TUN），且 DHT 在真实 IP 引导后仍连不上：
  /// 当前代理节点不转发 UDP，DHT 与 `udp://` tracker 都找不到 peer。
  fakeIpUdpBlocked,

  /// 没检测到 fake-ip，但 DHT 开着且长时间 0 节点：出站 UDP 被防火墙 / 网络拦了。
  dhtUnreachable,
}

/// DHT 冷启动给多久再下结论。真实网络下引导点几秒内就会回包；放宽到 90 秒是为了
/// 不在开机抢网、代理刚起来的那一小段误报。
const Duration kTorrentDhtGracePeriod = Duration(seconds: 90);

/// 判定会话级网络问题。
///
/// - [dhtEnabled]：用户设置里 DHT 是否开着；关着时无从测量，恒为 [TorrentNetworkIssue.none]。
/// - [dhtNodes]：`ht_session_status` 的路由表节点数（-1 = 尚未统计到）。
/// - [sessionAge]：会话（或最近一次网络设置变更）至今的时长。
/// - [fakeIpDetected]：[isFakeIpDnsActive] 的结论。
TorrentNetworkIssue diagnoseTorrentNetwork({
  required bool dhtEnabled,
  required int dhtNodes,
  required Duration sessionAge,
  required bool fakeIpDetected,
}) {
  // DHT 关着时没有可测量的 UDP 信号，不猜。
  if (!dhtEnabled || dhtNodes > 0) return TorrentNetworkIssue.none;
  if (sessionAge < kTorrentDhtGracePeriod) return TorrentNetworkIssue.none;
  return fakeIpDetected
      ? TorrentNetworkIssue.fakeIpUdpBlocked
      : TorrentNetworkIssue.dhtUnreachable;
}
