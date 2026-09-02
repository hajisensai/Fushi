/// 内置公开 tracker 兜底集（磁链 `&tr=` 用）。
///
/// 用户可以在下载设置里开 tracker 订阅（`kDefaultTrackerSubscriptionUrl`），但那
/// 条链路要联网、会失败，而且只对**加进引擎的**种子生效；磁链本身带的 tracker 是
/// 离线也成立的那一份。两者不是替代关系：订阅补的是「引擎侧全局」，这里补的是
/// 「磁链自带」，所以这份列表要能独立把种子连起来，不能只留三五条。
///
/// 只收长期存活的公开 tracker，UDP 优先（announce 开销远低于 HTTP）。索引器专属
/// tracker（如 nyaa 的 `nyaa.tracker.wf`）不进这里，由各 client 自己在前面拼。
const List<String> kPublicTrackers = <String>[
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://open.stunner.irish:80/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://opentracker.i2p.rocks:6969/announce',
  'udp://tracker.dler.org:6969/announce',
  'udp://tracker1.bt.moack.co.kr:80/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://bt.ktrackers.com:6666/announce',
  'udp://tracker-udp.gbitt.info:80/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://p4p.arenabg.com:1337/announce',
  'udp://tracker.filemail.com:6969/announce',
  'https://tracker.tamersunion.org:443/announce',
];
