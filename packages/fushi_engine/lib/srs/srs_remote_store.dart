/// 远程复习库（docs/specs/2026-11-01-srs-remote-review-design.md）：已配对设备不下载卡组，直接在互联主机的
/// 复习库上复习。客户端的 [SrsDbStore] 换成一个把每次调用转发到主机的实现，复习页 / 笔记编辑 / 牌组设置 /
/// 浏览等页面原样运行，功能与在本机复习一致；排队、排程（含 RWKV）、模板渲染、写入都在主机的 [SrsDbStore] 上做。
///
/// 这里是两端共用的部分：
/// - 线格式（[SrsRemoteWire]）：实体视图（笔记 / 笔记类型 / 牌组）不按字段搬，搬的是物化输入（身份记录 +
///   修改记录，[SrsEntitySource]），客户端用同一个物化内核得出逐字相同的视图（含修改记录 / 冲突寄存器）；
/// - 主机侧服务（[SrsRemoteStoreService]）：按操作名分派到当前 profile 的 [SrsDbStore]，写操作按客户端请求 id 幂等。
///
/// 路由在 `FushiSyncServer`（srs_remote_store_routes.dart），鉴权由它的 middleware 统一做。
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// host 在 `GET /api/capabilities` 声明的能力位。
const String kSrsRemoteStoreCapability = 'srsRemoteStoreV1';

/// 端点前缀（`POST <前缀>call`、`GET <前缀>media/<名字>`）。
const String kSrsRemoteStorePathPrefix = '/api/srs/remote/';

/// 远程复习库的失败：[code] 是给客户端的机读码，[status] 是 HTTP 状态。
class SrsRemoteStoreError implements Exception {
  const SrsRemoteStoreError(this.status, this.code, [this.detail]);

  final int status;
  final String code;

  /// 主机上的原始异常文字（只用于日志，界面按 [code] 出文案）。
  final String? detail;

  /// 作答时这张卡在主机上已经变了（别的设备 / 主机自己复习过、被删、被挂起）。
  static const String stale = 'stale';

  /// 主机期间切换了配置：写入不能落进另一份配置。
  static const String profileChanged = 'profile_changed';

  /// 复习模块没开。
  static const String unavailable = 'unavailable';

  /// 请求体不合契约。
  static const String badRequest = 'bad_request';

  /// 不认识的操作名。
  static const String unknownOp = 'unknown_op';

  /// 主机上执行时抛了异常（参数在主机上不成立，如卡已不存在）。
  static const String failed = 'failed';

  @override
  String toString() =>
      'SrsRemoteStoreError($status, $code${detail == null ? '' : ', $detail'})';
}

/// 客户端的远程复习库实现它：几个扩展方法直接读库（`db`），在客户端跑不了，开头按它转发到主机。
abstract interface class SrsRemoteForwarding {
  Future<List<String>> remoteNoteIdsOfType(String noteTypeId, {int? limit});
}

/// 线格式（两端共用；编码在主机，解码在客户端）。
abstract final class SrsRemoteWire {
  // ---------------------------------------------------------------- 实体

  static List<Object?> editItems(List<SrsEditItem> items) => <Object?>[
    for (final SrsEditItem e in items)
      <Object?>[utf8.decode(e.json), e.serverTime],
  ];

  static List<SrsEditItem> editItemsFrom(Object? json) => <SrsEditItem>[
    for (final Object? e in (json as List<Object?>?) ?? const <Object?>[])
      if (e case [final String item, final int? serverTime])
        SrsEditItem.stored(Uint8List.fromList(utf8.encode(item)), serverTime)
      else
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest),
  ];

  static Map<String, Object?> source(SrsEntitySource s) => <String, Object?>{
    'id': s.id,
    'p': s.payloadJson,
    'e': editItems(s.edits),
  };

  static SrsEntitySource sourceFrom(Object? json) {
    final Map<String, Object?> m = (json! as Map).cast<String, Object?>();
    return SrsEntitySource(
      m['id']! as String,
      m['p']! as String,
      editItemsFrom(m['e']),
    );
  }

  /// 物化输入的版本标签：身份记录不可变、修改记录只增不改，所以「条数 + 最后一条的 ID」变了视图才会变。
  /// 客户端按它缓存笔记类型 / 牌组树，没变就不再搬（笔记类型的修改记录里有整份模板，搬一次就够）。
  static String tagOf(SrsEntitySource s) =>
      '${s.payloadJson.length}:${s.edits.length}:'
      '${s.edits.isEmpty ? '' : s.edits.last.edit.id}';

  static List<SrsNoteView> notesFrom(List<SrsEntitySource> sources) =>
      sources.isEmpty ? const <SrsNoteView>[] : srsMaterializeNotes(sources);

  static List<SrsNoteTypeView> noteTypesFrom(
    String profileUid,
    List<SrsEntitySource> sources,
  ) => sources.isEmpty
      ? const <SrsNoteTypeView>[]
      : srsMaterializeNoteTypes(<(SrsEntitySource, SrsBuiltinNoteType?)>[
          for (final SrsEntitySource s in sources)
            (
              s,
              srsBuiltinNoteTypeForKey(
                profileUid,
                (jsonDecode(s.payloadJson) as Map)['builtin'] as String?,
              ),
            ),
        ]);

  static SrsDeckTree deckTreeFrom(List<SrsEntitySource> sources) =>
      SrsDeckTree(srsMaterializeDecks(sources));

  static SrsEntityEdits entityEditsFrom(Object? json) =>
      srsEntityEditsOf(<List<SrsEditItem>>[editItemsFrom(json)]).single;

  // ---------------------------------------------------------------- 复习

  static Map<String, Object?> dayContext(SrsDayContext d) => <String, Object?>{
    'off': d.utcOffsetMin,
    'roll': d.rolloverHour,
  };

  static SrsDayContext dayContextFrom(Object? json) {
    final Map<String, Object?> m = (json! as Map).cast<String, Object?>();
    return SrsDayContext(
      utcOffsetMin: m['off']! as int,
      rolloverHour: m['roll']! as int,
    );
  }

  /// 牌组行：牌组视图只带 ID，客户端从它缓存的牌组树里取（[SrsRemoteStoreService] 的回包总带树的标签）。
  static Map<String, Object?> summary(SrsDeckSummary s) => <String, Object?>{
    'deck': s.deck.id,
    'name': s.fullName,
    'depth': s.depth,
    'parent': s.parentId,
    'n': s.newCount,
    'l': s.learnCount,
    'r': s.reviewCount,
    'b': <String, Object?>{
      'limit': s.newBudget.limit,
      'allowed': s.newBudget.allowed,
      'rb': s.newBudget.reviewBudget,
      'why': s.newBudget.reason?.name,
    },
    'total': s.totalCards,
    'rp': s.rwkvPending,
  };

  static SrsDeckSummary? summaryFrom(Object? json, SrsDeckTree tree) {
    if (json == null) return null;
    final Map<String, Object?> m = (json as Map).cast<String, Object?>();
    final SrsDeckView? deck = tree[m['deck']! as String];
    if (deck == null) return null;
    final Map<String, Object?> b = (m['b']! as Map).cast<String, Object?>();
    final String? why = b['why'] as String?;
    return SrsDeckSummary(
      deck: deck,
      fullName: m['name']! as String,
      depth: m['depth']! as int,
      parentId: m['parent'] as String?,
      newCount: m['n']! as int,
      learnCount: m['l']! as int,
      reviewCount: m['r']! as int,
      newBudget: SrsNewCardBudget(
        limit: b['limit']! as int,
        allowed: b['allowed']! as int,
        reviewBudget: b['rb']! as int,
        reason: why == null
            ? null
            : SrsNewCardBudgetReason.values.firstWhere(
                (SrsNewCardBudgetReason r) => r.name == why,
              ),
      ),
      totalCards: m['total']! as int,
      rwkvPending: m['rp'] == true,
    );
  }

  static Map<String, Object?> study(SrsStudyState s) => <String, Object?>{
    'sum': summary(s.summary),
    'next': s.next,
    'after': s.after,
    if (s.custom != null)
      'custom': <String, Object?>{
        'left': s.custom!.left,
        'learn': s.custom!.learn,
      },
  };

  static SrsStudyState? studyFrom(Object? json, SrsDeckTree tree) {
    if (json == null) return null;
    final Map<String, Object?> m = (json as Map).cast<String, Object?>();
    final SrsDeckSummary? sum = summaryFrom(m['sum'], tree);
    if (sum == null) return null;
    return SrsStudyState(
      summary: sum,
      next: m['next'] as String?,
      after: m['after'] as String?,
      custom: SrsCustomStudyProgress.fromValue(m['custom']),
    );
  }

  static Map<String, Object?>? customStudy(SrsCustomStudy? c) => c == null
      ? null
      : <String, Object?>{
          'mode': c.mode.wire,
          'since': c.sinceMs,
          'days': c.days,
          'limit': c.limit,
          'states': <String>[
            for (final SrsCustomStudyState s in c.states) s.wire,
          ],
          'tags': c.tags,
        };

  static SrsCustomStudy? customStudyFrom(Object? json) {
    if (json == null) return null;
    final Map<String, Object?> m = (json as Map).cast<String, Object?>();
    final List<Object?> states = (m['states'] as List<Object?>?) ?? const [];
    return SrsCustomStudy(
      mode: SrsCustomStudyMode.values.firstWhere(
        (SrsCustomStudyMode x) => x.wire == m['mode'],
      ),
      sinceMs: m['since']! as int,
      days: (m['days'] as int?) ?? 1,
      limit: (m['limit'] as int?) ?? 100,
      states: <SrsCustomStudyState>{
        for (final SrsCustomStudyState s in SrsCustomStudyState.values)
          if (states.contains(s.wire)) s,
      },
      tags: <String>[
        for (final Object? t in (m['tags'] as List<Object?>?) ?? const [])
          t! as String,
      ],
    );
  }

  static Map<String, Object?> preview(SrsAnswerPreview p) => <String, Object?>{
    'plan': <String, Object?>{
      for (final MapEntry<int, SrsScheduleResult> e in p.plan.byRating.entries)
        '${e.key}': e.value.toJson(),
    },
    'mem': p.memoryBefore?.toJson(),
    'alg': p.algorithm.wire,
    'params': p.params,
    'now': p.nowMs,
    'ts': p.timeSource.wire,
  };

  static SrsAnswerPreview previewFrom(Object? json) {
    final Map<String, Object?> m = (json! as Map).cast<String, Object?>();
    return SrsAnswerPreview(
      plan: SrsAnswerPlan(<int, SrsScheduleResult>{
        for (final MapEntry<String, Object?> e
            in (m['plan']! as Map).cast<String, Object?>().entries)
          int.parse(e.key): SrsScheduleResult.fromJson(
            (e.value! as Map).cast<String, Object?>(),
          ),
      }),
      memoryBefore: SrsMemory.fromJson(m['mem']),
      algorithm: SrsAlgorithm.tryParse(m['alg'] as String?)!,
      params: <double>[
        for (final Object? v in m['params']! as List<Object?>)
          (v! as num).toDouble(),
      ],
      nowMs: m['now']! as int,
      timeSource: SrsTimeSource.parse(m['ts'] as String?),
    );
  }

  static Map<String, Object?> rendered(SrsRenderedCard r) => <String, Object?>{
    'q': r.question,
    'a': r.answer,
    'css': r.css,
    'empty': r.isEmpty,
    'fields': r.fields,
    'defs': r.fushiCardDefinitions,
  };

  static SrsRenderedCard? renderedFrom(Object? json) {
    if (json == null) return null;
    final Map<String, Object?> m = (json as Map).cast<String, Object?>();
    return SrsRenderedCard(
      question: m['q']! as String,
      answer: m['a']! as String,
      css: m['css']! as String,
      isEmpty: m['empty'] == true,
      fields: (m['fields']! as Map).cast<String, String>(),
      fushiCardDefinitions: m['defs'] as String?,
    );
  }

  static SrsCardCacheRow? cardRowFrom(Object? json) => json == null
      ? null
      : SrsCardCacheRow.fromJson((json as Map).cast<String, dynamic>());

  static List<SrsCardCacheRow> cardRowsFrom(Object? json) => <SrsCardCacheRow>[
    for (final Object? r in json! as List<Object?>) cardRowFrom(r)!,
  ];

  static SrsReviewLog logFrom(Object? json) =>
      SrsReviewLog.fromJson((json! as Map).cast<String, Object?>());

  static List<SrsReviewLog> logsFrom(Object? json) => <SrsReviewLog>[
    for (final Object? l in json! as List<Object?>) logFrom(l),
  ];

  static SrsFieldEdit editFrom(Object? json) =>
      SrsFieldEdit.fromJson((json! as Map).cast<String, Object?>());

  static List<SrsFieldEdit> editsFrom(Object? json) => <SrsFieldEdit>[
    for (final Object? e in json! as List<Object?>) editFrom(e),
  ];

  static List<Object?> editSpecs(List<SrsEditSpec> specs) => <Object?>[
    for (final SrsEditSpec s in specs)
      <Object?>[s.kind.wire, s.entityId, s.key, s.value],
  ];

  static List<SrsEditSpec> editSpecsFrom(Object? json) => <SrsEditSpec>[
    for (final Object? s in json! as List<Object?>)
      if (s case [
        final Object? kind,
        final String id,
        final String key,
        final Object? value,
      ])
        SrsEditSpec(_kind(kind), id, key, value)
      else
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest),
  ];

  static SrsEntityKind _kind(Object? wire) =>
      SrsEntityKind.tryParse(wire as String?) ??
      (throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest));

  static SrsEntityKind kindFrom(Object? wire) => _kind(wire);

  static Map<String, Object?> sync2Result(SrsSync2Result r) =>
      <String, Object?>{
        'json': r.json,
        'files': <Object?>[
          for (final (String path, Uint8List bytes) in r.files)
            <Object?>[path, base64Encode(bytes)],
        ],
      };

  static SrsSync2Result sync2ResultFrom(Object? json) {
    final Map<String, Object?> m = (json! as Map).cast<String, Object?>();
    return SrsSync2Result(m['json'], <(String, Uint8List)>[
      for (final Object? f in (m['files'] as List<Object?>?) ?? const [])
        if (f case [final String path, final String bytes])
          (path, base64Decode(bytes))
        else
          throw const FormatException('bad sync2 file entry'),
    ]);
  }
}

/// 一次分派的参数读取（缺 / 类型不对一律 400）。
class _Args {
  _Args(this._m);

  final Map<String, Object?> _m;

  Never _bad() =>
      throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);

  Object? raw(String key) => _m[key];

  String str(String key) {
    final Object? v = _m[key];
    return v is String ? v : _bad();
  }

  String? optStr(String key) {
    final Object? v = _m[key];
    if (v == null) return null;
    return v is String ? v : _bad();
  }

  int integer(String key) {
    final Object? v = _m[key];
    return v is int ? v : _bad();
  }

  int? optInt(String key) {
    final Object? v = _m[key];
    if (v == null) return null;
    return v is int ? v : _bad();
  }

  bool flag(String key) => _m[key] == true;

  List<String> strings(String key) {
    final Object? v = _m[key];
    if (v == null) return const <String>[];
    if (v is! List) _bad();
    return <String>[for (final Object? s in v) s is String ? s : _bad()];
  }

  Map<String, String>? optStrMap(String key) {
    final Object? v = _m[key];
    if (v == null) return null;
    if (v is! Map) _bad();
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<Object?, Object?> e in v.entries) {
      final Object? k = e.key;
      final Object? value = e.value;
      if (k is! String || value is! String) _bad();
      out[k] = value;
    }
    return out;
  }

  Map<String, Object?> map(String key) {
    final Object? v = _m[key];
    return v is Map ? v.cast<String, Object?>() : _bad();
  }
}

typedef _Run = Future<Object?> Function(SrsDbStore store, _Args a);

/// 一个可远程调用的操作；[write] = 改库（按请求 id 幂等，成功后通知 [SrsRemoteStoreService.onWrite]）。
class _Op {
  const _Op(this.run, {this.write = false});

  final _Run run;
  final bool write;
}

/// 主机侧服务：每个请求现取当前 profile 的 [SrsDbStore]（配置切换 / 模块开关即时生效）。
class SrsRemoteStoreService {
  SrsRemoteStoreService({
    required Future<SrsDbStore?> Function() readStore,
    required Future<Uint8List?> Function(String name) readMedia,
    void Function()? onWrite,
    int idempotencyCapacity = 256,
  }) : _readStore = readStore,
       _readMedia = readMedia,
       _onWrite = onWrite,
       _capacity = idempotencyCapacity;

  final Future<SrsDbStore?> Function() _readStore;
  final Future<Uint8List?> Function(String name) _readMedia;

  /// 远程写入落库后调用：主机自己的界面重读、互联推送照常发出（与本机写入同一条信号）。
  final void Function()? _onWrite;
  final int _capacity;

  /// 写操作幂等缓存：客户端请求 id → 回包（最近 [_capacity] 次，按插入顺序淘汰）。
  final LinkedHashMap<String, Map<String, Object?>> _done =
      LinkedHashMap<String, Map<String, Object?>>();

  /// 同一请求 id 并发重发时等第一次的结果，不各写一次。
  final Map<String, Future<Map<String, Object?>>> _inFlight =
      <String, Future<Map<String, Object?>>>{};

  /// 牌组树的线格式缓存（按 [SrsDbStore.deckTreeKey]）。
  ({String key, String tag, List<Map<String, Object?>> decks})? _tree;

  /// 卡面引用的媒体字节；名字不合法 / 不存在时 null。
  Future<Uint8List?> media(String name) => _readMedia(name);

  /// 执行一次调用。[profile] 是客户端以为的 profile（null = 握手，不核对）；[request] 是写操作的幂等 id。
  ///
  /// 回包：`{profile, rev, fp, tt, now, ts, sched, rwkv, result}`——`rev` / `fp` 是主机的修订号与统计指纹，
  /// `tt` 是牌组树标签（客户端据此判断缓存的树还新不新），`now` / `ts` 是主机此刻的复习时钟。
  Future<Map<String, Object?>> call({
    required String? profile,
    required String op,
    required Map<String, Object?> args,
    String? request,
  }) {
    final _Op? spec = _ops[op];
    if (spec == null) {
      return Future<Map<String, Object?>>.error(
        const SrsRemoteStoreError(404, SrsRemoteStoreError.unknownOp),
      );
    }
    if (!spec.write) return _run(spec, profile, args);
    if (request == null || request.isEmpty) {
      return Future<Map<String, Object?>>.error(
        const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest),
      );
    }
    final Map<String, Object?>? done = _done[request];
    if (done != null) return Future<Map<String, Object?>>.value(done);
    final Future<Map<String, Object?>>? running = _inFlight[request];
    if (running != null) return running;
    final Future<Map<String, Object?>> future = _run(spec, profile, args);
    _inFlight[request] = future;
    return future
        .then((Map<String, Object?> out) {
          _done[request] = out;
          while (_done.length > _capacity) {
            _done.remove(_done.keys.first);
          }
          _onWrite?.call();
          return out;
        })
        .whenComplete(() => _inFlight.remove(request));
  }

  Future<Map<String, Object?>> _run(
    _Op spec,
    String? profile,
    Map<String, Object?> args,
  ) async {
    final SrsDbStore? store = await _readStore();
    if (store == null) {
      throw const SrsRemoteStoreError(503, SrsRemoteStoreError.unavailable);
    }
    if (profile != null && profile != store.profileUid) {
      throw const SrsRemoteStoreError(409, SrsRemoteStoreError.profileChanged);
    }
    final Object? result;
    try {
      result = await spec.run(store, _Args(args));
    } on SrsRemoteStoreError {
      rethrow;
    } on ArgumentError catch (e) {
      throw SrsRemoteStoreError(400, SrsRemoteStoreError.failed, '$e');
    } on StateError catch (e) {
      throw SrsRemoteStoreError(409, SrsRemoteStoreError.failed, '$e');
    }
    final (int nowMs, SrsTimeSource source) = store.now();
    return <String, Object?>{
      'profile': store.profileUid,
      'rev': store.revision,
      'fp': store.contentFingerprint,
      'tt': (await _treeWire(store)).tag,
      'now': nowMs,
      'ts': source.wire,
      'sched': store.canSchedule,
      'rwkv': store.rwkv?.ready ?? false,
      'result': result,
    };
  }

  Future<({String key, String tag, List<Map<String, Object?>> decks})>
  _treeWire(SrsDbStore store) async {
    final String key = store.deckTreeKey;
    final ({String key, String tag, List<Map<String, Object?>> decks})? c =
        _tree;
    if (c != null && c.key == key) return c;
    final List<SrsEntitySource> sources = await store.entitySources(
      SrsEntityKind.deck,
    );
    final List<String> tags = <String>[
      for (final SrsEntitySource s in sources)
        '${s.id}=${SrsRemoteWire.tagOf(s)}',
    ]..sort();
    final ({String key, String tag, List<Map<String, Object?>> decks}) out = (
      key: key,
      tag: tags.join(';'),
      decks: <Map<String, Object?>>[
        for (final SrsEntitySource s in sources) SrsRemoteWire.source(s),
      ],
    );
    if (store.deckTreeKey == key) _tree = out;
    return out;
  }

  static Future<List<Map<String, Object?>>> _sources(
    SrsDbStore store,
    SrsEntityKind kind,
    Iterable<String> ids,
  ) async => <Map<String, Object?>>[
    for (final SrsEntitySource s in await store.entitySources(kind, ids: ids))
      SrsRemoteWire.source(s),
  ];

  /// 笔记类型只带 `{id, tag}`：客户端缓存里标签一致就不再搬（[SrsRemoteWire.tagOf]）。
  static Future<List<Map<String, Object?>>> _typeRefs(
    SrsDbStore store,
    Iterable<String> ids,
  ) async => <Map<String, Object?>>[
    for (final SrsEntitySource s in await store.entitySources(
      SrsEntityKind.noteType,
      ids: ids,
    ))
      <String, Object?>{'id': s.id, 'tag': SrsRemoteWire.tagOf(s)},
  ];

  static Future<Map<String, Object?>?> _detail(
    SrsDbStore store,
    String cardId,
  ) async {
    final SrsCardDetail? d = await store.cardDetail(cardId);
    if (d == null) return null;
    return <String, Object?>{
      'card': d.card.toJson(),
      'note': (await _sources(store, SrsEntityKind.note, <String>[
        d.note.id,
      ])).single,
      'type': (await _typeRefs(store, <String>[d.noteType.id])).single,
      'tpl': d.template?.id,
      'deckName': d.deckName,
    };
  }

  static final Map<String, _Op> _ops = <String, _Op>{
    // ------------------------------------------------------------ 读
    'hello': _Op((SrsDbStore s, _Args a) async => null),
    'dayContext': _Op(
      (SrsDbStore s, _Args a) async =>
          SrsRemoteWire.dayContext(await s.dayContext()),
    ),
    'deckTree': _Op((SrsDbStore s, _Args a) async {
      final List<SrsEntitySource> sources = await s.entitySources(
        SrsEntityKind.deck,
      );
      return <Map<String, Object?>>[
        for (final SrsEntitySource x in sources) SrsRemoteWire.source(x),
      ];
    }),
    'deckSummaries': _Op(
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsDeckSummary d in await s.deckSummaries())
          SrsRemoteWire.summary(d),
      ],
    ),
    'deckSummary': _Op((SrsDbStore s, _Args a) async {
      final SrsDeckSummary? d = await s.deckSummary(a.str('deck'));
      return d == null ? null : SrsRemoteWire.summary(d);
    }),
    'studyState': _Op((SrsDbStore s, _Args a) async {
      final SrsStudyState? st = await s.studyState(
        a.str('deck'),
        exclude: a.strings('exclude').toSet(),
        custom: SrsRemoteWire.customStudyFrom(a.raw('custom')),
      );
      return st == null ? null : SrsRemoteWire.study(st);
    }),
    'cardRow': _Op(
      (SrsDbStore s, _Args a) async =>
          (await s.cardRow(a.str('card')))?.toJson(),
    ),
    'cardRows': _Op(
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsCardCacheRow r in await s.cardRows(a.strings('cards')))
          r.toJson(),
      ],
    ),
    'cardsOfNote': _Op(
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsCardCacheRow r in await s.cardsOfNote(a.str('note')))
          r.toJson(),
      ],
    ),
    'cardDetail': _Op(
      (SrsDbStore s, _Args a) async => _detail(s, a.str('card')),
    ),
    'renderCard': _Op((SrsDbStore s, _Args a) async {
      final SrsRenderedCard? r = await s.renderCard(a.str('card'));
      return r == null ? null : SrsRemoteWire.rendered(r);
    }),
    'preview': _Op(
      (SrsDbStore s, _Args a) async =>
          SrsRemoteWire.preview(await s.preview(a.str('card'))),
    ),
    'notes': _Op(
      (SrsDbStore s, _Args a) async =>
          _sources(s, SrsEntityKind.note, a.strings('ids')),
    ),
    'noteTypeRefs': _Op((SrsDbStore s, _Args a) async {
      final List<String> ids = a.strings('ids');
      return _typeRefs(s, ids);
    }),
    'allNoteTypeRefs': _Op(
      (SrsDbStore s, _Args a) async => _typeRefs(s, <String>[
        for (final SrsNoteTypeView t in await s.noteTypes()) t.id,
      ]),
    ),
    'noteTypeSources': _Op(
      (SrsDbStore s, _Args a) async =>
          _sources(s, SrsEntityKind.noteType, a.strings('ids')),
    ),
    'history': _Op(
      (SrsDbStore s, _Args a) async =>
          (await s.history(a.str('card'))).toWire(),
    ),
    'entityEdits': _Op((SrsDbStore s, _Args a) async {
      final List<SrsEntitySource> src = await s.entitySources(
        SrsRemoteWire.kindFrom(a.raw('kind')),
        ids: <String>[a.str('id')],
      );
      return src.isEmpty
          ? <Object?>[]
          : SrsRemoteWire.editItems(src.single.edits);
    }),
    'expandFields': _Op(
      (SrsDbStore s, _Args a) async => s.expandFields(
        a.optStrMap('fields') ?? const <String, String>{},
        dropMissing: a.flag('dropMissing'),
      ),
    ),
    'syncConflicts': _Op((SrsDbStore s, _Args a) async {
      final List<(SrsEntityKind, String, SrsRegister)> all = await s
          .syncConflicts();
      final Map<String, Object?> edits = <String, Object?>{};
      for (final (SrsEntityKind kind, String id, _) in all) {
        final String k = '${kind.wire}/$id';
        if (edits.containsKey(k)) continue;
        final List<SrsEntitySource> src = await s.entitySources(
          kind,
          ids: <String>[id],
        );
        edits[k] = src.isEmpty
            ? <Object?>[]
            : SrsRemoteWire.editItems(src.single.edits);
      }
      return <String, Object?>{
        'items': <Object?>[
          for (final (SrsEntityKind kind, String id, SrsRegister r) in all)
            <Object?>[kind.wire, id, r.key],
        ],
        'edits': edits,
      };
    }),
    'instantDueCardIds': _Op(
      (SrsDbStore s, _Args a) async => (await s.instantDueCardIds())?.toList(),
    ),
    'noteIdsOfType': _Op(
      (SrsDbStore s, _Args a) async =>
          s.noteIdsOfType(a.str('type'), limit: a.optInt('limit')),
    ),
    // ------------------------------------------------------------ 写
    'answerAndStudy': _Op(write: true, (SrsDbStore s, _Args a) async {
      final String card = a.str('card');
      if (a.raw('checkBase') == true) {
        final SrsCardCacheRow? row = await s.cardRow(card);
        if (row == null || row.lastLogId != a.optStr('base')) {
          throw const SrsRemoteStoreError(409, SrsRemoteStoreError.stale);
        }
      }
      final SrsAnswerOutcome out = await s.answerAndStudy(
        card,
        a.integer('rating'),
        durationMs: a.integer('durationMs').clamp(0, kSrsMaxAnswerDurationMs),
        studyDeckId: a.optStr('deck'),
        custom: SrsRemoteWire.customStudyFrom(a.raw('custom')),
      );
      final SrsStudyState? study = out.study;
      return <String, Object?>{
        'log': out.log.toJson(),
        'study': study == null ? null : SrsRemoteWire.study(study),
      };
    }),
    'undo': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => s.undo(a.str('card'), a.str('log')),
    ),
    'resetCard': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.resetCard(a.str('card'));
      return null;
    }),
    'resetCards': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsReviewLog l in await s.resetCards(a.strings('cards')))
          l.toJson(),
      ],
    ),
    'setDueDays': _Op(write: true, (SrsDbStore s, _Args a) async {
      final Map<String, int> days = <String, int>{
        for (final MapEntry<String, Object?> e in a.map('days').entries)
          e.key: e.value is int
              ? e.value! as int
              : (throw const SrsRemoteStoreError(
                  400,
                  SrsRemoteStoreError.badRequest,
                )),
      };
      return <Object?>[
        for (final SrsReviewLog l in await s.setDueDays(days)) l.toJson(),
      ];
    }),
    'rescheduleDeck': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => s.rescheduleDeck(a.str('deck')),
    ),
    'createNote': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => s.createNote(
        noteTypeId: a.str('type'),
        fieldsById: a.optStrMap('fields') ?? const <String, String>{},
        deckId: a.optStr('deck'),
        tags: a.strings('tags'),
        source: SrsSourceRef.fromJson(a.raw('source')),
        guid: a.optStr('guid'),
        createdAt: a.optInt('createdAt'),
      ),
    ),
    'updateNote': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.updateNote(
        a.str('note'),
        fieldsById: a.optStrMap('fields'),
        tags: a.raw('tags') == null ? null : a.strings('tags'),
      );
      return null;
    }),
    'deleteNote': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.deleteNote(a.str('note'));
      return null;
    }),
    'restoreNote': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.restoreNote(a.str('note'));
      return null;
    }),
    'setSuspended': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.setSuspended(a.str('card'), a.flag('value'));
      return null;
    }),
    'buryUntil': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.buryUntil(a.str('card'), a.optInt('day'));
      return null;
    }),
    'setFlag': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.setFlag(a.str('card'), a.integer('flag'));
      return null;
    }),
    'moveCard': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.moveCard(a.str('card'), a.str('deck'));
      return null;
    }),
    'editFields': _Op(write: true, (SrsDbStore s, _Args a) async {
      final List<SrsFieldEdit>? out = await s.editFields(
        SrsRemoteWire.kindFrom(a.raw('kind')),
        a.str('id'),
        a.map('values'),
        machine: a.flag('machine'),
      );
      return out == null
          ? null
          : <Object?>[for (final SrsFieldEdit e in out) e.toJson()];
    }),
    'editFieldsBatch': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsFieldEdit e in await s.editFieldsBatch(<SrsFieldChange>[
          for (final SrsEditSpec x in SrsRemoteWire.editSpecsFrom(
            a.raw('changes'),
          ))
            SrsFieldChange(x.kind, x.entityId, x.key, x.value),
        ]))
          e.toJson(),
      ],
    ),
    'writeEdits': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsFieldEdit e in await s.writeEdits(
          SrsRemoteWire.editSpecsFrom(a.raw('specs')),
          records: <SrsEntityRecord>[
            for (final Object? r
                in (a.raw('records') as List<Object?>?) ?? const <Object?>[])
              SrsEntityRecord.fromJson((r! as Map).cast<String, Object?>()),
          ],
        ))
          e.toJson(),
      ],
    ),
    // 浏览命令是查询会话（结果可能很大），不进幂等缓存；浏览里的批量改走上面的写操作。
    'browseCommand': _Op(
      (SrsDbStore s, _Args a) async =>
          SrsRemoteWire.sync2Result(await s.browseCommand(a.map('request'))),
    ),
  };

  /// 全部操作名（守卫测试据此核对客户端覆盖了哪些）。
  static Iterable<String> get operations => _ops.keys;
}
