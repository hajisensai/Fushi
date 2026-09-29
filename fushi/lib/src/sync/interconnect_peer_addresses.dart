import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_ping_client.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// 互联「对端 = 同一 hostId 的一组地址」（docs/specs/2026-09-28-interconnect-remote-reach.md
/// §1/§2）。
///
/// 地址列表 `sync_hibiki_client_urls` 仍是扁平的有序列表（持久化格式不变），这里
/// 只提供按 host 视角读它的三件事：分组、组内并发选路、学习合并。没有 hostId 的
/// 老条目各自单独成组、从不探测，行为与升级前逐字一致。

/// 按 host 分组，保持每组首次出现的顺序；组内保持原相对顺序。
List<List<FushiClientUrl>> groupInterconnectPeers(
  Iterable<FushiClientUrl> urls,
) {
  final Map<String, List<FushiClientUrl>> groups =
      <String, List<FushiClientUrl>>{};
  for (final FushiClientUrl u in urls) {
    final String? hostId = u.hostId;
    final String key = (hostId != null && hostId.isNotEmpty)
        ? 'host:$hostId'
        : 'url:${u.url}';
    (groups[key] ??= <FushiClientUrl>[]).add(u);
  }
  return groups.values.toList(growable: false);
}

/// 每台 host 的**身份代表**：组内第一条手输（非 learned）条目，没有就取第一条。
///
/// 用于「列出已配对设备」「把选中的设备存进偏好」这类场景：同一台 host 只出现
/// 一次，且代表地址稳定——learned 条目会随 host 地址变化被自动删除，存它进偏好
/// 会在 host 换 IP 后变成孤儿；手输条目永不被自动删改。
List<FushiClientUrl> interconnectPeerRepresentatives(
  Iterable<FushiClientUrl> urls,
) => <FushiClientUrl>[
  for (final List<FushiClientUrl> g in groupInterconnectPeers(urls))
    _identityOf(g),
];

FushiClientUrl _identityOf(List<FushiClientUrl> group) => group.firstWhere(
  (FushiClientUrl u) => !u.learned,
  orElse: () => group.first,
);

/// [url] 所属 host 的身份代表（[url] 不在列表里 → null）。偏好里存的是某条地址
/// 时，用它判「这台设备还在不在配对清单里」，而不是按 URL 字面精确匹配。
FushiClientUrl? interconnectPeerRepresentativeOf(
  Iterable<FushiClientUrl> urls,
  String url,
) {
  for (final List<FushiClientUrl> g in groupInterconnectPeers(urls)) {
    if (g.any((FushiClientUrl u) => u.url == url)) return _identityOf(g);
  }
  return null;
}

/// [url] 所属 host 的全部地址（[url] 不在列表里 → 空）。
List<FushiClientUrl> interconnectPeerAddressesOf(
  Iterable<FushiClientUrl> urls,
  String url,
) {
  for (final List<FushiClientUrl> g in groupInterconnectPeers(urls)) {
    if (g.any((FushiClientUrl u) => u.url == url)) return g;
  }
  return const <FushiClientUrl>[];
}

/// 每台 host 的**连接代表**：组内并发选路后排在最前的地址（可达者优先）。用于
/// 「对每台已配对设备各发一次请求」的场景。
Future<List<FushiClientUrl>> resolveInterconnectPeerConnections(
  List<FushiClientUrl> enabled, {
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
}) async => <FushiClientUrl>[
  for (final List<FushiClientUrl> g in groupInterconnectPeers(
    await rankInterconnectCandidates(enabled, probe: probe),
  ))
    g.first,
];

/// 一条候选地址是否可达、且背后仍是 [expectedHostId] 那台 host。
typedef InterconnectAddressProbe =
    Future<bool> Function(FushiClientUrl candidate, String? expectedHostId);

/// 默认探测：无鉴权 `/api/ping`（https 带指纹走钉扎连接），2 秒超时。
///
/// 身份核对：组有 hostId 时，ping 回报的 hostId 必须相等。学到的 LAN 地址换个
/// 网络可能指向**别人的** Fushi host——明文 http 下只看 `app=='fushi'` 会选中它，
/// 随后的请求就把本机 token 用 Basic 发了过去。
Future<bool> defaultInterconnectAddressProbe(
  FushiClientUrl candidate,
  String? expectedHostId,
) async {
  final Uri? uri = Uri.tryParse(candidate.url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final FushiPingOutcome outcome = await probeFushiPing(
    candidate.url,
    pinnedFingerprint: candidate.fingerprintSha256,
    timeout: const Duration(seconds: 2),
  );
  final FushiPingResult? result = outcome.result;
  if (result == null) return false;
  if (expectedHostId == null) return true;
  return result.hostId == expectedHostId;
}

/// 在同一台 host 的多条地址里选出最优的可达地址（null = 全不可达）。
///
/// 全部同时探测，但**按优先级（列表顺序）裁决**：排在前面的一旦成功立即胜出；
/// 排在后面的先成功时，最多再给前面还没出结果的 [grace]——LAN 在的话几毫秒就回，
/// 不在的话不必等它的 2 秒超时。总延迟 ≈ 最快可达者的 RTT + [grace]，而升级前是
/// 「死地址个数 × 超时」。
///
/// 只用于**同一台 host** 的地址：跨 host 抢先会把用户换到另一个媒体库。
Future<FushiClientUrl?> raceInterconnectHostAddresses(
  List<FushiClientUrl> addresses, {
  String? hostId,
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  Duration grace = const Duration(milliseconds: 300),
}) {
  if (addresses.isEmpty) return Future<FushiClientUrl?>.value();
  final List<bool?> results = List<bool?>.filled(addresses.length, null);
  final Completer<FushiClientUrl?> done = Completer<FushiClientUrl?>();
  Timer? graceTimer;

  void finish(FushiClientUrl? winner) {
    if (done.isCompleted) return;
    graceTimer?.cancel();
    done.complete(winner);
  }

  FushiClientUrl? bestSucceeded() {
    for (int i = 0; i < results.length; i++) {
      if (results[i] == true) return addresses[i];
    }
    return null;
  }

  void evaluate() {
    if (done.isCompleted) return;
    for (int i = 0; i < results.length; i++) {
      final bool? r = results[i];
      if (r == true) return finish(addresses[i]);
      if (r == null) {
        // 更高优先级还没出结果：有更低优先级已成功就只再等 grace。
        if (bestSucceeded() != null) {
          graceTimer ??= Timer(grace, () => finish(bestSucceeded()));
        }
        return;
      }
    }
    finish(null);
  }

  for (int i = 0; i < addresses.length; i++) {
    final int index = i;
    probe(addresses[index], hostId).then(
      (bool ok) {
        results[index] = ok;
        evaluate();
      },
      onError: (Object e, StackTrace st) {
        engineLog.logDiagnostic('InterconnectRace:${addresses[index].url}', e);
        results[index] = false;
        evaluate();
      },
    );
  }
  return done.future;
}

/// 最近一次选路结果（hostId → 胜出地址），[_raceCacheTtl] 内直接复用，免得查词
/// 这类高频调用每次都多付一轮探测。缓存的地址失效时消费方会顺序试组内其余地址，
/// 不会因为缓存而连不上。
final Map<String, (String url, DateTime at)> _raceCache =
    <String, (String, DateTime)>{};
const Duration _raceCacheTtl = Duration(seconds: 30);

@visibleForTesting
void resetInterconnectRaceCache() => _raceCache.clear();

/// 把候选列表按 host 重排：每台 host 的可达地址排到组首，组内其余保持原序；组
/// 与组之间保持首次出现的顺序。单地址组（含全部老条目）原样不探测。
///
/// 各消费方的「逐个试候选」循环结构不用改，只把数据源换成本函数的结果。
Future<List<FushiClientUrl>> rankInterconnectCandidates(
  List<FushiClientUrl> candidates, {
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  Duration grace = const Duration(milliseconds: 300),
  DateTime Function() now = DateTime.now,
}) async {
  final List<List<FushiClientUrl>> groups = groupInterconnectPeers(candidates);
  final List<List<FushiClientUrl>> ranked =
      await Future.wait(<Future<List<FushiClientUrl>>>[
        for (final List<FushiClientUrl> g in groups)
          _rankGroup(g, probe: probe, grace: grace, now: now),
      ]);
  return <FushiClientUrl>[for (final List<FushiClientUrl> g in ranked) ...g];
}

Future<List<FushiClientUrl>> _rankGroup(
  List<FushiClientUrl> group, {
  required InterconnectAddressProbe probe,
  required Duration grace,
  required DateTime Function() now,
}) async {
  final String? hostId = group.first.hostId;
  if (group.length < 2 || hostId == null) return group;

  final (String, DateTime)? cached = _raceCache[hostId];
  FushiClientUrl? winner;
  if (cached != null && now().difference(cached.$2) < _raceCacheTtl) {
    for (final FushiClientUrl u in group) {
      if (u.url == cached.$1) winner = await _resolveTransport(u);
    }
  }
  // 直连地址（LAN / IPv6 / 组网 / 公网）先并发选；全部不通才建 P2P 隧道——
  // 否则每次选路都会去连一次中继（docs/specs/2026-09-28-interconnect-remote-reach.md §5）。
  winner ??= await raceInterconnectHostAddresses(
    <FushiClientUrl>[
      for (final FushiClientUrl u in group)
        if (!_isP2pUrl(u.url)) u,
    ],
    hostId: hostId,
    probe: probe,
    grace: grace,
  );
  winner ??= await _raceP2p(group, hostId: hostId, probe: probe, grace: grace);
  if (winner == null) {
    _raceCache.remove(hostId);
    return group;
  }
  // 缓存记的是持久地址（P2P 是 `p2p://`，不是本次的本地转发口）。
  final FushiClientUrl first = winner;
  final String persistedUrl = _p2pOrigins[first.url] ?? first.url;
  _raceCache[hostId] = (persistedUrl, now());
  return <FushiClientUrl>[
    first,
    for (final FushiClientUrl u in group)
      if (u.url != persistedUrl) u,
  ];
}

Future<FushiClientUrl?> _raceP2p(
  List<FushiClientUrl> group, {
  required String hostId,
  required InterconnectAddressProbe probe,
  required Duration grace,
}) async {
  final List<FushiClientUrl> tunnels = <FushiClientUrl>[];
  for (final FushiClientUrl u in group) {
    if (!_isP2pUrl(u.url)) continue;
    final FushiClientUrl? resolved = await _resolveTransport(u);
    if (resolved != null) tunnels.add(resolved);
  }
  if (tunnels.isEmpty) return null;
  return raceInterconnectHostAddresses(
    tunnels,
    hostId: hostId,
    probe: probe,
    grace: grace,
  );
}

bool _isP2pUrl(String url) => url.startsWith('p2p://');

/// 本地转发口 URL → 它代表的 `p2p://` 持久地址（选路结果回写缓存 / 组内去重用）。
final Map<String, String> _p2pOrigins = <String, String>{};

/// [url] 若是本进程的 P2P 本地转发口，换回它代表的持久 `p2p://` 地址；其余原样。
/// 凡是「拿选路结果的 baseUrl 回候选列表里找那一行」（取凭据等）都必须先过它：
/// 转发口只活在内存里，列表里存的是 `p2p://`（审查问题 6）。
String interconnectPersistedUrl(String url) => _p2pOrigins[url] ?? url;

/// `p2p://` 地址 → 本地转发口候选（隧道层没装 / 起不来 → null）；其余原样。
Future<FushiClientUrl?> _resolveTransport(FushiClientUrl candidate) async {
  if (!_isP2pUrl(candidate.url)) return candidate;
  final Future<FushiClientUrl?> Function(FushiClientUrl)? resolver =
      _p2pResolver;
  if (resolver == null) return null;
  try {
    final FushiClientUrl? local = await resolver(candidate);
    if (local != null) _p2pOrigins[local.url] = candidate.url;
    return local;
  } on Object catch (e, st) {
    engineLog.log('InterconnectP2p.resolve', e, st);
    return null;
  }
}

Future<FushiClientUrl?> Function(FushiClientUrl candidate)? _p2pResolver;

/// 隧道层装配点：把 `p2p://<nodeId>` 候选变成 `http(s)://127.0.0.1:<转发口>`。
/// 解析出的 URL 只活在内存里（不落库）：转发口每次运行都不同。
void setInterconnectP2pResolver(
  Future<FushiClientUrl?> Function(FushiClientUrl candidate)? resolver,
) {
  _p2pResolver = resolver;
}

/// 一条已存条目的优先级：learned 条目用 host 标注的种类，其余按 URL 推断。
int interconnectEntryRank(FushiClientUrl entry) {
  final String? kind = entry.addressKind;
  if (kind != null) {
    for (final InterconnectAddressKind k in InterconnectAddressKind.values) {
      if (k.name == kind) return interconnectAddressRank(k);
    }
  }
  return interconnectUrlRank(entry.url);
}

/// 一条已存地址的优先级，由 URL 字面推断（存量条目没有记 kind）。与
/// [interconnectAddressRank] 同一刻度：LAN 0、全局 v6 1、组网 2、公网/域名 3、P2P 4。
int interconnectUrlRank(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return 3;
  if (uri.scheme == 'p2p') return 4;
  final String host = uri.host.toLowerCase();
  final List<String> v4 = host.split('.');
  if (v4.length == 4 && v4.every((String p) => int.tryParse(p) != null)) {
    final int a = int.parse(v4[0]);
    final int b = int.parse(v4[1]);
    if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) {
      return 0;
    }
    if (a == 100 && b >= 64 && b <= 127) return 2;
    return 3;
  }
  if (host.contains(':')) {
    // Tailscale 的 ULA 前缀 fd7a:115c:a1e0::/48 是组网，不是局域网。
    if (host.startsWith('fd7a:115c:a1e0')) return 2;
    if (host.startsWith('fc') || host.startsWith('fd')) return 0;
    return 1;
  }
  return 3;
}

/// 把 [url] 挪到 [beforeUrl] 前面（[beforeUrl] 为 null 或已不在列表 → 挪到末尾）。
/// 设置页的拖动排序在**库里最新的**列表上按 URL 执行它：其余条目（包括拖动期间
/// 学习器新插入的）保持相对顺序。[url] 已不在列表 → 原样返回同一实例（不写盘）。
List<FushiClientUrl> moveInterconnectUrlBefore(
  List<FushiClientUrl> urls,
  String url,
  String? beforeUrl,
) {
  final int from = urls.indexWhere((FushiClientUrl u) => u.url == url);
  if (from < 0 || url == beforeUrl) return urls;
  final List<FushiClientUrl> out = <FushiClientUrl>[...urls];
  final FushiClientUrl moved = out.removeAt(from);
  final int to = beforeUrl == null
      ? -1
      : out.indexWhere((FushiClientUrl u) => u.url == beforeUrl);
  out.insert(to < 0 ? out.length : to, moved);
  return out;
}

/// 把 host 公布的地址集合并进候选列表（纯函数，便于单测）。
///
/// - [anchorUrl] 是本次拿到地址集时用的那条地址；它被标上 [hostId]。列表里找不
///   到它（用户刚删了）→ 原样返回。
/// - 同 hostId 的 learned 条目按新集合增删；手输条目永不删改，只在 URL 恰好被
///   host 公布时补标 hostId（同一台机器，归入同组）。
/// - 新条目继承锚点的 token / 指纹 / 展示名：per-peer token 对这台 host 的所有
///   地址都有效，证书也是同一张。指纹只给 https 地址。
/// - 插入位置：同组内第一个优先级更低的条目之前；手输条目的相对顺序不变。
List<FushiClientUrl> mergeLearnedHostAddresses(
  List<FushiClientUrl> list, {
  required String anchorUrl,
  required String hostId,
  required List<InterconnectHostAddress> addresses,
}) {
  final int anchorIndex = list.indexWhere(
    (FushiClientUrl u) => u.url == anchorUrl,
  );
  if (anchorIndex < 0) return list;
  final FushiClientUrl anchor = list[anchorIndex].copyWith(hostId: hostId);
  final Set<String> published = <String>{
    for (final InterconnectHostAddress a in addresses) a.url,
  };

  final List<FushiClientUrl> out = <FushiClientUrl>[];
  for (int i = 0; i < list.length; i++) {
    final FushiClientUrl u = i == anchorIndex ? anchor : list[i];
    if (u.hostId == hostId && u.learned && !published.contains(u.url)) {
      continue; // host 不再公布的学到地址：删。
    }
    if (u.hostId == null && !u.learned && published.contains(u.url)) {
      out.add(u.copyWith(hostId: hostId)); // 手输的同一台机器：归组。
      continue;
    }
    out.add(u);
  }

  for (final InterconnectHostAddress a in addresses) {
    // 只学带密码学身份的地址（https / p2p）；明文地址一律不学，见
    // [isInterconnectLearnableUrl]。
    if (!isInterconnectLearnableUrl(a.url)) continue;
    if (a.kind == InterconnectAddressKind.p2p) {
      // P2P 地址只有装了隧道能力的 client 才用得上；由隧道层自己决定是否收。
      if (!_acceptP2pAddresses) continue;
    }
    if (out.any((FushiClientUrl u) => u.url == a.url)) continue;
    // 指纹只给走 TLS 的地址：https，或 host 开着 TLS 时的 `p2p://…?tls=1`
    // （隧道里跑的仍是同一张自签证书）。
    final bool https = a.url.toLowerCase().startsWith('https://') ||
        (_isP2pUrl(a.url) && Uri.tryParse(a.url)?.queryParameters['tls'] == '1');
    final FushiClientUrl learned = FushiClientUrl(
      url: a.url,
      fingerprintSha256: https ? anchor.fingerprintSha256 : null,
      deviceName: anchor.deviceName,
      token: anchor.token,
      hostId: hostId,
      learned: true,
      addressKind: a.kind.name,
    );
    final int rank = interconnectAddressRank(a.kind);
    int insertAt = -1;
    int lastInGroup = -1;
    for (int i = 0; i < out.length; i++) {
      if (out[i].hostId != hostId) continue;
      lastInGroup = i;
      if (insertAt < 0 && interconnectEntryRank(out[i]) > rank) insertAt = i;
    }
    out.insert(insertAt >= 0 ? insertAt : lastInGroup + 1, learned);
  }
  return out;
}

/// 本 client 是否接收 `p2p://` 地址（隧道能力装配后置 true）。
bool _acceptP2pAddresses = false;

/// 隧道层装配点：原生 P2P 库可用时打开。
void setInterconnectAcceptsP2pAddresses(bool accept) {
  _acceptP2pAddresses = accept;
}

/// 从 host 的 `/api/host/addresses` 学习它公布的地址集并合并进候选列表。
///
/// 触发点：配对成功（立即）、同步选路成功（后台、按地址节流）。学习失败只留痕，
/// 从不影响触发它的那次同步 / 配对——地址集是锦上添花，不是连接前提。
class InterconnectAddressLearner {
  InterconnectAddressLearner(
    this._repo, {
    http.Client Function(String? fingerprint)? clientFactory,
    Duration throttle = const Duration(minutes: 10),
    DateTime Function() now = DateTime.now,
  }) : _clientFactory = clientFactory ?? _defaultClient,
       _throttle = throttle,
       _now = now;

  final SyncRepository _repo;
  final http.Client Function(String? fingerprint) _clientFactory;
  final Duration _throttle;
  final DateTime Function() _now;

  /// 按锚点地址记上次学习时刻（进程内；节流后台刷新）。
  static final Map<String, DateTime> _lastRefresh = <String, DateTime>{};

  @visibleForTesting
  static void resetForTest() {
    _lastRefresh.clear();
  }

  static http.Client _defaultClient(String? fingerprint) =>
      (fingerprint != null && fingerprint.isNotEmpty)
      ? createPinnedHttpPackageClient(expectedFingerprint: fingerprint)
      : http.Client();

  /// 立即学习一次。返回候选列表是否因此改变。
  ///
  /// 只从经 TLS 认证的锚点学：明文锚点背后可能是冒名者，它公布的地址集（哪怕全是
  /// https）会被带着本机 token 落库。
  Future<bool> refresh(FushiClientUrl anchor) async {
    _lastRefresh[anchor.url] = _now();
    if (!anchor.url.toLowerCase().startsWith('https://')) return false;
    final String? token = interconnectTokenFor(
      anchor,
      await _repo.getFushiClientToken(),
    );
    if (token == null) return false;
    final ({String hostId, List<InterconnectHostAddress> addresses})?
    published = await _fetchPublished(anchor, token);
    if (published == null) return false;

    bool changed = false;
    await _repo.updateFushiClientUrls((List<FushiClientUrl> before) {
      final List<FushiClientUrl> after = mergeLearnedHostAddresses(
        before,
        anchorUrl: anchor.url,
        hostId: published.hostId,
        addresses: published.addresses,
      );
      if (_sameList(before, after)) return before;
      changed = true;
      return after;
    });
    return changed;
  }

  /// 后台学习（同一锚点 [_throttle] 内只跑一次）；失败只留痕。
  void refreshInBackground(FushiClientUrl anchor) {
    final DateTime? last = _lastRefresh[anchor.url];
    if (last != null && _now().difference(last) < _throttle) return;
    unawaited(
      refresh(anchor).then<void>(
        (bool _) {},
        onError: (Object e, StackTrace st) =>
            engineLog.logDiagnostic('InterconnectAddressLearner', e),
      ),
    );
  }

  Future<({String hostId, List<InterconnectHostAddress> addresses})?>
  _fetchPublished(FushiClientUrl anchor, String token) async {
    final Uri? base = Uri.tryParse(anchor.url);
    if (base == null || (base.scheme != 'http' && base.scheme != 'https')) {
      return null;
    }
    final Uri uri = base.replace(path: '/api/host/addresses');
    final String? fp = base.scheme == 'https' ? anchor.fingerprintSha256 : null;
    final http.Client client = _clientFactory(fp);
    try {
      final http.Response resp = await client
          .get(
            uri,
            headers: <String, String>{
              'Authorization':
                  'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final Object? decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) return null;
      final Object? hostId = decoded['hostId'];
      final Object? rawAddresses = decoded['addresses'];
      if (hostId is! String || hostId.isEmpty || rawAddresses is! List) {
        return null; // 老 host（404）：不公布地址集。
      }
      final List<InterconnectHostAddress> addresses =
          <InterconnectHostAddress>[];
      for (final Object? e in rawAddresses) {
        final InterconnectHostAddress? a = InterconnectHostAddress.fromJson(e);
        if (a != null) addresses.add(a);
      }
      return (hostId: hostId, addresses: addresses);
    } finally {
      client.close();
    }
  }

  static bool _sameList(List<FushiClientUrl> a, List<FushiClientUrl> b) =>
      jsonEncode(a.map((FushiClientUrl u) => u.toJson()).toList()) ==
      jsonEncode(b.map((FushiClientUrl u) => u.toJson()).toList());
}
