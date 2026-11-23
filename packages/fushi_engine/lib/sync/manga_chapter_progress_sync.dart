/// 互联同步分章漫画的每章阅读进度（拍板台 design-ic-manga-chapter-progress，反馈 2bNEiehLgw）。
///
/// 经互联收下的章节式漫画（host 端是 Mihon / Aidoku 等分章条目），书级 `reader_positions` 只装
/// 「当前章第几页」、不带章身份，不能拿来对齐（BUG-5352）；真正的进度在 `manga_chapter_states`
/// （每章页码、页内偏移、已读时刻，`updatedAt` 同时是「继续阅读」选章的依据）。两端章 key 逐字相同
/// （client 的章表就是 host 页表端点给的章 key），所以按章做 last-write-wins，不需要三方基线：
///
/// - `GET  /api/library/manga-chapter-progress/<bookKey>` → host 这本书的全部章状态；
/// - `PUT  /api/library/manga-chapter-progress/<bookKey>` → client 把自己较新的章推上去，host 按章
///   LWW 合并后回合并后的全部章状态。
///
/// 已读 / 未读标记随行同步（标未读 = `readAt` 置空、`updatedAt` 刷新，后写者胜）；行从不单删
/// （只随整本书删），所以不需要墓碑。两台设备同时读同一章时以后写的为准，不弹冲突对话框（拍板代价
/// 里写明）。老 host 没有这条路由（不报能力位 [kMangaChapterProgressCapability]、端点 404），
/// client 静默跳过。
///
/// 判定只在 [mangaChapterStateReplaces] 一处：host 合并 PUT 与 client 落地 host 那份用同一个函数，
/// 两端对「谁新」的结论不会漂开（否则同戳不同内容会来回推）。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show capFutureSyncStamp, trustedStoredSyncStamp;
import 'package:fushi_engine/sync/interconnect_module.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart'
    show readJsonObjectBody;
import 'package:shelf/shelf.dart' as shelf;

/// 路由前缀；`<前缀>/<bookKey>`（bookKey 经 `Uri.encodeComponent`）。
///
/// 不挂在 `/api/library/books/` / `/api/library/manga/` 下：老 host 会把那两条前缀下的未知子路径
/// 当书名 / 页表请求处理；挂在新前缀上，老 host 落进 WebDAV 文件分支回 404。client 只在 GET 成功后
/// 才 PUT（老 host 的 WebDAV PUT 会真的落一个文件）。
const String kMangaChapterProgressPath = '/api/library/manga-chapter-progress';

/// `/api/capabilities` 顶层能力键；值 `{'v': kMangaChapterProgressWireVersion}`。
const String kMangaChapterProgressCapability = 'mangaChapterProgress';

/// wire 版本。
const int kMangaChapterProgressWireVersion = 1;

/// GET / PUT 体与回执里章状态表的键：`{"states": {chapterKey: {…}}}`。
const String kMangaChapterStatesKey = 'states';

/// 一章的阅读状态（`manga_chapter_states` 一行去掉书身份）。
class RemoteMangaChapterState {
  const RemoteMangaChapterState({
    required this.lastPage,
    required this.lastFraction,
    required this.pageCount,
    required this.readAt,
    required this.updatedAtMs,
  });

  /// 0-based 页码。
  final int lastPage;

  /// webtoon 页内千分比；-1 = 无精确偏移。
  final int lastFraction;

  /// 该章总页数；未知 null。
  final int? pageCount;

  /// 读完时刻；null = 未读完（「标为未读」也是 null）。
  final int? readAt;

  /// 最后一次改动的时刻：LWW 的依据，也是「继续阅读」选章的依据，落地时逐字保留。
  final int updatedAtMs;

  factory RemoteMangaChapterState.fromRow(MangaChapterStateRow row) =>
      RemoteMangaChapterState(
        lastPage: row.lastPage,
        lastFraction: row.lastFraction,
        pageCount: row.pageCount,
        readAt: row.readAt,
        updatedAtMs: row.updatedAt,
      );

  /// 落进本端 `manga_chapter_states` 的一行。
  MangaChapterStateRow toRow({
    required String bookUid,
    required String chapterKey,
  }) => MangaChapterStateRow(
    bookUid: bookUid,
    chapterKey: chapterKey,
    lastPage: lastPage,
    lastFraction: lastFraction,
    pageCount: pageCount,
    readAt: readAt,
    updatedAt: updatedAtMs,
  );

  /// 只换时间戳的副本。
  RemoteMangaChapterState withUpdatedAt(int atMs) => atMs == updatedAtMs
      ? this
      : RemoteMangaChapterState(
          lastPage: lastPage,
          lastFraction: lastFraction,
          pageCount: pageCount,
          readAt: readAt,
          updatedAtMs: atMs,
        );

  Map<String, Object?> toJson() => <String, Object?>{
    'lastPage': lastPage,
    'lastFraction': lastFraction,
    if (pageCount != null) 'pageCount': pageCount,
    if (readAt != null) 'readAt': readAt,
    'updatedAt': updatedAtMs,
  };

  /// 解析一章；缺 `updatedAt` 或字段类型不对 → [FormatException]（整份拒收，不猜）。
  static RemoteMangaChapterState fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('manga chapter state: expected an object');
    }
    int? intOf(String key) => switch (json[key]) {
      final int v => v,
      final num v when v == v.truncate() => v.toInt(),
      null => null,
      _ => throw FormatException('manga chapter state: bad "$key"'),
    };
    final int? updatedAt = intOf('updatedAt');
    if (updatedAt == null) {
      throw const FormatException('manga chapter state: missing "updatedAt"');
    }
    return RemoteMangaChapterState(
      lastPage: intOf('lastPage') ?? 0,
      lastFraction: intOf('lastFraction') ?? -1,
      pageCount: intOf('pageCount'),
      readAt: intOf('readAt'),
      updatedAtMs: updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteMangaChapterState &&
      other.lastPage == lastPage &&
      other.lastFraction == lastFraction &&
      other.pageCount == pageCount &&
      other.readAt == readAt &&
      other.updatedAtMs == updatedAtMs;

  @override
  int get hashCode =>
      Object.hash(lastPage, lastFraction, pageCount, readAt, updatedAtMs);

  @override
  String toString() =>
      'RemoteMangaChapterState(page=$lastPage, fraction=$lastFraction, '
      'pages=$pageCount, readAt=$readAt, at=$updatedAtMs)';
}

/// 章状态表 → `{"states": {…}}`。
Map<String, Object?> encodeMangaChapterStates(
  Map<String, RemoteMangaChapterState> states,
) => <String, Object?>{
  kMangaChapterStatesKey: <String, Object?>{
    for (final MapEntry<String, RemoteMangaChapterState> e in states.entries)
      e.key: e.value.toJson(),
  },
};

/// [encodeMangaChapterStates] 的逆；形态不对 → [FormatException]。空章 key 丢弃。
Map<String, RemoteMangaChapterState> decodeMangaChapterStates(Object? json) {
  if (json is! Map) {
    throw const FormatException('manga chapter states: expected an object');
  }
  final Object? states = json[kMangaChapterStatesKey];
  if (states is! Map) {
    throw const FormatException('manga chapter states: missing "states"');
  }
  return <String, RemoteMangaChapterState>{
    for (final MapEntry<dynamic, dynamic> e in states.entries)
      if (e.key is String && (e.key as String).isNotEmpty)
        e.key as String: RemoteMangaChapterState.fromJson(e.value),
  };
}

/// 同戳时的确定性次序：已读 > 未读，再比页码、偏移、页数、读完时刻。两端用同一个次序，
/// 同戳不同内容时双方结论一致（只会朝一个方向收敛一次，不会来回推）。
List<int> _tieOrder(RemoteMangaChapterState s) => <int>[
  s.readAt == null ? 0 : 1,
  s.lastPage,
  s.lastFraction,
  s.pageCount ?? -1,
  s.readAt ?? 0,
];

/// [incoming] 是否该盖掉本端已存的 [current]（null = 本端没有这一章）。纯函数，host 合并 PUT、
/// client 定计划、client 落地都只用它，两端对「谁新」的结论不会漂开。
///
/// 时间戳纪律（BUG-3367 同一套）：两边的戳都按 [trustedStoredSyncStamp] 看——超出未来余量的毒戳
/// （时钟走快的设备写下的）按 0 比较，不会永远胜出；落地时写的是截过的戳（[cappedMangaChapterState]），
/// 毒戳不会扩散。两边都按同一口径看，持有毒戳的那一端在下一次比较里落败、被对端的正常值盖掉，自愈。
bool mangaChapterStateReplaces({
  required RemoteMangaChapterState? current,
  required RemoteMangaChapterState incoming,
  required int nowMs,
}) {
  if (current == null) return true;
  final int incomingAt = trustedStoredSyncStamp(
    incoming.updatedAtMs,
    nowMs: nowMs,
  );
  final int currentAt = trustedStoredSyncStamp(
    current.updatedAtMs,
    nowMs: nowMs,
  );
  if (incomingAt != currentAt) return incomingAt > currentAt;
  final List<int> a = _tieOrder(incoming);
  final List<int> b = _tieOrder(current);
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

/// 落地前把 [s] 的戳截到 [capFutureSyncStamp]（与 [mangaChapterStateReplaces] 的比较口径一致）。
RemoteMangaChapterState cappedMangaChapterState(
  RemoteMangaChapterState s, {
  required int nowMs,
}) => s.withUpdatedAt(capFutureSyncStamp(s.updatedAtMs, nowMs: nowMs));

/// 一本书一次按章 LWW 的计划：[pull] = host 较新、要落到本端的章（戳已截），[push] = 本端较新、
/// 要推给 host 的章（原样，host 收到时自己截）。两端相同的章两边都不出现。
typedef MangaChapterSyncPlan = ({
  Map<String, RemoteMangaChapterState> pull,
  Map<String, RemoteMangaChapterState> push,
});

/// 按章比较 [local] 与 [remote]，给出 [MangaChapterSyncPlan]。纯函数。
MangaChapterSyncPlan planMangaChapterStateSync({
  required Map<String, RemoteMangaChapterState> local,
  required Map<String, RemoteMangaChapterState> remote,
  required int nowMs,
}) {
  final Map<String, RemoteMangaChapterState> pull =
      <String, RemoteMangaChapterState>{};
  final Map<String, RemoteMangaChapterState> push =
      <String, RemoteMangaChapterState>{};
  for (final MapEntry<String, RemoteMangaChapterState> e in remote.entries) {
    if (mangaChapterStateReplaces(
      current: local[e.key],
      incoming: e.value,
      nowMs: nowMs,
    )) {
      pull[e.key] = cappedMangaChapterState(e.value, nowMs: nowMs);
    }
  }
  for (final MapEntry<String, RemoteMangaChapterState> e in local.entries) {
    if (pull.containsKey(e.key)) continue;
    if (mangaChapterStateReplaces(
      current: remote[e.key],
      incoming: e.value,
      nowMs: nowMs,
    )) {
      push[e.key] = e.value;
    }
  }
  return (pull: pull, push: push);
}

/// 把 [incoming] 按章 LWW 合并进 [db] 里书 [bookUid] 的章状态（一个事务内读-比较-写，与本机阅读器
/// 的写入互不插队）。返回真正写下的章 key。host 合并 PUT 与 client 落地共用。
Future<List<String>> landMangaChapterStates(
  FushiDatabase db, {
  required String bookUid,
  required Map<String, RemoteMangaChapterState> incoming,
  required int nowMs,
}) {
  if (bookUid.isEmpty || incoming.isEmpty) {
    return Future<List<String>>.value(const <String>[]);
  }
  return db.upsertMangaChapterStatesWhere(
    bookUid: bookUid,
    rows: <MangaChapterStateRow>[
      for (final MapEntry<String, RemoteMangaChapterState> e
          in incoming.entries)
        if (e.key.isNotEmpty)
          cappedMangaChapterState(
            e.value,
            nowMs: nowMs,
          ).toRow(bookUid: bookUid, chapterKey: e.key),
    ],
    replaces: (MangaChapterStateRow? existing, MangaChapterStateRow row) =>
        mangaChapterStateReplaces(
          current: existing == null
              ? null
              : RemoteMangaChapterState.fromRow(existing),
          incoming: RemoteMangaChapterState.fromRow(row),
          nowMs: nowMs,
        ),
  );
}

/// 本端书 [bookUid] 的全部章状态（wire 形态）。
Future<Map<String, RemoteMangaChapterState>> readMangaChapterStates(
  FushiDatabase db,
  String bookUid,
) async => <String, RemoteMangaChapterState>{
  for (final MapEntry<String, MangaChapterStateRow> e
      in (await db.getMangaChapterStates(bookUid)).entries)
    e.key: RemoteMangaChapterState.fromRow(e.value),
};

/// 「按章供给 / 合并漫画阅读进度」的 host 能力（**可选**，[BookProgressBatchHost] 同一范式：server
/// 用 `is` 协商，不实现的 host 不报能力位、端点 404）。
abstract interface class MangaChapterProgressHost {
  /// host 书库里漫画 [bookKey] 的全部章状态（没读过任何一章 = 空表）。书不在库 / 不是漫画 → null
  /// （端点 404）。
  Future<Map<String, RemoteMangaChapterState>?> readMangaChapterProgress(
    String bookKey,
  );

  /// 把 [incoming] 按章 LWW（[mangaChapterStateReplaces]）合并进漫画 [bookKey]，返回合并**之后**
  /// 这本书的全部章状态。书不在库 / 不是漫画 → null（端点 404）。
  Future<Map<String, RemoteMangaChapterState>?> mergeMangaChapterProgress(
    String bookKey,
    Map<String, RemoteMangaChapterState> incoming,
  );
}

/// [MangaChapterProgressHost] 的互联模块：路由 [kMangaChapterProgressPath]、能力位
/// [kMangaChapterProgressCapability]。由 `FushiSyncServer` 按库服务是否实现该能力自动装配（它是库服务
/// 的一部分，跟书进度端点一样，不另设装配点）。
class MangaChapterProgressInterconnectModule extends InterconnectHostModule {
  MangaChapterProgressInterconnectModule(this.host);

  /// null = 这台 host 的库服务不提供章级进度（能力位不出现、路由 404）。
  final MangaChapterProgressHost? host;

  @override
  String get capabilityKey => kMangaChapterProgressCapability;

  @override
  Future<Object?> capability() async => host == null
      ? null
      : const <String, Object?>{'v': kMangaChapterProgressWireVersion};

  @override
  List<String> get routePrefixes => const <String>[kMangaChapterProgressPath];

  @override
  Future<shelf.Response> handle(InterconnectRequest request) async {
    final MangaChapterProgressHost? h = host;
    if (h == null) {
      return shelf.Response.notFound('Manga chapter progress unsupported');
    }
    if (!request.path.startsWith('$kMangaChapterProgressPath/')) {
      return shelf.Response.notFound('Not found');
    }
    // 路径已由服务器解码；bookKey 只用于查库，不参与任何文件路径。
    final String bookKey = request.path.substring(
      kMangaChapterProgressPath.length + 1,
    );
    if (bookKey.isEmpty) return shelf.Response.notFound('Not found');
    switch (request.method.toUpperCase()) {
      case 'GET':
        final Map<String, RemoteMangaChapterState>? states = await h
            .readMangaChapterProgress(bookKey);
        if (states == null) return shelf.Response.notFound('Book not found');
        return _json(encodeMangaChapterStates(states));
      case 'PUT':
        final Map<String, dynamic>? body = await readJsonObjectBody(
          request.raw,
        );
        if (body == null) return shelf.Response(400, body: 'Invalid JSON');
        final Map<String, RemoteMangaChapterState> incoming;
        try {
          incoming = decodeMangaChapterStates(body);
        } on FormatException catch (e) {
          return shelf.Response(400, body: e.message);
        }
        final Map<String, RemoteMangaChapterState>? merged = await h
            .mergeMangaChapterProgress(bookKey, incoming);
        if (merged == null) return shelf.Response.notFound('Book not found');
        return _json(encodeMangaChapterStates(merged));
      default:
        return shelf.Response(405);
    }
  }

  static shelf.Response _json(Map<String, Object?> body) => shelf.Response.ok(
    jsonEncode(body),
    // 章 key / bookKey 含 CJK：charset 必带。
    headers: const <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    },
  );
}
