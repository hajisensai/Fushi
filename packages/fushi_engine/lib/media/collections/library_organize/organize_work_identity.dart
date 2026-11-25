/// 条目的**权威作品身份**与 AI 合集归属改动的本地否决（BUG-5460）。
///
/// AI 整理（`library_organize_plan.dart`）与 AI 管库变更集（`library_changeset.dart`）
/// 只靠标题让模型判断「放错了没有」。可有的条目本身就带着比模型更硬的证据：
///
/// - **来源的剧身份**（[OrganizeWorkIdentity.seriesKey]）：媒体服务器（Jellyfin / Emby /
///   飞牛 / Plex）的单集带着服务器给的剧名，在线视频源的集带着源里的作品；入库时就按它
///   收进同一个 playlist 合集（`mediaServerCollectionOf` / `AnimeSourceVideoClient` →
///   `adoptRemoteCollectionMember`）。命名空间按来源分（同一台服务器、同一个源），不同
///   来源之间不比较——同一部剧在两台服务器上名字可能不一样，那不是矛盾。
/// - **刮削到的作品 id**（[OrganizeWorkIdentity.externalWorkKey]）：只认挂在这一条本身
///   上的刮削作品，不认从所在合集继承来的（那是「它在这个合集里」推出来的，拿它判
///   「该不该留在这个合集」是循环论证）。
///
/// 两条否决规则，只拦 AI 写入（规则成组、收敛、用户操作不经过这里）：
///
/// 1. **不拆散、不移空同一部作品**（[organizeIdentityForbidsRelease]）：移完后合集里还留着
///    同一部作品的成员时，AI 不能把它移出；一整部作品一起离开时，只有合集里还留着可比的
///    另一部作品（它是混进来的）或去处就是这部作品的合集（归拢）才放行——把一部剧的
///    13 集从它自己的合集里全部移出、移空删掉，就是这条要拦的；而被塞进别的剧合集里的
///    一整部剧要能挪回去。
/// 2. **不塞进另一部剧**（[OrganizeSeriesGate]）：目标合集里已有同一来源、但不是同一部剧
///    的集，而没有这部剧的集时，AI 不能把这一集放进去（新建合集同理：一个新合集里不能
///    混两部来源剧）。只看来源的剧身份，不看刮削 id——AniList / AniDB 的 id 按季 / 按篇
///    分，续季、OVA 进同一部剧的合集是正当的。
library;

import 'dart:convert';

/// 一个条目的权威作品身份（都没有 = [isEmpty]，不参与否决）。
class OrganizeWorkIdentity {
  const OrganizeWorkIdentity({this.externalWorkKey, this.seriesKey});

  static const OrganizeWorkIdentity none = OrganizeWorkIdentity();

  /// 挂在这一条本身上的刮削作品键（`anilist:<id>` / `tmdb:<tv|movie>:<id>` /
  /// `anidb:<id>`，与 `OrganizeEntry.externalWorkKey` 同口径）。
  final String? externalWorkKey;

  /// 来源的剧身份：`<命名空间> NUL <剧>`，见 [remoteSeriesKeyOfStreamSpec]。
  final String? seriesKey;

  bool get isEmpty => externalWorkKey == null && seriesKey == null;

  /// [seriesKey] 的命名空间（同一台媒体服务器 / 同一个在线源）。
  String? get seriesNamespace {
    final String? key = seriesKey;
    if (key == null) return null;
    final int sep = key.indexOf('\u0000');
    return sep < 0 ? key : key.substring(0, sep);
  }

  /// 两条是同一部作品（任一种身份相同）。
  bool sameWorkAs(OrganizeWorkIdentity other) =>
      (externalWorkKey != null && externalWorkKey == other.externalWorkKey) ||
      (seriesKey != null && seriesKey == other.seriesKey);

  /// 两条可比且确定不是同一部作品：同一来源命名空间里的两部剧，或刮到两个不同的作品。
  /// 不同来源 / 一边没有身份的不可比（同一部剧在两台服务器上名字可能不一样）。
  bool distinctWorkFrom(OrganizeWorkIdentity other) {
    if (sameWorkAs(other)) return false;
    final bool series =
        seriesKey != null &&
        other.seriesKey != null &&
        seriesNamespace == other.seriesNamespace;
    final bool scraped =
        externalWorkKey != null && other.externalWorkKey != null;
    return series || scraped;
  }
}

/// 媒体服务器入库条目的 spec 类型标记（app `MediaServerBookSpec.kind`）。
const String kMediaServerStreamSpecKind = 'media-server';

/// 在线视频源入库条目的 spec 类型标记（app `AnimeSourceBookSpec.kind`）。
const String kAnimeSourceStreamSpecKind = 'anime-source';

/// 从 `video_books.stream_spec_json` 读来源的剧身份；不是这两种 spec、或这一条不属于
/// 任何剧（媒体服务器的电影没有剧归属）返回 null，**绝不抛**。
///
/// - 媒体服务器：`media-server:<serverId>` + 入库快照里的合集归属（`info.collection`，
///   即 `mediaServerCollectionOf` 给的剧名 + 合集类型）——这正是入库时收进合集用的
///   那个自然键。不用 `workId`：它是「加入媒体库」那一刻点的条目（整部剧、某一季或
///   单集都有可能），同一部剧的集可能各不相同。
/// - 在线视频源：`anime-source:<扩展包>:<源>` + 作品 URL（与 app
///   `AnimeSourceBookSpec.sameWorkAs` 同口径）。
String? remoteSeriesKeyOfStreamSpec(String? specJson) {
  if (specJson == null || specJson.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(specJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  switch (decoded['kind']) {
    case kMediaServerStreamSpecKind:
      final Object? serverId = decoded['serverId'];
      final Object? info = decoded['info'];
      if (serverId is! String || serverId.isEmpty || info is! Map) return null;
      final Object? collection = info['collection'];
      if (collection is! Map) return null;
      final Object? name = collection['name'];
      final Object? type = collection['collectionType'];
      if (name is! String || name.isEmpty || type is! String || type.isEmpty) {
        return null;
      }
      return '$kMediaServerStreamSpecKind:$serverId\u0000$type:$name';
    case kAnimeSourceStreamSpecKind:
      final Object? package = decoded['extensionPackage'];
      final Object? source = decoded['sourceId'];
      final Object? anime = decoded['anime'];
      if (package is! String || package.isEmpty || anime is! Map) return null;
      final Object? url = anime['url'];
      if (url is! String || url.isEmpty) return null;
      return '$kAnimeSourceStreamSpecKind:$package:${source ?? ''}\u0000$url';
  }
  return null;
}

/// 规则 1：AI 能不能把 [memberKey] 从合集里移出。true = 不能（与权威作品身份矛盾）。
///
/// [members]：合集成员行键（`mediaType NUL entryKey`）→ 身份，只需带有身份的成员。
/// [leaving]：同一处改动里一起离开这个合集的成员行键（一起挪走的一整部剧不算「拆散」）。
/// [destination]：去处里已有（或同一处改动里一起去）的成员身份；单独放 = 空。
///
/// - **拆散**：移完后合集里还留着同一部作品的成员 → 不能。
/// - 整部作品一起离开：
///   - 合集里留着同一来源的另一部剧 / 另一个刮削作品 → 它是混进来的那一部，可以移出
///     （包括这个 bug 自己造成的「13 集被塞进另一部剧的合集」，要能挪回去）；
///   - 去处已经是这部作品的合集 → 归拢，可以；
///   - 否则这就是它自己的合集（合集里没有可比的别的作品），移出 = 把一部剧从自己的
///     合集里移空 → 不能。
/// 没有身份的条目不受这条限制。
bool organizeIdentityForbidsRelease(
  Map<String, OrganizeWorkIdentity> members,
  String memberKey, {
  Set<String> leaving = const <String>{},
  Iterable<OrganizeWorkIdentity> destination = const <OrganizeWorkIdentity>[],
}) {
  final OrganizeWorkIdentity? own = members[memberKey];
  if (own == null || own.isEmpty) return false;
  bool otherWorkStays = false;
  for (final MapEntry<String, OrganizeWorkIdentity> m in members.entries) {
    if (m.key == memberKey || leaving.contains(m.key)) continue;
    if (m.value.sameWorkAs(own)) return true;
    if (m.value.distinctWorkFrom(own)) otherWorkStays = true;
  }
  if (otherWorkStays) return false;
  for (final OrganizeWorkIdentity d in destination) {
    if (d.sameWorkAs(own)) return false;
  }
  return true;
}

/// 一批要一起离开同一个合集的条目里，按规则 1 真能离开的那些：逐轮把不能离开的剔掉、
/// 剩下的再按「一起离开」重判，直到不变（剔掉一条只会让别的更难离开，必然收敛）。
/// [ok]：给定这一轮一起离开的行键集合，[T] 能不能离开。
List<T> organizeReleasableTogether<T>(
  List<T> candidates,
  String Function(T) keyOf,
  bool Function(T item, Set<String> leaving) ok,
) {
  List<T> current = candidates;
  while (true) {
    final Set<String> leaving = <String>{for (final T c in current) keyOf(c)};
    final List<T> next = <T>[
      for (final T c in current)
        if (ok(c, leaving)) c,
    ];
    if (next.length == current.length) return next;
    current = next;
  }
}

/// 规则 2：往一个合集里放条目时的剧身份闸门。以合集现有成员的剧身份起头，每放行
/// 一条就记下它的剧身份——同一批里先放进去的也算（一次改动里不能先塞 A 剧再塞 B 剧）。
class OrganizeSeriesGate {
  OrganizeSeriesGate([
    Iterable<OrganizeWorkIdentity> members = const <OrganizeWorkIdentity>[],
  ]) {
    for (final OrganizeWorkIdentity m in members) {
      _record(m);
    }
  }

  /// 命名空间 → 合集里已有的剧身份。
  final Map<String, Set<String>> _series = <String, Set<String>>{};

  void _record(OrganizeWorkIdentity identity) {
    final String? key = identity.seriesKey;
    if (key == null) return;
    (_series[identity.seriesNamespace!] ??= <String>{}).add(key);
  }

  /// [identity] 放进来会不会与合集里已有的剧冲突（不记账）。
  bool conflicts(OrganizeWorkIdentity identity) {
    final String? key = identity.seriesKey;
    if (key == null) return false;
    final Set<String>? held = _series[identity.seriesNamespace!];
    return held != null && held.isNotEmpty && !held.contains(key);
  }

  /// 放行就记账并返回 true；冲突返回 false（不记账）。
  bool admit(OrganizeWorkIdentity identity) {
    if (conflicts(identity)) return false;
    _record(identity);
    return true;
  }

  /// 一份独立的副本（试放用，不影响本闸门的账）。
  OrganizeSeriesGate copy() {
    final OrganizeSeriesGate out = OrganizeSeriesGate();
    _series.forEach(
      (String ns, Set<String> keys) => out._series[ns] = <String>{...keys},
    );
    return out;
  }

  /// 一批（如合并时败方的全部成员）要么全放行并记账，要么一条都不记。
  bool admitAll(Iterable<OrganizeWorkIdentity> identities) {
    final OrganizeSeriesGate trial = copy();
    for (final OrganizeWorkIdentity i in identities) {
      if (!trial.admit(i)) return false;
    }
    _series
      ..clear()
      ..addAll(trial._series);
    return true;
  }
}
