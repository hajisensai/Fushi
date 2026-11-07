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

import 'package:fushi_anki/fushi_anki_core.dart'
    show FushiCardItem, kFushiCardDefaultBackItems, kFushiCardDefaultFrontItems;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
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

  /// 主机的回包不合契约（客户端判定，主机不发这个码）：多半是两端版本不一致。见 [SrsRemoteWireError]。
  static const String badResponse = 'bad_response';

  @override
  String toString() =>
      'SrsRemoteStoreError($status, $code${detail == null ? '' : ', $detail'})';
}

/// 客户端的远程复习库实现它：几个扩展方法直接读库（`db`），在客户端跑不了，开头按它转发到主机。
abstract interface class SrsRemoteForwarding {
  Future<List<String>> remoteNoteIdsOfType(String noteTypeId, {int? limit});

  Future<SrsNoteTypeChangePreview> remotePreviewNoteTypeChange({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  });

  Future<void> remoteChangeNoteType({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  });

  Future<int> remoteMigrateLegacyLapis(
    String sourceTypeId, {
    List<String>? noteIds,
    String? targetDeckId,
  });

  Future<List<SrsHistoryEntry>> remoteEditHistory(
    SrsEntityKind kind,
    String entityId,
  );

  Future<Map<String, String>> remoteDeviceNames();
}

/// 线格式解码失败：对端发来的 JSON 不合契约（缺字段、类型不对、认不得的枚举值）。[path] 指出是哪一处
/// （如 `deckSummaries[3].b.limit`），[cause] 是下游解析器抛的原始异常（有的话）。
///
/// 两端共用同一批解码器：主机解请求体时它落成 400 [SrsRemoteStoreError.badRequest]
/// （[SrsRemoteStoreService.call]），客户端解回包时落成 [SrsRemoteStoreError.badResponse]
/// （`SrsRemoteStore`）。解码器里不留未校验的 `as`：不合契约一律走到这里，不漏成 `TypeError`。
class SrsRemoteWireError implements Exception {
  const SrsRemoteWireError(this.path, [this.cause]);

  final String path;
  final Object? cause;

  @override
  String toString() =>
      'SrsRemoteWireError($path${cause == null ? '' : ': $cause'})';
}

/// 线格式的取值校验：类型不对一律抛 [SrsRemoteWireError]（带路径）。路径只在出错时拼。
abstract final class _J {
  static Never bad(String at, [Object? cause]) =>
      throw SrsRemoteWireError(at, cause);

  static Map<String, Object?> map(Object? v, String at) {
    if (v is Map<String, Object?>) return v;
    if (v is! Map) bad(at);
    final Map<String, Object?> out = <String, Object?>{};
    for (final MapEntry<Object?, Object?> e in v.entries) {
      final Object? k = e.key;
      if (k is! String) bad(at);
      out[k] = e.value;
    }
    return out;
  }

  static List<Object?> list(Object? v, String at) =>
      v is List<Object?> ? v : bad(at);

  static String str(Object? v, String at) => v is String ? v : bad(at);

  static String? optStr(Object? v, String at) => v == null ? null : str(v, at);

  static int integer(Object? v, String at) => v is int ? v : bad(at);

  static int? optInt(Object? v, String at) => v == null ? null : integer(v, at);

  static List<String> strings(Object? v, String at) {
    final List<Object?> l = list(v, at);
    return <String>[for (int i = 0; i < l.length; i++) str(l[i], '$at[$i]')];
  }

  static Map<String, String> strMap(Object? v, String at) => <String, String>{
    for (final MapEntry<String, Object?> e in map(v, at).entries)
      e.key: str(e.value, '$at.${e.key}'),
  };

  /// 交给别处的解析器（`fromJson` / 物化内核）：它们按自己的契约读，读不了抛的类型 / 格式错误在这里
  /// 归成 [SrsRemoteWireError]，带上路径与原始异常。只转换，不吞：调用方照常收到异常。
  static T guard<T>(String at, T Function() parse) {
    try {
      return parse();
    } on TypeError catch (e) {
      bad(at, e);
    } on FormatException catch (e) {
      bad(at, e);
    } on ArgumentError catch (e) {
      bad(at, e);
    } on StateError catch (e) {
      bad(at, e);
    }
  }
}

/// 一次回包的信封（[SrsRemoteStoreService.call] 的回包里 `result` 之外的部分）。缺的字段为 null，
/// 客户端沿用上次的值。
typedef SrsRemoteEnvelope = ({
  String? profile,
  int? revision,
  String? fingerprint,
  String? treeTag,
  bool canSchedule,
  bool rwkvReady,
  String? device,
  int? nowMs,
  String? timeSource,
});

/// 笔记类型引用 `{id, tag}`（客户端按 tag 判断缓存的视图还新不新）。
typedef SrsRemoteTypeRef = ({String id, String tag});

/// `cardDetail` 的回包（笔记与笔记类型按物化输入 / 引用搬，客户端物化）。
typedef SrsRemoteCardDetail = ({
  SrsCardCacheRow card,
  SrsEntitySource note,
  SrsRemoteTypeRef type,
  String? templateId,
  String deckName,
});

/// `previewNoteTypeChange` 的回包。
typedef SrsRemoteNoteTypeChange = ({
  SrsRemoteTypeRef from,
  SrsRemoteTypeRef to,
  List<SrsNoteTypeChangePlan> plans,
});

/// 线格式（两端共用；编码在主机，解码在客户端，请求体的几个结构反过来）。解码器只用 [_J] 取值：
/// 不合契约抛 [SrsRemoteWireError]，参数 `at` 是出错时报告的路径前缀。
abstract final class SrsRemoteWire {
  // ---------------------------------------------------------------- 信封

  static SrsRemoteEnvelope envelopeFrom(Map<String, Object?> m) => (
    profile: _J.optStr(m['profile'], 'profile'),
    revision: _J.optInt(m['rev'], 'rev'),
    fingerprint: _J.optStr(m['fp'], 'fp'),
    treeTag: _J.optStr(m['tt'], 'tt'),
    canSchedule: m['sched'] == true,
    rwkvReady: m['rwkv'] == true,
    device: _J.optStr(m['dev'], 'dev'),
    nowMs: _J.optInt(m['now'], 'now'),
    timeSource: _J.optStr(m['ts'], 'ts'),
  );

  // ---------------------------------------------------------------- 标量

  static String stringFrom(Object? json, [String at = 'result']) =>
      _J.str(json, at);

  static int intFrom(Object? json, [String at = 'result']) =>
      _J.integer(json, at);

  static List<String> stringsFrom(Object? json, [String at = 'result']) =>
      _J.strings(json, at);

  static Map<String, String> stringMapFrom(
    Object? json, [
    String at = 'result',
  ]) => _J.strMap(json, at);

  // ---------------------------------------------------------------- 实体

  static List<Object?> editItems(List<SrsEditItem> items) => <Object?>[
    for (final SrsEditItem e in items)
      <Object?>[utf8.decode(e.json), e.serverTime],
  ];

  static List<SrsEditItem> editItemsFrom(Object? json, [String at = 'edits']) {
    if (json == null) return const <SrsEditItem>[];
    final List<Object?> l = _J.list(json, at);
    return <SrsEditItem>[
      for (int i = 0; i < l.length; i++)
        if (l[i] case [final String item, final int? serverTime])
          SrsEditItem.stored(Uint8List.fromList(utf8.encode(item)), serverTime)
        else
          _J.bad('$at[$i]'),
    ];
  }

  static Map<String, Object?> source(SrsEntitySource s) => <String, Object?>{
    'id': s.id,
    'p': s.payloadJson,
    'e': editItems(s.edits),
  };

  static SrsEntitySource sourceFrom(Object? json, [String at = 'source']) {
    final Map<String, Object?> m = _J.map(json, at);
    return SrsEntitySource(
      _J.str(m['id'], '$at.id'),
      _J.str(m['p'], '$at.p'),
      editItemsFrom(m['e'], '$at.e'),
    );
  }

  static List<SrsEntitySource> sourcesFrom(
    Object? json, [
    String at = 'result',
  ]) {
    final List<Object?> l = _J.list(json, at);
    return <SrsEntitySource>[
      for (int i = 0; i < l.length; i++) sourceFrom(l[i], '$at[$i]'),
    ];
  }

  /// 物化输入的版本标签：身份记录不可变、修改记录只增不改，所以「条数 + 最后一条的 ID」变了视图才会变。
  /// 客户端按它缓存笔记类型 / 牌组树，没变就不再搬（笔记类型的修改记录里有整份模板，搬一次就够）。
  static String tagOf(SrsEntitySource s) =>
      '${s.payloadJson.length}:${s.edits.length}:'
      '${s.edits.isEmpty ? '' : s.edits.last.edit.id}';

  static SrsRemoteTypeRef typeRefFrom(Object? json, [String at = 'type']) {
    final Map<String, Object?> m = _J.map(json, at);
    return (id: _J.str(m['id'], '$at.id'), tag: _J.str(m['tag'], '$at.tag'));
  }

  /// 笔记类型引用列表；null = 空。
  static List<SrsRemoteTypeRef> typeRefsFrom(
    Object? json, [
    String at = 'result',
  ]) {
    if (json == null) return const <SrsRemoteTypeRef>[];
    final List<Object?> l = _J.list(json, at);
    return <SrsRemoteTypeRef>[
      for (int i = 0; i < l.length; i++) typeRefFrom(l[i], '$at[$i]'),
    ];
  }

  static List<SrsNoteView> notesFrom(List<SrsEntitySource> sources) =>
      sources.isEmpty
      ? const <SrsNoteView>[]
      : _J.guard('notes', () => srsMaterializeNotes(sources));

  static List<SrsNoteTypeView> noteTypesFrom(
    String profileUid,
    List<SrsEntitySource> sources,
  ) => sources.isEmpty
      ? const <SrsNoteTypeView>[]
      : _J.guard(
          'noteTypes',
          () =>
              srsMaterializeNoteTypes(<(SrsEntitySource, SrsBuiltinNoteType?)>[
                for (final SrsEntitySource s in sources)
                  (s, srsBuiltinNoteTypeForKey(profileUid, _builtinKeyOf(s))),
              ]),
        );

  /// 笔记类型身份记录里的内置标识（`builtin`）；没有为 null。
  static String? _builtinKeyOf(SrsEntitySource s) {
    final String at = 'noteType(${s.id}).p';
    final Object? payload = _J.guard(at, () => jsonDecode(s.payloadJson));
    return _J.optStr(_J.map(payload, at)['builtin'], '$at.builtin');
  }

  static SrsDeckTree deckTreeFrom(List<SrsEntitySource> sources) =>
      _J.guard('deckTree', () => SrsDeckTree(srsMaterializeDecks(sources)));

  static SrsEntityEdits entityEditsFrom(Object? json, [String at = 'edits']) {
    final List<SrsEditItem> items = editItemsFrom(json, at);
    return _J
        .guard(at, () => srsEntityEditsOf(<List<SrsEditItem>>[items]))
        .single;
  }

  static SrsEntityRecord entityRecordFrom(Object? json, String at) {
    final Map<String, Object?> m = _J.map(json, at);
    return _J.guard(at, () => SrsEntityRecord.fromJson(m));
  }

  static List<SrsEntityRecord> entityRecordsFrom(Object? json, String at) {
    if (json == null) return const <SrsEntityRecord>[];
    final List<Object?> l = _J.list(json, at);
    return <SrsEntityRecord>[
      for (int i = 0; i < l.length; i++) entityRecordFrom(l[i], '$at[$i]'),
    ];
  }

  // ---------------------------------------------------------------- 复习

  static Map<String, Object?> dayContext(SrsDayContext d) => <String, Object?>{
    'off': d.utcOffsetMin,
    'roll': d.rolloverHour,
  };

  static SrsDayContext dayContextFrom(Object? json, [String at = 'result']) {
    final Map<String, Object?> m = _J.map(json, at);
    return SrsDayContext(
      utcOffsetMin: _J.integer(m['off'], '$at.off'),
      rolloverHour: _J.integer(m['roll'], '$at.roll'),
    );
  }

  static Map<String, Object?> todayReviews(SrsTodayReviewSummary s) =>
      <String, Object?>{'n': s.count, 'ms': s.durationMs, 'again': s.again};

  static SrsTodayReviewSummary todayReviewsFrom(
    Object? json, [
    String at = 'result',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    return SrsTodayReviewSummary(
      count: _J.integer(m['n'], '$at.n'),
      durationMs: _J.integer(m['ms'], '$at.ms'),
      again: _J.integer(m['again'], '$at.again'),
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
    'rs': s.rwkvScheduled,
  };

  /// 牌组行；null = 没有这个牌组，或它不在 [tree] 里（树与摘要之间主机删了它）。
  static SrsDeckSummary? summaryFrom(
    Object? json,
    SrsDeckTree tree, [
    String at = 'result',
  ]) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    final SrsDeckView? deck = tree[_J.str(m['deck'], '$at.deck')];
    if (deck == null) return null;
    final Map<String, Object?> b = _J.map(m['b'], '$at.b');
    return SrsDeckSummary(
      deck: deck,
      fullName: _J.str(m['name'], '$at.name'),
      depth: _J.integer(m['depth'], '$at.depth'),
      parentId: _J.optStr(m['parent'], '$at.parent'),
      newCount: _J.integer(m['n'], '$at.n'),
      learnCount: _J.integer(m['l'], '$at.l'),
      reviewCount: _J.integer(m['r'], '$at.r'),
      newBudget: SrsNewCardBudget(
        limit: _J.integer(b['limit'], '$at.b.limit'),
        allowed: _J.integer(b['allowed'], '$at.b.allowed'),
        reviewBudget: _J.integer(b['rb'], '$at.b.rb'),
        reason: _budgetReason(_J.optStr(b['why'], '$at.b.why'), '$at.b.why'),
      ),
      totalCards: _J.integer(m['total'], '$at.total'),
      rwkvPending: m['rp'] == true,
      rwkvScheduled: m['rs'] == true,
    );
  }

  static SrsNewCardBudgetReason? _budgetReason(String? name, String at) {
    if (name == null) return null;
    for (final SrsNewCardBudgetReason r in SrsNewCardBudgetReason.values) {
      if (r.name == name) return r;
    }
    _J.bad(at);
  }

  /// 牌组行列表（先序）。不在 [tree] 里的行跳过（见 [summaryFrom]）。
  static List<SrsDeckSummary> summariesFrom(
    Object? json,
    SrsDeckTree tree, [
    String at = 'result',
  ]) {
    final List<Object?> l = _J.list(json, at);
    return <SrsDeckSummary>[
      for (int i = 0; i < l.length; i++)
        ?summaryFrom(_J.map(l[i], '$at[$i]'), tree, '$at[$i]'),
    ];
  }

  /// 一台主机牌组摘要的本机缓存（复习首页「已配对设备」落盘的格式）：牌组树的物化输入 + 牌组行，
  /// 与线格式同一套编码，读回时经同一套校验（[deckCacheFrom]）。
  static Map<String, Object?> deckCache(
    List<SrsEntitySource> tree,
    List<SrsDeckSummary> decks,
  ) => <String, Object?>{
    'tree': <Object?>[for (final SrsEntitySource s in tree) source(s)],
    'decks': <Object?>[for (final SrsDeckSummary d in decks) summary(d)],
  };

  static List<SrsDeckSummary> deckCacheFrom(
    Object? json, [
    String at = 'cache',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    final SrsDeckTree tree = deckTreeFrom(sourcesFrom(m['tree'], '$at.tree'));
    return summariesFrom(m['decks'], tree, '$at.decks');
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

  static SrsStudyState? studyFrom(
    Object? json,
    SrsDeckTree tree, [
    String at = 'result',
  ]) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    final SrsDeckSummary? sum = summaryFrom(m['sum'], tree, '$at.sum');
    if (sum == null) return null;
    final Object? custom = m['custom'];
    return SrsStudyState(
      summary: sum,
      next: _J.optStr(m['next'], '$at.next'),
      after: _J.optStr(m['after'], '$at.after'),
      custom: custom == null
          ? null
          : SrsCustomStudyProgress(
              left: _J.integer(
                _J.map(custom, '$at.custom')['left'],
                '$at.custom.left',
              ),
              learn: _J.integer(
                _J.map(custom, '$at.custom')['learn'],
                '$at.custom.learn',
              ),
            ),
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
          if (c.source != null) 'source': c.source,
        };

  static SrsCustomStudy? customStudyFrom(Object? json, [String at = 'custom']) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    final List<String> states = m['states'] == null
        ? const <String>[]
        : _J.strings(m['states'], '$at.states');
    final String mode = _J.str(m['mode'], '$at.mode');
    return SrsCustomStudy(
      mode:
          <SrsCustomStudyMode?>[
            for (final SrsCustomStudyMode x in SrsCustomStudyMode.values)
              if (x.wire == mode) x,
          ].firstOrNull ??
          _J.bad('$at.mode'),
      sinceMs: _J.integer(m['since'], '$at.since'),
      days: _J.optInt(m['days'], '$at.days') ?? 1,
      limit: _J.optInt(m['limit'], '$at.limit') ?? 100,
      states: <SrsCustomStudyState>{
        for (final SrsCustomStudyState s in SrsCustomStudyState.values)
          if (states.contains(s.wire)) s,
      },
      tags: m['tags'] == null
          ? const <String>[]
          : _J.strings(m['tags'], '$at.tags'),
      source: _J.optStr(m['source'], '$at.source'),
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

  static SrsAnswerPreview previewFrom(Object? json, [String at = 'result']) {
    final Map<String, Object?> m = _J.map(json, at);
    final List<Object?> params = _J.list(m['params'], '$at.params');
    return SrsAnswerPreview(
      plan: SrsAnswerPlan(<int, SrsScheduleResult>{
        for (final MapEntry<String, Object?> e
            in _J.map(m['plan'], '$at.plan').entries)
          int.tryParse(e.key) ?? _J.bad('$at.plan.${e.key}'): _J.guard(
            '$at.plan.${e.key}',
            () => SrsScheduleResult.fromJson(
              _J.map(e.value, '$at.plan.${e.key}'),
            ),
          ),
      }),
      memoryBefore: _J.guard('$at.mem', () => SrsMemory.fromJson(m['mem'])),
      algorithm:
          SrsAlgorithm.tryParse(_J.optStr(m['alg'], '$at.alg')) ??
          _J.bad('$at.alg'),
      params: <double>[
        for (int i = 0; i < params.length; i++)
          switch (params[i]) {
            final num v => v.toDouble(),
            _ => _J.bad('$at.params[$i]'),
          },
      ],
      nowMs: _J.integer(m['now'], '$at.now'),
      timeSource: SrsTimeSource.parse(_J.optStr(m['ts'], '$at.ts')),
    );
  }

  static Map<String, Object?> rendered(SrsRenderedCard r) => <String, Object?>{
    'q': r.question,
    'a': r.answer,
    'css': r.css,
    'empty': r.isEmpty,
    'fields': r.fields,
    'defs': r.fushiCardDefinitions,
    'front': <Object?>[
      for (final FushiCardItem x in r.fushiCardFront) x.toJson(),
    ],
    'back': <Object?>[
      for (final FushiCardItem x in r.fushiCardBack) x.toJson(),
    ],
  };

  static SrsRenderedCard? renderedFrom(Object? json, [String at = 'result']) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    return SrsRenderedCard(
      question: _J.str(m['q'], '$at.q'),
      answer: _J.str(m['a'], '$at.a'),
      css: _J.str(m['css'], '$at.css'),
      isEmpty: m['empty'] == true,
      fields: _J.strMap(m['fields'], '$at.fields'),
      fushiCardDefinitions: _J.optStr(m['defs'], '$at.defs'),
      // 旧对端不发布局（它只在模板与代码定义逐字一致时才给 defs，即默认布局）：两面都按默认。
      // 认不得的布局项跳过（[FushiCardItem.fromJson] 返回 null）。
      fushiCardFront: m['front'] == null
          ? kFushiCardDefaultFrontItems
          : _layoutFrom(m['front'], '$at.front'),
      fushiCardBack: m['back'] == null
          ? kFushiCardDefaultBackItems
          : _layoutFrom(m['back'], '$at.back'),
    );
  }

  static List<FushiCardItem> _layoutFrom(Object? json, String at) {
    final List<Object?> l = _J.list(json, at);
    return <FushiCardItem>[
      for (int i = 0; i < l.length; i++)
        ?_J.guard('$at[$i]', () => FushiCardItem.fromJson(l[i])),
    ];
  }

  static SrsCardCacheRow? cardRowFrom(Object? json, [String at = 'result']) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    return _J.guard(at, () => SrsCardCacheRow.fromJson(m));
  }

  static List<SrsCardCacheRow> cardRowsFrom(
    Object? json, [
    String at = 'result',
  ]) {
    final List<Object?> l = _J.list(json, at);
    return <SrsCardCacheRow>[
      for (int i = 0; i < l.length; i++)
        cardRowFrom(l[i], '$at[$i]') ?? _J.bad('$at[$i]'),
    ];
  }

  static SrsRemoteCardDetail? cardDetailFrom(
    Object? json, [
    String at = 'result',
  ]) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    return (
      card: cardRowFrom(m['card'], '$at.card') ?? _J.bad('$at.card'),
      note: sourceFrom(m['note'], '$at.note'),
      type: typeRefFrom(m['type'], '$at.type'),
      templateId: _J.optStr(m['tpl'], '$at.tpl'),
      deckName: _J.str(m['deckName'], '$at.deckName'),
    );
  }

  static SrsReviewLog logFrom(Object? json, [String at = 'result']) {
    final Map<String, Object?> m = _J.map(json, at);
    return _J.guard(at, () => SrsReviewLog.fromJson(m));
  }

  static List<SrsReviewLog> logsFrom(Object? json, [String at = 'result']) {
    final List<Object?> l = _J.list(json, at);
    return <SrsReviewLog>[
      for (int i = 0; i < l.length; i++) logFrom(l[i], '$at[$i]'),
    ];
  }

  /// `answerAndStudy` 的回包：这次作答的日志 + 作答后重排的队。
  static SrsAnswerOutcome answerFrom(
    Object? json,
    SrsDeckTree tree, [
    String at = 'result',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    return SrsAnswerOutcome(
      logFrom(m['log'], '$at.log'),
      studyFrom(m['study'], tree, '$at.study'),
    );
  }

  static SrsCardHistory historyFrom(Object? json, [String at = 'result']) {
    final Map<String, Object?> m = _J.map(json, at);
    return _J.guard(at, () => SrsCardHistory.fromWire(m));
  }

  /// 一个实体的修改历史；null = 空。
  static List<SrsHistoryEntry> historyEntriesFrom(
    Object? json, [
    String at = 'result',
  ]) {
    if (json == null) return const <SrsHistoryEntry>[];
    final List<Object?> l = _J.list(json, at);
    return <SrsHistoryEntry>[
      for (int i = 0; i < l.length; i++)
        _J.guard(
          '$at[$i]',
          () => SrsHistoryEntry.fromJson(_J.map(l[i], '$at[$i]')),
        ),
    ];
  }

  static SrsFieldEdit editFrom(Object? json, [String at = 'result']) {
    final Map<String, Object?> m = _J.map(json, at);
    return _J.guard(at, () => SrsFieldEdit.fromJson(m));
  }

  static List<SrsFieldEdit> editsFrom(Object? json, [String at = 'result']) {
    final List<Object?> l = _J.list(json, at);
    return <SrsFieldEdit>[
      for (int i = 0; i < l.length; i++) editFrom(l[i], '$at[$i]'),
    ];
  }

  static List<Object?> editSpecs(List<SrsEditSpec> specs) => <Object?>[
    for (final SrsEditSpec s in specs)
      <Object?>[s.kind.wire, s.entityId, s.key, s.value],
  ];

  static List<SrsEditSpec> editSpecsFrom(Object? json, [String at = 'specs']) {
    final List<Object?> l = _J.list(json, at);
    return <SrsEditSpec>[
      for (int i = 0; i < l.length; i++)
        if (l[i] case [
          final Object? kind,
          final String id,
          final String key,
          final Object? value,
        ])
          SrsEditSpec(kindFrom(kind, '$at[$i][0]'), id, key, value)
        else
          _J.bad('$at[$i]'),
    ];
  }

  static SrsEntityKind kindFrom(Object? wire, [String at = 'kind']) =>
      SrsEntityKind.tryParse(_J.optStr(wire, at)) ?? _J.bad(at);

  /// `syncConflicts` 的回包：每个冲突 `[kind, id, key]` + 涉及实体的修改记录，寄存器在本机按同一个
  /// 内核算出。修改记录里找不到该键寄存器的冲突跳过（期间已被解决）。
  static List<(SrsEntityKind, String, SrsRegister)> syncConflictsFrom(
    Object? json, [
    String at = 'result',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    final Map<String, SrsEntityEdits> edits = <String, SrsEntityEdits>{
      for (final MapEntry<String, Object?> e
          in _J.map(m['edits'], '$at.edits').entries)
        e.key: entityEditsFrom(e.value, '$at.edits.${e.key}'),
    };
    final List<Object?> items = _J.list(m['items'], '$at.items');
    return <(SrsEntityKind, String, SrsRegister)>[
      for (int i = 0; i < items.length; i++)
        if (items[i] case [
          final String kind,
          final String id,
          final String key,
        ])
          if (edits['$kind/$id']?[key] case final SrsRegister reg)
            (kindFrom(kind, '$at.items[$i][0]'), id, reg)
          else
            ...const <(SrsEntityKind, String, SrsRegister)>[]
        else
          _J.bad('$at.items[$i]'),
    ];
  }

  static SrsRemoteNoteTypeChange noteTypeChangeFrom(
    Object? json, [
    String at = 'result',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    final List<Object?> plans = _J.list(m['plans'], '$at.plans');
    return (
      from: typeRefFrom(m['from'], '$at.from'),
      to: typeRefFrom(m['to'], '$at.to'),
      plans: <SrsNoteTypeChangePlan>[
        for (int i = 0; i < plans.length; i++)
          _noteTypeChangePlanFrom(plans[i], '$at.plans[$i]'),
      ],
    );
  }

  static SrsNoteTypeChangePlan _noteTypeChangePlanFrom(
    Object? json,
    String at,
  ) {
    final Map<String, Object?> m = _J.map(json, at);
    return SrsNoteTypeChangePlan(
      noteId: _J.str(m['note'], '$at.note'),
      fieldValues: _J.strMap(m['fields'], '$at.fields'),
      cardLinks: _J.strMap(m['links'], '$at.links'),
      droppedCards: _J.strings(m['dropped'], '$at.dropped'),
    );
  }

  /// `extendTodayLimits` 的回包：今天放宽后的新卡 / 复习上限。
  static ({int newCards, int reviews}) extendedLimitsFrom(
    Object? json, [
    String at = 'result',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    return (
      newCards: _J.integer(m['n'], '$at.n'),
      reviews: _J.integer(m['r'], '$at.r'),
    );
  }

  static Map<String, Object?> sync2Result(SrsSync2Result r) =>
      <String, Object?>{
        'json': r.json,
        'files': <Object?>[
          for (final (String path, Uint8List bytes) in r.files)
            <Object?>[path, base64Encode(bytes)],
        ],
      };

  static SrsSync2Result sync2ResultFrom(Object? json, [String at = 'result']) {
    final Map<String, Object?> m = _J.map(json, at);
    final List<Object?> files = m['files'] == null
        ? const <Object?>[]
        : _J.list(m['files'], '$at.files');
    return SrsSync2Result(m['json'], <(String, Uint8List)>[
      for (int i = 0; i < files.length; i++)
        if (files[i] case [final String path, final String bytes])
          (path, _J.guard('$at.files[$i]', () => base64Decode(bytes)))
        else
          _J.bad('$at.files[$i]'),
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

  Map<String, Object?> map(String key) => _J.map(_m[key], key);
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

  /// 执行一次调用。[profile] 是客户端以为的 profile（读操作可为 null = 握手，不核对；写操作必须带，
  /// 主机切了配置时拒绝写入，不靠客户端自觉）；[request] 是写操作的幂等 id。
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
    if (request == null ||
        request.isEmpty ||
        profile == null ||
        profile.isEmpty) {
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
    } on SrsRemoteWireError catch (e) {
      throw SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest, '$e');
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
      'dev': store.sync2Device,
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
    'todayReviewSummary': _Op(
      (SrsDbStore s, _Args a) async =>
          SrsRemoteWire.todayReviews(await s.todayReviewSummary()),
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
      // 只查一个实体（牌组设置页）：`entityKind` / `entityId` 同时给。
      final String? entityId = a.optStr('entityId');
      final List<(SrsEntityKind, String, SrsRegister)> all = await s
          .syncConflicts(
            entity: entityId == null
                ? null
                : (
                    kind: SrsRemoteWire.kindFrom(a.raw('entityKind')),
                    id: entityId,
                  ),
          );
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
    'previewNoteTypeChange': _Op((SrsDbStore s, _Args a) async {
      final SrsNoteTypeChangePreview p = await s.previewNoteTypeChange(
        noteIds: a.strings('notes'),
        targetTypeId: a.str('target'),
        fieldMap: _nullableMap(a.raw('fieldMap')),
        templateMap: _nullableMap(a.raw('templateMap')),
      );
      return <String, Object?>{
        'from': (await _typeRefs(s, <String>[p.from.id])).single,
        'to': (await _typeRefs(s, <String>[p.to.id])).single,
        'plans': <Object?>[
          for (final SrsNoteTypeChangePlan x in p.plans)
            <String, Object?>{
              'note': x.noteId,
              'fields': x.fieldValues,
              'links': x.cardLinks,
              'dropped': x.droppedCards,
            },
        ],
      };
    }),
    'editHistory': _Op(
      (SrsDbStore s, _Args a) async => (await s.sync2Command(<String, Object?>{
        'op': 'history',
        'kind': SrsRemoteWire.kindFrom(a.raw('kind')).wire,
        'entity': a.str('id'),
      })).json,
    ),
    'deviceNames': _Op((SrsDbStore s, _Args a) async => s.sync2DeviceNames()),
    'noteIdsOfType': _Op(
      (SrsDbStore s, _Args a) async =>
          s.noteIdsOfType(a.str('type'), limit: a.optInt('limit')),
    ),
    // ------------------------------------------------------------ 写
    'answerAndStudy': _Op(write: true, (SrsDbStore s, _Args a) async {
      final String card = a.str('card');
      final int rating = a.integer('rating');
      final int durationMs = a
          .integer('durationMs')
          .clamp(0, kSrsMaxAnswerDurationMs);
      final String? deck = a.optStr('deck');
      final SrsCustomStudy? custom = SrsRemoteWire.customStudyFrom(
        a.raw('custom'),
      );
      // 核对基准与记日志在同一个写独占区里：否则两次 await 之间主机本机（或另一台客户端）作答落库，
      // 同一张卡会记两条日志——基准要防的正是这个。runExclusive 可重入，内层 answerAndStudy 直接执行。
      final SrsAnswerOutcome out = await s.runExclusive(() async {
        if (a.raw('checkBase') == true) {
          final SrsCardCacheRow? row = await s.cardRow(card);
          if (row == null || row.lastLogId != a.optStr('base')) {
            throw const SrsRemoteStoreError(409, SrsRemoteStoreError.stale);
          }
        }
        return s.answerAndStudy(
          card,
          rating,
          durationMs: durationMs,
          studyDeckId: deck,
          custom: custom,
        );
      });
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
          e.key: switch (e.value) {
            final int v => v,
            _ => throw const SrsRemoteStoreError(
              400,
              SrsRemoteStoreError.badRequest,
            ),
          },
      };
      return <Object?>[
        for (final SrsReviewLog l in await s.setDueDays(days)) l.toJson(),
      ];
    }),
    'extendTodayLimits': _Op(write: true, (SrsDbStore s, _Args a) async {
      final ({int newCards, int reviews}) total = await s.extendTodayLimits(
        a.str('deck'),
        newCards: a.optInt('newCards') ?? 0,
        reviews: a.optInt('reviews') ?? 0,
      );
      return <String, Object?>{'n': total.newCards, 'r': total.reviews};
    }),
    'changeNoteType': _Op(write: true, (SrsDbStore s, _Args a) async {
      await s.changeNoteType(
        noteIds: a.strings('notes'),
        targetTypeId: a.str('target'),
        fieldMap: _nullableMap(a.raw('fieldMap')),
        templateMap: _nullableMap(a.raw('templateMap')),
      );
      return null;
    }),
    'migrateLegacyLapis': _Op(
      write: true,
      (SrsDbStore s, _Args a) async => s.migrateLegacyLapis(
        a.str('source'),
        noteIds: a.raw('notes') == null ? null : a.strings('notes'),
        targetDeckId: a.optStr('deck'),
      ),
    ),
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
            'changes',
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
          records: SrsRemoteWire.entityRecordsFrom(a.raw('records'), 'records'),
        ))
          e.toJson(),
      ],
    ),
    // 浏览命令是查询会话（结果可能很大），不进幂等缓存；浏览里的批量改走上面的写操作。
    // 只放行浏览会话命令（[SrsDbStore.kSrsBrowseOps]）：其余 sync2 内核命令（`seal_file` / `open_file`
    // 按请求给的路径读写主机文件、`apply` 等改库命令）一律 400，不进 store。
    'browseCommand': _Op((SrsDbStore s, _Args a) async {
      final Map<String, Object?> request = a.map('request');
      if (!SrsDbStore.kSrsBrowseOps.contains(request['op'])) {
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
      }
      return SrsRemoteWire.sync2Result(await s.browseCommand(request));
    }),
  };

  static Map<String, String?> _nullableMap(Object? json) {
    if (json is! Map) {
      throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
    }
    final Map<String, String?> out = <String, String?>{};
    for (final MapEntry<Object?, Object?> e in json.entries) {
      final Object? k = e.key;
      final Object? v = e.value;
      if (k is! String || (v != null && v is! String)) {
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
      }
      out[k] = v is String ? v : null;
    }
    return out;
  }

  /// 全部操作名（守卫测试据此核对客户端覆盖了哪些）。
  static Iterable<String> get operations => _ops.keys;
}
