/// AnkiConnect v6 兼容层：让 Yomitan、asbplayer 等只认 AnkiConnect 的工具不改代码就能往
/// Fushi SRS 里加卡、查重、打开卡片。
///
/// 输入 `{action, version, params, key?}`，输出 `{result, error}`（version ≥ 5 时两个键总在；
/// version ≤ 4 成功时回裸值——与插件的 `format_success_reply` 一致，`multi` 里不带 version 的
/// 子请求也按这条走，Yomitan 依赖它）。字段 / 牌组 / 笔记类型一律按名字映射，牌组名「父::子」；
/// 笔记 / 卡片 / 牌组的整数 id = [SrsIds.ankiNumericId]，笔记类型的整数 id = 它的 ankiNum。
///
/// 不在 Dart 里常驻任何集合镜像（L-5）：findNotes / findCards 的搜索、canAddNotes 的库内查重、getTags 走
/// 原生浏览会话（native/fushi_fsrs/src/store/browse.rs 的 `anki_find` / `anki_dupes` / `anki_tags`，与浏览页同一份
/// 常驻语料、随写入增量更新）；notesInfo / cardsInfo 按 id 读缓存行与笔记寄存器。
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
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';

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

/// 一次请求用到的结构：笔记类型（未删除）与牌组树（store 按内容指纹缓存，没有写入时不重读）。
class _Ctx {
  _Ctx(this.store, this.types, this.tree)
    : typeById = <String, SrsNoteTypeView>{
        for (final SrsNoteTypeView t in types) t.id: t,
      };

  final SrsDbStore store;
  final List<SrsNoteTypeView> types;
  final Map<String, SrsNoteTypeView> typeById;
  final SrsDeckTree tree;

  String deckName(String deckId) =>
      tree[deckId] == null ? '' : tree.fullName(deckId);
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

/// 解析好、还没查重的候选笔记：要写的内容加查重选项（AnkiConnect `options`）。
class _NoteCandidate {
  _NoteCandidate({
    required this.note,
    required this.allowDuplicate,
    required this.deckScope,
    required this.scopeDeckName,
    required this.checkChildren,
    required this.checkAllModels,
  });

  final _PreparedNote note;
  final bool allowDuplicate;
  final bool deckScope;
  final String? scopeDeckName;
  final bool checkChildren;
  final bool checkAllModels;

  /// 查重比较用的首字段原文（笔记类型字段顺序第一个）；笔记类型没有字段时为 null——直接判空，
  /// 不必规范化。
  String? get firstFieldRaw {
    final List<SrsFieldDef> fields = note.type.fields;
    return fields.isEmpty ? null : (note.fieldsById[fields.first.id] ?? '');
  }
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
    List<String> Function(List<String> fields)? dupeNormBatch,
  }) : _store = store,
       _dupeNormBatch = dupeNormBatch ?? srsDupeNormBatch,
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

  /// 查重规范形的批量内核（缺省 [srsDupeNormBatch]，一批一次 FFI）；测试可包一层计调用次数。
  final List<String> Function(List<String> fields) _dupeNormBatch;

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
    'setSpecificValueOfCard',
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
        return _addNote(await _ctx(), _requireMap(p, 'note'), caller);
      case 'addNotes':
        return _addNotes(await _ctx(), _requireList(p, 'notes'), caller);
      case 'canAddNotes':
        final _Ctx s = await _ctx();
        return <bool>[
          for (final String? err in await _tryPrepareAll(
            s,
            _requireList(p, 'notes'),
          ))
            err == null,
        ];
      case 'canAddNotesWithErrorDetail':
        final _Ctx s = await _ctx();
        return <Map<String, Object?>>[
          for (final String? err in await _tryPrepareAll(
            s,
            _requireList(p, 'notes'),
          ))
            switch (err) {
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
        return (await _find(_asString(q, 'query'), notes: true)).ids;
      case 'findCards':
        final Object? q = p['query'];
        if (q == null) return <int>[];
        return (await _find(_asString(q, 'query'), notes: false)).ids;
      case 'notesInfo':
        return _notesInfo(p);
      case 'cardsInfo':
        return _cardsInfo(_requireIntList(p, 'cards'));
      case 'cardsToNotes':
        final SrsDbStore store = await _store();
        final Map<String, SrsCardCacheRow> rows = await _cardRowsByNums(
          store,
          _requireIntList(p, 'cards'),
        );
        final Set<int> out = <int>{};
        for (final int c in _requireIntList(p, 'cards')) {
          final SrsCardCacheRow? row = rows['$c'];
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
        return <String>[
          for (final Object? t
              in (await (await _store()).browseCommand(<String, Object?>{
                    'op': 'anki_tags',
                  })).map['tags']!
                  as List<Object?>)
            t! as String,
        ];
      case 'suspend':
        return _setSuspended(_requireIntList(p, 'cards'), true);
      case 'unsuspend':
        return _setSuspended(_requireIntList(p, 'cards'), false);
      case 'suspended':
        final SrsCardCacheRow c = await _cardByNum(_requireInt(p, 'card'));
        return c.suspended;
      case 'areSuspended':
        final List<int> cards = _requireIntList(p, 'cards');
        final Map<String, SrsCardCacheRow> rows = await _cardRowsByNums(
          await _store(),
          cards,
        );
        return <bool?>[for (final int n in cards) rows['$n']?.suspended];
      case 'setSpecificValueOfCard':
        return _setSpecificValueOfCard(p);
      case 'storeMediaFile':
        return _storeMediaFile(p);
      case 'guiBrowse':
        final Future<void> Function(String?, List<String>)? browse =
            _onGuiBrowse;
        if (browse == null) throw const _AcError('guiBrowse is not available');
        final Object? q = p['query'];
        final ({List<int> ids, List<String> cards}) found = q == null
            ? (ids: const <int>[], cards: const <String>[])
            : await _find(_asString(q, 'query'), notes: false, uuids: true);
        await browse(q as String?, found.cards);
        return found.ids;
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

  /// 本请求的结构上下文（笔记类型、牌组树）。
  Future<_Ctx> _ctx() async {
    final SrsDbStore store = await _store();
    return _Ctx(store, await store.noteTypes(), await store.deckTree());
  }

  /// 一条笔记的可见卡排成 AnkiConnect 的顺序：模板顺序，再 clozeOrd（笔记类型里没有的模板当 0）。
  static List<SrsCardCacheRow> _visibleCardsInOrder(
    SrsNoteTypeView t,
    Iterable<SrsCardCacheRow> cards,
  ) {
    final Map<String, int> ord = <String, int>{
      for (final SrsTemplateDef d in t.templates) d.id: d.ord,
    };
    return <SrsCardCacheRow>[
      for (final SrsCardCacheRow c in cards)
        if (!c.hidden) c,
    ]..sort((SrsCardCacheRow a, SrsCardCacheRow b) {
      final int c = (ord[a.templateId] ?? 0).compareTo(ord[b.templateId] ?? 0);
      return c != 0 ? c : a.clozeOrd.compareTo(b.clozeOrd);
    });
  }

  /// 一组整数卡片 id 的缓存行（含隐藏的），按 `'$整数 id'` 取；不存在的不在表里。一次映射、
  /// 一次分块读（以前每张卡各查一次）。
  Future<Map<String, SrsCardCacheRow>> _cardRowsByNums(
    SrsDbStore store,
    List<int> nums,
  ) async {
    final List<String?> ids = await store.cardIdsForAnkiNumericIds(nums);
    final Map<String, SrsCardCacheRow> byId = <String, SrsCardCacheRow>{
      for (final SrsCardCacheRow c in await store.cardRows(<String>[
        for (final String? id in ids)
          if (id != null) id,
      ]))
        c.id: c,
    };
    return <String, SrsCardCacheRow>{
      for (int i = 0; i < nums.length; i++)
        if (ids[i] case final String id)
          if (byId[id] case final SrsCardCacheRow row) '${nums[i]}': row,
    };
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
    final SrsFieldDef? exact = _fieldByExactName(t, name);
    if (exact != null) return exact;
    // 内置 Fushi 卡片 2026-10-29 给 9 个字段改了名（[FushiCardFields]）：Yomitan 等客户端
    // 的字段配置还是旧名（`Expression` / `Picture` / `MiscInfo` …）时按别名认，否则这些字段
    // 会被静默丢掉（首字段丢了还会整张拒收）。只对内置类型生效：用户自建类型的字段名就是它自己。
    if (t.builtinKey != kSrsBuiltinFushiCardKey) return null;
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> e
        in FushiCardFields.legacyNames.entries) {
      final String? alias = e.key.toLowerCase() == lower
          ? e.value
          : (e.value.toLowerCase() == lower ? e.key : null);
      if (alias != null) return _fieldByExactName(t, alias);
    }
    return null;
  }

  static SrsFieldDef? _fieldByExactName(SrsNoteTypeView t, String name) {
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

  static _AcError _searchError(SrsSearchUnsupported e) =>
      _AcError(switch (e.kind) {
        SrsSearchErrorKind.unsupported =>
          'unsupported search syntax: ${e.reason} [${e.query}]',
        SrsSearchErrorKind.syntax => 'invalid search: ${e.reason} [${e.query}]',
        SrsSearchErrorKind.unavailable => 'search unavailable: ${e.reason}',
      });

  /// findNotes / findCards：在原生浏览会话的常驻语料上求值（[SrsDbStore.browseCommand] `anki_find`），命中按
  /// (笔记创建时刻, 笔记 id, 卡片顺序)。[notes] 为真时每条命中的笔记一个数字 id，否则每张命中的卡一个；[uuids]
  /// 为真时另交回命中卡的 id（guiBrowse）。
  Future<({List<int> ids, List<String> cards})> _find(
    String query, {
    required bool notes,
    bool uuids = false,
  }) async {
    final SrsDbStore store = await _store();
    try {
      final SrsSearchNode node = parseAnkiSearch(query);
      final SrsSync2Result r = await store.browseCommand(<String, Object?>{
        'op': 'anki_find',
        ...await srsBrowseContext(store, rwkvInstant: false),
        if (node is! SrsSearchAll) 'node': srsSearchNodeJson(node),
        'mode': notes ? 'notes' : 'cards',
        if (uuids) 'uuids': true,
      });
      srsBrowseCheckResult(r.map, query);
      final Uint8List bytes = r.files
          .firstWhere(((String, Uint8List) f) => f.$1 == 'ids.i64')
          .$2;
      final ByteData d = ByteData.sublistView(bytes);
      return (
        ids: <int>[
          for (int i = 0; i < bytes.length ~/ 8; i++)
            d.getInt64(i * 8, Endian.little),
        ],
        cards: <String>[
          if (uuids)
            for (final Object? id in r.map['cards']! as List<Object?>)
              id! as String,
        ],
      );
    } on SrsSearchUnsupported catch (e) {
      throw _searchError(e);
    }
  }

  // ---------------------------------------------------------------- 加卡与查重

  /// 判重比较用的首字段，整批：先按样式去重规范形（内联样式与引用行同值），再去 HTML、trim
  /// （原生内核 `ffsrs_search_dupe_norm_batch`，一批一次 FFI；空批不调）。
  List<String> _normAll(List<String> fields) {
    if (fields.isEmpty) return const <String>[];
    try {
      return _dupeNormBatch(fields);
    } on SrsSearchUnsupported catch (e) {
      throw _searchError(e);
    }
  }

  /// 一批候选笔记各自能不能加：能加为 null，不能加为 AnkiConnect 的错误串，按输入顺序。
  Future<List<String?>> _tryPrepareAll(_Ctx s, List<Object?> raws) async =>
      <String?>[
        for (final Object r in await _prepareAll(s, raws))
          r is _AcError ? r.message : null,
      ];

  /// AnkiConnect `createNote` + `isNoteDuplicateOrEmptyInScope`（不写库、不存媒体）。
  Future<_PreparedNote> _prepare(_Ctx s, Map<String, Object?> note) async =>
      switch ((await _prepareAll(s, <Object?>[note])).single) {
        final _AcError e => throw e,
        final Object r => r as _PreparedNote,
      };

  /// 一批候选笔记逐个 [_prepare]，结果按输入顺序：[_PreparedNote] 或 [_AcError]。语义与逐条做
  /// 相同，只是候选首字段的查重规范形先收齐、整批一次算完（一次 FFI），库内查重整批一条原生命令
  /// （`anki_dupes`），不在候选循环里逐条跨边界。
  ///
  /// [candidates] / [norms]（与 [raws] 等长）给了就按位置记下解析好的候选与它首字段的规范形
  /// （addNotes 判批内重复用）。
  Future<List<Object>> _prepareAll(
    _Ctx s,
    List<Object?> raws, {
    List<_NoteCandidate?>? candidates,
    List<String?>? norms,
  }) async {
    final List<Object> out = <Object>[];
    final List<int> pendingAt = <int>[];
    final List<String> pendingRaw = <String>[];
    for (final Object? raw in raws) {
      try {
        final _NoteCandidate c = _parseNote(s, _asNoteMap(raw));
        final String? first = c.firstFieldRaw;
        if (first != null) {
          pendingAt.add(out.length);
          pendingRaw.add(first);
        }
        out.add(c);
      } on _AcError catch (e) {
        out.add(e);
      }
    }
    final Map<int, String> normAt = <int, String>{};
    try {
      final List<String> norms = _normAll(pendingRaw);
      for (int k = 0; k < pendingAt.length; k++) {
        normAt[pendingAt[k]] = norms[k];
      }
    } on _AcError catch (e) {
      // 内核不可用：逐条做时每个要规范化的候选都会报同一个错。
      for (final int i in pendingAt) {
        out[i] = e;
      }
    }
    // 空首字段先判；要查库的候选（范围牌组存在）收齐成一条原生命令。
    final Map<int, bool> dupAt = <int, bool>{};
    final List<int> lookupAt = <int>[];
    final List<Map<String, Object?>> lookups = <Map<String, Object?>>[];
    for (int i = 0; i < out.length; i++) {
      final Object c = out[i];
      if (c is! _NoteCandidate) continue;
      candidates?[i] = c;
      norms?[i] = normAt[i];
      final String? norm = normAt[i];
      if (c.note.type.fields.isEmpty || norm == null || norm.isEmpty) {
        out[i] = const _AcError(kSrsAnkiEmptyError);
        continue;
      }
      final Set<String>? dids = _scopeDecks(
        s,
        deckId: c.note.deckId,
        deckScope: c.deckScope,
        scopeDeckName: c.scopeDeckName,
        checkChildren: c.checkChildren,
      );
      // 范围牌组不存在 → 不可能重复（同 AnkiConnect）。
      if (dids != null && dids.isEmpty) {
        dupAt[i] = false;
        continue;
      }
      lookupAt.add(i);
      lookups.add(<String, Object?>{
        'norm': norm,
        'type': c.note.type.id,
        'all': c.checkAllModels,
        'decks': dids?.toList(),
      });
    }
    if (lookups.isNotEmpty) {
      final List<Object?> dup =
          (await s.store.browseCommand(<String, Object?>{
                'op': 'anki_dupes',
                'first': <String, Object?>{
                  for (final SrsNoteTypeView t in s.types)
                    if (t.fields.isNotEmpty) t.id: t.fields.first.id,
                },
                'cands': lookups,
              })).map['dup']!
              as List<Object?>;
      for (int k = 0; k < lookupAt.length; k++) {
        dupAt[lookupAt[k]] = dup[k]! as bool;
      }
    }
    for (int i = 0; i < out.length; i++) {
      final Object c = out[i];
      if (c is! _NoteCandidate) continue;
      out[i] = (dupAt[i]! && !c.allowDuplicate)
          ? const _AcError(kSrsAnkiDuplicateError)
          : c.note;
    }
    return out;
  }

  /// 按名字解析一条候选笔记（模型 / 牌组 / 字段 / 标签 / 查重选项），不查重。
  _NoteCandidate _parseNote(_Ctx s, Map<String, Object?> note) {
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

    return _NoteCandidate(
      note: _PreparedNote(
        type: type,
        deckId: deckId,
        fieldsById: byId,
        tags: tags,
      ),
      allowDuplicate: allowDuplicate,
      deckScope: scope == 'deck',
      scopeDeckName: scopeDeck,
      checkChildren: checkChildren,
      checkAllModels: checkAllModels,
    );
  }

  /// 查重范围内的牌组：null = 整个集合；空集 = 指定的范围牌组不存在（不可能重复）。
  static Set<String>? _scopeDecks(
    _Ctx s, {
    required String deckId,
    required bool deckScope,
    required String? scopeDeckName,
    required bool checkChildren,
  }) {
    if (!deckScope) return null;
    String did = deckId;
    if (scopeDeckName != null) {
      final String? d2 = _deckByName(s.tree, scopeDeckName);
      if (d2 == null) return const <String>{};
      did = d2;
    }
    return checkChildren ? s.tree.subtree(did).toSet() : <String>{did};
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
    _Ctx s,
    Map<String, Object?> note,
    SrsAnkiConnectCaller caller,
  ) async {
    final _PreparedNote prep = await _prepare(s, note);
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

  /// AnkiConnect `addNotes`：结果与逐条 `addNote`（每条之前的已加进集合）相同——不能加的为 null，
  /// 后面的笔记与本批前面已加的重复同样算重复。但整批只取一次上下文、首字段规范形一次算完、
  /// 写入合成一个批次（一个事务、一次缓存刷新），不再每条笔记各重读整库一遍。
  Future<List<int?>> _addNotes(
    _Ctx s,
    List<Object?> raws,
    SrsAnkiConnectCaller caller,
  ) async {
    final List<_NoteCandidate?> candidates = List<_NoteCandidate?>.filled(
      raws.length,
      null,
    );
    final List<String?> norms = List<String?>.filled(raws.length, null);
    final List<Object> prepared = await _prepareAll(
      s,
      raws,
      candidates: candidates,
      norms: norms,
    );
    final String? url = caller.sourceUrl;
    final List<int?> out = List<int?>.filled(raws.length, null);
    // 本批已经接受的笔记（候选、首字段规范形）：后面的候选还要和它们查重。
    final List<(_NoteCandidate, String)> accepted =
        <(_NoteCandidate, String)>[];
    final List<SrsEventDraft> drafts = <SrsEventDraft>[];
    final List<(int, String)> created = <(int, String)>[];
    for (int i = 0; i < raws.length; i++) {
      final Object r = prepared[i];
      if (r is! _PreparedNote) continue;
      final _NoteCandidate c = candidates[i]!;
      final String norm = norms[i]!;
      if (!c.allowDuplicate && _duplicateInBatch(s, c, norm, accepted)) {
        continue;
      }
      try {
        final Map<String, String> fields = Map<String, String>.of(r.fieldsById);
        await _attachNoteMedia(r.type, fields, _asNoteMap(raws[i]));
        if (!_producesCard(r.type, fields)) continue;
        final String guid = newNoteGuid();
        drafts.addAll(
          s.store.newNoteDrafts(
            noteTypeId: r.type.id,
            fieldsById: fields,
            guid: guid,
            deckId: r.deckId,
            tags: r.tags,
            source: SrsSourceRef(SrsSourceKind.web, <String, Object?>{
              if (url != null && url.isNotEmpty) 'url': url,
              'via': kSrsAnkiConnectSourceVia,
            }),
          ),
        );
        accepted.add((c, norm));
        created.add((i, SrsIds.note(s.store.profileUid, guid)));
      } on Object {
        // 与逐条加一样：这一条算失败（null），不影响别的。
      }
    }
    if (drafts.isEmpty) return out;
    try {
      await s.store.importDrafts(drafts);
    } on Object {
      // 整批一个事务：落库失败时一条都没加上。
      return out;
    }
    for (final (int i, String noteId) in created) {
      out[i] = _num(noteId);
    }
    return out;
  }

  /// [c] 是否与本批前面已接受的笔记重复（范围、模型选项与库内查重同一套；新笔记的卡
  /// 都落在它自己的牌组里）。
  bool _duplicateInBatch(
    _Ctx s,
    _NoteCandidate c,
    String norm,
    List<(_NoteCandidate, String)> accepted,
  ) {
    if (accepted.isEmpty) return false;
    final Set<String>? dids = _scopeDecks(
      s,
      deckId: c.note.deckId,
      deckScope: c.deckScope,
      scopeDeckName: c.scopeDeckName,
      checkChildren: c.checkChildren,
    );
    if (dids != null && dids.isEmpty) return false;
    for (final (_NoteCandidate a, String aNorm) in accepted) {
      if (aNorm != norm) continue;
      if (!c.checkAllModels && a.note.type.id != c.note.type.id) continue;
      if (dids == null || dids.contains(a.note.deckId)) return true;
    }
    return false;
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
    // 笔记按块一次预读、改动攒成一个批次写（以前每条笔记各查三次、各一个事务一次缓存刷新，
    // BUG-3543）。中途遇到不存在的笔记：前面算好的照写再报错，与逐条写同结果。
    final Map<String, List<String>> next = <String, List<String>>{};
    try {
      for (final Object r in await _notesByNums(
        store,
        _requireList(p, 'notes'),
      )) {
        if (r is _AcError) throw r;
        final SrsNoteView note = r as SrsNoteView;
        final List<String> before = next[note.id] ?? note.tags;
        final List<String> tags = List<String>.of(before);
        for (final String t in changes) {
          final String lower = t.toLowerCase();
          final bool present = tags.any((String x) => x.toLowerCase() == lower);
          if (add && !present) tags.add(t);
          if (!add) tags.removeWhere((String x) => x.toLowerCase() == lower);
        }
        if (!const ListEquality<String>().equals(tags, before)) {
          next[note.id] = tags;
        }
      }
    } finally {
      if (next.isNotEmpty) {
        await store.editFieldsBatch(<SrsFieldChange>[
          for (final MapEntry<String, List<String>> e in next.entries)
            SrsFieldChange(
              SrsEntityKind.note,
              e.key,
              SrsFieldKeys.noteTags,
              e.value,
            ),
        ]);
      }
    }
  }

  /// [_noteByNum] 的成批版本：按序给出每项的笔记（[SrsNoteView]），或逐条查时它会抛的错误
  /// （[_AcError]，由调用方按序抛出）。笔记按块一次预读。
  Future<List<Object>> _notesByNums(
    SrsDbStore store,
    List<Object?> raws,
  ) async {
    final List<int?> nums = <int?>[
      for (final Object? raw in raws)
        raw is int
            ? raw
            : (raw is num && raw == raw.truncate() ? raw.toInt() : null),
    ];
    final List<String?> mapped = await store.noteIdsForAnkiNumericIds(<int>[
      for (final int? n in nums) n ?? 0,
    ]);
    final List<(int?, String?)> ids = <(int?, String?)>[
      for (int i = 0; i < nums.length; i++)
        (nums[i], nums[i] == null ? null : mapped[i]),
    ];
    final Map<String, SrsNoteView?> views = await store.notes(<String>[
      for (final (int?, String?) e in ids)
        if (e.$2 != null) e.$2!,
    ]);
    return <Object>[
      for (final (int? n, String? id) in ids)
        if (n == null)
          const _AcError('note id must be an integer')
        else if (id == null ||
            views[id] == null ||
            views[id]!.deletedAt != null)
          _AcError('Note was not found: $n')
        else
          views[id]!,
    ];
  }

  /// AnkiConnect `setSpecificValueOfCard`：只支持新卡的 `due`（= 新卡队列位置，
  /// 「按词频重排新卡」用它）。结果形状照插件：每个键一项，成功 `true`、失败
  /// `[false, 原因]`；卡不存在是单项 `[[false, 原因]]`；keys 与 newValues 长度不同
  /// 返回裸 `false`。别的键（ease / ivl / type …）直接对应 Anki 内部排程列，Fushi 的
  /// 排程只来自复习日志，一律报不支持而不是假装写进去。
  Future<Object?> _setSpecificValueOfCard(Map<String, Object?> p) async {
    final int card = _requireInt(p, 'card');
    final List<Object?> keys = _requireList(p, 'keys');
    final List<Object?> values = _requireList(p, 'newValues');
    if (keys.length != values.length) return false;
    final SrsDbStore store = await _store();
    final String? cid = await store.cardIdForAnkiNumericId(card);
    final SrsCardCacheRow? row = cid == null ? null : await store.cardRow(cid);
    if (row == null || row.hidden) {
      return <Object?>[
        <Object?>[false, 'Card was not found: $card'],
      ];
    }
    final List<Object?> out = <Object?>[];
    int? due;
    for (int i = 0; i < keys.length; i++) {
      final Object? key = keys[i];
      final Object? raw = values[i];
      final int? value = raw is int
          ? raw
          : raw is num && raw == raw.truncate()
          ? raw.toInt()
          : int.tryParse('$raw');
      if (key != 'due') {
        out.add(<Object?>[false, 'Fushi review cannot set "$key" on a card']);
      } else if (row.queue != SrsQueue.newCard.wire) {
        out.add(<Object?>[
          false,
          'Fushi review only sets "due" (queue position) on new cards',
        ]);
      } else if (value == null) {
        out.add(<Object?>[false, 'due must be an integer']);
      } else {
        due = value;
        out.add(true);
      }
    }
    if (due != null) {
      await store.setNewCardPositions(<String, int>{row.id: due});
    }
    return out;
  }

  Future<bool> _setSuspended(List<int> cards, bool value) async {
    final SrsDbStore store = await _store();
    // 卡片缓存行一次读、改动攒成一个批次写（以前每张卡一个事务一次缓存刷新，BUG-3543）。
    // 中途遇到不存在的卡：前面的照写再报错，与逐张写同结果。
    final List<String?> ids = await store.cardIdsForAnkiNumericIds(cards);
    final Map<String, SrsCardCacheRow> rows = <String, SrsCardCacheRow>{
      for (final SrsCardCacheRow c in await store.cardRows(<String>[
        for (final String? id in ids)
          if (id != null) id,
      ]))
        c.id: c,
    };
    final Set<String> changed = <String>{};
    try {
      for (int i = 0; i < cards.length; i++) {
        final SrsCardCacheRow? c = ids[i] == null ? null : rows[ids[i]];
        if (c == null) throw _AcError('Card was not found: ${cards[i]}');
        // 重复的卡：第一次已经记下（逐张写时第二次读到的已是新值，跳过）。
        if (c.suspended == value) continue;
        changed.add(c.id);
      }
    } finally {
      if (changed.isNotEmpty) {
        await store.editFieldsBatch(<SrsFieldChange>[
          for (final String id in changed)
            SrsFieldChange(
              SrsEntityKind.card,
              id,
              SrsFieldKeys.suspended,
              value,
            ),
        ]);
      }
    }
    return changed.isNotEmpty;
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

  /// notesInfo：按 id 读笔记（寄存器物化）与它们的卡片缓存行；查询形式先 findNotes。
  Future<List<Object?>> _notesInfo(Map<String, Object?> p) async {
    final _Ctx s = await _ctx();
    final List<int> ids = p.containsKey('query') && !p.containsKey('notes')
        ? (await _find(_requireString(p, 'query'), notes: true)).ids
        : _requireIntList(p, 'notes');
    final List<String?> noteIds = await s.store.noteIdsForAnkiNumericIds(ids);
    final List<String> known = <String>[
      for (final String? id in noteIds)
        if (id != null) id,
    ];
    final Map<String, SrsNoteView?> views = await s.store.notes(known);
    final Map<String, List<SrsCardCacheRow>> cards = await s.store.cardsOfNotes(
      known,
    );
    final List<Object?> out = <Object?>[];
    for (int k = 0; k < ids.length; k++) {
      final int n = ids[k];
      final String? id = noteIds[k];
      final SrsNoteView? note = id == null ? null : views[id];
      final SrsNoteTypeView? t = note == null || note.deletedAt != null
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
          for (final SrsCardCacheRow c in _visibleCardsInOrder(
            t,
            cards[note.id] ?? const <SrsCardCacheRow>[],
          ))
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

  /// cardsInfo：按 id 读卡片缓存行与所属笔记（寄存器物化），一批一次读。
  Future<List<Object?>> _cardsInfo(List<int> ids) async {
    final _Ctx s = await _ctx();
    final SrsDayContext day = await s.store.dayContext();
    final int today = day.dayIndexOf(s.store.now().$1);
    final Map<String, SrsCardCacheRow> rows = await _cardRowsByNums(
      s.store,
      ids,
    );
    final Map<String, SrsNoteView?> notes = await s.store.notes(<String>{
      for (final SrsCardCacheRow c in rows.values) c.noteId,
    });
    final List<Object?> out = <Object?>[];
    for (int k = 0; k < ids.length; k++) {
      final int n = ids[k];
      // 隐藏 / 不存在的卡、已删的笔记都回 {}。
      final SrsCardCacheRow? c = rows['$n'];
      final SrsNoteView? note = c == null || c.hidden ? null : notes[c.noteId];
      final SrsNoteTypeView? t = note == null || note.deletedAt != null
          ? null
          : s.typeById[note.noteTypeId];
      if (c == null || c.hidden || note == null || t == null) {
        out.add(<String, Object?>{});
        continue;
      }
      final SrsTemplateDef? tpl = t.templates
          .where((SrsTemplateDef d) => d.id == c.templateId)
          .firstOrNull;
      final int ord = t.isCloze ? max(0, c.clozeOrd - 1) : (tpl?.ord ?? 0);
      // 卡、笔记、笔记类型、牌组都已读好：直接交给渲染，不再逐张回库读一遍。
      final SrsRenderedCard? r = await s.store.renderCard(
        c.id,
        detail: SrsCardDetail(
          card: c,
          note: note,
          noteType: t,
          template: tpl,
          deckName: s.tree.effectiveDeckNameOf(
            c.deckId,
            fallback: s.store.defaultDeckId,
          ),
        ),
      );
      final (int type, int queue) = _ankiTypeQueue(c, today);
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
        // review：Fushi 排程日序号；learn：到期时刻（秒）；new：排过的新卡是队列位置
        // （setSpecificValueOfCard 写的 due），没排过的是 0。不是 Anki 集合内的序号。
        'due': switch (q) {
          SrsQueue.newCard => c.newPosition ?? 0,
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
