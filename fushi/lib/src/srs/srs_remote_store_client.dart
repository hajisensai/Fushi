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
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';

export 'package:fushi_engine/srs/srs_remote_store.dart'
    show SrsRemoteStoreError;

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

/// 列出此刻提供远程复习库的互联主机。
Future<List<InterconnectHostTarget>> probeSrsRemoteStoreTargets(
  SyncRepository repository,
) => probeInterconnectHostTargets(
  repository: repository,
  probe: (SyncRepository repo, FushiClientUrl peer) =>
      SrsRemoteHostClient(repository: repo, peer: peer).supportsRemoteStore(),
);

/// 主机上的复习库（见文件头）。本类没覆盖的 [SrsDbStore] 成员（导入、同步、备份等库管理）调用时抛
/// [UnsupportedError]：它们不在复习会话可达的页面里，守卫测试核对可达页面用到的成员都已覆盖。
class SrsRemoteStore implements SrsDbStore, SrsRemoteForwarding {
  SrsRemoteStore._(this._client, this.profileUid, {this.prefetchMedia});

  /// 握手：读主机当前的 profile 与状态。
  static Future<SrsRemoteStore> connect(
    SrsRemoteHostClient client, {
    Future<void> Function(Set<String> names)? prefetchMedia,
  }) async {
    final Map<String, dynamic> hello = await client.call('hello');
    final SrsRemoteStore store = SrsRemoteStore._(
      client,
      hello['profile'] as String,
      prefetchMedia: prefetchMedia,
    );
    store._absorb(hello);
    return store;
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

  ({String tag, SrsDeckTree tree})? _tree;
  ({String fp, SrsDayContext day})? _day;
  final Map<String, ({String tag, SrsNoteTypeView view})> _types =
      <String, ({String tag, SrsNoteTypeView view})>{};

  /// 本机读到的每张卡的最后一条日志：作答时交给主机核对卡在此期间变没变（别的设备 / 主机自己复习过）。
  final Map<String, String?> _bases = <String, String?>{};

  final Random _random = Random.secure();

  /// 主机那边不跑 RWKV 的装配：RWKV 在主机上跑，这里的赋值不起作用。
  @override
  SrsRwkvScheduling? rwkv;

  void _absorb(Map<String, dynamic> envelope) {
    _revision = envelope['rev'] as int? ?? _revision;
    _fingerprint = envelope['fp'] as String? ?? _fingerprint;
    _treeTag = envelope['tt'] as String? ?? _treeTag;
    _canSchedule = envelope['sched'] == true;
    _rwkvReady = envelope['rwkv'] == true;
    _device = envelope['dev'] as String? ?? _device;
    final Object? now = envelope['now'];
    if (now is int) {
      _clockOffsetMs = now - DateTime.now().millisecondsSinceEpoch;
      _timeSource = SrsTimeSource.parse(envelope['ts'] as String?);
    }
  }

  String _newRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  Future<Object?> _read(String op, [Map<String, Object?>? args]) async {
    final Map<String, dynamic> env = await _client.call(
      op,
      args: args ?? const <String, Object?>{},
      profile: profileUid,
    );
    _absorb(env);
    return env['result'];
  }

  /// 写操作：请求 id 只生成一次，连接层失败（回包丢了）用同一个 id 重发一次——主机按 id 去重，不会写两遍。
  Future<Object?> _write(String op, Map<String, Object?> args) async {
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
    _absorb(env);
    return env['result'];
  }

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

  Future<SrsDeckTree> _currentTree() async {
    final ({String tag, SrsDeckTree tree})? cached = _tree;
    if (cached != null && cached.tag == _treeTag) return cached.tree;
    final List<SrsEntitySource> sources = <SrsEntitySource>[
      for (final Object? s in (await _read('deckTree'))! as List<Object?>)
        SrsRemoteWire.sourceFrom(s),
    ];
    final SrsDeckTree tree = SrsRemoteWire.deckTreeFrom(sources);
    _tree = (tag: _treeTag, tree: tree);
    return tree;
  }

  /// 按引用 `{id, tag}` 取笔记类型视图：缓存里标签一致的直接用，其余一次搬齐。
  Future<List<SrsNoteTypeView>> _typesOf(Object? refs) async {
    final List<({String id, String tag})> list = <({String id, String tag})>[
      for (final Object? r in (refs as List<Object?>?) ?? const <Object?>[])
        (id: (r! as Map)['id']! as String, tag: (r as Map)['tag']! as String),
    ];
    final List<String> missing = <String>[
      for (final ({String id, String tag}) r in list)
        if (_types[r.id]?.tag != r.tag) r.id,
    ];
    if (missing.isNotEmpty) {
      final List<SrsEntitySource> sources = <SrsEntitySource>[
        for (final Object? s
            in (await _read('noteTypeSources', <String, Object?>{
                  'ids': missing,
                }))!
                as List<Object?>)
          SrsRemoteWire.sourceFrom(s),
      ];
      final List<SrsNoteTypeView> views = SrsRemoteWire.noteTypesFrom(
        profileUid,
        sources,
      );
      for (int i = 0; i < sources.length; i++) {
        _types[sources[i].id] = (
          tag: SrsRemoteWire.tagOf(sources[i]),
          view: views[i],
        );
      }
    }
    return <SrsNoteTypeView>[
      for (final ({String id, String tag}) r in list)
        if (_types[r.id] case final ({String tag, SrsNoteTypeView view}) hit)
          hit.view,
    ];
  }

  SrsCardCacheRow? _row(Object? json) {
    final SrsCardCacheRow? row = SrsRemoteWire.cardRowFrom(json);
    if (row != null) _bases[row.id] = row.lastLogId;
    return row;
  }

  List<SrsCardCacheRow> _rows(Object? json) => <SrsCardCacheRow>[
    for (final Object? r in json! as List<Object?>) _row(r)!,
  ];

  Map<String, SrsNoteView?> _notesFrom(Object? json, Iterable<String> ids) {
    final List<SrsEntitySource> sources = <SrsEntitySource>[
      for (final Object? s in json! as List<Object?>)
        SrsRemoteWire.sourceFrom(s),
    ];
    final List<SrsNoteView> views = SrsRemoteWire.notesFrom(sources);
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
    final SrsDayContext day = SrsRemoteWire.dayContextFrom(
      await _read('dayContext'),
    );
    _day = (fp: _fingerprint, day: day);
    return day;
  }

  @override
  Future<SrsDeckTree> deckTree() async {
    // 先问一次主机拿到当前树标签（缓存命中时不再搬树）。
    if (_tree == null) return _currentTree();
    await _read('hello');
    return _currentTree();
  }

  @override
  Future<List<SrsDeckSummary>> deckSummaries() async {
    final Object? json = await _read('deckSummaries');
    final SrsDeckTree tree = await _currentTree();
    return <SrsDeckSummary>[
      for (final Object? s in json! as List<Object?>)
        if (SrsRemoteWire.summaryFrom(s, tree) case final SrsDeckSummary d) d,
    ];
  }

  @override
  Future<SrsDeckSummary?> deckSummary(String deckId) async {
    final Object? json = await _read('deckSummary', <String, Object?>{
      'deck': deckId,
    });
    return SrsRemoteWire.summaryFrom(json, await _currentTree());
  }

  @override
  Future<SrsStudyState?> studyState(
    String deckId, {
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) async {
    final Object? json = await _read('studyState', <String, Object?>{
      'deck': deckId,
      'exclude': exclude.toList(),
      'custom': SrsRemoteWire.customStudy(custom),
    });
    return SrsRemoteWire.studyFrom(json, await _currentTree());
  }

  @override
  Future<String?> nextCard(
    String deckId, {
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) async =>
      (await studyState(deckId, exclude: exclude, custom: custom))?.next;

  @override
  Future<SrsCardCacheRow?> cardRow(String cardId) async =>
      _row(await _read('cardRow', <String, Object?>{'card': cardId}));

  @override
  Future<List<SrsCardCacheRow>> cardRows(Iterable<String> cardIds) async =>
      _rows(
        await _read('cardRows', <String, Object?>{'cards': cardIds.toList()}),
      );

  @override
  Future<List<SrsCardCacheRow>> cardsOfNote(String noteId) async =>
      _rows(await _read('cardsOfNote', <String, Object?>{'note': noteId}));

  @override
  Future<SrsCardDetail?> cardDetail(String cardId) async {
    final Object? json = await _read('cardDetail', <String, Object?>{
      'card': cardId,
    });
    if (json == null) return null;
    final Map<String, Object?> m = (json as Map).cast<String, Object?>();
    final SrsCardCacheRow card = _row(m['card'])!;
    final SrsNoteView note = SrsRemoteWire.notesFrom(<SrsEntitySource>[
      SrsRemoteWire.sourceFrom(m['note']),
    ]).single;
    final List<SrsNoteTypeView> types = await _typesOf(<Object?>[m['type']]);
    if (types.isEmpty) return null;
    final SrsNoteTypeView type = types.single;
    return SrsCardDetail(
      card: card,
      note: note,
      noteType: type,
      template: type.templates
          .where((SrsTemplateDef t) => t.id == m['tpl'])
          .firstOrNull,
      deckName: m['deckName']! as String,
    );
  }

  @override
  Future<SrsRenderedCard?> renderCard(
    String cardId, {
    SrsCardDetail? detail,
  }) async {
    final SrsRenderedCard? r = SrsRemoteWire.renderedFrom(
      await _read('renderCard', <String, Object?>{'card': cardId}),
    );
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
  Future<SrsAnswerPreview> preview(String cardId) async =>
      SrsRemoteWire.previewFrom(
        await _read('preview', <String, Object?>{'card': cardId}),
      );

  @override
  Future<SrsNoteView?> note(String id) async => (await notes(<String>[id]))[id];

  @override
  Future<Map<String, SrsNoteView?>> notes(Iterable<String> ids) async {
    final List<String> list = ids.toSet().toList();
    return _notesFrom(
      await _read('notes', <String, Object?>{'ids': list}),
      list,
    );
  }

  @override
  Future<SrsNoteTypeView?> noteType(String id) async =>
      (await noteTypesById(<String>[id]))[id];

  @override
  Future<Map<String, SrsNoteTypeView?>> noteTypesById(
    Iterable<String> ids,
  ) async {
    final List<String> list = ids.toSet().toList();
    final List<SrsNoteTypeView> views = await _typesOf(
      await _read('noteTypeRefs', <String, Object?>{'ids': list}),
    );
    final Map<String, SrsNoteTypeView> byId = <String, SrsNoteTypeView>{
      for (final SrsNoteTypeView v in views) v.id: v,
    };
    return <String, SrsNoteTypeView?>{
      for (final String id in list) id: byId[id],
    };
  }

  @override
  Future<List<SrsNoteTypeView>> noteTypes() async =>
      _typesOf(await _read('allNoteTypeRefs'));

  @override
  Future<SrsCardHistory> history(String cardId) async =>
      SrsCardHistory.fromWire(
        ((await _read('history', <String, Object?>{'card': cardId}))! as Map)
            .cast<String, Object?>(),
      );

  @override
  Future<SrsEntityEdits> entityEdits(SrsEntityKind kind, String id) async =>
      SrsRemoteWire.entityEditsFrom(
        await _read('entityEdits', <String, Object?>{
          'kind': kind.wire,
          'id': id,
        }),
      );

  @override
  Future<Map<String, String>> expandFields(
    Map<String, String> fields, {
    bool dropMissing = false,
  }) async =>
      ((await _read('expandFields', <String, Object?>{
                'fields': fields,
                'dropMissing': dropMissing,
              }))!
              as Map)
          .cast<String, String>();

  @override
  Future<List<(SrsEntityKind, String, SrsRegister)>> syncConflicts() async {
    final Map<String, Object?> m = ((await _read('syncConflicts'))! as Map)
        .cast<String, Object?>();
    final Map<String, Object?> rawEdits = (m['edits']! as Map)
        .cast<String, Object?>();
    final Map<String, SrsEntityEdits> edits = <String, SrsEntityEdits>{
      for (final MapEntry<String, Object?> e in rawEdits.entries)
        e.key: SrsRemoteWire.entityEditsFrom(e.value),
    };
    return <(SrsEntityKind, String, SrsRegister)>[
      for (final Object? item in m['items']! as List<Object?>)
        if (item case [final String kind, final String id, final String key])
          if (edits['$kind/$id']?[key] case final SrsRegister reg)
            (SrsRemoteWire.kindFrom(kind), id, reg),
    ];
  }

  @override
  Future<Set<String>?> instantDueCardIds() async {
    final Object? json = await _read('instantDueCardIds');
    return json == null
        ? null
        : <String>{
            for (final Object? id in json as List<Object?>) id! as String,
          };
  }

  @override
  Future<SrsSync2Result> browseCommand(Map<String, Object?> request) async =>
      SrsRemoteWire.sync2ResultFrom(
        await _read('browseCommand', <String, Object?>{'request': request}),
      );

  @override
  Future<List<String>> remoteNoteIdsOfType(
    String noteTypeId, {
    int? limit,
  }) async => <String>[
    for (final Object? id
        in (await _read('noteIdsOfType', <String, Object?>{
              'type': noteTypeId,
              'limit': limit,
            }))!
            as List<Object?>)
      id! as String,
  ];

  @override
  Future<SrsNoteTypeChangePreview> remotePreviewNoteTypeChange({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  }) async {
    final Map<String, Object?> m =
        ((await _read('previewNoteTypeChange', <String, Object?>{
                  'notes': noteIds,
                  'target': targetTypeId,
                  'fieldMap': fieldMap,
                  'templateMap': templateMap,
                }))!
                as Map)
            .cast<String, Object?>();
    final List<SrsNoteTypeView> types = await _typesOf(<Object?>[
      m['from'],
      m['to'],
    ]);
    return SrsNoteTypeChangePreview(
      from: types[0],
      to: types[1],
      plans: <SrsNoteTypeChangePlan>[
        for (final Object? x in m['plans']! as List<Object?>)
          if (x case {
            'note': final String note,
            'fields': final Map<Object?, Object?> fields,
            'links': final Map<Object?, Object?> links,
            'dropped': final List<Object?> dropped,
          })
            SrsNoteTypeChangePlan(
              noteId: note,
              fieldValues: fields.cast<String, String>(),
              cardLinks: links.cast<String, String>(),
              droppedCards: dropped.cast<String>(),
            ),
      ],
    );
  }

  @override
  Future<List<SrsHistoryEntry>> remoteEditHistory(
    SrsEntityKind kind,
    String entityId,
  ) async => <SrsHistoryEntry>[
    for (final Object? e
        in (await _read('editHistory', <String, Object?>{
                  'kind': kind.wire,
                  'id': entityId,
                })
                as List<Object?>?) ??
            const <Object?>[])
      if (e is Map) SrsHistoryEntry.fromJson(e.cast<String, Object?>()),
  ];

  @override
  Future<Map<String, String>> remoteDeviceNames() async =>
      ((await _read('deviceNames'))! as Map).cast<String, String>();

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
  });

  @override
  Future<int> remoteMigrateLegacyLapis(
    String sourceTypeId, {
    List<String>? noteIds,
    String? targetDeckId,
  }) async =>
      (await _write('migrateLegacyLapis', <String, Object?>{
            'source': sourceTypeId,
            'notes': noteIds,
            'deck': targetDeckId,
          }))!
          as int;

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
      });
    } on InterconnectHostError catch (e) {
      // 出题之后卡在主机上变了：基线作废（不然重新出这张卡也永远 stale），交给复习页跳过重排。
      if (e.message == SrsRemoteStoreError.stale) {
        throw SrsCardChangedError(cardId);
      }
      // 其余失败（连不上等）没写成，基线仍有效，留着给重试。
      if (known) _bases[cardId] = base;
      rethrow;
    }
    final Map<String, Object?> m = (result! as Map).cast<String, Object?>();
    return SrsAnswerOutcome(
      SrsRemoteWire.logFrom(m['log']),
      SrsRemoteWire.studyFrom(m['study'], await _currentTree()),
    );
  }

  @override
  Future<bool> undo(String cardId, String logId) async {
    _bases.remove(cardId);
    return (await _write('undo', <String, Object?>{
          'card': cardId,
          'log': logId,
        })) ==
        true;
  }

  Future<void> _cardWrite(
    String op,
    String cardId, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    _bases.remove(cardId);
    await _write(op, <String, Object?>{'card': cardId, ...args});
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
  Future<List<SrsReviewLog>> resetCards(Iterable<String> cardIds) async {
    final List<String> ids = cardIds.toList();
    ids.forEach(_bases.remove);
    return SrsRemoteWire.logsFrom(
      await _write('resetCards', <String, Object?>{'cards': ids}),
    );
  }

  @override
  Future<List<SrsReviewLog>> setDueDays(Map<String, int> dueDays) async {
    dueDays.keys.forEach(_bases.remove);
    return SrsRemoteWire.logsFrom(
      await _write('setDueDays', <String, Object?>{'days': dueDays}),
    );
  }

  @override
  Future<int> rescheduleDeck(String deckId) async =>
      (await _write('rescheduleDeck', <String, Object?>{'deck': deckId}))!
          as int;

  @override
  Future<({int newCards, int reviews})> extendTodayLimits(
    String deckId, {
    int newCards = 0,
    int reviews = 0,
  }) async {
    final Map<String, Object?> m =
        ((await _write('extendTodayLimits', <String, Object?>{
                  'deck': deckId,
                  'newCards': newCards,
                  'reviews': reviews,
                }))!
                as Map)
            .cast<String, Object?>();
    return (newCards: m['n']! as int, reviews: m['r']! as int);
  }

  @override
  Future<String> createNote({
    required String noteTypeId,
    required Map<String, String> fieldsById,
    String? deckId,
    List<String> tags = const <String>[],
    SrsSourceRef? source,
    String? guid,
    int? createdAt,
  }) async =>
      (await _write('createNote', <String, Object?>{
            'type': noteTypeId,
            'fields': fieldsById,
            'deck': deckId,
            'tags': tags,
            'source': source?.toJson(),
            'guid': guid,
            'createdAt': createdAt,
          }))!
          as String;

  @override
  Future<void> updateNote(
    String noteId, {
    Map<String, String>? fieldsById,
    List<String>? tags,
  }) => _write('updateNote', <String, Object?>{
    'note': noteId,
    'fields': fieldsById,
    'tags': tags,
  });

  @override
  Future<void> deleteNote(String noteId) =>
      _write('deleteNote', <String, Object?>{'note': noteId});

  @override
  Future<void> restoreNote(String noteId) =>
      _write('restoreNote', <String, Object?>{'note': noteId});

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
  }) async {
    if (kind == SrsEntityKind.card) _bases.remove(entityId);
    final Object? json = await _write('editFields', <String, Object?>{
      'kind': kind.wire,
      'id': entityId,
      'values': values,
      'machine': machine,
    });
    return json == null ? null : SrsRemoteWire.editsFrom(json);
  }

  @override
  Future<List<SrsFieldEdit>> editFieldsBatch(
    List<SrsFieldChange> changes,
  ) async {
    for (final SrsFieldChange c in changes) {
      if (c.kind == SrsEntityKind.card) _bases.remove(c.entityId);
    }
    return SrsRemoteWire.editsFrom(
      await _write('editFieldsBatch', <String, Object?>{
        'changes': SrsRemoteWire.editSpecs(<SrsEditSpec>[
          for (final SrsFieldChange c in changes)
            SrsEditSpec(c.kind, c.entityId, c.key, c.value),
        ]),
      }),
    );
  }

  @override
  Future<List<SrsFieldEdit>> writeEdits(
    List<SrsEditSpec> specs, {
    List<SrsEntityRecord> records = const <SrsEntityRecord>[],
  }) async {
    for (final SrsEditSpec s in specs) {
      if (s.kind == SrsEntityKind.card) _bases.remove(s.entityId);
    }
    return SrsRemoteWire.editsFrom(
      await _write('writeEdits', <String, Object?>{
        'specs': SrsRemoteWire.editSpecs(specs),
        'records': <Object?>[
          for (final SrsEntityRecord r in records) r.toJson(),
        ],
      }),
    );
  }
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
