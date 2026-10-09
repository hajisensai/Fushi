// 排行榜 Worker 的 JSON 线格式（真相源：services/leaderboard/src/views.js / account.js / shelf.js）。
//
// 读侧类型只做 fromJson/toJson 的忠实映射，不做业务判断；上报类型（ShelfEntryUpload /
// DailyCharsUpload）在构造时就拒绝服务端必然 400 的形状，错误尽早在本机暴露。

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

typedef JsonMap = Map<String, dynamic>;

int _int(Object? v) => (v as num).toInt();
int? _intOrNull(Object? v) => v == null ? null : (v as num).toInt();
String _str(Object? v) => v as String? ?? '';
JsonMap _map(Object? v) => (v as Map<Object?, Object?>).cast<String, dynamic>();
List<T> _list<T>(Object? v, T Function(JsonMap) f) => List<T>.unmodifiable(
  ((v as List<Object?>?) ?? const <Object?>[]).map((Object? e) => f(_map(e))),
);

/// 枚举与线上字符串一一对应的共用查找。
T _byWire<T>(List<T> values, String Function(T) wire, Object? raw) {
  for (final T v in values) {
    if (wire(v) == raw) return v;
  }
  throw FormatException('unknown value: $raw');
}

/// 作品种类（shelf.js `KINDS`）。漫画在服务端是独立种类。
enum LeaderboardKind {
  book('book'),
  manga('manga'),
  video('video'),
  game('game');

  const LeaderboardKind(this.wire);
  final String wire;

  static LeaderboardKind fromWire(Object? raw) =>
      _byWire(values, (LeaderboardKind v) => v.wire, raw);
}

/// 排名指标（views.js `METRICS`）：四类读完数 + 字数。
enum LeaderboardMetric {
  book('book'),
  manga('manga'),
  video('video'),
  game('game'),
  chars('chars');

  const LeaderboardMetric(this.wire);
  final String wire;

  static LeaderboardMetric fromWire(Object? raw) =>
      _byWire(values, (LeaderboardMetric v) => v.wire, raw);
}

/// 时间窗（views.js `WINDOWS`）：本周（周一起，UTC）/ 本月 / 总榜。
enum LeaderboardWindow {
  week('week'),
  month('month'),
  all('all');

  const LeaderboardWindow(this.wire);
  final String wire;

  static LeaderboardWindow fromWire(Object? raw) =>
      _byWire(values, (LeaderboardWindow v) => v.wire, raw);
}

enum LeaderboardScope {
  global('global'),
  friends('friends');

  const LeaderboardScope(this.wire);
  final String wire;

  static LeaderboardScope fromWire(Object? raw) =>
      _byWire(values, (LeaderboardScope v) => v.wire, raw);
}

/// 公开账户（views.js `publicAccount`）。[avatar] 是 `/img/...` 相对路径或 null，
/// 用 `LeaderboardClient.resolveMedia` 拼成绝对地址。
class LeaderboardAccount {
  const LeaderboardAccount({
    required this.id,
    required this.nickname,
    required this.discriminator,
    this.avatar,
  });

  factory LeaderboardAccount.fromJson(JsonMap j) => LeaderboardAccount(
    id: j['id'] as String,
    nickname: _str(j['nickname']),
    discriminator: _int(j['discriminator']),
    avatar: j['avatar'] as String?,
  );

  final String id;
  final String nickname;
  final int discriminator;
  final String? avatar;

  /// 展示形态 `昵称#0042`。
  String get tag => '$nickname#${discriminator.toString().padLeft(4, '0')}';

  JsonMap toJson() => <String, dynamic>{
    'id': id,
    'nickname': nickname,
    'discriminator': discriminator,
    'avatar': avatar,
  };
}

/// 自己的账户（account.js `selfView`）。[shelfCount] 是服务端当前书架行数（旧服务端不给 = null）。
///
/// `account.id` 是**服务端账户 id**：换设备邮箱登录后它不再等于本机钥匙推出来的
/// `LeaderboardIdentity.accountId`（后者只是设备钥匙 id）。分享链接与「是不是我」
/// 一律用这里的 id。
class LeaderboardSelf {
  const LeaderboardSelf({
    required this.account,
    required this.visibility,
    required this.createdAt,
    this.shelfCount,
    this.emailVerified = false,
    this.uploadDevice,
    this.role = 'user',
  });

  factory LeaderboardSelf.fromJson(JsonMap j) => LeaderboardSelf(
    account: LeaderboardAccount.fromJson(j),
    visibility: _str(j['visibility']),
    createdAt: _int(j['createdAt']),
    shelfCount: _intOrNull(j['shelfCount']),
    emailVerified: j['emailVerified'] == true,
    uploadDevice: j['uploadDevice'] as bool?,
    role: j['role'] as String? ?? 'user',
  );

  final LeaderboardAccount account;

  /// `public` | `friends`。
  final String visibility;
  final int createdAt;
  final int? shelfCount;
  final bool emailVerified;

  /// 本机钥匙是否为本账户的「上传设备」（每账户只有一台能上传书架）；旧服务端不给 = null。
  final bool? uploadDevice;

  /// `user` | `dev`（开发者：可在 App 内处理反馈；权限以服务端为准）。旧服务端不给 = `user`。
  final String role;

  bool get isDeveloper => role == 'dev';

  JsonMap toJson() => <String, dynamic>{
    ...account.toJson(),
    'visibility': visibility,
    'createdAt': createdAt,
    if (shelfCount != null) 'shelfCount': shelfCount,
    'emailVerified': emailVerified,
    if (uploadDevice != null) 'uploadDevice': uploadDevice,
    if (role != 'user') 'role': role,
  };
}

/// 公开作品（views.js `publicWork`）。[cover] 可能是白名单图床绝对 URL 或 `/img/...`。
class LeaderboardWork {
  const LeaderboardWork({
    required this.id,
    required this.kind,
    required this.title,
    required this.author,
    this.cover,
    this.nsfw = false,
  });

  factory LeaderboardWork.fromJson(JsonMap j) => LeaderboardWork(
    id: j['id'] as String,
    kind: LeaderboardKind.fromWire(j['kind']),
    title: _str(j['title']),
    author: _str(j['author']),
    cover: j['cover'] as String?,
    nsfw: j['nsfw'] == true,
  );

  final String id;
  final LeaderboardKind kind;
  final String title;
  final String author;
  final String? cover;
  final bool nsfw;

  JsonMap toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.wire,
    'title': title,
    'author': author,
    'cover': cover,
    'nsfw': nsfw,
  };
}

/// 某指标下的数值与名次。[rank] 为 null = 没上榜（值为 0）。
class UserStanding {
  const UserStanding({required this.value, this.rank});

  factory UserStanding.fromJson(JsonMap j) =>
      UserStanding(value: _int(j['value']), rank: _intOrNull(j['rank']));

  final int value;
  final int? rank;

  JsonMap toJson() => <String, dynamic>{'value': value, 'rank': rank};
}

class RankRow {
  const RankRow({
    required this.rank,
    required this.value,
    required this.account,
  });

  factory RankRow.fromJson(JsonMap j) => RankRow(
    rank: _int(j['rank']),
    value: _int(j['value']),
    account: LeaderboardAccount.fromJson(_map(j['account'])),
  );

  final int rank;
  final int value;
  final LeaderboardAccount account;

  JsonMap toJson() => <String, dynamic>{
    'rank': rank,
    'value': value,
    'account': account.toJson(),
  };
}

/// GET /v1/rank。[from] = 窗口起始日 `YYYY-MM-DD`（总榜为 null）；[me] 只在带签名时有。
/// [computedAt] = 榜单快照生成时刻（毫秒）；null = 快照还没生成（榜单为空），UI 显示
/// 「榜单生成中」。
class RankPage {
  const RankPage({
    required this.metric,
    required this.window,
    required this.scope,
    required this.from,
    this.computedAt,
    required this.total,
    required this.me,
    required this.rows,
  });

  factory RankPage.fromJson(JsonMap j) => RankPage(
    metric: LeaderboardMetric.fromWire(j['metric']),
    window: LeaderboardWindow.fromWire(j['window']),
    scope: LeaderboardScope.fromWire(j['scope']),
    from: j['from'] as String?,
    computedAt: _intOrNull(j['computedAt']),
    total: _int(j['total']),
    me: j['me'] == null ? null : UserStanding.fromJson(_map(j['me'])),
    rows: _list(j['rows'], RankRow.fromJson),
  );

  final LeaderboardMetric metric;
  final LeaderboardWindow window;
  final LeaderboardScope scope;
  final String? from;
  final int? computedAt;
  final int total;
  final UserStanding? me;
  final List<RankRow> rows;

  JsonMap toJson() => <String, dynamic>{
    'metric': metric.wire,
    'window': window.wire,
    'scope': scope.wire,
    'from': from,
    'computedAt': computedAt,
    'total': total,
    'me': me?.toJson(),
    'rows': rows.map((RankRow r) => r.toJson()).toList(),
  };
}

class PopularWorkRow {
  const PopularWorkRow({
    required this.rank,
    required this.readers,
    required this.work,
  });

  factory PopularWorkRow.fromJson(JsonMap j) => PopularWorkRow(
    rank: _int(j['rank']),
    readers: _int(j['readers']),
    work: LeaderboardWork.fromJson(_map(j['work'])),
  );

  final int rank;
  final int readers;
  final LeaderboardWork work;

  JsonMap toJson() => <String, dynamic>{
    'rank': rank,
    'readers': readers,
    'work': work.toJson(),
  };
}

/// GET /v1/works/popular。[computedAt] 同 [RankPage.computedAt]（null = 生成中）。
class PopularPage {
  const PopularPage({
    required this.window,
    required this.kind,
    required this.from,
    this.computedAt,
    required this.rows,
  });

  factory PopularPage.fromJson(JsonMap j) => PopularPage(
    window: LeaderboardWindow.fromWire(j['window']),
    kind: j['kind'] == null ? null : LeaderboardKind.fromWire(j['kind']),
    from: j['from'] as String?,
    computedAt: _intOrNull(j['computedAt']),
    rows: _list(j['rows'], PopularWorkRow.fromJson),
  );

  final LeaderboardWindow window;
  final LeaderboardKind? kind;
  final String? from;
  final int? computedAt;
  final List<PopularWorkRow> rows;

  JsonMap toJson() => <String, dynamic>{
    'window': window.wire,
    'kind': kind?.wire,
    'from': from,
    'computedAt': computedAt,
    'rows': rows.map((PopularWorkRow r) => r.toJson()).toList(),
  };
}

/// GET /v1/users/:id（萌メーター式左侧卡片）。[stats] 键是 [LeaderboardMetric.wire]。
class UserCard {
  const UserCard({
    required this.account,
    required this.createdAt,
    required this.firstRecordDate,
    required this.visibility,
    required this.shelfVisible,
    this.rankComputedAt,
    required this.stats,
    this.relation,
  });

  factory UserCard.fromJson(JsonMap j) => UserCard(
    account: LeaderboardAccount.fromJson(_map(j['account'])),
    createdAt: _int(j['createdAt']),
    firstRecordDate: j['firstRecordDate'] as String?,
    visibility: _str(j['visibility']),
    shelfVisible: j['shelfVisible'] == true,
    rankComputedAt: _intOrNull(j['rankComputedAt']),
    stats: Map<String, UserStanding>.unmodifiable(<String, UserStanding>{
      for (final MapEntry<String, dynamic> e in _map(
        j['stats'] ?? const <String, dynamic>{},
      ).entries)
        e.key: UserStanding.fromJson(_map(e.value)),
    }),
    relation: j['relation'] as String?,
  );

  final LeaderboardAccount account;
  final int createdAt;
  final String? firstRecordDate;
  final String visibility;
  final bool shelfVisible;

  /// [stats] 里名次所依据的榜单快照时刻；null = 快照还没生成（名次都为 null）。
  final int? rankComputedAt;
  final Map<String, UserStanding> stats;

  /// 观看者与此用户的关系（只有签名请求才有值）：`self` | `friend` | `outgoing`
  /// （我发出的好友申请待对方接受）| `incoming`（对方申请待我接受）| `none`（无关系）；
  /// null = 匿名 / 旧服务端（没有这个字段）。
  final String? relation;

  /// 取某指标（缺失 = 值 0、未上榜）。
  UserStanding standing(LeaderboardMetric metric) =>
      stats[metric.wire] ?? const UserStanding(value: 0);

  JsonMap toJson() => <String, dynamic>{
    'account': account.toJson(),
    'createdAt': createdAt,
    'firstRecordDate': firstRecordDate,
    'visibility': visibility,
    'shelfVisible': shelfVisible,
    'rankComputedAt': rankComputedAt,
    'stats': <String, dynamic>{
      for (final MapEntry<String, UserStanding> e in stats.entries)
        e.key: e.value.toJson(),
    },
    if (relation != null) 'relation': relation,
  };
}

/// 书架一行。[finishedAt] 为 null 且 [finishedDate] 为 null：在读，或读完但日期未知
/// （status=finished 查询里出现的 null 即「日期未知」）。[wall] = 读过此作品的其他可见用户。
class ShelfItem {
  const ShelfItem({
    required this.work,
    required this.finishedAt,
    required this.finishedDate,
    required this.chars,
    required this.ms,
    required this.readers,
    required this.wall,
  });

  factory ShelfItem.fromJson(JsonMap j) => ShelfItem(
    work: LeaderboardWork.fromJson(_map(j['work'])),
    finishedAt: _intOrNull(j['finishedAt']),
    finishedDate: j['finishedDate'] as String?,
    chars: _intOrNull(j['chars']) ?? 0,
    ms: _intOrNull(j['ms']) ?? 0,
    readers: _intOrNull(j['readers']) ?? 0,
    wall: _list(j['wall'], LeaderboardAccount.fromJson),
  );

  final LeaderboardWork work;
  final int? finishedAt;
  final String? finishedDate;
  final int chars;
  final int ms;
  final int readers;
  final List<LeaderboardAccount> wall;

  JsonMap toJson() => <String, dynamic>{
    'work': work.toJson(),
    'finishedAt': finishedAt,
    'finishedDate': finishedDate,
    'chars': chars,
    'ms': ms,
    'readers': readers,
    'wall': wall.map((LeaderboardAccount a) => a.toJson()).toList(),
  };
}

/// GET /v1/users/:id/shelf。[status] = `finished` | `reading`。[next] = 下一页游标
/// （原样传回 `userShelf(cursor:)`）；null = 没有更多。
class ShelfPage {
  const ShelfPage({
    required this.account,
    required this.status,
    required this.rows,
    this.next,
  });

  factory ShelfPage.fromJson(JsonMap j) => ShelfPage(
    account: LeaderboardAccount.fromJson(_map(j['account'])),
    status: _str(j['status']),
    rows: _list(j['rows'], ShelfItem.fromJson),
    next: j['next'] as String?,
  );

  final LeaderboardAccount account;
  final String status;
  final List<ShelfItem> rows;
  final String? next;

  JsonMap toJson() => <String, dynamic>{
    'account': account.toJson(),
    'status': status,
    'rows': rows.map((ShelfItem r) => r.toJson()).toList(),
    'next': next,
  };
}

class WorkReader {
  const WorkReader({
    required this.account,
    required this.finishedAt,
    required this.finishedDate,
  });

  factory WorkReader.fromJson(JsonMap j) => WorkReader(
    account: LeaderboardAccount.fromJson(_map(j['account'])),
    finishedAt: _intOrNull(j['finishedAt']),
    finishedDate: j['finishedDate'] as String?,
  );

  final LeaderboardAccount account;
  final int? finishedAt;
  final String? finishedDate;

  JsonMap toJson() => <String, dynamic>{
    'account': account.toJson(),
    'finishedAt': finishedAt,
    'finishedDate': finishedDate,
  };
}

/// GET /v1/works/:id。[readers] = 读完人数（全体未隐藏账户）；[rows] 只含观看者可见的读者；
/// [next] = 下一页游标，null = 没有更多。
class WorkPage {
  const WorkPage({
    required this.work,
    required this.readers,
    required this.rows,
    this.next,
  });

  factory WorkPage.fromJson(JsonMap j) => WorkPage(
    work: LeaderboardWork.fromJson(_map(j['work'])),
    readers: _int(j['readers']),
    rows: _list(j['rows'], WorkReader.fromJson),
    next: j['next'] as String?,
  );

  final LeaderboardWork work;
  final int readers;
  final List<WorkReader> rows;
  final String? next;

  JsonMap toJson() => <String, dynamic>{
    'work': work.toJson(),
    'readers': readers,
    'rows': rows.map((WorkReader r) => r.toJson()).toList(),
    'next': next,
  };
}

/// 已互为好友。[since] = 成为好友的时刻（毫秒）。
class Friend {
  const Friend({required this.account, required this.since});

  factory Friend.fromJson(JsonMap j) => Friend(
    account: LeaderboardAccount.fromJson(_map(j['account'])),
    since: _int(j['since']),
  );

  final LeaderboardAccount account;
  final int since;

  JsonMap toJson() => <String, dynamic>{
    'account': account.toJson(),
    'since': since,
  };
}

/// 待处理的好友申请（收到的 / 发出的）。[at] = 申请时刻（毫秒）。
class FriendRequest {
  const FriendRequest({required this.account, required this.at});

  factory FriendRequest.fromJson(JsonMap j) => FriendRequest(
    account: LeaderboardAccount.fromJson(_map(j['account'])),
    at: _int(j['at']),
  );

  final LeaderboardAccount account;
  final int at;

  JsonMap toJson() => <String, dynamic>{'account': account.toJson(), 'at': at};
}

/// GET /v1/friends。
class FriendList {
  const FriendList({
    required this.friends,
    required this.incoming,
    required this.outgoing,
  });

  factory FriendList.fromJson(JsonMap j) => FriendList(
    friends: _list(j['friends'], Friend.fromJson),
    incoming: _list(j['incoming'], FriendRequest.fromJson),
    outgoing: _list(j['outgoing'], FriendRequest.fromJson),
  );

  final List<Friend> friends;
  final List<FriendRequest> incoming;
  final List<FriendRequest> outgoing;

  JsonMap toJson() => <String, dynamic>{
    'friends': friends.map((Friend f) => f.toJson()).toList(),
    'incoming': incoming.map((FriendRequest f) => f.toJson()).toList(),
    'outgoing': outgoing.map((FriendRequest f) => f.toJson()).toList(),
  };
}

/// 上报响应里一条 put 条目（下标 [i]）落到的作品，以及它是否缺封面（缺则可补传缩略图）。
class UploadedWork {
  const UploadedWork({
    required this.i,
    required this.workId,
    required this.needsCover,
  });

  factory UploadedWork.fromJson(JsonMap j) => UploadedWork(
    i: _int(j['i']),
    workId: j['workId'] as String,
    needsCover: j['needsCover'] == true,
  );

  final int i;
  final String workId;
  final bool needsCover;

  JsonMap toJson() => <String, dynamic>{
    'i': i,
    'workId': workId,
    'needsCover': needsCover,
  };
}

/// POST /v1/shelf 的响应。[shelfCount] = 本账户服务端当前书架行数（客户端据此核对是否需要 reset 重传）。
class ShelfUploadResult {
  const ShelfUploadResult({required this.works, required this.shelfCount});

  factory ShelfUploadResult.fromJson(JsonMap j) => ShelfUploadResult(
    works: _list(j['works'], UploadedWork.fromJson),
    shelfCount: _int(j['shelfCount']),
  );

  final List<UploadedWork> works;
  final int shelfCount;

  JsonMap toJson() => <String, dynamic>{
    'works': works.map((UploadedWork w) => w.toJson()).toList(),
    'shelfCount': shelfCount,
  };
}

final RegExp _dateKeyRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// 书架上报条目（shelf.js `normalizeEntry`）。三态：
/// - 在读：`finished = false`，无 [finishedAt]；
/// - 读完且日期未知：`finished = true`，无 [finishedAt]（只进总榜）；
/// - 读完有日期：[finishedAt] 与 [finishedDate]（本地日 `YYYY-MM-DD`）同时给出。
class ShelfEntryUpload {
  ShelfEntryUpload({
    required this.kind,
    required List<String> refs,
    required this.title,
    this.author = '',
    this.coverUrl,
    this.nsfw = false,
    required this.finished,
    this.finishedAt,
    this.finishedDate,
    this.chars = 0,
    this.ms = 0,
    this.counted = true,
  }) : refs = List<String>.unmodifiable(refs) {
    if (refs.isEmpty) {
      throw ArgumentError.value(refs, 'refs', 'must not be empty');
    }
    if ((finishedAt == null) != (finishedDate == null)) {
      throw ArgumentError('finishedAt and finishedDate must be given together');
    }
    if (finishedAt != null && !finished) {
      throw ArgumentError('finishedAt given for an unfinished entry');
    }
    if (finishedDate != null && !_dateKeyRe.hasMatch(finishedDate!)) {
      throw ArgumentError.value(finishedDate, 'finishedDate', 'not YYYY-MM-DD');
    }
  }

  final LeaderboardKind kind;
  final List<String> refs;
  final String title;
  final String author;
  final String? coverUrl;
  final bool nsfw;
  final bool finished;
  final int? finishedAt;
  final String? finishedDate;
  final int chars;
  final int ms;

  /// 是否计入作品维度的读者数（读者数 / 作品人气 / 作品周月榜 / 读者列表）。false 只用于
  /// 「本机没有任何 Profile 有学习记录」的作品在非代表 Profile 上的那一份：同一台机器的
  /// 多个 Profile 共享同一个库，这类作品会被每个开了上传的 Profile 各报一次（BUG-2870）。
  /// 账户自己的读完数与计分不受影响。只在 false 时上报，已有条目的 [contentHash] 不变。
  final bool counted;

  JsonMap toJson() => <String, dynamic>{
    'kind': kind.wire,
    'refs': refs,
    'title': title,
    'author': author,
    if (coverUrl != null) 'coverUrl': coverUrl,
    'nsfw': nsfw,
    'finished': finished,
    if (finishedAt != null) 'finishedAt': finishedAt,
    if (finishedDate != null) 'finishedDate': finishedDate,
    'chars': chars,
    'ms': ms,
    if (!counted) 'counted': false,
  };

  /// 规范化 JSON（键按字典序递归排序）的 sha256 hex：同一条目恒得同一值，
  /// 调用方据此判断条目是否变化、是否需要重新上报。
  String contentHash() =>
      crypto.sha256.convert(utf8.encode(_canonicalJson(toJson()))).toString();
}

/// 每日字数（shelf.js `normalizeDaily`）。[chars] = 0 表示删除该日。
class DailyCharsUpload {
  DailyCharsUpload({required this.date, required this.chars}) {
    if (!_dateKeyRe.hasMatch(date)) {
      throw ArgumentError.value(date, 'date', 'not YYYY-MM-DD');
    }
    if (chars < 0) throw ArgumentError.value(chars, 'chars', 'negative');
  }

  final String date;
  final int chars;

  JsonMap toJson() => <String, dynamic>{'date': date, 'chars': chars};
}

/// GET /v1/me/devices 的一行：本账户绑定的一把设备钥匙。[current] = 发请求的本机。
class LeaderboardDevice {
  const LeaderboardDevice({
    required this.keyId,
    required this.createdAt,
    this.lastUsedAt,
    required this.current,
  });

  factory LeaderboardDevice.fromJson(JsonMap j) => LeaderboardDevice(
    keyId: _str(j['keyId']),
    createdAt: _int(j['createdAt']),
    lastUsedAt: _intOrNull(j['lastUsedAt']),
    current: j['current'] == true,
  );

  /// 设备钥匙 id（sha256(spki) 前 16 位，同 X-Fushi-Account）。
  final String keyId;
  final int createdAt;

  /// 最近一次用这把钥匙签名的时刻；服务端没记过为 null。
  final int? lastUsedAt;
  final bool current;

  JsonMap toJson() => <String, dynamic>{
    'keyId': keyId,
    'createdAt': createdAt,
    'lastUsedAt': lastUsedAt,
    'current': current,
  };
}

String _canonicalJson(Object? v) => jsonEncode(_sortKeys(v));

Object? _sortKeys(Object? v) {
  if (v is Map) {
    final List<String> keys = v.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final String k in keys) k: _sortKeys(v[k])};
  }
  if (v is List) return v.map(_sortKeys).toList();
  return v;
}
