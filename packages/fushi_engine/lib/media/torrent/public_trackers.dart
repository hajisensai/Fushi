/// 内置公开 tracker 兜底集（拼磁链时的 `&tr=`）。
///
/// 与 tracker 订阅（`kDefaultTrackerSubscriptionUrl`，默认指向 trackerslist 的
/// best.txt 镜像）不是替代关系：订阅要联网、会失败，而且只作用于**已经加进引擎
/// 的**种子；磁链自己带的这份是离线也成立的那一批。所以它必须能独立把种子连起
/// 来，不能只留三五条。
///
/// **列表来源（2026-09-02 取样，更新时照做一遍）**：凭印象写 tracker 不行——形
/// 状合法的死 tracker 只会安静地永不响应，没有任何报错。这份是两个持续实测源的
/// 并集，再并上仓库原有的几条（只加不减，免得动到用户已在下的种子）：
///  - `ngosang/trackerslist` 的 `trackers_best.txt`（默认订阅那份的上游）；
///  - `newtrackon.com/api/stable`（uptime ≥ 95%）。
///
/// 注意本机若开着 fake-ip 代理，直接对这些域名发 BEP 15 握手会全部超时（DNS 被
/// 解析成 198.18.x.x），那是环境问题，不能当成 tracker 已死的证据。
///
/// 索引器专属 tracker（如 nyaa 的 `nyaa.tracker.wf`）不进这里，由各 client 自己
/// 拼在最前面。
const List<String> kPublicTrackers = <String>[
  // 仓库原有（保留）。
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://open.stunner.irish:80/announce',
  // 两个源都收录（best + uptime ≥ 95%）。
  'udp://tracker-udp.gbitt.info:80/announce',
  'udp://tracker.qu.ax:6969/announce',
  'udp://tracker.peerfect.org:6969/announce',
  'udp://tracker.opentrackr.com:6969/announce',
  'udp://tracker.ilibr.org:6969/announce',
  'udp://tr4ck3r.duckdns.org:6969/announce',
  'udp://torrentclub.online:1984/announce',
  // 仅 trackers_best.txt 收录。
  'udp://zer0day.ch:1337/announce',
  'udp://tracker.therarbg.to:6969/announce',
  'udp://tracker.publictracker.xyz:6969/announce',
  'udp://tracker2.dler.org:80/announce',
  'udp://tracker.wildkat.net:6969/announce',
  'udp://tracker.filemail.com:6969/announce',
  'udp://tracker.ducks.party:1984/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.auctor.tv:6969/announce',
];
