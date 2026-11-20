/// 远程复习库（docs/specs/2026-11-01-srs-remote-review-design.md）：已配对设备不下载卡组，直接在互联主机的
/// 复习库上复习。客户端的 [SrsDbStore] 换成一个把每次调用转发到主机的实现，复习页 / 笔记编辑 / 牌组设置 /
/// 浏览等页面原样运行，功能与在本机复习一致；排队、排程（含 RWKV）、模板渲染、写入都在主机的 [SrsDbStore] 上做。
///
/// 这里是两端共用的部分（线格式 V2，复习库协议 4；协商见 srs_remote_generation.dart）：
/// - 线格式（[SrsRemoteWire]）：实体（笔记 / 笔记类型 / 牌组）搬主机内核 `entity_views` 算好的视图 `{id, tag, v}`
///   （[SrsEntityView]，规划 §1.8）：`v` 是视图 JSON 原文，`tag` 视图一变必变；客户端经与本机同一份解码器
///   （srs_entity_views.dart）解成物化输入、交给同一个物化内核。胜者、按类判定的活着的写入、信任状态都在主机算好，
///   客户端不重算（D31）。
/// - ID 一律是主机集合里的规范 ID：主机内核对请求里的 ID 先归一；客户端的内置实体 ID（默认牌组、两个内置笔记类型）
///   不自己派生，取回包信封里主机给的那一份（`ids`），归一经主机的 `canonical_ids`（[SrsRemoteStoreService] 的
///   `canonicalIds`）。
/// - 主机侧服务（[SrsRemoteStoreService]）：按操作名分派到当前 profile 的 [SrsDbStore]，写操作按客户端请求 id 幂等。
///   远程对端是不可信输入：操作表就是白名单（只开远程复习页面用到的读与复习写），主机替客户端发出的内核命令只限
///   [kSrsRemoteKernelOps]；身份 / 绑定 / 导入导出 / 清除 / 同步 / 加解密类命令没有任何入口。
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
import 'package:fushi_engine/srs/srs_canonical_ids.dart'
    show srsCanonicalIdIn, srsCanonicalIdMap;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_engine/srs/srs_entity_views.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart'
    show SrsCardNativeFallback, SrsCardNativeFallbackCode;
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

/// host 在 `GET /api/capabilities` 声明的能力位。
const String kSrsRemoteStoreCapability = 'srsRemoteStoreV1';

/// 端点前缀（`POST <前缀>call`、`GET <前缀>media/<名字>`）。
const String kSrsRemoteStorePathPrefix = '/api/srs/remote/';

/// 请求体里客户端设备此刻的 UTC 偏移（分钟）的键：主机按它算这次调用的「今天」（[SrsDbStore.withDeviceOffset]）。
///
/// 向后兼容（不改能力位）：旧客户端不带 → 主机照旧用自己的偏移；旧主机不认这个键 → 忽略（路由只读已知键），
/// 同样按主机的偏移算。
const String kSrsRemoteDeviceOffsetKey = 'tz';

/// 主机接受的设备偏移范围（分钟，含两端）：现实时区 UTC−12:00 … UTC+14:00。
const int kSrsRemoteDeviceOffsetMinMin = -12 * 60;
const int kSrsRemoteDeviceOffsetMinMax = 14 * 60;

/// [offsetMin] 在现实时区范围内时原样返回，否则 null（越界不当成任何时区：调用方回落到主机自己的偏移）。
int? srsRemoteDeviceOffset(int? offsetMin) =>
    offsetMin != null &&
        offsetMin >= kSrsRemoteDeviceOffsetMinMin &&
        offsetMin <= kSrsRemoteDeviceOffsetMinMax
    ? offsetMin
    : null;

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

  /// 两端的远程复习线格式不是同一代（HTTP 426，srs_remote_generation.dart）：新代主机收到 V1 请求、或 V2 请求
  /// 带的代号不对。
  static const String upgradeRequired = 'upgrade_required';

  /// 主机正在把复习库迁移到新代（HTTP 503）：迁移完成前不提供复习。
  static const String migrating = 'migrating';

  /// 主机迁移复习库失败（HTTP 503）：要在主机上处理，客户端重试没有用。
  static const String migrationFailed = 'migration_failed';

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

/// 主机集合里根上内置实体的规范 ID（信封的 `ids`：`{deck, lapis, fushi}`）。客户端不按 uid 派生，用这一份。
typedef SrsRemoteRootIds = ({
  String defaultDeck,
  String lapis,
  String fushiCard,
});

/// 一次回包的信封（[SrsRemoteStoreService.call] 的回包里 `result` 之外的部分）。缺的字段为 null，
/// 客户端沿用上次的值。[collection] 是主机这份 profile 绑定的集合（`col`），[roots] 是根上内置实体的规范 ID（`ids`）。
typedef SrsRemoteEnvelope = ({
  String? profile,
  String? collection,
  SrsRemoteRootIds? roots,
  int? revision,
  String? fingerprint,
  String? treeTag,
  bool canSchedule,
  bool rwkvReady,
  SrsRwkvStatus? rwkvStatus,
  String? device,
  int? nowMs,
  String? timeSource,
});

/// 笔记类型引用 `{id, tag}`（客户端按 tag 判断缓存的视图还新不新）。
typedef SrsRemoteTypeRef = ({String id, String tag});

/// `cardDetail` 的回包（笔记按视图、笔记类型按引用搬，客户端物化）。
typedef SrsRemoteCardDetail = ({
  SrsCardCacheRow card,
  SrsEntityView note,
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
    collection: _J.optStr(m['col'], 'col'),
    roots: rootIdsFrom(m['ids']),
    revision: _J.optInt(m['rev'], 'rev'),
    fingerprint: _J.optStr(m['fp'], 'fp'),
    treeTag: _J.optStr(m['tt'], 'tt'),
    canSchedule: m['sched'] == true,
    rwkvReady: m['rwkv'] == true,
    rwkvStatus: rwkvStatusFrom(m['rk']),
    device: _J.optStr(m['dev'], 'dev'),
    nowMs: _J.optInt(m['now'], 'now'),
    timeSource: _J.optStr(m['ts'], 'ts'),
  );

  /// 信封的 `ids`：`{deck, lapis, fushi}`；缺 = null（沿用上次）。
  static Map<String, Object?> rootIds(SrsRemoteRootIds r) => <String, Object?>{
    'deck': r.defaultDeck,
    'lapis': r.lapis,
    'fushi': r.fushiCard,
  };

  static SrsRemoteRootIds? rootIdsFrom(Object? v) {
    if (v == null) return null;
    final Map<String, Object?> m = _J.map(v, 'ids');
    return (
      defaultDeck: _J.str(m['deck'], 'ids.deck'),
      lapis: _J.str(m['lapis'], 'ids.lapis'),
      fushiCard: _J.str(m['fushi'], 'ids.fushi'),
    );
  }

  /// 主机 RWKV 的准备状态 `{p: 阶段名, d, t, e?}`（信封的 `rk`）：远程复习页「等 RWKV」时显示进度 / 错误用。
  /// 错误只搬文本。
  static Map<String, Object?> rwkvStatus(SrsRwkvStatus s) => <String, Object?>{
    'p': s.phase.name,
    'd': s.done,
    't': s.total,
    if (s.error != null) 'e': '${s.error}',
  };

  /// [rwkvStatus] 的逆。缺（老主机 / 主机没有 RWKV 运行时）→ null；阶段名不认识（更新的主机）→ 也当没有，
  /// 客户端退回只看 `rwkv` 布尔。
  static SrsRwkvStatus? rwkvStatusFrom(Object? v) {
    if (v == null) return null;
    final Map<String, Object?> m = _J.map(v, 'rk');
    final String name = _J.str(m['p'], 'rk.p');
    for (final SrsRwkvPhase phase in SrsRwkvPhase.values) {
      if (phase.name != name) continue;
      return SrsRwkvStatus(
        phase,
        done: _J.optInt(m['d'], 'rk.d') ?? 0,
        total: _J.optInt(m['t'], 'rk.t') ?? 0,
        error: _J.optStr(m['e'], 'rk.e'),
      );
    }
    return null;
  }

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

  /// 一个实体视图 `{id, tag, v}`（规划 §1.8）：`v` 是主机内核 `entity_views` 的视图 JSON 原文，原样搬。
  static Map<String, Object?> view(SrsEntityView v) => <String, Object?>{
    'id': v.id,
    'tag': v.tag,
    'v': v.json,
  };

  static SrsEntityView viewFrom(Object? json, [String at = 'view']) {
    final Map<String, Object?> m = _J.map(json, at);
    return SrsEntityView(
      _J.str(m['id'], '$at.id'),
      _J.str(m['tag'], '$at.tag'),
      _J.str(m['v'], '$at.v'),
    );
  }

  static List<SrsEntityView> viewsFrom(Object? json, [String at = 'result']) {
    final List<Object?> l = _J.list(json, at);
    return <SrsEntityView>[
      for (int i = 0; i < l.length; i++) viewFrom(l[i], '$at[$i]'),
    ];
  }

  /// 视图 → 物化输入（srs_entity_views.dart 的唯一解码器；不合形归成 [SrsRemoteWireError]）。没有身份记录的跳过。
  static List<SrsEntitySource> sourcesOf(
    List<SrsEntityView> views, [
    String at = 'views',
  ]) => _J.guard(at, () => srsEntitySourcesOfViews(views));

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

  static List<SrsNoteView> notesFrom(List<SrsEntityView> views) {
    final List<SrsEntitySource> sources = sourcesOf(views, 'notes');
    return sources.isEmpty
        ? const <SrsNoteView>[]
        : _J.guard('notes', () => srsMaterializeNotes(sources));
  }

  /// 笔记类型视图按输入顺序物化（没有身份记录的跳过；结果与跳过后的输入逐项对应，按 ID 对回）。内置类型的代码默认值
  /// （字段 / 模板 ID）由主机信封里的规范 ID [roots] 派生（G10-4）：客户端不按 uid 派生，并入 / 认领后主机 profile 的
  /// uid 与集合无关，规范 ID 才是两端共同的那一份。
  static List<SrsNoteTypeView> noteTypesFrom(
    SrsRemoteRootIds roots,
    List<SrsEntityView> views,
  ) => _noteTypesOf(roots, sourcesOf(views, 'noteTypes'));

  static List<SrsNoteTypeView> _noteTypesOf(
    SrsRemoteRootIds roots,
    List<SrsEntitySource> sources,
  ) => sources.isEmpty
      ? const <SrsNoteTypeView>[]
      : _J.guard(
          'noteTypes',
          () =>
              srsMaterializeNoteTypes(<(SrsEntitySource, SrsBuiltinNoteType?)>[
                for (final SrsEntitySource s in sources)
                  (s, _builtinOf(roots, _builtinKeyOf(s))),
              ]),
        );

  /// 内置标识 [key] 在主机集合里的定义（不是内置 = null）。只认信封 `ids` 里有规范 ID 的两种内置类型；内核以后多出
  /// 一种内置类型而信封没带它的 ID 时报线格式错，不退回按 uid 派生。
  static SrsBuiltinNoteType? _builtinOf(SrsRemoteRootIds roots, String? key) {
    final SrsBuiltinNoteTypeSpec? spec = srsBuiltinNoteTypeSpec(key);
    if (spec == null) return null;
    final String nt = switch (spec.key) {
      kSrsBuiltinLapisKey => roots.lapis,
      kSrsBuiltinFushiCardKey => roots.fushiCard,
      _ => throw SrsRemoteWireError('ids.${spec.key}'),
    };
    return srsBuiltinNoteTypeIn(nt, spec);
  }

  /// 笔记类型身份记录里的内置标识（`builtin`）；没有为 null。
  static String? _builtinKeyOf(SrsEntitySource s) {
    final String at = 'noteType(${s.id}).p';
    final Object? payload = _J.guard(at, () => jsonDecode(s.payloadJson));
    return _J.optStr(_J.map(payload, at)['builtin'], '$at.builtin');
  }

  static SrsDeckTree deckTreeFrom(List<SrsEntityView> views) {
    final List<SrsEntitySource> sources = sourcesOf(views, 'deckTree');
    return _J.guard(
      'deckTree',
      () => SrsDeckTree(srsMaterializeDecks(sources)),
    );
  }

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
    'rm': ?s.reviewMinutesLeft,
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
      reviewMinutesLeft: _J.optInt(m['rm'], '$at.rm'),
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

  /// 一台主机牌组摘要的本机缓存（复习首页「已配对设备」落盘的格式）：牌组树的视图 + 牌组行，
  /// 与线格式同一套编码，读回时经同一套校验（[deckCacheFrom]）。
  static Map<String, Object?> deckCache(
    List<SrsEntityView> tree,
    List<SrsDeckSummary> decks,
  ) => <String, Object?>{
    'tree': <Object?>[for (final SrsEntityView v in tree) view(v)],
    'decks': <Object?>[for (final SrsDeckSummary d in decks) summary(d)],
  };

  static List<SrsDeckSummary> deckCacheFrom(
    Object? json, [
    String at = 'cache',
  ]) {
    final Map<String, Object?> m = _J.map(json, at);
    final SrsDeckTree tree = deckTreeFrom(viewsFrom(m['tree'], '$at.tree'));
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
    // 整面 WebView 的原因（反馈 O5YDP27Xko）：客户端据此记诊断、外观页显示原因。
    if (r.nativeFallback case final SrsCardNativeFallback f)
      'nfb': <String, Object?>{'code': f.code.name, 'detail': f.detail},
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
      nativeFallback: _nativeFallbackFrom(m['nfb'], '$at.nfb'),
    );
  }

  /// `nfb`：主机侧没走原生的原因。老主机不发（null，客户端按
  /// [SrsCardNativeFallbackCode.remoteUnknown]）；更新的主机发了本端不认识的类别时同样按
  /// remoteUnknown，原类别名并进说明，不丢信息。
  static SrsCardNativeFallback? _nativeFallbackFrom(Object? json, String at) {
    if (json == null) return null;
    final Map<String, Object?> m = _J.map(json, at);
    final String code = _J.str(m['code'], '$at.code');
    final String detail = _J.optStr(m['detail'], '$at.detail') ?? '';
    final SrsCardNativeFallbackCode? known = SrsCardNativeFallbackCode.values
        .asNameMap()[code];
    return known != null
        ? SrsCardNativeFallback(known, detail)
        : SrsCardNativeFallback(
            SrsCardNativeFallbackCode.remoteUnknown,
            detail.isEmpty ? code : '$code: $detail',
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
      note: viewFrom(m['note'], '$at.note'),
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

  /// 实体种类：远程只开复习库里的牌组 / 笔记类型 / 笔记 / 卡；`profile`（profile 级设置实体）与不认识的一律 400。
  SrsEntityKind kind(String key) => srsRemoteEntityKind(_m[key]);

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

/// 远程可以点名的实体种类（[_Args.kind]、编辑规格、撤销凭据）：不含 `profile`——那是 profile 级设置（翻日时刻等），
/// 只由本机写（`SrsRemoteStore.setDayRolloverHour` 同口径）。
const Set<SrsEntityKind> kSrsRemoteEntityKinds = <SrsEntityKind>{
  SrsEntityKind.deck,
  SrsEntityKind.noteType,
  SrsEntityKind.note,
  SrsEntityKind.card,
};

/// [wire] 是 [kSrsRemoteEntityKinds] 里的种类就返回它，否则 400 [SrsRemoteStoreError.badRequest]。
SrsEntityKind srsRemoteEntityKind(Object? wire) {
  final SrsEntityKind? k = wire is String ? SrsEntityKind.tryParse(wire) : null;
  if (k == null || !kSrsRemoteEntityKinds.contains(k)) {
    throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
  }
  return k;
}

/// 主机替远程客户端发出的内核命令（经 [srsRemoteKernelCommand]）只能是这些：只读的实体视图 / 归一 / 修改历史，加浏览会话命令
/// （[SrsDbStore.kSrsBrowseOps]，也只读）。身份（`identity` / `collection_*` / `binding_set`）、导入导出、清除
/// （`purge` / `profile_purge`）、同步一轮、加解密（`seal_file` / `open_file` 按请求给的路径读写主机文件）一律不在内。
const Set<String> kSrsRemoteKernelOps = <String>{
  'entity_views',
  'canonical_ids',
  'history',
  ...SrsDbStore.kSrsBrowseOps,
};

/// 替远程客户端发一条内核命令：不在 [kSrsRemoteKernelOps] 里的 400，不进 store。主机替远程发的内核命令只经这一处
/// （`editHistory`、`browseCommand`）；`browseCommand` 自己再收窄到浏览会话命令。测试直接调它核对闸门本身。
@visibleForTesting
Future<SrsSync2Result> srsRemoteKernelCommand(
  SrsDbStore store,
  Map<String, Object?> request,
) async {
  if (!kSrsRemoteKernelOps.contains(request['op'])) {
    throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
  }
  return SrsDbStore.kSrsBrowseOps.contains(request['op'])
      ? store.browseCommand(request)
      : store.sync2Command(request);
}

typedef _Run = Future<Object?> Function(SrsDbStore store, _Args a);

/// 一个可远程调用的操作；[write] = 改库（按请求 id 幂等，成功后通知 [SrsRemoteStoreService.onWrite]）。
class _Op {
  const _Op(this.run, {this.write = false});

  final _Run run;
  final bool write;
}

/// 主机提供的一份 profile（握手回包 `profiles` 里的一项）：[name] 是给人看的名字（取不到为空），[notes] 是用户笔记数。
class SrsRemoteServedProfile {
  const SrsRemoteServedProfile({
    required this.uid,
    this.name = '',
    this.notes = 0,
  });

  factory SrsRemoteServedProfile.fromJson(Map<String, Object?> json) =>
      SrsRemoteServedProfile(
        uid: json['uid']! as String,
        name: (json['name'] as String?) ?? '',
        notes: (json['notes'] as num?)?.toInt() ?? 0,
      );

  final String uid;
  final String name;
  final int notes;

  Map<String, Object?> toJson() => <String, Object?>{
    'uid': uid,
    'name': name,
    'notes': notes,
  };
}

/// 主机的库因代际状态打不开（[SrsStoreOpenBlocked]）时给客户端的机读码（HTTP 503）：迁移失败 / 只剩封存旧库 /
/// 旁边另有没迁移的旧库要在主机上处理 → [SrsRemoteStoreError.migrationFailed]；还没迁移（等主机上的用户点升级）/
/// 别的进程正在迁移 → [SrsRemoteStoreError.migrating]。客户端重试前者没有用，后者等一会儿再来。
SrsRemoteStoreError srsRemoteOpenBlockedError(SrsStoreOpenBlocked e) =>
    switch (e) {
      SrsStoreNotMigrated(
        state: SrsGenState.migrationFailed || SrsGenState.sealedOldOnly,
      ) ||
      SrsStoreLegacyUnmigrated() => SrsRemoteStoreError(
        503,
        SrsRemoteStoreError.migrationFailed,
        '$e',
      ),
      SrsStoreNotMigrated() || SrsStoreMigrating() => SrsRemoteStoreError(
        503,
        SrsRemoteStoreError.migrating,
        '$e',
      ),
    };

/// 主机侧服务：每个请求现取当前 profile 的 [SrsDbStore]（配置切换 / 模块开关即时生效）。读库时抛
/// [SrsStoreOpenBlocked]（库在换代途中）的，按 [srsRemoteOpenBlockedError] 回机读码，不当成「复习模块没开」。
class SrsRemoteStoreService {
  ///
  /// 一台主机可以同时提供几份 profile（无头服务端：一门语言一份）：[readProfile] 按客户端点名的 uid 取那份库
  /// （没提供 = 只有 [readStore] 那一份，桌面 host 就是这样）；[profiles] 列出提供的全部 profile，随握手（`hello`）
  /// 一起回给客户端（`profiles: [{uid, name, notes}]`），客户端据此直接打开自己那份或让用户选。[readStore] 是
  /// 客户端不点名时的默认 profile。[onWrite] 收到写入落库的那份 profile uid。
  SrsRemoteStoreService({
    required Future<SrsDbStore?> Function() readStore,
    required Future<Uint8List?> Function(String name) readMedia,
    Future<SrsDbStore?> Function(String profileUid)? readProfile,
    Future<List<SrsRemoteServedProfile>> Function()? profiles,
    void Function(String profileUid)? onWrite,
    int idempotencyCapacity = 256,
  }) : _readStore = readStore,
       _readMedia = readMedia,
       _readProfile = readProfile,
       _profiles = profiles,
       _onWrite = onWrite,
       _capacity = idempotencyCapacity;

  final Future<SrsDbStore?> Function() _readStore;
  final Future<Uint8List?> Function(String name) _readMedia;
  final Future<SrsDbStore?> Function(String profileUid)? _readProfile;
  final Future<List<SrsRemoteServedProfile>> Function()? _profiles;

  /// 远程写入落库后调用：主机自己的界面重读、互联推送照常发出（与本机写入同一条信号）。
  final void Function(String profileUid)? _onWrite;
  final int _capacity;

  /// 写操作幂等缓存：客户端请求 id → 回包（最近 [_capacity] 次，按插入顺序淘汰）。
  final LinkedHashMap<String, Map<String, Object?>> _done =
      LinkedHashMap<String, Map<String, Object?>>();

  /// 同一请求 id 并发重发时等第一次的结果，不各写一次。
  final Map<String, Future<Map<String, Object?>>> _inFlight =
      <String, Future<Map<String, Object?>>>{};

  /// 牌组树的线格式缓存（每份 profile 一条，按 [SrsDbStore.deckTreeKey]）。
  final Map<
    String,
    ({String key, String tag, List<Map<String, Object?>> decks})
  >
  _trees =
      <String, ({String key, String tag, List<Map<String, Object?>> decks})>{};

  /// 卡面引用的媒体字节；名字不合法 / 不存在时 null。
  Future<Uint8List?> media(String name) => _readMedia(name);

  /// 执行一次调用。[profile] 是客户端以为的 profile（读操作可为 null = 握手，不核对；写操作必须带，
  /// 主机切了配置时拒绝写入，不靠客户端自觉）；[request] 是写操作的幂等 id。
  ///
  /// [deviceOffsetMin]：客户端设备此刻的 UTC 偏移（分钟，[kSrsRemoteDeviceOffsetKey]）。「今天」的时区取用户手上那台
  /// 设备：给了且在现实时区范围内（[srsRemoteDeviceOffset]）时这次调用按它算日界（每日上限、到期计数、作答日志
  /// 记下的偏移）；不给（旧客户端）或越界时按主机自己的偏移算，与旧协议一致。翻日时刻照旧取 profile 同步的那一份。
  ///
  /// [collection]：客户端握手时看到的集合（信封的 `col`）。读写操作带了而主机这份 profile 此刻绑定的集合不是它（期间
  /// 并入 / 认领换了集合，客户端手里的 ID 与缓存都按旧集合）→ 409 [SrsRemoteStoreError.profileChanged]，客户端重新
  /// 握手，不把写入落到它没见过的集合上。
  ///
  /// 回包：`{profile, col, ids, rev, fp, tt, now, ts, sched, rwkv, rk, dev, result}`——`col` 是这份 profile 绑定的集合，
  /// `ids` 是根上内置实体的规范 ID（[SrsRemoteWire.rootIds]），`rev` / `fp` 是主机的修订号与统计指纹，
  /// `tt` 是牌组树标签（客户端据此判断缓存的树还新不新），`now` / `ts` 是主机此刻的复习时钟，`rwkv` / `rk` 是
  /// 主机 RWKV 是否就绪与它的准备状态（[SrsRemoteWire.rwkvStatus]；主机没有 RWKV 运行时不带 `rk`），`dev` 是主机
  /// 在集合里的设备号。
  Future<Map<String, Object?>> call({
    required String? profile,
    required String op,
    required Map<String, Object?> args,
    String? request,
    String? collection,
    int? deviceOffsetMin,
  }) {
    final int? offset = srsRemoteDeviceOffset(deviceOffsetMin);
    final _Op? spec = _ops[op];
    if (spec == null) {
      return Future<Map<String, Object?>>.error(
        const SrsRemoteStoreError(404, SrsRemoteStoreError.unknownOp),
      );
    }
    // 读操作也核对集合：中间一次读看到换了集合就 409，客户端不会在读里悄悄换成新集合、再拿旧集合的 ID
    // 落写（写带的 `col` 是握手时那一份，读不更新它）。
    if (!spec.write) return _run(op, spec, profile, args, offset, collection);
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
    final Future<Map<String, Object?>> future = _run(
      op,
      spec,
      profile,
      args,
      offset,
      collection,
    );
    _inFlight[request] = future;
    return future
        .then((Map<String, Object?> out) {
          _done[request] = out;
          while (_done.length > _capacity) {
            _done.remove(_done.keys.first);
          }
          _onWrite?.call(out['profile']! as String);
          return out;
        })
        .whenComplete(() => _inFlight.remove(request));
  }

  Future<Map<String, Object?>> _run(
    String op,
    _Op spec,
    String? profile,
    Map<String, Object?> args,
    int? deviceOffsetMin,
    String? collection,
  ) async {
    final Future<SrsDbStore?> Function(String)? byUid = _readProfile;
    final SrsDbStore? store = await _open(profile, byUid);
    if (store == null) {
      // 点名的 profile 主机不（再）提供了：与「主机切了 profile」同一个错误，客户端重新握手。
      if (profile != null && byUid != null) {
        throw const SrsRemoteStoreError(
          409,
          SrsRemoteStoreError.profileChanged,
        );
      }
      throw const SrsRemoteStoreError(503, SrsRemoteStoreError.unavailable);
    }
    if (profile != null && profile != store.profileUid) {
      throw const SrsRemoteStoreError(409, SrsRemoteStoreError.profileChanged);
    }
    if (collection != null && collection != store.sync2Collection) {
      throw const SrsRemoteStoreError(409, SrsRemoteStoreError.profileChanged);
    }
    final Object? result;
    try {
      result = deviceOffsetMin == null
          ? await spec.run(store, _Args(args))
          : await store.withDeviceOffset(
              deviceOffsetMin,
              () => spec.run(store, _Args(args)),
            );
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
      'col': store.sync2Collection,
      'ids': SrsRemoteWire.rootIds((
        defaultDeck: store.defaultDeckId,
        lapis: store.lapisNoteTypeId,
        fushiCard: store.fushiCardNoteTypeId,
      )),
      'rev': store.revision,
      'fp': store.contentFingerprint,
      'tt': (await _treeWire(store)).tag,
      'now': nowMs,
      'ts': source.wire,
      'sched': store.canSchedule,
      'rwkv': store.rwkv?.ready ?? false,
      if (store.rwkv case final SrsRwkvStatusSource source)
        'rk': SrsRemoteWire.rwkvStatus(source.status),
      'dev': store.sync2Device,
      'result': result,
      if (op == 'hello' && _profiles != null)
        'profiles': <Map<String, Object?>>[
          for (final SrsRemoteServedProfile p in await _profiles()) p.toJson(),
        ],
    };
  }

  /// 现取这次调用的库：点名的 profile 走 [byUid]，否则默认那份。库在换代途中按 [srsRemoteOpenBlockedError] 回机读码。
  Future<SrsDbStore?> _open(
    String? profile,
    Future<SrsDbStore?> Function(String)? byUid,
  ) async {
    try {
      return profile != null && byUid != null
          ? await byUid(profile)
          : await _readStore();
    } on SrsStoreOpenBlocked catch (e) {
      throw srsRemoteOpenBlockedError(e);
    }
  }

  Future<({String key, String tag, List<Map<String, Object?>> decks})>
  _treeWire(SrsDbStore store) async {
    final String key = store.deckTreeKey;
    final ({String key, String tag, List<Map<String, Object?>> decks})? c =
        _trees[store.profileUid];
    if (c != null && c.key == key) return c;
    final List<SrsEntityView> views = await store.entityViews(
      SrsEntityKind.deck,
    );
    final List<String> tags = <String>[
      for (final SrsEntityView v in views) '${v.id}=${v.tag}',
    ]..sort();
    final ({String key, String tag, List<Map<String, Object?>> decks}) out = (
      key: key,
      tag: tags.join(';'),
      decks: <Map<String, Object?>>[
        for (final SrsEntityView v in views) SrsRemoteWire.view(v),
      ],
    );
    if (store.deckTreeKey == key) _trees[store.profileUid] = out;
    return out;
  }

  static Future<List<Map<String, Object?>>> _views(
    SrsDbStore store,
    SrsEntityKind kind,
    Iterable<String> ids,
  ) async => <Map<String, Object?>>[
    for (final SrsEntityView v in await store.entityViews(kind, ids: ids))
      SrsRemoteWire.view(v),
  ];

  /// 一个实体按类判定活着的修改记录（取自它的视图，与本机读 `edits` 同一份原文）；不存在 = 空。
  static Future<List<Object?>> _editItemsOf(
    SrsDbStore store,
    SrsEntityKind kind,
    String id,
  ) async {
    final List<SrsEntityView> v = await store.entityViews(
      kind,
      ids: <String>[id],
    );
    return v.isEmpty
        ? <Object?>[]
        : SrsRemoteWire.editItems(srsEntityViewEdits(v.single));
  }

  /// 笔记类型只带 `{id, tag}`：客户端缓存里标签一致就不再搬（tag 是主机内核按视图字节算的）。
  static Future<List<Map<String, Object?>>> _typeRefs(
    SrsDbStore store,
    Iterable<String> ids,
  ) async => <Map<String, Object?>>[
    for (final SrsEntityView v in await store.entityViews(
      SrsEntityKind.noteType,
      ids: ids,
    ))
      <String, Object?>{'id': v.id, 'tag': v.tag},
  ];

  static Future<Map<String, Object?>?> _detail(
    SrsDbStore store,
    String cardId,
  ) async {
    final SrsCardDetail? d = await store.cardDetail(cardId);
    if (d == null) return null;
    return <String, Object?>{
      'card': d.card.toJson(),
      'note': (await _views(store, SrsEntityKind.note, <String>[
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
    // 让主机（重新）准备 RWKV：远程复习页「等 RWKV」出错时的「重试」。不等它跑完，状态随之后每次回包的 `rk` 回来。
    // 不是库的写入：不走幂等 id、不触发同步。
    'rwkvStart': _Op((SrsDbStore s, _Args a) async {
      if (s.rwkv case final SrsRwkvStatusSource source) {
        source.start(force: a.raw('force') == true).ignore();
      }
      return null;
    }),
    'dayContext': _Op(
      (SrsDbStore s, _Args a) async =>
          SrsRemoteWire.dayContext(await s.dayContext()),
    ),
    'deckTree': _Op(
      (SrsDbStore s, _Args a) async => <Map<String, Object?>>[
        for (final SrsEntityView v in await s.entityViews(SrsEntityKind.deck))
          SrsRemoteWire.view(v),
      ],
    ),
    'deckSummaries': _Op(
      (SrsDbStore s, _Args a) async => <Object?>[
        for (final SrsDeckSummary d in await s.deckSummaries())
          SrsRemoteWire.summary(d),
      ],
    ),
    'limitUnitLegacyDecks': _Op(
      (SrsDbStore s, _Args a) async =>
          (await s.limitUnitLegacyDecks()).toList()..sort(),
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
          _views(s, SrsEntityKind.note, a.strings('ids')),
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
    'noteTypeViews': _Op(
      (SrsDbStore s, _Args a) async =>
          _views(s, SrsEntityKind.noteType, a.strings('ids')),
    ),
    'history': _Op(
      (SrsDbStore s, _Args a) async =>
          (await s.history(a.str('card'))).toWire(),
    ),
    'entityEdits': _Op(
      (SrsDbStore s, _Args a) async =>
          _editItemsOf(s, a.kind('kind'), a.str('id')),
    ),
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
                : (kind: a.kind('entityKind'), id: entityId),
          );
      // 涉及的实体按类收齐，每类一次 entity_views 批量取（不按冲突逐个取整份视图）。
      final Map<SrsEntityKind, Set<String>> byKind =
          <SrsEntityKind, Set<String>>{};
      for (final (SrsEntityKind kind, String id, _) in all) {
        (byKind[kind] ??= <String>{}).add(id);
      }
      final Map<String, Object?> edits = <String, Object?>{};
      for (final MapEntry<SrsEntityKind, Set<String>> e in byKind.entries) {
        // 视图按规范 ID 回来（别名类只回一份）：冲突里的 ID 先归一，再按规范 ID 对回。
        final Map<String, String> canonical = await srsCanonicalIdMap(
          e.value,
          s.canonicalIds,
        );
        final Map<String, SrsEntityView> got = <String, SrsEntityView>{
          for (final SrsEntityView v in await s.entityViews(
            e.key,
            ids: canonical.values,
          ))
            v.id: v,
        };
        for (final String id in e.value) {
          final SrsEntityView? v = got[srsCanonicalIdIn(canonical, id)];
          edits['${e.key.wire}/$id'] = v == null
              ? <Object?>[]
              : SrsRemoteWire.editItems(srsEntityViewEdits(v));
        }
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
      (SrsDbStore s, _Args a) async =>
          (await srsRemoteKernelCommand(s, <String, Object?>{
            'op': 'history',
            'kind': a.kind('kind').wire,
            'entity': a.str('id'),
          })).json,
    ),
    // 规范 ID（主机内核 `canonical_ids`，只读）：客户端的归一在这里做（规划 §1.8；交接 §14 第 5 条）。
    'canonicalIds': _Op((SrsDbStore s, _Args a) async {
      final List<String> ids = a.strings('ids');
      if (ids.length > kSrsEntityViewsBatchMax) {
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
      }
      return s.canonicalIds(ids);
    }),
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
      // 核对基准与记日志是内核的一条命令（`apply` 的 `expectLast`）：否则两步之间主机本机（或另一台客户端）作答
      // 落库，同一张卡会记两条日志——基准要防的正是这个。
      final SrsAnswerOutcome out;
      try {
        out = await s.answerAndStudy(
          card,
          rating,
          durationMs: durationMs,
          studyDeckId: deck,
          custom: custom,
          expectBase: a.raw('checkBase') == true
              ? (lastLogId: a.optStr('base'))
              : null,
        );
      } on SrsStaleCardError {
        throw const SrsRemoteStoreError(409, SrsRemoteStoreError.stale);
      }
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
        a.kind('kind'),
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
          for (final SrsEditSpec x in _specs(a.raw('changes'), 'changes'))
            SrsFieldChange(x.kind, x.entityId, x.key, x.value),
        ]))
          e.toJson(),
      ],
    ),
    // 编辑类撤销（srs_edit_undo.dart）：写入交回撤销凭据、撤销在主机的写锁里按修改记录裁决。
    'editFieldsUndoable': _Op(
      write: true,
      (SrsDbStore s, _Args a) async =>
          (await s.editFieldsUndoable(<SrsFieldChange>[
            for (final SrsEditSpec x in _specs(a.raw('changes'), 'changes'))
              SrsFieldChange(x.kind, x.entityId, x.key, x.value),
          ])).toJson(),
    ),
    'revertEdits': _Op(write: true, (SrsDbStore s, _Args a) async {
      final SrsEditUndo undo = SrsEditUndo.fromJson(a.raw('undo'));
      for (final SrsEditUndoItem x in undo.items) {
        srsRemoteEntityKind(x.kind.wire);
      }
      return (await s.revertEdits(undo)).toJson();
    }),
    // 只收编辑规格：身份记录（`records`，任意种类的实体定义）远程不开——建实体走上面有意图的写（`createNote` 等）。
    'writeEdits': _Op(write: true, (SrsDbStore s, _Args a) async {
      if (a.raw('records') case final Object records
          when records is! List || records.isNotEmpty) {
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
      }
      return <Object?>[
        for (final SrsFieldEdit e in await s.writeEdits(
          _specs(a.raw('specs'), 'specs'),
        ))
          e.toJson(),
      ];
    }),
    // 浏览命令是查询会话（结果可能很大），不进幂等缓存；浏览里的批量改走上面的写操作。
    // 只放行浏览会话命令（[SrsDbStore.kSrsBrowseOps]）：其余 sync2 内核命令（`seal_file` / `open_file`
    // 按请求给的路径读写主机文件、`apply` 等改库命令）一律 400，不进 store。
    'browseCommand': _Op((SrsDbStore s, _Args a) async {
      final Map<String, Object?> request = a.map('request');
      if (!SrsDbStore.kSrsBrowseOps.contains(request['op'])) {
        throw const SrsRemoteStoreError(400, SrsRemoteStoreError.badRequest);
      }
      return SrsRemoteWire.sync2Result(
        await srsRemoteKernelCommand(s, request),
      );
    }),
  };

  /// 编辑规格（不合形 400）：种类只能是 [kSrsRemoteEntityKinds]。
  static List<SrsEditSpec> _specs(Object? json, String at) {
    final List<SrsEditSpec> specs = SrsRemoteWire.editSpecsFrom(json, at);
    for (final SrsEditSpec x in specs) {
      srsRemoteEntityKind(x.kind.wire);
    }
    return specs;
  }

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
