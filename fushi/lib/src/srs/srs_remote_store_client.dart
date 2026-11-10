/// 远程复习库的客户端（docs/specs/2026-11-01-srs-remote-review-design.md）：已配对设备不下载卡组，直接在
/// 互联主机的复习库上复习。
///
/// [SrsRemoteStore] 实现 [SrsDbStore] 的接口，每次调用转发到主机（`/api/srs/remote/call`），复习页 / 笔记编辑 /
/// 牌组设置 / 浏览等页面原样跑在它上面（`srs_remote_review_page.dart` 在子作用域里把 `srsStoreProvider` 换成它），
/// 所以功能与在本机复习一致。实体视图按物化输入搬运、在本机用同一个内核物化（[SrsRemoteWire]）；笔记类型与
/// 牌组树按版本标签缓存，没变就不再搬。卡面媒体按名字拉进本机缓存（[SrsRemoteMediaStore]）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/srs/srs_card_media.dart' show srsCardReferencedMedia;
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';

export 'package:fushi_engine/srs/srs_remote_store.dart'
    show SrsRemoteStoreError, SrsRemoteWireError;

/// 一台互联主机的远程复习库端点。失败抛 [InterconnectHostError]，`message` 是主机的机读码
/// （[SrsRemoteStoreError] 的常量）或连接层的码（[InterconnectHostError.unreachableCode] 等）。
class SrsRemoteHostClient extends InterconnectHostClient {
  SrsRemoteHostClient({
    required super.repository,
    required super.peer,
    super.httpClient,
    super.pinnedClientFactory,
  });

  /// 一次调用；回包是整个信封（`result` 之外还有主机的修订号、牌组树标签、时钟）。
  Future<Map<String, dynamic>> call(
    String op, {
    Map<String, Object?> args = const <String, Object?>{},
    String? profile,
    String? request,
  }) => postJson(
    '${kSrsRemoteStorePathPrefix}call',
    body: <String, dynamic>{
      'op': op,
      'args': args,
      'profile': ?profile,
      'request': ?request,
    },
    timeout: const Duration(seconds: 30),
    authErrorMessage: 'SRS remote store authentication rejected',
  );

  /// 主机是否声明了远程复习库。null = 没有应答。
  Future<bool?> supportsRemoteStore() =>
      declaresCapability(kSrsRemoteStoreCapability);

  /// 一个媒体文件的字节；主机没有时 null。
  Future<Uint8List?> media(String name) async {
    final http.Response? r = await getFromHost(
      '${kSrsRemoteStorePathPrefix}media/${Uri.encodeComponent(name)}',
      timeout: const Duration(seconds: 30),
    );
    return r?.bodyBytes;
  }
}

/// 远程复习库的能力探测。
Future<bool?> _probeSrsRemoteStore(
  SyncRepository repository,
  FushiClientUrl peer,
) => SrsRemoteHostClient(
  repository: repository,
  peer: peer,
).supportsRemoteStore();

/// [candidates]（[configuredInterconnectHostTargets] 列出的）里此刻提供远程复习库的那些。
Future<List<InterconnectHostTarget>> filterSrsRemoteStoreTargets(
  SyncRepository repository,
  List<InterconnectHostTarget> candidates,
) => filterInterconnectHostTargets(
  repository: repository,
  candidates: candidates,
  probe: _probeSrsRemoteStore,
);

/// 主机的回包不合契约（[SrsRemoteWireError]）：按 [InterconnectHostError] 的形状抛，机读码是
/// [SrsRemoteStoreError.badResponse]，页面与别的远程失败走同一套文案和重试。[op] 是哪一次调用，
/// [cause] 带着出错的路径（写进错误日志）。
class SrsRemoteBadResponse extends InterconnectHostError {
  const SrsRemoteBadResponse(this.op, this.cause)
    : super(SrsRemoteStoreError.badResponse, statusCode: 200);

  final String op;
  final SrsRemoteWireError cause;

  @override
  String toString() => '${SrsRemoteStoreError.badResponse} ($op): $cause';
}

/// 一台主机牌组摘要的快照：[decks] 给界面画，[cache] 是落盘格式（[SrsRemoteWire.deckCache]）。
typedef SrsRemoteDeckSnapshot = ({
  List<SrsDeckSummary> decks,
  Map<String, Object?> cache,
});

/// 握手回包里主机提供的 profile（老主机 / 桌面 host 不带 = 空）。
List<SrsRemoteServedProfile> srsServedProfilesOf(Map<String, dynamic> hello) {
  final Object? raw = hello['profiles'];
  if (raw is! List) return const <SrsRemoteServedProfile>[];
  return <SrsRemoteServedProfile>[
    for (final Object? e in raw)
      if (e is Map && e['uid'] is String)
        SrsRemoteServedProfile.fromJson(e.cast<String, Object?>()),
  ];
}

/// 用户在「选哪份复习库」时取消了。
class SrsRemoteProfileChoiceCancelled implements Exception {
  const SrsRemoteProfileChoiceCancelled();
}

/// 打开主机上的哪一份 profile（见 [SrsRemoteStore.connect]）：本机自己的在 [served] 里 → 它；主机提供不止一份
/// 又没有本机的 → [chooseProfile]（没给就用主机默认）；其余 → 主机默认 [hostDefault]。
Future<String> srsPickRemoteProfile({
  required String hostDefault,
  required List<SrsRemoteServedProfile> served,
  String? preferProfile,
  Future<String?> Function(List<SrsRemoteServedProfile> profiles)?
  chooseProfile,
}) async {
  if (preferProfile != null &&
      served.any((SrsRemoteServedProfile p) => p.uid == preferProfile)) {
    return preferProfile;
  }
  if (served.length < 2 || chooseProfile == null) return hostDefault;
  final String? chosen = await chooseProfile(served);
  if (chosen == null) throw const SrsRemoteProfileChoiceCancelled();
  return chosen;
}

/// 主机上的复习库（见文件头）。本类没覆盖的 [SrsDbStore] 成员（导入、同步、备份等库管理）调用时抛
/// [UnsupportedError]：它们不在复习会话可达的页面里，守卫测试核对可达页面用到的成员都已覆盖。
///
/// 回包一律经 [SrsRemoteWire] 的解码器校验（[_call]）：不合契约抛 [SrsRemoteBadResponse]，不漏成 `TypeError`。
class SrsRemoteStore implements SrsDbStore, SrsRemoteForwarding {
  SrsRemoteStore._(this._client, this.profileUid, {this.prefetchMedia});

  /// 握手：读主机当前的 profile 与状态。
  ///
  /// 主机同时提供几份 profile 时（无头服务端，握手回包带 `profiles`）：本机自己的 profile（[preferProfile]）在
  /// 里面就直接打开那一份；不在就交给 [chooseProfile] 让用户选（返回 null = 用户取消，抛
  /// [SrsRemoteProfileChoiceCancelled]）。主机只有一份（桌面 host、老服务端）时照旧打开主机的那一份。
  static Future<SrsRemoteStore> connect(
    SrsRemoteHostClient client, {
    String? preferProfile,
    Future<String?> Function(List<SrsRemoteServedProfile> profiles)?
    chooseProfile,
    Future<void> Function(Set<String> names)? prefetchMedia,
  }) async {
    Map<String, dynamic> hello = await client.call('hello');
    final String hostDefault = _parse('hello', () {
      final Object? p = hello['profile'];
      if (p is! String) throw const SrsRemoteWireError('profile');
      return p;
    });
    final String pick = await srsPickRemoteProfile(
      hostDefault: hostDefault,
      served: srsServedProfilesOf(hello),
      preferProfile: preferProfile,
      chooseProfile: chooseProfile,
    );
    if (pick != hostDefault) {
      hello = await client.call('hello', profile: pick);
    }
    final SrsRemoteEnvelope envelope = _parse('hello', () {
      final SrsRemoteEnvelope e = SrsRemoteWire.envelopeFrom(hello);
      if (e.profile == null) throw const SrsRemoteWireError('profile');
      return e;
    });
    final SrsRemoteStore store = SrsRemoteStore._(
      client,
      envelope.profile!,
      prefetchMedia: prefetchMedia,
    );
    store._absorb(envelope);
    return store;
  }

  /// 解码失败统一换成 [SrsRemoteBadResponse]（嵌套调用抛出的已经是它，原样穿过）。
  static T _parse<T>(String op, T Function() decode) {
    try {
      return decode();
    } on SrsRemoteWireError catch (e) {
      throw SrsRemoteBadResponse(op, e);
    }
  }

  final SrsRemoteHostClient _client;

  @override
  final String profileUid;

  /// 渲染出卡面之后、交给页面之前把卡面引用的媒体拉进本机缓存（`[sound:]` 播放读本地文件）。
  final Future<void> Function(Set<String> names)? prefetchMedia;

  int _revision = 0;
  String _fingerprint = '';
  String _treeTag = '';
  bool _canSchedule = false;
  bool _rwkvReady = false;
  String? _device;
  int _clockOffsetMs = 0;
  SrsTimeSource _timeSource = SrsTimeSource.wall;

  _RemoteTree? _tree;
  ({String fp, SrsDayContext day})? _day;
  final Map<String, ({String tag, SrsNoteTypeView view})> _types =
      <String, ({String tag, SrsNoteTypeView view})>{};

  /// 本机读到的每张卡的最后一条日志：作答时交给主机核对卡在此期间变没变（别的设备 / 主机自己复习过）。
  final Map<String, String?> _bases = <String, String?>{};

  final Random _random = Random.secure();

  /// 主机那边不跑 RWKV 的装配：RWKV 在主机上跑，这里的赋值不起作用。
  @override
  SrsRwkvScheduling? rwkv;

  void _absorb(SrsRemoteEnvelope e) {
    _revision = e.revision ?? _revision;
    _fingerprint = e.fingerprint ?? _fingerprint;
    _treeTag = e.treeTag ?? _treeTag;
    _canSchedule = e.canSchedule;
    _rwkvReady = e.rwkvReady;
    _device = e.device ?? _device;
    final int? now = e.nowMs;
    if (now != null) {
      _clockOffsetMs = now - DateTime.now().millisecondsSinceEpoch;
      _timeSource = SrsTimeSource.parse(e.timeSource);
    }
  }

  String _newRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  /// 信封与 `result` 都经校验：先吸收信封（修订号、树标签、时钟），再交 [decode] 解 `result`。
  /// [decode] 可以再发调用（取牌组树 / 笔记类型），那些调用自己的解码失败已换成 [SrsRemoteBadResponse]。
  Future<T> _call<T>(
    String op,
    Map<String, dynamic> envelope,
    FutureOr<T> Function(Object? result) decode,
  ) async {
    try {
      _absorb(SrsRemoteWire.envelopeFrom(envelope));
      return await decode(envelope['result']);
    } on SrsRemoteWireError catch (e) {
      throw SrsRemoteBadResponse(op, e);
    }
  }

  Future<T> _read<T>(
    String op,
    Map<String, Object?>? args,
    FutureOr<T> Function(Object? result) decode,
  ) async => _call(
    op,
    await _client.call(
      op,
      args: args ?? const <String, Object?>{},
      profile: profileUid,
    ),
    decode,
  );

  /// 写操作：请求 id 只生成一次，连接层失败（回包丢了）用同一个 id 重发一次——主机按 id 去重，不会写两遍。
  Future<T> _write<T>(
    String op,
    Map<String, Object?> args,
    FutureOr<T> Function(Object? result) decode,
  ) async {
    final String request = _newRequestId();
    Map<String, dynamic> env;
    try {
      env = await _client.call(
        op,
        args: args,
        profile: profileUid,
        request: request,
      );
    } on InterconnectHostError catch (e) {
      if (e.message != InterconnectHostError.unreachableCode) rethrow;
      env = await _client.call(
        op,
        args: args,
        profile: profileUid,
        request: request,
      );
    }
    return _call(op, env, decode);
  }

  static void _ignore(Object? _) {}

  // ---------------------------------------------------------------- 同步成员

  @override
  String get defaultDeckId => SrsIds.builtinDefaultDeck(profileUid);
  @override
  String get lapisNoteTypeId => srsLapisNoteTypeId(profileUid);
  @override
  String get fushiCardNoteTypeId => srsFushiCardNoteTypeId(profileUid);
  @override
  bool get canSchedule => _canSchedule;
  @override
  int get revision => _revision;
  @override
  String get contentFingerprint => _fingerprint;
  @override
  String get deckTreeKey => _treeTag;
  @override
  bool get isClosed => false;
  @override
  FsrsEngine? get engine => null;

  /// 主机在同步集合里的设备 ID（修改历史据此标出「本机」= 主机写的）。
  @override
  String? get sync2Device => _device;

  /// 主机的复习时钟：最近一次回包里的主机此刻 + 之后本机走过的量。
  @override
  (int, SrsTimeSource) now() =>
      (DateTime.now().millisecondsSinceEpoch + _clockOffsetMs, _timeSource);

  /// 主机上没有跨调用的事务：每个写操作在主机上各自独占执行。
  @override
  Future<T> runExclusive<T>(Future<T> Function() body) => body();

  @override
  bool instantActiveFor(SrsDeckTree tree, String deckId) =>
      _rwkvReady &&
      tree
          .schedulingConfig(
            tree.effectiveDeckOf(deckId, fallback: defaultDeckId),
          )
          .algorithm
          .usesRwkv;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'SrsRemoteStore: ${invocation.memberName} is not available on a remote '
    'collection',
  );

  // ---------------------------------------------------------------- 牌组 / 笔记类型缓存

  Future<_RemoteTree> _currentEntry() async {
    final _RemoteTree? cached = _tree;
    if (cached != null && cached.tag == _treeTag) return cached;
    final List<SrsEntitySource> sources = await _read(
      'deckTree',
      null,
      SrsRemoteWire.sourcesFrom,
    );
    final _RemoteTree entry = _RemoteTree(
      _treeTag,
      sources,
      _parse('deckTree', () => SrsRemoteWire.deckTreeFrom(sources)),
    );
    _tree = entry;
    return entry;
  }

  Future<SrsDeckTree> _currentTree() async => (await _currentEntry()).tree;

  /// 按引用 `{id, tag}` 取笔记类型视图：缓存里标签一致的直接用，其余一次搬齐。
  Future<List<SrsNoteTypeView>> _typesOf(List<SrsRemoteTypeRef> refs) async {
    final List<String> missing = <String>[
      for (final SrsRemoteTypeRef r in refs)
        if (_types[r.id]?.tag != r.tag) r.id,
    ];
    if (missing.isNotEmpty) {
      final List<SrsEntitySource> sources = await _read(
        'noteTypeSources',
        <String, Object?>{'ids': missing},
        SrsRemoteWire.sourcesFrom,
      );
      final List<SrsNoteTypeView> views = _parse(
        'noteTypeSources',
        () => SrsRemoteWire.noteTypesFrom(profileUid, sources),
      );
      for (int i = 0; i < sources.length; i++) {
        _types[sources[i].id] = (
          tag: SrsRemoteWire.tagOf(sources[i]),
          view: views[i],
        );
      }
    }
    return <SrsNoteTypeView>[
      for (final SrsRemoteTypeRef r in refs)
        if (_types[r.id] case final ({String tag, SrsNoteTypeView view}) hit)
          hit.view,
    ];
  }

  SrsCardCacheRow? _remember(SrsCardCacheRow? row) {
    if (row != null) _bases[row.id] = row.lastLogId;
    return row;
  }

  List<SrsCardCacheRow> _rows(Object? json) {
    final List<SrsCardCacheRow> rows = SrsRemoteWire.cardRowsFrom(json);
    rows.forEach(_remember);
    return rows;
  }

  Map<String, SrsNoteView?> _notesFrom(Object? json, Iterable<String> ids) {
    final List<SrsNoteView> views = SrsRemoteWire.notesFrom(
      SrsRemoteWire.sourcesFrom(json),
    );
    final Map<String, SrsNoteView> byId = <String, SrsNoteView>{
      for (final SrsNoteView v in views) v.id: v,
    };
    return <String, SrsNoteView?>{for (final String id in ids) id: byId[id]};
  }

  // ---------------------------------------------------------------- 读

  @override
  Future<SrsDayContext> dayContext() async {
    final ({String fp, SrsDayContext day})? cached = _day;
    if (cached != null && cached.fp == _fingerprint) return cached.day;
    final SrsDayContext day = await _read(
      'dayContext',
      null,
      SrsRemoteWire.dayContextFrom,
    );
    _day = (fp: _fingerprint, day: day);
    return day;
  }

  @override
  Future<SrsDeckTree> deckTree() async {
    // 先问一次主机拿到当前树标签（缓存命中时不再搬树）。
    if (_tree == null) return _currentTree();
    await _read('hello', null, _ignore);
    return _currentTree();
  }

  Future<(List<SrsDeckSummary>, _RemoteTree)> _summaries() =>
      _read('deckSummaries', null, (Object? json) async {
        final _RemoteTree entry = await _currentEntry();
        return (SrsRemoteWire.summariesFrom(json, entry.tree), entry);
      });

  @override
  Future<List<SrsDeckSummary>> deckSummaries() async => (await _summaries()).$1;

  /// 牌组摘要 + 解码它们用的那份牌组树（同一次读出）：复习首页据此落盘缓存。
  Future<SrsRemoteDeckSnapshot> deckSnapshot() async {
    final (List<SrsDeckSummary> decks, _RemoteTree entry) = await _summaries();
    return (decks: decks, cache: SrsRemoteWire.deckCache(entry.sources, decks));
  }

  @override
  Future<SrsTodayReviewSummary> todayReviewSummary() =>
      _read('todayReviewSummary', null, SrsRemoteWire.todayReviewsFrom);

  @override
  Future<SrsDeckSummary?> deckSummary(String deckId) => _read(
    'deckSummary',
    <String, Object?>{'deck': deckId},
    (Object? json) async =>
        SrsRemoteWire.summaryFrom(json, await _currentTree()),
  );

  @override
  Future<SrsStudyState?> studyState(
    String deckId, {
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) => _read(
    'studyState',
    <String, Object?>{
      'deck': deckId,
      'exclude': exclude.toList(),
      'custom': SrsRemoteWire.customStudy(custom),
    },
    (Object? json) async => SrsRemoteWire.studyFrom(json, await _currentTree()),
  );

  @override
  Future<String?> nextCard(
    String deckId, {
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) async =>
      (await studyState(deckId, exclude: exclude, custom: custom))?.next;

  @override
  Future<SrsCardCacheRow?> cardRow(String cardId) => _read(
    'cardRow',
    <String, Object?>{'card': cardId},
    (Object? json) => _remember(SrsRemoteWire.cardRowFrom(json)),
  );

  @override
  Future<List<SrsCardCacheRow>> cardRows(Iterable<String> cardIds) =>
      _read('cardRows', <String, Object?>{'cards': cardIds.toList()}, _rows);

  @override
  Future<List<SrsCardCacheRow>> cardsOfNote(String noteId) =>
      _read('cardsOfNote', <String, Object?>{'note': noteId}, _rows);

  @override
  Future<SrsCardDetail?> cardDetail(String cardId) => _read(
    'cardDetail',
    <String, Object?>{'card': cardId},
    (Object? json) async {
      final SrsRemoteCardDetail? d = SrsRemoteWire.cardDetailFrom(json);
      if (d == null) return null;
      _remember(d.card);
      final SrsNoteView note = SrsRemoteWire.notesFrom(<SrsEntitySource>[
        d.note,
      ]).single;
      final List<SrsNoteTypeView> types = await _typesOf(<SrsRemoteTypeRef>[
        d.type,
      ]);
      if (types.isEmpty) return null;
      final SrsNoteTypeView type = types.single;
      return SrsCardDetail(
        card: d.card,
        note: note,
        noteType: type,
        template: type.templates
            .where((SrsTemplateDef t) => t.id == d.templateId)
            .firstOrNull,
        deckName: d.deckName,
      );
    },
  );

  @override
  Future<SrsRenderedCard?> renderCard(
    String cardId, {
    SrsCardDetail? detail,
  }) async {
    final SrsRenderedCard? r = await _read('renderCard', <String, Object?>{
      'card': cardId,
    }, SrsRemoteWire.renderedFrom);
    final Future<void> Function(Set<String>)? prefetch = prefetchMedia;
    if (r != null && prefetch != null) {
      await prefetch(<String>{
        ...srsCardReferencedMedia(r.question),
        ...srsCardReferencedMedia(r.answer),
        ...srsCardReferencedMedia(r.css),
        for (final String v in r.fields.values) ...srsCardReferencedMedia(v),
        if (r.fushiCardDefinitions != null)
          ...srsCardReferencedMedia(r.fushiCardDefinitions!),
      });
    }
    return r;
  }

  @override
  Future<SrsAnswerPreview> preview(String cardId) => _read(
    'preview',
    <String, Object?>{'card': cardId},
    SrsRemoteWire.previewFrom,
  );

  @override
  Future<SrsNoteView?> note(String id) async => (await notes(<String>[id]))[id];

  @override
  Future<Map<String, SrsNoteView?>> notes(Iterable<String> ids) {
    final List<String> list = ids.toSet().toList();
    return _read('notes', <String, Object?>{
      'ids': list,
    }, (Object? json) => _notesFrom(json, list));
  }

  @override
  Future<SrsNoteTypeView?> noteType(String id) async =>
      (await noteTypesById(<String>[id]))[id];

  @override
  Future<Map<String, SrsNoteTypeView?>> noteTypesById(Iterable<String> ids) {
    final List<String> list = ids.toSet().toList();
    return _read('noteTypeRefs', <String, Object?>{'ids': list}, (
      Object? json,
    ) async {
      final List<SrsNoteTypeView> views = await _typesOf(
        SrsRemoteWire.typeRefsFrom(json),
      );
      final Map<String, SrsNoteTypeView> byId = <String, SrsNoteTypeView>{
        for (final SrsNoteTypeView v in views) v.id: v,
      };
      return <String, SrsNoteTypeView?>{
        for (final String id in list) id: byId[id],
      };
    });
  }

  @override
  Future<List<SrsNoteTypeView>> noteTypes() => _read(
    'allNoteTypeRefs',
    null,
    (Object? json) => _typesOf(SrsRemoteWire.typeRefsFrom(json)),
  );

  @override
  Future<SrsCardHistory> history(String cardId) => _read(
    'history',
    <String, Object?>{'card': cardId},
    SrsRemoteWire.historyFrom,
  );

  @override
  Future<SrsEntityEdits> entityEdits(SrsEntityKind kind, String id) => _read(
    'entityEdits',
    <String, Object?>{'kind': kind.wire, 'id': id},
    SrsRemoteWire.entityEditsFrom,
  );

  @override
  Future<Map<String, String>> expandFields(
    Map<String, String> fields, {
    bool dropMissing = false,
  }) => _read('expandFields', <String, Object?>{
    'fields': fields,
    'dropMissing': dropMissing,
  }, SrsRemoteWire.stringMapFrom);

  @override
  Future<List<(SrsEntityKind, String, SrsRegister)>> syncConflicts({
    ({SrsEntityKind kind, String id})? entity,
  }) => _read('syncConflicts', <String, Object?>{
    if (entity != null) 'entityKind': entity.kind.wire,
    if (entity != null) 'entityId': entity.id,
  }, SrsRemoteWire.syncConflictsFrom);

  @override
  Future<Set<String>?> instantDueCardIds() => _read(
    'instantDueCardIds',
    null,
    (Object? json) =>
        json == null ? null : SrsRemoteWire.stringsFrom(json).toSet(),
  );

  @override
  Future<SrsSync2Result> browseCommand(Map<String, Object?> request) => _read(
    'browseCommand',
    <String, Object?>{'request': request},
    SrsRemoteWire.sync2ResultFrom,
  );

  @override
  Future<List<String>> remoteNoteIdsOfType(String noteTypeId, {int? limit}) =>
      _read('noteIdsOfType', <String, Object?>{
        'type': noteTypeId,
        'limit': limit,
      }, SrsRemoteWire.stringsFrom);

  @override
  Future<SrsNoteTypeChangePreview> remotePreviewNoteTypeChange({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  }) => _read(
    'previewNoteTypeChange',
    <String, Object?>{
      'notes': noteIds,
      'target': targetTypeId,
      'fieldMap': fieldMap,
      'templateMap': templateMap,
    },
    (Object? json) async {
      final SrsRemoteNoteTypeChange c = SrsRemoteWire.noteTypeChangeFrom(json);
      final List<SrsNoteTypeView> types = await _typesOf(<SrsRemoteTypeRef>[
        c.from,
        c.to,
      ]);
      if (types.length != 2) {
        throw const SrsRemoteWireError('previewNoteTypeChange.from/to');
      }
      return SrsNoteTypeChangePreview(
        from: types[0],
        to: types[1],
        plans: c.plans,
      );
    },
  );

  @override
  Future<List<SrsHistoryEntry>> remoteEditHistory(
    SrsEntityKind kind,
    String entityId,
  ) => _read('editHistory', <String, Object?>{
    'kind': kind.wire,
    'id': entityId,
  }, SrsRemoteWire.historyEntriesFrom);

  @override
  Future<Map<String, String>> remoteDeviceNames() =>
      _read('deviceNames', null, SrsRemoteWire.stringMapFrom);

  // ---------------------------------------------------------------- 写

  @override
  Future<void> remoteChangeNoteType({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  }) => _write('changeNoteType', <String, Object?>{
    'notes': noteIds,
    'target': targetTypeId,
    'fieldMap': fieldMap,
    'templateMap': templateMap,
  }, _ignore);

  @override
  Future<int> remoteMigrateLegacyLapis(
    String sourceTypeId, {
    List<String>? noteIds,
    String? targetDeckId,
  }) => _write('migrateLegacyLapis', <String, Object?>{
    'source': sourceTypeId,
    'notes': noteIds,
    'deck': targetDeckId,
  }, SrsRemoteWire.intFrom);

  @override
  Future<SrsAnswerOutcome> answerAndStudy(
    String cardId,
    int rating, {
    int durationMs = 0,
    String? studyDeckId,
    SrsCustomStudy? custom,
  }) async {
    final bool known = _bases.containsKey(cardId);
    final String? base = _bases.remove(cardId);
    final Object? result;
    try {
      result = await _write('answerAndStudy', <String, Object?>{
        'card': cardId,
        'rating': rating,
        'durationMs': durationMs,
        'deck': studyDeckId,
        'custom': SrsRemoteWire.customStudy(custom),
        if (known) 'checkBase': true,
        if (known) 'base': base,
      }, (Object? json) => json);
    } on SrsRemoteBadResponse {
      // 信封不合契约：主机已经处理了这次作答，基线作废（同 stale）。
      rethrow;
    } on InterconnectHostError catch (e) {
      // 出题之后卡在主机上变了：基线作废（不然重新出这张卡也永远 stale），交给复习页跳过重排。
      if (e.message == SrsRemoteStoreError.stale) {
        throw SrsCardChangedError(cardId);
      }
      // 其余失败（连不上等）没写成，基线仍有效，留着给重试。
      if (known) _bases[cardId] = base;
      rethrow;
    }
    // 作答已落在主机上；这里解码失败同样不恢复基线。
    final SrsDeckTree tree = await _currentTree();
    return _parse(
      'answerAndStudy',
      () => SrsRemoteWire.answerFrom(result, tree),
    );
  }

  @override
  Future<bool> undo(String cardId, String logId) {
    _bases.remove(cardId);
    return _write('undo', <String, Object?>{
      'card': cardId,
      'log': logId,
    }, (Object? json) => json == true);
  }

  Future<void> _cardWrite(
    String op,
    String cardId, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) {
    _bases.remove(cardId);
    return _write(op, <String, Object?>{'card': cardId, ...args}, _ignore);
  }

  @override
  Future<void> resetCard(String cardId) => _cardWrite('resetCard', cardId);

  @override
  Future<void> setSuspended(String cardId, bool value) =>
      _cardWrite('setSuspended', cardId, <String, Object?>{'value': value});

  @override
  Future<void> buryUntil(String cardId, int? dayIndex) =>
      _cardWrite('buryUntil', cardId, <String, Object?>{'day': dayIndex});

  @override
  Future<void> setFlag(String cardId, int flag) =>
      _cardWrite('setFlag', cardId, <String, Object?>{'flag': flag});

  @override
  Future<void> moveCard(String cardId, String deckId) =>
      _cardWrite('moveCard', cardId, <String, Object?>{'deck': deckId});

  @override
  Future<List<SrsReviewLog>> resetCards(Iterable<String> cardIds) {
    final List<String> ids = cardIds.toList();
    ids.forEach(_bases.remove);
    return _write('resetCards', <String, Object?>{
      'cards': ids,
    }, SrsRemoteWire.logsFrom);
  }

  @override
  Future<List<SrsReviewLog>> setDueDays(Map<String, int> dueDays) {
    dueDays.keys.forEach(_bases.remove);
    return _write('setDueDays', <String, Object?>{
      'days': dueDays,
    }, SrsRemoteWire.logsFrom);
  }

  @override
  Future<int> rescheduleDeck(String deckId) => _write(
    'rescheduleDeck',
    <String, Object?>{'deck': deckId},
    SrsRemoteWire.intFrom,
  );

  @override
  Future<({int newCards, int reviews})> extendTodayLimits(
    String deckId, {
    int newCards = 0,
    int reviews = 0,
  }) => _write('extendTodayLimits', <String, Object?>{
    'deck': deckId,
    'newCards': newCards,
    'reviews': reviews,
  }, SrsRemoteWire.extendedLimitsFrom);

  @override
  Future<String> createNote({
    required String noteTypeId,
    required Map<String, String> fieldsById,
    String? deckId,
    List<String> tags = const <String>[],
    SrsSourceRef? source,
    String? guid,
    int? createdAt,
  }) => _write('createNote', <String, Object?>{
    'type': noteTypeId,
    'fields': fieldsById,
    'deck': deckId,
    'tags': tags,
    'source': source?.toJson(),
    'guid': guid,
    'createdAt': createdAt,
  }, SrsRemoteWire.stringFrom);

  @override
  Future<void> updateNote(
    String noteId, {
    Map<String, String>? fieldsById,
    List<String>? tags,
  }) => _write('updateNote', <String, Object?>{
    'note': noteId,
    'fields': fieldsById,
    'tags': tags,
  }, _ignore);

  @override
  Future<void> deleteNote(String noteId) =>
      _write('deleteNote', <String, Object?>{'note': noteId}, _ignore);

  @override
  Future<void> restoreNote(String noteId) =>
      _write('restoreNote', <String, Object?>{'note': noteId}, _ignore);

  @override
  Future<SrsFieldEdit?> editField(
    SrsEntityKind kind,
    String entityId,
    String key,
    Object? value, {
    bool machine = false,
  }) async => (await editFields(kind, entityId, <String, Object?>{
    key: value,
  }, machine: machine))?.firstOrNull;

  @override
  Future<List<SrsFieldEdit>?> editFields(
    SrsEntityKind kind,
    String entityId,
    Map<String, Object?> values, {
    bool machine = false,
  }) {
    if (kind == SrsEntityKind.card) _bases.remove(entityId);
    return _write('editFields', <String, Object?>{
      'kind': kind.wire,
      'id': entityId,
      'values': values,
      'machine': machine,
    }, (Object? json) => json == null ? null : SrsRemoteWire.editsFrom(json));
  }

  @override
  Future<List<SrsFieldEdit>> editFieldsBatch(List<SrsFieldChange> changes) {
    for (final SrsFieldChange c in changes) {
      if (c.kind == SrsEntityKind.card) _bases.remove(c.entityId);
    }
    return _write('editFieldsBatch', <String, Object?>{
      'changes': SrsRemoteWire.editSpecs(<SrsEditSpec>[
        for (final SrsFieldChange c in changes)
          SrsEditSpec(c.kind, c.entityId, c.key, c.value),
      ]),
    }, SrsRemoteWire.editsFrom);
  }

  @override
  Future<List<SrsFieldEdit>> writeEdits(
    List<SrsEditSpec> specs, {
    List<SrsEntityRecord> records = const <SrsEntityRecord>[],
  }) {
    for (final SrsEditSpec s in specs) {
      if (s.kind == SrsEntityKind.card) _bases.remove(s.entityId);
    }
    return _write('writeEdits', <String, Object?>{
      'specs': SrsRemoteWire.editSpecs(specs),
      'records': <Object?>[for (final SrsEntityRecord r in records) r.toJson()],
    }, SrsRemoteWire.editsFrom);
  }
}

/// 缓存的主机牌组树：按树标签失效；[sources] 留着给首页落盘（[SrsRemoteStore.deckSnapshot]）。
class _RemoteTree {
  const _RemoteTree(this.tag, this.sources, this.tree);

  final String tag;
  final List<SrsEntitySource> sources;
  final SrsDeckTree tree;
}

/// 远程复习的卡面媒体缓存：卡面照旧经 [SrsMediaStore] 读本地文件，缺的从主机按名字补拉。
///
/// 媒体名是内容哈希（[SrsMediaStore.contentName]），同名即同内容、永不变，所以按名字缓存不会读到旧内容；
/// 缓存放在临时目录，系统可随时清。
class SrsRemoteMediaStore extends SrsMediaStore {
  SrsRemoteMediaStore(super.root, this._client);

  final SrsRemoteHostClient _client;
  final Map<String, Future<bool>> _fetching = <String, Future<bool>>{};

  /// [hostId] 那台主机的缓存目录。
  static Directory directoryFor(Directory tempRoot, String hostId) => Directory(
    p.join(
      tempRoot.path,
      'srs_remote_media',
      hostId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'),
    ),
  );

  @override
  Future<Uint8List?> load(String name) async {
    final Uint8List? hit = await super.load(name);
    if (hit != null) return hit;
    if (!await fetch(name)) return null;
    return super.load(name);
  }

  /// 把 [names] 里还没缓存的拉下来。失败的跳过：卡面照常显示，缺的媒体在卡面里显示为缺失。
  Future<void> prefetch(Iterable<String> names) async {
    await Future.wait(<Future<bool>>[for (final String n in names) fetch(n)]);
  }

  /// 缓存里有或拉成功返回 true。同名并发只拉一次。
  Future<bool> fetch(String name) {
    final File? file = resolve(name);
    if (file == null) return Future<bool>.value(false);
    return _fetching.putIfAbsent(name, () async {
      try {
        if (await file.exists()) return true;
        final Uint8List? bytes = await _client.media(name);
        if (bytes == null) return false;
        await root.create(recursive: true);
        // 先写临时文件再改名：被杀时不留下半截文件（名字即内容，半截文件会一直错）。
        final File tmp = File('${file.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
        return true;
      } catch (_) {
        return false;
      } finally {
        unawaited(Future<void>(() => _fetching.remove(name)));
      }
    });
  }
}
