/// AnkiConnect v6 兼容层：让 Yomitan、asbplayer 等只认 AnkiConnect 的工具不改代码就能往
/// Fushi SRS 里加卡、查重、打开卡片。
///
/// 输入 `{action, version, params, key?}`，输出 `{result, error}`（version ≥ 5 时两个键总在；
/// version ≤ 4 成功时回裸值——与插件的 `format_success_reply` 一致，`multi` 里不带 version 的
/// 子请求也按这条走，Yomitan 依赖它）。字段 / 牌组 / 笔记类型一律按名字映射，牌组名「父::子」；
/// 笔记 / 卡片 / 牌组的整数 id = [SrsIds.ankiNumericId]，笔记类型的整数 id = 它的 ankiNum。
///
/// HTTP 层（Origin 白名单、回环限制、CORS 预检）在 `srs_ankiconnect_endpoint.dart`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_media.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// 兼容的 AnkiConnect API 版本。
const int kSrsAnkiConnectVersion = 6;

/// 加卡时的出处标记（SourceRef kind = web，`via` 标明经兼容层进来）。
const String kSrsAnkiConnectSourceVia = 'ankiconnect';

/// 与 AnkiConnect 逐字一致的错误串（Yomitan 按子串判重复）。
const String kSrsAnkiDuplicateError =
    'cannot create note because it is a duplicate';
const String kSrsAnkiEmptyError = 'cannot create note because it is empty';
const String kSrsAnkiKeyError = 'valid api key must be provided';
const String kSrsAnkiUnsupportedAction = 'unsupported action';

/// 随机实例 id（防自环识别：`fushiIdentify` 回它，Fushi 自己的 AnkiConnect 客户端据此认出自己）。
String srsAnkiConnectNewInstanceId() {
  final Random r = Random.secure();
  return List<String>.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// HTTP 层交进来的调用方信息。
class SrsAnkiConnectCaller {
  const SrsAnkiConnectCaller({
    this.originAllowed = true,
    this.headerKey,
    this.sourceUrl,
  });

  /// 请求的 Origin 是否在白名单里（不带 Origin 视为允许）。只影响 `requestPermission`。
  final bool originAllowed;

  /// 头部带的 key（x-api-key / Bearer），body 没有 `key` 时用它。
  final String? headerKey;

  /// 能从请求拿到的页面 URL（Referer）；加卡时写进 SourceRef。
  final String? sourceUrl;
}

class _AcError implements Exception {
  const _AcError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一次请求内的只读快照。
class _Snapshot {
  _Snapshot({
    required this.store,
    required this.types,
    required this.tree,
    required this.notes,
    required this.cardsByNote,
    required this.day,
    required this.nowMs,
  }) : typeById = <String, SrsNoteTypeView>{
         for (final SrsNoteTypeView t in types) t.id: t,
       },
       noteById = <String, SrsNoteView>{
         for (final SrsNoteView n in notes) n.id: n,
       },
       today = day.dayIndexOf(nowMs);

  final SrsDbStore store;
  final List<SrsNoteTypeView> types;
  final Map<String, SrsNoteTypeView> typeById;
  final SrsDeckTree tree;

  /// 未删除的笔记，按 (createdAt, id) 排。
  final List<SrsNoteView> notes;
  final Map<String, SrsNoteView> noteById;

  /// noteId → 可见卡片（按模板顺序 / clozeOrd 排）。
  final Map<String, List<SrsCardCacheRow>> cardsByNote;
  final SrsDayContext day;
  final int nowMs;
  final int today;

  String deckName(String deckId) =>
      tree[deckId] == null ? '' : tree.fullName(deckId);
}

/// 一张卡作为搜索求值对象：语义与浏览页同一份（[SrsCardSearchSubject]），整数 id 走本请求的
/// 记忆化映射。
class _CardSubject extends SrsCardSearchSubject {
  _CardSubject(
    _Snapshot s,
    SrsNoteView note,
    SrsNoteTypeView type,
    SrsCardCacheRow card,
    int Function(String) ids,
  ) : super(
        note: note,
        noteType: type,
        card: card,
        deckName: s.deckName(card.deckId),
        day: s.day,
        nowMs: s.nowMs,
        todayDayIndex: s.today,
        numericId: ids,
      );
}

/// 准备好要写的笔记（字段已按名字映射到 fieldId）。
class _PreparedNote {
  _PreparedNote({
    required this.type,
    required this.deckId,
    required this.fieldsById,
    required this.tags,
  });

  final SrsNoteTypeView type;
  final String deckId;
  final Map<String, String> fieldsById;
  final List<String> tags;
}

class SrsAnkiConnectHandler {
  SrsAnkiConnectHandler({
    required Future<SrsDbStore> Function() store,
    required this.instanceId,
    String? Function()? apiKey,
    String Function()? profileName,
    void Function()? onSync,
    Future<void> Function(String? query, List<String> cardIds)? onGuiBrowse,
    Future<void> Function(String noteId)? onGuiEditNote,
    SrsAnkiMediaSink? mediaSink,
    SrsAnkiMediaPolicy Function()? mediaPolicy,
    SrsAnkiHostResolver? resolveHost,
    SrsAnkiUrlFetcher? fetchUrl,
  }) : _store = store,
       _apiKey = apiKey,
       _profileName = profileName,
       _onSync = onSync,
       _onGuiBrowse = onGuiBrowse,
       _onGuiEditNote = onGuiEditNote,
       _mediaSink = mediaSink,
       _mediaPolicy = mediaPolicy,
       _resolveHost = resolveHost,
       _fetchUrl = fetchUrl;

  final Future<SrsDbStore> Function() _store;

  /// `fushiIdentify` 回的随机实例 id。
  final String instanceId;
  final String? Function()? _apiKey;
  final String Function()? _profileName;
  final void Function()? _onSync;
  final Future<void> Function(String? query, List<String> cardIds)?
  _onGuiBrowse;
  final Future<void> Function(String noteId)? _onGuiEditNote;
  final SrsAnkiMediaSink? _mediaSink;
  final SrsAnkiMediaPolicy Function()? _mediaPolicy;
  final SrsAnkiHostResolver? _resolveHost;
  final SrsAnkiUrlFetcher? _fetchUrl;

  /// 支持的动作（`apiReflect` 据此回答；不在表里的一律 `unsupported action`）。
  static const List<String> supportedActions = <String>[
    'addNote',
    'addNotes',
    'addTags',
    'apiReflect',
    'areSuspended',
    'canAddNotes',
    'canAddNotesWithErrorDetail',
    'cardsInfo',
    'cardsToNotes',
    'createDeck',
    'deckNames',
    'deckNamesAndIds',
    'findCards',
    'findNotes',
    'fushiIdentify',
    'getActiveProfile',
    'getProfiles',
    'getTags',
    'guiBrowse',
    'guiEditNote',
    'loadProfile',
    'modelFieldNames',
    'modelNames',
    'modelNamesAndIds',
    'multi',
    'notesInfo',
    'removeTags',
    'requestPermission',
    'storeMediaFile',
    'suspend',
    'suspended',
    'sync',
    'unsuspend',
    'updateNote',
    'updateNoteFields',
    'version',
  ];

  /// 是否设了 Fushi API key（HTTP 层据此决定是否只收回环请求）。
  bool get keyConfigured {
    final String? k = _apiKey?.call();
    return k != null && k.isNotEmpty;
  }

  // ---------------------------------------------------------------- 入口

  Future<void> _tail = Future<void>.value();

  /// 处理一个 AnkiConnect 请求。所有请求串行执行（查重与加卡之间不能交错）。
  Future<Object?> handle(
    Map<String, Object?> request, {
    SrsAnkiConnectCaller caller = const SrsAnkiConnectCaller(),
  }) {
    final Completer<Object?> done = Completer<Object?>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await _handleOne(request, caller, inheritedKey: null));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<Object?> _handleOne(
    Map<String, Object?> request,
    SrsAnkiConnectCaller caller, {
    required String? inheritedKey,
  }) async {
    final Object? rawVersion = request['version'];
    final int version = rawVersion is int ? rawVersion : 4;
    final Object? rawAction = request['action'];
    try {
      if (rawAction is! String || rawAction.isEmpty) {
        throw const _AcError('action is required');
      }
      final String? configured = _apiKey?.call();
      final bool keyed = configured != null && configured.isNotEmpty;
      final Object? bodyKey = request['key'];
      final String? provided = bodyKey is String
          ? bodyKey
          : (inheritedKey ?? caller.headerKey);
      if (keyed &&
          rawAction != 'requestPermission' &&
          rawAction != 'fushiIdentify' &&
          !_constantTimeEquals(provided, configured)) {
        throw const _AcError(kSrsAnkiKeyError);
      }
      final Object rawParams = request['params'] ?? const <String, Object?>{};
      if (rawParams is! Map) throw const _AcError('params must be an object');
      final Map<String, Object?> params = rawParams.cast<String, Object?>();
      final Object? result = await _dispatch(
        rawAction,
        params,
        caller,
        validatedKey: keyed ? provided : null,
      );
      return version <= 4
          ? result
          : <String, Object?>{'result': result, 'error': null};
    } on _AcError catch (e) {
      return <String, Object?>{'result': null, 'error': e.message};
    } on SrsAnkiMediaException catch (e) {
      return <String, Object?>{'result': null, 'error': e.message};
    } on Object catch (e) {
      return <String, Object?>{'result': null, 'error': '$e'};
    }
  }

  Future<Object?> _dispatch(
    String action,
    Map<String, Object?> p,
    SrsAnkiConnectCaller caller, {
    required String? validatedKey,
  }) async {
    switch (action) {
      case 'version':
        return kSrsAnkiConnectVersion;
      case 'requestPermission':
        return caller.originAllowed
            ? <String, Object?>{
                'permission': 'granted',
                'requireApikey': keyConfigured,
                'version': kSrsAnkiConnectVersion,
              }
            : <String, Object?>{'permission': 'denied'};
      case 'fushiIdentify':
        return <String, Object?>{'fushi': true, 'instance': instanceId};
      case 'apiReflect':
        return _apiReflect(p);
      case 'multi':
        return _multi(p, caller, validatedKey);
      case 'sync':
        final void Function()? sync = _onSync;
        if (sync != null) {
          // 立即返回 null：同步在后台跑，失败不回传给 AnkiConnect 客户端。
          scheduleMicrotask(() {
            try {
              sync();
            } on Object {
              // 同步失败由 SRS 同步自身记录；这里只负责触发。
            }
          });
        }
        return null;
      case 'getProfiles':
        return <String>[_profile];
      case 'getActiveProfile':
        return _profile;
      case 'loadProfile':
        return _requireString(p, 'name') == _profile;
      case 'deckNames':
        return _deckNames(await _store());
      case 'deckNamesAndIds':
        return _deckNamesAndIds(await _store());
      case 'createDeck':
        final SrsDbStore store = await _store();
        return _num(await store.ensureDeckPath(_requireString(p, 'deck')));
      case 'modelNames':
        return <String>[
          for (final SrsNoteTypeView t in await (await _store()).noteTypes())
            t.name,
        ];
      case 'modelNamesAndIds':
        return <String, Object?>{
          for (final SrsNoteTypeView t in await (await _store()).noteTypes())
            t.name: t.ankiNum,
        };
      case 'modelFieldNames':
        final SrsNoteTypeView? t = _modelByName(
          await (await _store()).noteTypes(),
          _requireString(p, 'modelName'),
        );
        if (t == null) {
          throw _AcError('model was not found: ${p['modelName']}');
        }
        return <String>[for (final SrsFieldDef f in t.fields) f.name];
      case 'addNote':
        return _addNote(await _snapshot(), _requireMap(p, 'note'), caller);
      case 'addNotes':
        final List<Object?> notes = _requireList(p, 'notes');
        final List<int?> out = <int?>[];
        for (final Object? n in notes) {
          try {
            out.add(await _addNote(await _snapshot(), _asNoteMap(n), caller));
          } on Object {
            out.add(null);
          }
        }
        return out;
      case 'canAddNotes':
        final _Snapshot s = await _snapshot();
        return <bool>[
          for (final Object? n in _requireList(p, 'notes'))
            _tryPrepare(s, n) == null,
        ];
      case 'canAddNotesWithErrorDetail':
        final _Snapshot s = await _snapshot();
        return <Map<String, Object?>>[
          for (final Object? n in _requireList(p, 'notes'))
            switch (_tryPrepare(s, n)) {
              null => <String, Object?>{'canAdd': true},
              final String err => <String, Object?>{
                'canAdd': false,
                'error': err,
              },
            },
        ];
      case 'findNotes':
        final Object? q = p['query'];
        if (q == null) return <int>[];
        return _findNotes(await _snapshot(), _asString(q, 'query'));
      case 'findCards':
        final Object? q = p['query'];
        if (q == null) return <int>[];
        return <int>[
          for (final _CardSubject c in _matchCards(
            await _snapshot(),
            _asString(q, 'query'),
          ))
            c.cardId,
        ];
      case 'notesInfo':
        return _notesInfo(p);
      case 'cardsInfo':
        return _cardsInfo(_requireIntList(p, 'cards'));
      case 'cardsToNotes':
        final SrsDbStore store = await _store();
        final Set<int> out = <int>{};
        for (final int c in _requireIntList(p, 'cards')) {
          final String? cid = await store.cardIdForAnkiNumericId(c);
          final SrsCardCacheRow? row = cid == null
              ? null
              : await store.cardRow(cid);
          if (row != null) out.add(_num(row.noteId));
        }
        return out.toList();
      case 'updateNoteFields':
        await _updateNote(_requireMap(p, 'note'), requireFields: true);
        return null;
      case 'updateNote':
        await _updateNote(_requireMap(p, 'note'), requireFields: false);
        return null;
      case 'addTags':
        await _editTags(p, add: true);
        return null;
      case 'removeTags':
        await _editTags(p, add: false);
        return null;
      case 'getTags':
        final _Snapshot s = await _snapshot();
        return (<String>{
          for (final SrsNoteView n in s.notes) ...n.tags,
        }.toList()..sort());
      case 'suspend':
        return _setSuspended(_requireIntList(p, 'cards'), true);
      case 'unsuspend':
        return _setSuspended(_requireIntList(p, 'cards'), false);
      case 'suspended':
        final SrsCardCacheRow c = await _cardByNum(_requireInt(p, 'card'));
        return c.suspended;
      case 'areSuspended':
        final SrsDbStore store = await _store();
        final List<bool?> out = <bool?>[];
        for (final int n in _requireIntList(p, 'cards')) {
          final String? cid = await store.cardIdForAnkiNumericId(n);
          final SrsCardCacheRow? row = cid == null
              ? null
              : await store.cardRow(cid);
          out.add(row?.suspended);
        }
        return out;
      case 'storeMediaFile':
        return _storeMediaFile(p);
      case 'guiBrowse':
        final Future<void> Function(String?, List<String>)? browse =
            _onGuiBrowse;
        if (browse == null) throw const _AcError('guiBrowse is not available');
        final Object? q = p['query'];
        final List<_CardSubject> cards = q == null
            ? const <_CardSubject>[]
            : _matchCards(await _snapshot(), _asString(q, 'query'));
        await browse(q as String?, <String>[
          for (final _CardSubject c in cards) c.card.id,
        ]);
        return <int>[for (final _CardSubject c in cards) c.cardId];
      case 'guiEditNote':
        final Future<void> Function(String)? edit = _onGuiEditNote;
        if (edit == null) throw const _AcError('guiEditNote is not available');
        final int n = _requireInt(p, 'note');
        final String? noteId = await (await _store()).noteIdForAnkiNumericId(n);
        final SrsNoteView? note = noteId == null
            ? null
            : await (await _store()).note(noteId);
        if (note == null || note.deletedAt != null) {
          throw _AcError('Note was not found: $n');
        }
        await edit(note.id);
        return null;
    }
    throw const _AcError(kSrsAnkiUnsupportedAction);
  }

  String get _profile => _profileName?.call() ?? 'Fushi';

  // ---------------------------------------------------------------- 参数

  static Map<String, Object?> _requireMap(Map<String, Object?> p, String k) {
    final Object? v = p[k];
    if (v is! Map) throw _AcError('parameter "$k" must be an object');
    return v.cast<String, Object?>();
  }

  static Map<String, Object?> _asNoteMap(Object? v) {
    if (v is! Map) throw const _AcError('note must be an object');
    return v.cast<String, Object?>();
  }

  static List<Object?> _requireList(Map<String, Object?> p, String k) {
    final Object? v = p[k];
    if (v is! List) throw _AcError('parameter "$k" must be an array');
    return v;
  }

  static String _requireString(Map<String, Object?> p, String k) =>
      _asString(p[k], k);

  static String _asString(Object? v, String k) {
    if (v is! String) throw _AcError('parameter "$k" must be a string');
    return v;
  }

  static int _requireInt(Map<String, Object?> p, String k) {
    final Object? v = p[k];
    if (v is int) return v;
    if (v is num && v == v.truncate()) return v.toInt();
    throw _AcError('parameter "$k" must be an integer');
  }

  static List<int> _requireIntList(Map<String, Object?> p, String k) => <int>[
    for (final Object? v in _requireList(p, k))
      if (v is int)
        v
      else if (v is num && v == v.truncate())
        v.toInt()
      else
        throw _AcError('parameter "$k" must contain integers'),
  ];

  static bool _constantTimeEquals(String? a, String b) {
    if (a == null) return false;
    final List<int> x = utf8.encode(a), y = utf8.encode(b);
    int diff = x.length ^ y.length;
    for (int i = 0; i < y.length; i++) {
      diff |= (i < x.length ? x[i] : 0) ^ y[i];
    }
    return diff == 0;
  }

  // ---------------------------------------------------------------- 快照与 id

  final Map<String, int> _numMemo = <String, int>{};

  int _num(String uuid) {
    if (_numMemo.length > 500000) _numMemo.clear();
    return _numMemo[uuid] ??= SrsIds.ankiNumericId(uuid);
  }

  SrsDbStore? _cachedFor;
  (int, int)? _cachedStamp;
  int _cachedAt = 0;
  List<SrsNoteView> _cachedNotes = const <SrsNoteView>[];

  /// 笔记物化按笔记缓存的变化戳缓存（同一毫秒内的变化不信缓存，直接重建）。
  Future<List<SrsNoteView>> _liveNotes(SrsDbStore store) async {
    final (int, int) stamp = await store.notesCacheStamp();
    if (identical(store, _cachedFor) &&
        stamp == _cachedStamp &&
        stamp.$2 < _cachedAt) {
      return _cachedNotes;
    }
    final int builtAt = DateTime.now().millisecondsSinceEpoch;
    final List<SrsNoteView> notes =
        (await store.allNoteViews())
            .where((SrsNoteView n) => n.deletedAt == null)
            .toList()
          ..sort((SrsNoteView a, SrsNoteView b) {
            final int c = a.createdAt.compareTo(b.createdAt);
            return c != 0 ? c : a.id.compareTo(b.id);
          });
    _cachedFor = store;
    _cachedStamp = stamp;
    _cachedAt = builtAt;
    _cachedNotes = notes;
    return notes;
  }

  Future<_Snapshot> _snapshot() async {
    final SrsDbStore store = await _store();
    final List<SrsNoteTypeView> types = await store.noteTypes();
    final Map<String, int> tplOrd = <String, int>{
      for (final SrsNoteTypeView t in types)
        for (final SrsTemplateDef d in t.templates) d.id: d.ord,
    };
    final Map<String, List<SrsCardCacheRow>> byNote =
        <String, List<SrsCardCacheRow>>{};
    for (final SrsCardCacheRow c in await store.allCardRows()) {
      if (c.hidden) continue;
      (byNote[c.noteId] ??= <SrsCardCacheRow>[]).add(c);
    }
    for (final List<SrsCardCacheRow> l in byNote.values) {
      l.sort((SrsCardCacheRow a, SrsCardCacheRow b) {
        final int c = (tplOrd[a.templateId] ?? 0).compareTo(
          tplOrd[b.templateId] ?? 0,
        );
        return c != 0 ? c : a.clozeOrd.compareTo(b.clozeOrd);
      });
    }
    final (int nowMs, _) = store.now();
    return _Snapshot(
      store: store,
      types: types,
      tree: await store.deckTree(),
      notes: await _liveNotes(store),
      cardsByNote: byNote,
      day: await store.dayContext(),
      nowMs: nowMs,
    );
  }

  Future<SrsCardCacheRow> _cardByNum(int n) async {
    final SrsDbStore store = await _store();
    final String? cid = await store.cardIdForAnkiNumericId(n);
    final SrsCardCacheRow? row = cid == null ? null : await store.cardRow(cid);
    if (row == null) throw _AcError('Card was not found: $n');
    return row;
  }

  // ---------------------------------------------------------------- 名字映射

  static SrsNoteTypeView? _modelByName(List<SrsNoteTypeView> types, String n) {
    for (final SrsNoteTypeView t in types) {
      if (t.name == n) return t;
    }
    final String lower = n.toLowerCase();
    for (final SrsNoteTypeView t in types) {
      if (t.name.toLowerCase() == lower) return t;
    }
    return null;
  }

  /// 「父::子」全名 → deckId（各段去空白后比较；先区分大小写，再不区分）。
  static String? _deckByName(SrsDeckTree tree, String name) {
    final String want = name
        .split('::')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .join('::');
    for (final SrsDeckView d in tree.decks) {
      if (tree.fullName(d.id) == want) return d.id;
    }
    final String lower = want.toLowerCase();
    for (final SrsDeckView d in tree.decks) {
      if (tree.fullName(d.id).toLowerCase() == lower) return d.id;
    }
    return null;
  }

  static SrsFieldDef? _fieldByName(SrsNoteTypeView t, String name) {
    for (final SrsFieldDef f in t.fields) {
      if (f.name == name) return f;
    }
    final String lower = name.toLowerCase();
    for (final SrsFieldDef f in t.fields) {
      if (f.name.toLowerCase() == lower) return f;
    }
    return null;
  }

  Future<List<String>> _deckNames(SrsDbStore store) async {
    final SrsDeckTree tree = await store.deckTree();
    return <String>[for (final SrsDeckView d in tree.decks) tree.fullName(d.id)]
      ..sort();
  }

  Future<Map<String, int>> _deckNamesAndIds(SrsDbStore store) async {
    final SrsDeckTree tree = await store.deckTree();
    return <String, int>{
      for (final SrsDeckView d in tree.decks) tree.fullName(d.id): _num(d.id),
    };
  }

  // ---------------------------------------------------------------- 搜索

  static SrsSearchNode _parse(String query) {
    try {
      return parseAnkiSearch(query);
    } on SrsSearchUnsupported catch (e) {
      throw _AcError(
        e.kind == SrsSearchErrorKind.unsupported
            ? 'unsupported search syntax: ${e.reason} [${e.query}]'
            : 'invalid search: ${e.reason} [${e.query}]',
      );
    }
  }

  List<_CardSubject> _matchCards(_Snapshot s, String query) {
    final SrsSearchNode node = _parse(query);
    final List<_CardSubject> out = <_CardSubject>[];
    for (final SrsNoteView n in s.notes) {
      final SrsNoteTypeView? t = s.typeById[n.noteTypeId];
      if (t == null) continue;
      for (final SrsCardCacheRow c
          in s.cardsByNote[n.id] ?? const <SrsCardCacheRow>[]) {
        final _CardSubject subj = _CardSubject(s, n, t, c, _num);
        if (matchesAnkiSearch(node, subj)) out.add(subj);
      }
    }
    return out;
  }

  List<int> _findNotes(_Snapshot s, String query) {
    final List<int> out = <int>[];
    String? last;
    for (final _CardSubject c in _matchCards(s, query)) {
      if (c.note.id == last) continue;
      last = c.note.id;
      out.add(c.noteId);
    }
    return out;
  }

  // ---------------------------------------------------------------- 加卡与查重

  /// 判重比较用的首字段：先按样式去重规范形（内联样式与引用行同值），再去 HTML。
  static String _norm(String field) =>
      ankiSearchStripHtml(srsDedupStyles(field).html).trim();

  /// 能加返回 null，不能加返回 AnkiConnect 的错误串。
  String? _tryPrepare(_Snapshot s, Object? raw) {
    try {
      _prepare(s, _asNoteMap(raw));
      return null;
    } on _AcError catch (e) {
      return e.message;
    }
  }

  /// AnkiConnect `createNote` + `isNoteDuplicateOrEmptyInScope`（不写库、不存媒体）。
  _PreparedNote _prepare(_Snapshot s, Map<String, Object?> note) {
    final Object? modelName = note['modelName'];
    final SrsNoteTypeView? type = modelName is String
        ? _modelByName(s.types, modelName)
        : null;
    if (type == null) throw _AcError('model was not found: $modelName');
    final Object? deckName = note['deckName'];
    final String? deckId = deckName is String
        ? _deckByName(s.tree, deckName)
        : null;
    if (deckId == null) throw _AcError('deck was not found: $deckName');
    final Object? rawFields = note['fields'];
    if (rawFields is! Map) {
      throw const _AcError('note fields must be an object');
    }
    final Map<String, String> byId = <String, String>{};
    for (final MapEntry<Object?, Object?> e in rawFields.entries) {
      final SrsFieldDef? f = _fieldByName(type, '${e.key}');
      if (f == null) continue;
      final Object? v = e.value;
      byId[f.id] = v is String ? v : (v == null ? '' : '$v');
    }
    final Object? rawTags = note['tags'];
    final List<String> tags = rawTags is List
        ? <String>[
            for (final Object? t in rawTags)
              if (t is String && t.trim().isNotEmpty) t.trim(),
          ]
        : const <String>[];

    bool allowDuplicate = false;
    String? scope;
    String? scopeDeck;
    bool checkChildren = false;
    bool checkAllModels = false;
    final Object? options = note['options'];
    if (options is Map) {
      if (options.containsKey('allowDuplicate')) {
        final Object? v = options['allowDuplicate'];
        if (v is! bool) {
          throw const _AcError(
            'option parameter "allowDuplicate" must be boolean',
          );
        }
        allowDuplicate = v;
      }
      final Object? sc = options['duplicateScope'];
      if (sc is String) scope = sc;
      final Object? so = options['duplicateScopeOptions'];
      if (so is Map) {
        final Object? dn = so['deckName'];
        if (dn is String) scopeDeck = dn;
        if (so.containsKey('checkChildren')) {
          final Object? v = so['checkChildren'];
          if (v is! bool) {
            throw const _AcError(
              'option parameter "duplicateScopeOptions.checkChildren" must be boolean',
            );
          }
          checkChildren = v;
        }
        if (so.containsKey('checkAllModels')) {
          final Object? v = so['checkAllModels'];
          if (v is! bool) {
            throw const _AcError(
              'option parameter "duplicateScopeOptions.checkAllModels" must be boolean',
            );
          }
          checkAllModels = v;
        }
      }
    }
    // Yomitan 的 deck-root：查重范围 = 根牌组及其全部子牌组（它自己在发送前也这样展开）。
    if (scope == 'deck-root') {
      scope = 'deck';
      scopeDeck = (deckName as String).split('::').first;
      checkChildren = true;
    }

    switch (_dupeOrEmpty(
      s,
      type: type,
      deckId: deckId,
      fieldsById: byId,
      deckScope: scope == 'deck',
      scopeDeckName: scopeDeck,
      checkChildren: checkChildren,
      checkAllModels: checkAllModels,
    )) {
      case 1:
        throw const _AcError(kSrsAnkiEmptyError);
      case 2:
        if (!allowDuplicate) throw const _AcError(kSrsAnkiDuplicateError);
    }
    return _PreparedNote(
      type: type,
      deckId: deckId,
      fieldsById: byId,
      tags: tags,
    );
  }

  /// 1 = 第一个字段为空；2 = 重复；0 = 都不是。查重 = 笔记类型字段顺序第一个字段去 HTML 后相等。
  int _dupeOrEmpty(
    _Snapshot s, {
    required SrsNoteTypeView type,
    required String deckId,
    required Map<String, String> fieldsById,
    required bool deckScope,
    required String? scopeDeckName,
    required bool checkChildren,
    required bool checkAllModels,
  }) {
    if (type.fields.isEmpty) return 1;
    final String first = _norm(fieldsById[type.fields.first.id] ?? '');
    if (first.isEmpty) return 1;
    Set<String>? dids;
    if (deckScope) {
      String did = deckId;
      if (scopeDeckName != null) {
        final String? d2 = _deckByName(s.tree, scopeDeckName);
        if (d2 == null) return 0; // 范围牌组不存在 → 不可能重复（同 AnkiConnect）。
        did = d2;
      }
      dids = checkChildren ? s.tree.subtree(did).toSet() : <String>{did};
    }
    for (final SrsNoteView n in s.notes) {
      if (!checkAllModels && n.noteTypeId != type.id) continue;
      final SrsNoteTypeView? t = s.typeById[n.noteTypeId];
      if (t == null || t.fields.isEmpty) continue;
      if (_norm(n.field(t.fields.first.id)) != first) continue;
      if (dids == null) return 2;
      for (final SrsCardCacheRow c
          in s.cardsByNote[n.id] ?? const <SrsCardCacheRow>[]) {
        if (dids.contains(c.deckId)) return 2;
      }
    }
    return 0;
  }

  /// 是否至少生成一张非空卡（AnkiConnect：「would make an empty question on all cards」）。
  static bool _producesCard(SrsNoteTypeView t, Map<String, String> byId) {
    final Map<String, String> byName = <String, String>{
      for (final SrsFieldDef f in t.fields) f.name: byId[f.id] ?? '',
    };
    if (t.isCloze) {
      return t.templates.isNotEmpty &&
          clozeOrdinalsIn(byName.values.join('\n')).isNotEmpty;
    }
    final Map<String, String> idToName = <String, String>{
      for (final SrsFieldDef f in t.fields) f.id: f.name,
    };
    for (final SrsTemplateDef tpl in t.templates) {
      try {
        if (!isAnkiCardEmpty(
          questionTemplate: templateIdsToNames(tpl.front, idToName),
          noteFields: byName,
          cardOrd: tpl.ord,
          isCloze: false,
        )) {
          return true;
        }
      } on Object {
        return true; // 模板解析失败按「非空」处理，与卡片生成门一致。
      }
    }
    return false;
  }

  Future<int> _addNote(
    _Snapshot s,
    Map<String, Object?> note,
    SrsAnkiConnectCaller caller,
  ) async {
    final _PreparedNote prep = _prepare(s, note);
    final Map<String, String> fields = Map<String, String>.of(prep.fieldsById);
    await _attachNoteMedia(prep.type, fields, note);
    if (!_producesCard(prep.type, fields)) {
      throw const _AcError(
        'The field values you have provided would make an empty question on all cards.',
      );
    }
    final String? url = caller.sourceUrl;
    final String noteId = await s.store.createNote(
      noteTypeId: prep.type.id,
      fieldsById: fields,
      deckId: prep.deckId,
      tags: prep.tags,
      source: SrsSourceRef(SrsSourceKind.web, <String, Object?>{
        if (url != null && url.isNotEmpty) 'url': url,
        'via': kSrsAnkiConnectSourceVia,
      }),
    );
    return _num(noteId);
  }

  // ---------------------------------------------------------------- 媒体

  /// addNote / updateNoteFields 的 `audio` / `video` / `picture`：存好后把引用追加进指定字段；
  /// 单项失败时与 AnkiConnect 一样把错误文本（转义后）写进字段，不让整张卡失败。
  Future<void> _attachNoteMedia(
    SrsNoteTypeView type,
    Map<String, String> fieldsById,
    Map<String, Object?> note,
  ) async {
    for (final String kind in const <String>['audio', 'video', 'picture']) {
      final Object? raw = note[kind];
      if (raw == null) continue;
      final List<Object?> items = raw is List ? raw : <Object?>[raw];
      for (final Object? item in items) {
        if (item is! Map) continue;
        final Map<String, Object?> m = item.cast<String, Object?>();
        final Object? targets = m['fields'];
        if (targets is! List || targets.isEmpty) continue;
        String append;
        try {
          final String? name = await _storeMedia(m);
          if (name == null) continue;
          append = kind == 'picture' ? '<img src="$name">' : '[sound:$name]';
        } on Object catch (e) {
          final String msg = e is _AcError
              ? e.message
              : (e is SrsAnkiMediaException ? e.message : '$e');
          append = const HtmlEscape(HtmlEscapeMode.element).convert(msg);
        }
        for (final Object? f in targets) {
          final SrsFieldDef? def = f is String ? _fieldByName(type, f) : null;
          if (def == null) continue;
          fieldsById[def.id] = (fieldsById[def.id] ?? '') + append;
        }
      }
    }
  }

  Future<Object?> _storeMediaFile(Map<String, Object?> p) => _storeMedia(p);

  /// 返回实际文件名；`skipHash` 与内容 MD5 相同时返回 null（同 AnkiConnect）。
  Future<String?> _storeMedia(Map<String, Object?> p) async {
    final SrsAnkiMediaSink? sink = _mediaSink;
    if (sink == null) throw const _AcError('media storage is not available');
    final Object? rawName = p['filename'];
    if (rawName is! String) {
      throw const _AcError('parameter "filename" must be a string');
    }
    final String filename = srsAnkiSanitizeFilename(rawName);
    final SrsAnkiMediaPolicy policy =
        _mediaPolicy?.call() ?? const SrsAnkiMediaPolicy();
    final Object? data = p['data'];
    final Object? path = p['path'];
    final Object? url = p['url'];
    final Uint8List bytes;
    if (data is String && data.isNotEmpty) {
      try {
        bytes = base64Decode(data);
      } on FormatException {
        throw const _AcError('parameter "data" is not valid base64');
      }
    } else if (path is String && path.isNotEmpty) {
      if (!policy.allowPath) {
        throw const _AcError(
          'the "path" parameter of storeMediaFile is disabled in Fushi '
          '(it would let any caller read local files); send "data" instead',
        );
      }
      bytes = await File(path).readAsBytes();
    } else if (url is String && url.isNotEmpty) {
      if (!policy.allowUrl) {
        throw const _AcError(
          'the "url" parameter of storeMediaFile is disabled in Fushi '
          '(server-side fetches can reach private networks); send "data" instead',
        );
      }
      final Uri? uri = Uri.tryParse(url);
      if (uri == null) throw _AcError('invalid url "$url"');
      final SrsAnkiUrlFetcher? fetch = _fetchUrl;
      if (fetch == null) {
        throw const _AcError('url fetching is not configured in this host');
      }
      bytes = await srsAnkiDownload(uri, resolve: _resolveHost, fetch: fetch);
    } else {
      throw const _AcError(
        'You must provide a "data", "path", or "url" field.',
      );
    }
    final Object? skipHash = p['skipHash'];
    if (skipHash is String && md5.convert(bytes).toString() == skipHash) {
      return null;
    }
    return sink(filename, bytes);
  }

  // ---------------------------------------------------------------- 编辑

  Future<SrsNoteView> _noteByNum(SrsDbStore store, Object? raw) async {
    final int? n = raw is int
        ? raw
        : (raw is num && raw == raw.truncate() ? raw.toInt() : null);
    if (n == null) throw const _AcError('note id must be an integer');
    final String? id = await store.noteIdForAnkiNumericId(n);
    final SrsNoteView? note = id == null ? null : await store.note(id);
    if (note == null || note.deletedAt != null) {
      throw _AcError('Note was not found: $n');
    }
    return note;
  }

  Future<void> _updateNote(
    Map<String, Object?> p, {
    required bool requireFields,
  }) async {
    final SrsDbStore store = await _store();
    final SrsNoteView note = await _noteByNum(store, p['id']);
    final SrsNoteTypeView? type = await store.noteType(note.noteTypeId);
    if (type == null) throw _AcError('model was not found: ${note.noteTypeId}');
    final Object? rawFields = p['fields'];
    final Object? rawTags = p['tags'];
    if (requireFields && rawFields is! Map) {
      throw const _AcError('note fields must be an object');
    }
    if (!requireFields && rawFields is! Map && rawTags == null) {
      throw const _AcError('Must provide a "fields" or "tags" property.');
    }
    Map<String, String>? byId;
    if (rawFields is Map) {
      byId = <String, String>{};
      for (final MapEntry<Object?, Object?> e in rawFields.entries) {
        final SrsFieldDef? f = _fieldByName(type, '${e.key}');
        if (f == null) continue;
        final Object? v = e.value;
        byId[f.id] = v is String ? v : (v == null ? '' : '$v');
      }
      final Map<String, String> withMedia = <String, String>{
        for (final SrsFieldDef f in type.fields)
          f.id: byId[f.id] ?? note.field(f.id),
      };
      await _attachNoteMedia(type, withMedia, p);
      for (final MapEntry<String, String> e in withMedia.entries) {
        if (byId.containsKey(e.key) || e.value != note.field(e.key)) {
          byId[e.key] = e.value;
        }
      }
    }
    List<String>? tags;
    if (!requireFields && rawTags != null) {
      final List<Object?> list = rawTags is String
          ? <Object?>[rawTags]
          : (rawTags is List
                ? rawTags
                : throw const _AcError(
                    'Must provide tags as a list of strings',
                  ));
      tags = <String>[
        for (final Object? t in list)
          if (t is String && t.trim().isNotEmpty)
            t.trim()
          else if (t is! String)
            throw const _AcError('Must provide tags as a list of strings'),
      ];
    }
    await store.updateNote(note.id, fieldsById: byId, tags: tags);
  }

  Future<void> _editTags(Map<String, Object?> p, {required bool add}) async {
    final SrsDbStore store = await _store();
    final List<String> changes = _requireString(
      p,
      'tags',
    ).split(RegExp(r'\s+')).where((String t) => t.isNotEmpty).toList();
    for (final Object? raw in _requireList(p, 'notes')) {
      final SrsNoteView note = await _noteByNum(store, raw);
      final List<String> tags = List<String>.of(note.tags);
      for (final String t in changes) {
        final String lower = t.toLowerCase();
        final bool present = tags.any((String x) => x.toLowerCase() == lower);
        if (add && !present) tags.add(t);
        if (!add) tags.removeWhere((String x) => x.toLowerCase() == lower);
      }
      if (!const ListEquality<String>().equals(tags, note.tags)) {
        await store.updateNote(note.id, tags: tags);
      }
    }
  }

  Future<bool> _setSuspended(List<int> cards, bool value) async {
    final SrsDbStore store = await _store();
    bool changed = false;
    for (final int n in cards) {
      final SrsCardCacheRow c = await _cardByNum(n);
      if (c.suspended == value) continue;
      await store.setSuspended(c.id, value);
      changed = true;
    }
    return changed;
  }

  // ---------------------------------------------------------------- 信息

  /// 字段值对外按 Anki 的样子给：释义样式去重的引用行展开回内联 `<style>`
  /// （外部工具读到的与它当初写进来的逐字节相同）。
  Future<Map<String, Object?>> _fieldsInfo(
    SrsDbStore store,
    SrsNoteTypeView t,
    SrsNoteView n,
  ) async => <String, Object?>{
    for (int i = 0; i < t.fields.length; i++)
      t.fields[i].name: <String, Object?>{
        'value': await store.expandStyles(n.field(t.fields[i].id)),
        'order': i,
      },
  };

  Future<List<Object?>> _notesInfo(Map<String, Object?> p) async {
    final _Snapshot s = await _snapshot();
    final List<int> ids = p.containsKey('query') && !p.containsKey('notes')
        ? _findNotes(s, _requireString(p, 'query'))
        : _requireIntList(p, 'notes');
    final List<Object?> out = <Object?>[];
    for (final int n in ids) {
      final String? id = await s.store.noteIdForAnkiNumericId(n);
      final SrsNoteView? note = id == null ? null : s.noteById[id];
      final SrsNoteTypeView? t = note == null
          ? null
          : s.typeById[note.noteTypeId];
      if (note == null || t == null) {
        out.add(<String, Object?>{});
        continue;
      }
      out.add(<String, Object?>{
        'noteId': n,
        'profile': _profile,
        'tags': note.tags,
        'fields': await _fieldsInfo(s.store, t, note),
        'modelName': t.name,
        'cards': <int>[
          for (final SrsCardCacheRow c
              in s.cardsByNote[note.id] ?? const <SrsCardCacheRow>[])
            _num(c.id),
        ],
      });
    }
    return out;
  }

  /// Anki 的 (type, queue)：new 0/0、learn 1/1、review 2/2、relearn 3/1；暂停 queue -1、埋卡 -3。
  static (int, int) _ankiTypeQueue(SrsCardCacheRow c, int today) {
    final SrsQueue q = SrsQueue.parse(c.queue);
    final int type = switch (q) {
      SrsQueue.newCard => 0,
      SrsQueue.learning => 1,
      SrsQueue.review => 2,
      SrsQueue.relearning => 3,
    };
    int queue = switch (q) {
      SrsQueue.newCard => 0,
      SrsQueue.learning || SrsQueue.relearning => 1,
      SrsQueue.review => 2,
    };
    if (c.buriedUntilDay != null && c.buriedUntilDay! > today) queue = -3;
    if (c.suspended) queue = -1;
    return (type, queue);
  }

  Future<List<Object?>> _cardsInfo(List<int> ids) async {
    final _Snapshot s = await _snapshot();
    final List<Object?> out = <Object?>[];
    for (final int n in ids) {
      final String? cid = await s.store.cardIdForAnkiNumericId(n);
      final SrsCardCacheRow? c = cid == null
          ? null
          : await s.store.cardRow(cid);
      final SrsNoteView? note = c == null ? null : s.noteById[c.noteId];
      final SrsNoteTypeView? t = note == null
          ? null
          : s.typeById[note.noteTypeId];
      if (c == null || c.hidden || note == null || t == null) {
        out.add(<String, Object?>{});
        continue;
      }
      final int ord = t.isCloze
          ? max(0, c.clozeOrd - 1)
          : (t.templates
                    .where((SrsTemplateDef d) => d.id == c.templateId)
                    .firstOrNull
                    ?.ord ??
                0);
      final SrsRenderedCard? r = await s.store.renderCard(c.id);
      final (int type, int queue) = _ankiTypeQueue(c, s.today);
      final SrsQueue q = SrsQueue.parse(c.queue);
      out.add(<String, Object?>{
        'cardId': n,
        'fields': await _fieldsInfo(s.store, t, note),
        'fieldOrder': ord,
        'question': r?.question ?? '',
        'answer': r?.answer ?? '',
        'modelName': t.name,
        'ord': ord,
        'deckName': s.deckName(c.deckId),
        'css': t.css,
        // FSRS 卡没有 ease；与 Anki 的 FSRS / 新卡一样报 0。
        'factor': 0,
        'interval': c.scheduledDays,
        'note': _num(c.noteId),
        'type': type,
        'queue': queue,
        // review：Fushi 排程日序号；learn：到期时刻（秒）；new：0。不是 Anki 集合内的序号。
        'due': switch (q) {
          SrsQueue.newCard => 0,
          SrsQueue.review => c.dueDay ?? 0,
          SrsQueue.learning || SrsQueue.relearning => (c.dueAt ?? 0) ~/ 1000,
        },
        'reps': c.reps,
        'lapses': c.lapses,
        'left': 0,
        'mod': (c.lastReviewedAt ?? c.noteCreatedAt) ~/ 1000,
        'flags': c.flag,
      });
    }
    return out;
  }

  // ---------------------------------------------------------------- 元动作

  Map<String, Object?> _apiReflect(Map<String, Object?> p) {
    final Object? scopes = p['scopes'];
    final Object? actions = p['actions'];
    if (scopes is! List) throw const _AcError('scopes has invalid value');
    if (actions != null && actions is! List) {
      throw const _AcError('actions has invalid value');
    }
    final List<String> scopes2 = <String>[];
    final Map<String, Object?> out = <String, Object?>{'scopes': scopes2};
    if (scopes.contains('actions')) {
      scopes2.add('actions');
      out['actions'] = actions == null
          ? List<String>.of(supportedActions)
          : <String>[
              for (final Object? a in actions as List)
                if (a is String && supportedActions.contains(a)) a,
            ];
    }
    return out;
  }

  Future<List<Object?>> _multi(
    Map<String, Object?> p,
    SrsAnkiConnectCaller caller,
    String? validatedKey,
  ) async {
    final List<Object?> out = <Object?>[];
    for (final Object? a in _requireList(p, 'actions')) {
      if (a is! Map) {
        out.add(<String, Object?>{
          'result': null,
          'error': 'action must be an object',
        });
        continue;
      }
      // 子请求不带 key 时继承外层已校验的 key（外层已证明持有者身份）。
      out.add(
        await _handleOne(
          a.cast<String, Object?>(),
          caller,
          inheritedKey: validatedKey,
        ),
      );
    }
    return out;
  }
}
