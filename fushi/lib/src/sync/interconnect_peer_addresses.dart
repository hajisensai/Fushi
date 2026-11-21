import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/interconnect_device_name.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart'
    show interconnectTunnelOriginUrl;
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
///
/// 不变式（BUG 地址归属闸）：**列表里 URL 唯一，是行主键；hostId 是行的归属标签。**
/// 设置页、偏好 `downloadExecutionHostUrl`、ctl 选择器、各 client 的凭据查找都按
/// URL 定位行；所有写路径（`addFushiClientUrl`、学习合并、设置页编辑）都按 URL
/// 去重，不得新增能产生重复 URL 的路径。往某一行写凭据前必须核对它的归属：行已归
/// 另一台 host 时不得静默写入（见 [interconnectAddressOwnerConflict] /
/// [applyIssuedInterconnectToken]），只有用户确认「作为新设备配对」才让这一行脱离
/// 旧组。TOFU 指纹比对与 MITM 守卫仍按 URL 判，不看对端自报的 hostId。

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

/// 设置页一条地址行在所属 host 里的位置：[index] 从 1 起、按列表顺序（也就是组内
/// 选路的优先顺序），[count] 是这台 host 的地址总数，[rank] 同 [interconnectEntryRank]，
/// [learned] 表示由 host 公布自动学到。
typedef InterconnectPeerAddressSlot = ({
  int index,
  int count,
  int rank,
  bool learned,
});

/// [entry] 在 [urls] 里所属 host 的位置；这台 host 只有一条地址（含全部无 hostId 的
/// 老条目）或 [entry] 不在列表里 → null。
///
/// 「已添加的设备」逐地址成行（排序 = 选路优先级、开关 / 测试结果 / 重新配对都按
/// 地址），同一台 host 的多条地址标题都是同一个设备名；靠它给每行标出「第几条、
/// 什么网络、是不是自动学到的」，两行才不会看起来像重复配对（BUG-4691）。
InterconnectPeerAddressSlot? interconnectPeerAddressSlotOf(
  List<FushiClientUrl> urls,
  FushiClientUrl entry,
) {
  final List<FushiClientUrl> group = interconnectPeerAddressesOf(
    urls,
    entry.url,
  );
  if (group.length < 2) return null;
  final int at = group.indexWhere((FushiClientUrl u) => u.url == entry.url);
  return (
    index: at + 1,
    count: group.length,
    rank: interconnectEntryRank(group[at]),
    learned: group[at].learned,
  );
}

/// 「忘记这台 host」：去掉 [url] 那一行；它带 [hostId] 时删的是**那台 host** 的全部
/// 地址——同组其余地址都带着它的 token，只删一行等于没解绑（剩下的照常同步，被删的
/// learned 地址 10 分钟内还会被学回来）。老条目（无 hostId）只删那一行。
/// 设置页地址行的删除与控制通道 `peer forget` 共用。
List<FushiClientUrl> withoutInterconnectHost(
  Iterable<FushiClientUrl> urls, {
  required String url,
  String? hostId,
}) => <FushiClientUrl>[
  for (final FushiClientUrl u in urls)
    if (u.url != url && (hostId == null || u.hostId != hostId)) u,
];

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
  final InterconnectAddressProbe? override = _probeOverride;
  if (override != null) return override(candidate, expectedHostId);
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

InterconnectAddressProbe? _probeOverride;

/// 测试缝：替换 [defaultInterconnectAddressProbe] 的真实 ping。只在测试的 `setUp`
/// 里设、`tearDown` 里清空（null）。
@visibleForTesting
set debugInterconnectAddressProbeOverride(InterconnectAddressProbe? probe) {
  _probeOverride = probe;
}

/// 在同一台 host 的多条地址里选出最优的可达地址（null = 全不可达）。
///
/// 全部同时探测，但**按优先级（列表顺序）裁决**：排在前面的一旦成功立即胜出；
/// 排在后面的先成功时，最多再给前面还没出结果的 [grace]——LAN 在的话几毫秒就回，
/// 不在的话不必等它的 2 秒超时。总延迟 ≈ 最快可达者的 RTT + [grace]，而升级前是
/// 「死地址个数 × 超时」。
///
/// 只用于**同一台 host** 的地址：跨 host 抢先会把用户换到另一个媒体库。
///
/// [onResult] 在每条探测结果落地时回调——包括胜者已决出之后才回来的结果；它不
/// 影响裁决，只用来记下「哪些地址核对通过」。
Future<FushiClientUrl?> raceInterconnectHostAddresses(
  List<FushiClientUrl> addresses, {
  String? hostId,
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  Duration grace = const Duration(milliseconds: 300),
  void Function(FushiClientUrl candidate, bool ok)? onResult,
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
        onResult?.call(addresses[index], ok);
        evaluate();
      },
      onError: (Object e, StackTrace st) {
        engineLog.logDiagnostic('InterconnectRace:${addresses[index].url}', e);
        results[index] = false;
        onResult?.call(addresses[index], false);
        evaluate();
      },
    );
  }
  return done.future;
}

/// 最近一次选路结果（hostId → 胜出地址的持久 URL + 本轮核对通过的明文地址集），
/// [_raceCacheTtl] 内直接复用，免得查词这类高频调用每次都多付一轮探测。缓存只决定
/// 组内顺序：返回的整组都是可拨的（`p2p://` 已换成本地转发口），缓存的地址失效时
/// 消费方顺序试组内其余地址照样能到；消费方用 [reportInterconnectCandidateUnreachable]
/// 报告失败后缓存立即作废，不会在 TTL 内一直把死地址排在组首（BUG-4278）。
///
/// `verifiedPlain` 是可变集合：本轮竞速开始前建好并写进缓存项，胜者决出之后才回来
/// 的明文探测结果（`onResult(ok=true)`）照样加进来，缓存窗口内就能用上。
final Map<String, (String url, DateTime at, Set<String> verifiedPlain)>
_raceCache = <String, (String, DateTime, Set<String>)>{};
const Duration _raceCacheTtl = Duration(seconds: 30);

@visibleForTesting
void resetInterconnectRaceCache() => _raceCache.clear();

/// 互联请求的传输层结局观察者：[reached] = 经 [candidate] 拿到了任何 HTTP 响应（含
/// 401 / 404 / 坏回包——对端活着），false = 连接被拒 / 超时 / 断开。
typedef InterconnectReachabilityObserver =
    void Function(FushiClientUrl candidate, bool reached);

final List<InterconnectReachabilityObserver> _reachabilityObservers =
    <InterconnectReachabilityObserver>[];

/// 订阅 [reportInterconnectCandidateReached] / [reportInterconnectCandidateUnreachable]
/// ——互联可达性的**唯一**上报点。按 host 的在线状态（词典服务器卡片、查词跳过死
/// host，BUG-4692）从这里听，不再在各传输层另开一条结局回调。
void addInterconnectReachabilityObserver(
  InterconnectReachabilityObserver observer,
) => _reachabilityObservers.add(observer);

void removeInterconnectReachabilityObserver(
  InterconnectReachabilityObserver observer,
) => _reachabilityObservers.remove(observer);

void _notifyReachability(FushiClientUrl candidate, bool reached) {
  for (final InterconnectReachabilityObserver o
      in List<InterconnectReachabilityObserver>.of(_reachabilityObservers)) {
    o(candidate, reached);
  }
}

/// 消费方对 [candidate]（选路结果里的一条，可以是本地转发口）的请求在传输层失败了
/// （连接被拒 / 建连超时 / 断开）：它若正是该 host 缓存的胜出地址，作废缓存，下一次
/// 选路重新竞速，不在缓存窗口内反复先撞那条死地址。观察者
/// （[addInterconnectReachabilityObserver]）照常收到这次结局。
void reportInterconnectCandidateUnreachable(FushiClientUrl candidate) {
  _notifyReachability(candidate, false);
  final String? hostId = candidate.hostId;
  if (hostId == null) return;
  final (String, DateTime, Set<String>)? cached = _raceCache[hostId];
  if (cached != null && cached.$1 == interconnectPersistedUrl(candidate.url)) {
    _raceCache.remove(hostId);
  }
}

/// 消费方经 [candidate] 拿到了 host 的应答：该 host 没有有效缓存（刚因失败作废）时
/// 记它为胜出地址，后续请求不必重新探测一轮死地址。已有缓存不覆盖。观察者照常收到。
///
/// 只记自带密码学身份的地址（[_credentialSafe]）：明文地址能否拿凭据要靠选路当场
/// ping 核对 hostId（V-B4），不能凭一次应答写进缓存绕过核对——明文胜者留给下一次
/// 选路重新竞速。
void reportInterconnectCandidateReached(
  FushiClientUrl candidate, {
  DateTime Function() now = DateTime.now,
}) {
  _notifyReachability(candidate, true);
  final String? hostId = candidate.hostId;
  if (hostId == null || !_credentialSafe(candidate)) return;
  final (String, DateTime, Set<String>)? cached = _raceCache[hostId];
  if (cached != null && now().difference(cached.$2) < _raceCacheTtl) return;
  _raceCache[hostId] = (
    interconnectPersistedUrl(candidate.url),
    now(),
    <String>{},
  );
}

/// 地址本身带密码学身份：https 且钉了指纹，或持久地址是 `p2p://`（含本进程的
/// 转发口——按 [interconnectPersistedUrl] 换回 `p2p://` 判）。其余（明文 http、
/// 未钉扎的 https）只有当场 ping 核对 hostId 通过才可以拿凭据。
bool _credentialSafe(FushiClientUrl u) {
  if (_isP2pUrl(interconnectPersistedUrl(u.url))) return true;
  return u.url.toLowerCase().startsWith('https://') &&
      (u.fingerprintSha256?.isNotEmpty ?? false);
}

/// 选路结果：[ranked] 是可以拿凭据去请求、且此刻拨得出去的候选（按 host 重排）；
/// [withheld] 是此刻用不上的地址数——明文地址当场核对 hostId 没通过（或没机会核对）
/// 而被扣下，或 `p2p://` 换不出本地转发口（隧道层没装 / 起不来）。消费方据此把
/// 「有已配对地址但一条都用不上」报成不可达，而不是「未配对」（BUG-4278 审查）。
typedef InterconnectRankedCandidates = ({
  List<FushiClientUrl> ranked,
  int withheld,
});

/// 把候选列表按 host 重排：每台 host 的可达地址排到组首，组内其余保持原序；组
/// 与组之间保持首次出现的顺序。老条目（无 hostId）原样不探测。
///
/// 带 hostId 的组里只要有明文成员（含单地址组），就必须当场 ping 核对：没核对
/// 通过的明文地址从结果里扣掉（V-B4）——它可能已经指向另一台 Fushi host，带着
/// 本组 token 的 Basic 请求不能发过去。
///
/// 返回的每一条都可以直接拨：`p2p://` 已换成本进程的本地转发口（隧道层没装 / 起
/// 不来的 `p2p://` 去掉、计入 withheld）。换转发口只在本机开一个回环监听口，真正的
/// 隧道连接在第一次有请求经过时才建。
///
/// 各消费方的「逐个试候选」循环结构不用改，只把数据源换成本函数的结果。
Future<List<FushiClientUrl>> rankInterconnectCandidates(
  List<FushiClientUrl> candidates, {
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  Duration grace = const Duration(milliseconds: 300),
  DateTime Function() now = DateTime.now,
}) async => (await rankInterconnectCandidatesDetailed(
  candidates,
  probe: probe,
  grace: grace,
  now: now,
)).ranked;

/// [rankInterconnectCandidates] 的详细版：同时给出此刻用不上的地址数，消费方据此把
/// 「候选全被扣下」报成不可达（而不是「未配对」）。
Future<InterconnectRankedCandidates> rankInterconnectCandidatesDetailed(
  List<FushiClientUrl> candidates, {
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  Duration grace = const Duration(milliseconds: 300),
  DateTime Function() now = DateTime.now,
}) async {
  final List<List<FushiClientUrl>> groups = groupInterconnectPeers(candidates);
  final List<InterconnectRankedCandidates> ranked =
      await Future.wait(<Future<InterconnectRankedCandidates>>[
        for (final List<FushiClientUrl> g in groups)
          _rankGroup(g, probe: probe, grace: grace, now: now),
      ]);
  return (
    ranked: <FushiClientUrl>[
      for (final InterconnectRankedCandidates g in ranked) ...g.ranked,
    ],
    withheld: ranked.fold<int>(
      0,
      (int sum, InterconnectRankedCandidates g) => sum + g.withheld,
    ),
  );
}

Future<InterconnectRankedCandidates> _rankGroup(
  List<FushiClientUrl> group, {
  required InterconnectAddressProbe probe,
  required Duration grace,
  required DateTime Function() now,
}) async {
  final String? hostId = group.first.hostId;
  // 老条目（无 hostId）没有可核对的身份，语义与升级前一致。
  if (hostId == null) return _dialable(group, withheld: 0);
  final bool hasPlain = group.any((FushiClientUrl u) => !_credentialSafe(u));
  // 全员自带密码学身份的单地址组不必探测——除非装了局域网重新定位
  // （[setInterconnectLanRelocation]）且这条是直连地址：不探就不知道它已经失效，
  // 换网后唯一那条旧地址会被原样交给消费方撞超时，永远轮不到 mDNS 去找新地址
  // （BUG-5068）。地址还活着时这一 ping 只多几毫秒。
  if (!hasPlain &&
      group.length < 2 &&
      (_lanRelocator == null || _isP2pUrl(group.first.url))) {
    return _dialable(group, withheld: 0);
  }

  final (String, DateTime, Set<String>)? cached = _raceCache[hostId];
  FushiClientUrl? winner;
  Set<String>? verified;
  // 命中缓存不续期：TTL 从那次真正选路算起，到期必重选。命中就续期的话，持续
  // 有请求时缓存永不过期——直连恢复后仍一直走隧道 / 中继（BUG-4278 审查）。
  if (cached != null && now().difference(cached.$2) < _raceCacheTtl) {
    for (final FushiClientUrl u in group) {
      if (u.url == cached.$1) winner = await _resolveTransport(u);
    }
    // 缓存的 `p2p://` 这次换不出转发口（隧道层停了）：winner 仍为 null，重新选路。
    if (winner != null) verified = cached.$3;
  }
  if (winner == null) {
    final Set<String> fresh = <String>{};
    verified = fresh;
    // 直连地址（LAN / IPv6 / 组网 / 公网）先并发选；全部不通才建 P2P 隧道——
    // 否则每次选路都会去连一次中继（docs/specs/2026-09-28-interconnect-remote-reach.md §5）。
    // 隧道成员按 [_credentialSafe] 判定，不需要记核对结果。
    winner = await raceInterconnectHostAddresses(
      <FushiClientUrl>[
        for (final FushiClientUrl u in group)
          if (!_isP2pUrl(u.url)) u,
      ],
      hostId: hostId,
      probe: probe,
      grace: grace,
      onResult: (FushiClientUrl c, bool ok) {
        if (ok && !_credentialSafe(c)) fresh.add(c.url);
      },
    );
    // 存量直连地址全不通：先在局域网上按 hostId 找这台 host 现在的地址（换网 /
    // 连手机热点后它换了网段，旧地址一条都不在新网络里，BUG-5068），再建隧道。
    // 重新定位到的地址带本组钉扎的指纹，与 https 直连同属 [_credentialSafe]。
    winner ??= await _raceRelocated(
      group,
      hostId: hostId,
      probe: probe,
      grace: grace,
    );
    winner ??= await _raceP2p(
      group,
      hostId: hostId,
      probe: probe,
      grace: grace,
    );
    if (winner != null) {
      // 缓存记的是持久地址（P2P 是 `p2p://`，不是本次的本地转发口）。
      _raceCache[hostId] = (interconnectPersistedUrl(winner.url), now(), fresh);
    }
  }
  if (winner == null) {
    // 全不可达：带密码学身份的地址照常交给消费方去试（`p2p://` 换成转发口），
    // 明文地址一律扣下。
    _raceCache.remove(hostId);
    final List<FushiClientUrl> safe = <FushiClientUrl>[
      for (final FushiClientUrl u in group)
        if (_credentialSafe(u)) u,
    ];
    // 一条都不交给消费方（全是明文地址、全没探通）：这台 host 此刻就是不可达，消费方
    // 不会再发请求、也就不会再上报，在这里替它报给观察者。有可拨的安全地址时由消费方
    // 试过之后上报。
    if (safe.isEmpty) _notifyReachability(group.first, false);
    return _dialable(safe, withheld: group.length - safe.length);
  }
  final Set<String> verifiedPlain = verified!;
  final String persistedUrl = interconnectPersistedUrl(winner.url);
  final List<FushiClientUrl> ordered = <FushiClientUrl>[
    winner,
    for (final FushiClientUrl u in group)
      if (u.url != persistedUrl) u,
  ];
  final List<FushiClientUrl> ranked = <FushiClientUrl>[
    for (final FushiClientUrl u in ordered)
      if (_credentialSafe(u) || verifiedPlain.contains(u.url)) u,
  ];
  // 胜者已是可拨地址；组内其余 `p2p://` 也换成转发口，直连胜者失效时消费方能顺序
  // 试到隧道（BUG-4278：只换胜者时其余 `p2p://` 原样交出，消费方拼不出地址）。
  return _dialable(ranked, withheld: ordered.length - ranked.length);
}

/// [group] 的每条都换成可拨地址（`p2p://` → 本地转发口，换不出的去掉并计入
/// withheld），顺序不变。
Future<InterconnectRankedCandidates> _dialable(
  List<FushiClientUrl> group, {
  required int withheld,
}) async {
  if (!group.any((FushiClientUrl u) => _isP2pUrl(u.url))) {
    return (ranked: group, withheld: withheld);
  }
  final List<FushiClientUrl> out = <FushiClientUrl>[];
  for (final FushiClientUrl u in group) {
    final FushiClientUrl? resolved = await _resolveTransport(u);
    if (resolved != null) out.add(resolved);
  }
  return (ranked: out, withheld: withheld + group.length - out.length);
}

/// 局域网重新定位（BUG-5068）：存量直连地址全不通时，向 [_lanRelocator] 要这台 host
/// 此刻在局域网上公布的地址，按本组身份核对后竞速；胜者交给 [_relocatedSink] 落库。
///
/// 只认 https，且必须用本组已钉扎的证书指纹去探：mDNS 的 TXT `id`（= hostId）是
/// 无鉴权的公开值，冒名者能自报别人的 hostId，但给不出那台 host 私钥对应的证书——
/// 钉扎握手 + ping 回报的 hostId 两样都对上才算同一台机器。组里没有钉扎指纹（明文
/// host）或钉扎指纹互相不一致时不重新定位：明文地址按地址归属闸一律不学
/// （[isInterconnectLearnableUrl]），也没有可以证明身份的东西。
Future<FushiClientUrl?> _raceRelocated(
  List<FushiClientUrl> group, {
  required String hostId,
  required InterconnectAddressProbe probe,
  required Duration grace,
}) async {
  final InterconnectLanRelocator? relocator = _lanRelocator;
  if (relocator == null) return null;
  // 「存量直连地址全部探不通」才轮到这里：组里一条直连地址都没有（只有 `p2p://`）
  // 时不是换网，不为它多等一轮局域网浏览。
  if (!group.any((FushiClientUrl u) => !_isP2pUrl(u.url))) return null;
  final FushiClientUrl? base = _relocationBase(group);
  if (base == null) return null;
  final List<String> found;
  try {
    found = await relocator(hostId);
  } on Object catch (e, st) {
    // 浏览失败（平台没有 mDNS 能力、权限被拒）只说明这条兜底此刻用不上，选路照常
    // 走隧道；留痕便于诊断。
    engineLog.log('InterconnectLanRelocate', e, st);
    return null;
  }
  final Set<String> known = <String>{
    for (final FushiClientUrl u in group) u.url,
  };
  final List<FushiClientUrl> fresh = <FushiClientUrl>[
    for (final String url in found.toSet())
      if (url.toLowerCase().startsWith('https://') && !known.contains(url))
        FushiClientUrl(
          url: url,
          fingerprintSha256: base.fingerprintSha256,
          deviceName: base.deviceName,
          token: base.token,
          hostId: hostId,
          learned: true,
          lookupEnabled: base.lookupEnabled,
        ),
  ];
  if (fresh.isEmpty) return null;
  final FushiClientUrl? winner = await raceInterconnectHostAddresses(
    fresh,
    hostId: hostId,
    probe: probe,
    grace: grace,
  );
  if (winner == null) return null;
  final InterconnectRelocatedAddressSink? sink = _relocatedSink;
  if (sink != null) {
    try {
      await sink(winner);
    } on Object catch (e, st) {
      // 落库失败不影响这一次连接（地址已当场核对过）；下次选路会重新定位。
      engineLog.log('InterconnectLanRelocate.persist', e, st);
    }
  }
  return winner;
}

/// 重新定位到的地址从哪一行继承凭据与指纹：组里第一条钉了指纹的行。组内钉扎指纹
/// 不一致（证书换过、旧行没清）→ null：分不清哪张才是这台 host 现在的证书，不猜。
FushiClientUrl? _relocationBase(List<FushiClientUrl> group) {
  FushiClientUrl? base;
  for (final FushiClientUrl u in group) {
    final String? fp = u.fingerprintSha256;
    if (fp == null || fp.isEmpty) continue;
    if (base == null) {
      base = u;
    } else if (!fingerprintEquals(base.fingerprintSha256!, fp)) {
      return null;
    }
  }
  return base;
}

/// 按 hostId 在局域网上找这台 host 此刻公布的地址（`https://<ip>:<port>`），限时
/// 返回。app 侧用 mDNS 浏览实现（`interconnect_lan_relocation.dart`）。
typedef InterconnectLanRelocator = Future<List<String>> Function(String hostId);

/// 重新定位并核对通过的地址（learned 行，带本组 hostId / token / 指纹）交给它落库。
typedef InterconnectRelocatedAddressSink =
    Future<void> Function(FushiClientUrl verified);

InterconnectLanRelocator? _lanRelocator;
InterconnectRelocatedAddressSink? _relocatedSink;

/// 局域网重新定位装配点（BUG-5068）：已配对 host 换了网段（电脑改连手机热点）后，
/// 存量地址全失效、而学新地址又要先连上它——没有这一步就是死结。传 null 撤掉。
void setInterconnectLanRelocation({
  InterconnectLanRelocator? relocator,
  InterconnectRelocatedAddressSink? sink,
}) {
  _lanRelocator = relocator;
  _relocatedSink = sink;
}

/// 把局域网重新定位核对通过的 [verified] 并入候选列表（纯函数）。
///
/// 遵守地址归属闸：URL 是行主键，列表里已有这条 URL（不论归谁）一律不动；这台
/// host 的组已不在列表里（用户刚删了它）不加；组内已钉扎的指纹必须与 [verified]
/// 相同（与 [_anchorMayClaimHostId] 同一判据）。并入的是 learned 行，插在组内第一条
/// 优先级更低的条目之前，token 取组里此刻的那一份（重新配对换过 token 时不写旧的）。
/// 之后照常由 [InterconnectAddressLearner] 以它为锚点刷新整组地址集。
List<FushiClientUrl> mergeRelocatedInterconnectAddress(
  List<FushiClientUrl> list,
  FushiClientUrl verified,
) {
  final String? hostId = verified.hostId;
  final String? fp = verified.fingerprintSha256;
  if (hostId == null ||
      hostId.isEmpty ||
      fp == null ||
      fp.isEmpty ||
      !verified.url.toLowerCase().startsWith('https://')) {
    return list;
  }
  if (list.any((FushiClientUrl u) => u.url == verified.url)) return list;
  String? token;
  bool pinned = false;
  bool inGroup = false;
  for (final FushiClientUrl u in list) {
    if (u.hostId != hostId) continue;
    inGroup = true;
    final String? memberFp = u.fingerprintSha256;
    if (memberFp != null && memberFp.isNotEmpty) {
      if (!fingerprintEquals(memberFp, fp)) return list;
      pinned = true;
    }
    if (token == null && (u.token?.isNotEmpty ?? false)) token = u.token;
  }
  if (!inGroup || !pinned) return list;
  final FushiClientUrl row = FushiClientUrl(
    url: verified.url,
    enabled: verified.enabled,
    fingerprintSha256: fp,
    deviceName: verified.deviceName,
    token: token ?? verified.token,
    hostId: hostId,
    learned: true,
    addressKind: verified.addressKind,
    lookupEnabled: verified.lookupEnabled,
  );
  final List<FushiClientUrl> out = <FushiClientUrl>[...list];
  _insertIntoHostGroup(out, row, hostId, interconnectEntryRank(row));
  return out;
}

/// 把 [learned] 插进 [out] 里 [hostId] 那一组：组内第一个优先级（[rank] 刻度）更低的
/// 条目之前，没有就放在组尾。
void _insertIntoHostGroup(
  List<FushiClientUrl> out,
  FushiClientUrl learned,
  String hostId,
  int rank,
) {
  int insertAt = -1;
  int lastInGroup = -1;
  for (int i = 0; i < out.length; i++) {
    if (out[i].hostId != hostId) continue;
    lastInGroup = i;
    if (insertAt < 0 && interconnectEntryRank(out[i]) > rank) insertAt = i;
  }
  out.insert(insertAt >= 0 ? insertAt : lastInGroup + 1, learned);
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

/// [url] 若是本进程**仍存活**的 P2P 本地转发口，换回它代表的持久 `p2p://` 地址；
/// 其余原样。凡是「拿选路结果的 baseUrl 回候选列表里找那一行」（取凭据等）都必须
/// 先过它：转发口只活在内存里，列表里存的是 `p2p://`（审查问题 6）。
///
/// 映射由 engine 随转发口一起持有（[interconnectTunnelOriginUrl]）：换提示撤口、
/// 关端点时一并回收，已撤销的旧口按普通回环明文地址看待，不再冒充隧道。
String interconnectPersistedUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasPort ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery) {
    return url;
  }
  return interconnectTunnelOriginUrl(uri.host, uri.port) ?? url;
}

/// `p2p://` 地址 → 本地转发口候选（隧道层没装 / 起不来 → null）；其余原样。
Future<FushiClientUrl?> _resolveTransport(FushiClientUrl candidate) async {
  if (!_isP2pUrl(candidate.url)) return candidate;
  final Future<FushiClientUrl?> Function(FushiClientUrl)? resolver =
      _p2pResolver;
  if (resolver == null) return null;
  try {
    return await resolver(candidate);
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

/// 锚点能否以 [hostId] 的身份并组。hostId 是公开值（ping / mDNS 都能拿到），任何
/// 被配对过一次的 host 都能在 `/api/host/addresses` 里自报别人的 hostId；只认它就会
/// 把真 host 的 learned 地址删掉、把冒名者并进那一组（审查 B1 / B2）。所以：
/// - 锚点已标了别的 hostId → 拒绝（一条地址不会中途换主人）；
/// - 锚点已是该组成员 → 放行（入组时已核对过）；
/// - 锚点要**加入**一个已有条目的组 → 锚点必须钉扎了证书指纹，且与组内已钉扎的
///   指纹相等（指纹 = 那台 host 的私钥，冒名者给不出同一个；明文锚点没有指纹，一律
///   不能并入已有的组）。
bool _anchorMayClaimHostId(
  List<FushiClientUrl> list,
  int anchorIndex,
  String hostId,
) {
  final FushiClientUrl anchor = list[anchorIndex];
  final String? current = anchor.hostId;
  if (current != null && current.isNotEmpty) return current == hostId;
  final String? anchorFp = anchor.fingerprintSha256;
  for (int i = 0; i < list.length; i++) {
    if (i == anchorIndex || list[i].hostId != hostId) continue;
    if (anchorFp == null || anchorFp.isEmpty) return false;
    final String? fp = list[i].fingerprintSha256;
    if (fp != null && fp.isNotEmpty && !fingerprintEquals(fp, anchorFp)) {
      return false;
    }
  }
  return true;
}

/// 同一网段（/64 前缀 + scheme + 端口）的 IPv6 地址只留一条。
///
/// 开着 IPv6 隐私扩展的主机（Windows / Android / macOS 默认）每天换一个临时地址，
/// 旧的以「已弃用」状态再挂最多 7 天；`dart:io` 拿不到临时 / 弃用标志，host 会把
/// 它们全部公布出来。逐条学下来，配对列表就会堆满同一台机器的十几行 IPv6，每次
/// 选路还要逐条探测。同一 /64 里的地址可达性相同，留一条就够。
///
/// 选哪条：[preferUrls] 里最先出现的（已在列表里的那条，免得每次刷新换一条），
/// 没有就取公布顺序的第一条。非 IPv6 字面量地址原样保留。
List<InterconnectHostAddress> collapseRotatingIpv6Addresses(
  List<InterconnectHostAddress> addresses, {
  List<String> preferUrls = const <String>[],
}) {
  final Map<String, List<InterconnectHostAddress>> byPrefix =
      <String, List<InterconnectHostAddress>>{};
  for (final InterconnectHostAddress a in addresses) {
    final String? key = _ipv6PrefixKey(a.url);
    if (key != null) (byPrefix[key] ??= <InterconnectHostAddress>[]).add(a);
  }
  final Set<String> chosen = <String>{};
  for (final List<InterconnectHostAddress> group in byPrefix.values) {
    InterconnectHostAddress pick = group.first;
    for (final String url in preferUrls) {
      final int i = group.indexWhere(
        (InterconnectHostAddress a) => a.url == url,
      );
      if (i >= 0) {
        pick = group[i];
        break;
      }
    }
    chosen.add(pick.url);
  }
  return <InterconnectHostAddress>[
    for (final InterconnectHostAddress a in addresses)
      if (_ipv6PrefixKey(a.url) == null || chosen.contains(a.url)) a,
  ];
}

/// `https://[2408:…]:38765` → `https|2408:821b:9a33:8900|38765`；非 IPv6 字面量 → null。
String? _ipv6PrefixKey(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.host.contains(':')) return null;
  final InternetAddress? ip = InternetAddress.tryParse(uri.host);
  if (ip == null || ip.type != InternetAddressType.IPv6) return null;
  final List<int> raw = ip.rawAddress;
  final String prefix = <String>[
    for (int i = 0; i < 8; i += 2)
      ((raw[i] << 8) | raw[i + 1]).toRadixString(16),
  ].join(':');
  return '${uri.scheme}|$prefix|${uri.port}';
}

/// [url] 那一行此刻属于另一台 host：行带非空 hostId，且签发方 [incomingHostId]
/// 为空（v1 / 老 host 证明不了自己是那台）或与之不同。返回那一行；不冲突 / 不在
/// 列表 → null。
FushiClientUrl? interconnectAddressOwnerConflict(
  Iterable<FushiClientUrl> list,
  String url, {
  String? incomingHostId,
}) {
  for (final FushiClientUrl u in list) {
    if (u.url != url) continue;
    final String? owner = u.hostId;
    if (owner == null || owner.isEmpty) return null;
    if (incomingHostId != null &&
        incomingHostId.isNotEmpty &&
        incomingHostId == owner) {
      return null;
    }
    return u;
  }
  return null;
}

/// 往一条已归另一台 host 的地址写凭据，而调用方没有拿到用户「作为新设备配对」的
/// 确认（见 [applyIssuedInterconnectToken] 的 `reassignOwner`）。
final class InterconnectAddressOwnerConflict implements Exception {
  const InterconnectAddressOwnerConflict({
    required this.url,
    required this.ownerHostId,
    this.ownerDeviceName,
    this.incomingHostId,
  });

  final String url;
  final String ownerHostId;
  final String? ownerDeviceName;
  final String? incomingHostId;

  @override
  String toString() =>
      'InterconnectAddressOwnerConflict($url: owner=$ownerHostId '
      'incoming=$incomingHostId)';
}

/// 53NT7G_tSO：把 host 刚签发给本机的 per-peer token 落到 [url] 那一行，**并同步到
/// 同一台 host 的全部地址**（纯函数）。
///
/// host 按设备记 token（`upsertPairedPeer` 以 deviceId 为键）：经任一地址重新配对，
/// 这台设备的旧 token 当场作废。以前只改了配对用的那一行，同组其余地址（内网 /
/// 外网 / IPv6 / P2P）还拿着旧 token 撞 401——用户看到的就是「内网和外网 token
/// 不同」，而 UI 又不提供逐地址配置。
///
/// [hostId] 是配对时 `/api/ping` 回报的 host 身份：这一行还没有 hostId 时，按
/// 与地址学习同一判据（[_anchorMayClaimHostId]：同组已钉扎的证书指纹必须相同）
/// 给它补标，再按组同步。不满足判据（对不上指纹 / 明文地址想并入已有组）就只改
/// 这一行，绝不把 token 发去另一台机器。[url] 不在列表里 → 原样返回。
///
/// 地址归属闸：这一行已归另一台 host（[interconnectAddressOwnerConflict]）时，
/// [reassignOwner] 为 false 抛 [InterconnectAddressOwnerConflict]、列表不动——以前
/// 这里不改标签却把 token 写进了旧 host 的整组；为 true（用户已确认「作为新设备
/// 配对」）则这一行脱离旧组（清 hostId / token / 展示名 / learned），再按「行还没有
/// hostId」处理，旧组其余各行一律不动。
List<FushiClientUrl> applyIssuedInterconnectToken(
  List<FushiClientUrl> list, {
  required String url,
  required String token,
  String? hostId,
  bool reassignOwner = false,
}) {
  final int index = list.indexWhere((FushiClientUrl u) => u.url == url);
  if (index < 0) return list;
  List<FushiClientUrl> rows = list;
  final FushiClientUrl? owner = interconnectAddressOwnerConflict(
    list,
    url,
    incomingHostId: hostId,
  );
  if (owner != null) {
    if (!reassignOwner) {
      throw InterconnectAddressOwnerConflict(
        url: url,
        ownerHostId: owner.hostId!,
        ownerDeviceName: owner.deviceName,
        incomingHostId: hostId,
      );
    }
    rows = <FushiClientUrl>[...list]
      ..[index] = FushiClientUrl(
        url: owner.url,
        enabled: owner.enabled,
        fingerprintSha256: owner.fingerprintSha256,
        addressKind: owner.addressKind,
      );
  }
  FushiClientUrl row = rows[index];
  if (hostId != null &&
      hostId.isNotEmpty &&
      (row.hostId == null || row.hostId!.isEmpty) &&
      _anchorMayClaimHostId(rows, index, hostId)) {
    row = row.copyWith(hostId: hostId);
  }
  final String? group = row.hostId;
  return <FushiClientUrl>[
    for (int i = 0; i < rows.length; i++)
      if (i == index)
        row.copyWith(token: token)
      else if (group != null && group.isNotEmpty && rows[i].hostId == group)
        rows[i].copyWith(token: token)
      else
        rows[i],
  ];
}

/// 把 host 公布的地址集合并进候选列表（纯函数，便于单测）。
///
/// - [anchorUrl] 是本次拿到地址集时用的那条地址；它被标上 [hostId]。列表里找不
///   到它（用户刚删了）→ 原样返回。
/// - 同 hostId 的 learned 条目按新集合增删；手输条目永不删改，只在 URL 恰好被
///   host 公布、且与锚点钉扎同一张证书时补标 hostId（同一台机器，归入同组）。
/// - 新条目继承锚点的 token / 指纹 / 展示名：per-peer token 对这台 host 的所有
///   地址都有效，证书也是同一张。指纹只给 https 地址。
/// - 插入位置：同组内第一个优先级更低的条目之前；手输条目的相对顺序不变。
/// - [deviceName]（host 自报的展示名，BUG-4322）：同组里还没有名字的条目（含锚点）补上，已有的名字
///   不动。升级前用手动地址配对的 host 没记名字，下次学地址时据此补齐。
List<FushiClientUrl> mergeLearnedHostAddresses(
  List<FushiClientUrl> list, {
  required String anchorUrl,
  required String hostId,
  required List<InterconnectHostAddress> addresses,
  String? deviceName,
}) {
  final int anchorIndex = list.indexWhere(
    (FushiClientUrl u) => u.url == anchorUrl,
  );
  if (anchorIndex < 0) return list;
  if (!_anchorMayClaimHostId(list, anchorIndex, hostId)) return list;
  final String? hostName = (deviceName?.trim().isNotEmpty ?? false)
      ? deviceName!.trim()
      : null;
  FushiClientUrl named(FushiClientUrl u) =>
      hostName == null || (u.deviceName?.trim().isNotEmpty ?? false)
      ? u
      : u.copyWith(deviceName: hostName);
  final FushiClientUrl anchor = named(
    list[anchorIndex].copyWith(hostId: hostId),
  );
  final List<InterconnectHostAddress> kept = collapseRotatingIpv6Addresses(
    addresses,
    preferUrls: <String>[
      anchor.url,
      for (final FushiClientUrl u in list) u.url,
    ],
  );
  final Set<String> published = <String>{
    for (final InterconnectHostAddress a in kept) a.url,
  };

  // 53NT7G_tSO：锚点刚用自己的 token 从 host 取到了地址集（`/api/host/addresses`
  // 要鉴权），所以它手里的就是 host 此刻认的那一份。同组其余地址若还拿着重新配对前
  // 的旧 token（已被 host 作废），在这里一并换新——已经坏掉的老配置也能自愈。
  final String? anchorToken = anchor.token;
  FushiClientUrl withAnchorToken(FushiClientUrl u) =>
      anchorToken == null || u.token == anchorToken
      ? u
      : u.copyWith(token: anchorToken);

  final List<FushiClientUrl> out = <FushiClientUrl>[];
  for (int i = 0; i < list.length; i++) {
    final FushiClientUrl u = i == anchorIndex ? anchor : list[i];
    if (u.hostId == hostId && u.learned && !published.contains(u.url)) {
      continue; // host 不再公布的学到地址：删。
    }
    if (u.hostId == null &&
        !u.learned &&
        published.contains(u.url) &&
        _sameCertificate(u, anchor)) {
      // 手输的同一台机器：归组。只认证书指纹（与锚点并组同一判据）——URL 恰好被
      // 公布不代表这条地址上应答的就是这台 host；明文手输行永不被收编，否则锚点的
      // token 会写给那个 URL 上实际应答的另一台机器（C6）。
      out.add(named(withAnchorToken(u.copyWith(hostId: hostId))));
      continue;
    }
    out.add(u.hostId == hostId ? named(withAnchorToken(u)) : u);
  }

  for (final InterconnectHostAddress a in kept) {
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
    final bool https =
        a.url.toLowerCase().startsWith('https://') ||
        (_isP2pUrl(a.url) &&
            Uri.tryParse(a.url)?.queryParameters['tls'] == '1');
    final FushiClientUrl learned = FushiClientUrl(
      url: a.url,
      fingerprintSha256: https ? anchor.fingerprintSha256 : null,
      deviceName: anchor.deviceName,
      token: anchor.token,
      hostId: hostId,
      learned: true,
      addressKind: a.kind.name,
      // 同一台 host 的「用它查词典」开关跟着锚点走：学到的新地址不能把关掉的 host
      // 重新拉回查词候选。
      lookupEnabled: anchor.lookupEnabled,
    );
    _insertIntoHostGroup(out, learned, hostId, interconnectAddressRank(a.kind));
  }
  return out;
}

/// [u] 与 [anchor] 钉扎的是同一张证书：u 是 https，两边指纹都非空且相等。
bool _sameCertificate(FushiClientUrl u, FushiClientUrl anchor) {
  if (!u.url.toLowerCase().startsWith('https://')) return false;
  final String? fp = u.fingerprintSha256;
  final String? anchorFp = anchor.fingerprintSha256;
  if (fp == null || fp.isEmpty || anchorFp == null || anchorFp.isEmpty) {
    return false;
  }
  return fingerprintEquals(fp, anchorFp);
}

/// 本 client 是否接收 `p2p://` 地址（隧道能力装配后置 true）。
bool _acceptP2pAddresses = false;

/// 隧道层装配点：原生 P2P 库可用时打开。
void setInterconnectAcceptsP2pAddresses(bool accept) {
  _acceptP2pAddresses = accept;
}

/// host 的 `/api/host/addresses` 回包：身份、展示名（老 host 为 null）与地址集。
typedef _PublishedHostAddresses = ({
  String hostId,
  String? deviceName,
  List<InterconnectHostAddress> addresses,
});

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
  /// 只从经认证的锚点学：明文锚点背后可能是冒名者，它公布的地址集（哪怕全是
  /// https）会被带着本机 token 落库。认证有两种：https 钉扎，或 [anchor] 是本进程
  /// 仍存活的 P2P 转发口——隧道按对端 NodeId 公钥认证，与 TLS 钉扎等价，所以明文
  /// 隧道也可以学；而 `p2p://` 行只会经已认证的锚点学到（[mergeLearnedHostAddresses]
  /// 只学 https / p2p 地址），NodeId 本身是可信来源。
  ///
  /// [anchor] 是传输 URL（选路结果，可能是本地转发口）：`/api/host/addresses` 走它，
  /// 指纹按它的 scheme 取（tls=1 隧道是 https + 钉扎，明文隧道不钉扎）；合并时用
  /// 持久 URL 在列表里认锚点——转发口只活在内存里，列表里存的是 `p2p://`。
  Future<bool> refresh(FushiClientUrl anchor) async {
    final String persisted = interconnectPersistedUrl(anchor.url);
    final bool viaTunnel = persisted != anchor.url && _isP2pUrl(persisted);
    _lastRefresh[persisted] = _now();
    if (!viaTunnel && !anchor.url.toLowerCase().startsWith('https://')) {
      return false;
    }
    if (viaTunnel && (anchor.hostId == null || anchor.hostId!.isEmpty)) {
      return false;
    }
    final String? token = interconnectTokenFor(
      anchor,
      await _repo.getFushiClientToken(),
    );
    if (token == null) return false;
    final _PublishedHostAddresses? published = await _fetchPublished(
      anchor,
      token,
    );
    if (published == null) return false;

    bool changed = false;
    await _repo.updateFushiClientUrls((List<FushiClientUrl> before) {
      final List<FushiClientUrl> after = mergeLearnedHostAddresses(
        before,
        anchorUrl: persisted,
        hostId: published.hostId,
        addresses: published.addresses,
        deviceName: published.deviceName,
      );
      if (_sameList(before, after)) return before;
      changed = true;
      return after;
    });
    return changed;
  }

  /// 后台学习（同一锚点 [_throttle] 内只跑一次，按持久 URL 计：同一条隧道换了
  /// 转发口仍是同一个锚点）；失败只留痕。
  void refreshInBackground(FushiClientUrl anchor) {
    final DateTime? last = _lastRefresh[interconnectPersistedUrl(anchor.url)];
    if (last != null && _now().difference(last) < _throttle) return;
    unawaited(
      refresh(anchor).then<void>(
        (bool _) {},
        onError: (Object e, StackTrace st) =>
            engineLog.logDiagnostic('InterconnectAddressLearner', e),
      ),
    );
  }

  Future<_PublishedHostAddresses?> _fetchPublished(
    FushiClientUrl anchor,
    String token,
  ) async {
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
      final Object? deviceName = decoded['deviceName'];
      return (
        hostId: hostId,
        // BUG-4322：host 展示名（老 host 不带）。
        deviceName: deviceName is String ? deviceName : null,
        addresses: addresses,
      );
    } finally {
      client.close();
    }
  }

  static bool _sameList(List<FushiClientUrl> a, List<FushiClientUrl> b) =>
      jsonEncode(a.map((FushiClientUrl u) => u.toJson()).toList()) ==
      jsonEncode(b.map((FushiClientUrl u) => u.toJson()).toList());
}

/// 设置页地址行的标题用名：本行的 [FushiClientUrl.deviceName]（去品牌前缀）；本行没有（学到的
/// 备用地址、老条目）就取同 hostId 组里第一个非空的名字。都没有 → null，由调用方
/// 回落显示 URL。同一台 host 的多条地址因此都显示同一个设备名，URL 退到副标题区分。
String? interconnectPeerRowName(
  Iterable<FushiClientUrl> urls,
  FushiClientUrl row,
) {
  String? clean(String? name) {
    if (name == null) return null;
    // 对端自报名带品牌前缀（`Fushi · Desk PC`），行上只显示人读部分。
    final String readable = interconnectPeerDisplayName(name);
    return readable.isEmpty ? null : readable;
  }

  final String? own = clean(row.deviceName);
  if (own != null) return own;
  final String? hostId = row.hostId;
  if (hostId == null || hostId.isEmpty) return null;
  for (final FushiClientUrl u in urls) {
    if (u.hostId != hostId) continue;
    final String? name = clean(u.deviceName);
    if (name != null) return name;
  }
  return null;
}

/// 「测试连接」要探测的地址：只测已启用的行。停用的行不参与任何真实同步 / 请求
/// （全部消费点都 `where((u) => u.enabled)`），给它亮 ✓ 会让人以为它在用。
List<FushiClientUrl> interconnectUrlsToTest(Iterable<FushiClientUrl> urls) =>
    <FushiClientUrl>[
      for (final FushiClientUrl u in urls)
        if (u.enabled) u,
    ];
