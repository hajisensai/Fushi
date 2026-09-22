// 纯 Dart 的假 AnkiConnect v6 HTTP 服务，给集成测试当「本机 Anki 桌面版」。
//
// 覆盖本仓 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart`
// 会发出的全部 action（请求/响应形状按该文件逐条对照，不凭记忆）：
//
//   * `version` → 6；`requestPermission` → `{permission, requireApiKey, version}`
//   * `deckNames` / `deckNamesAndIds` / `modelNames` / `modelNamesAndIds` /
//     `modelFieldNames {modelName}` / `modelTemplates` → `{模板名: {Front, Back}}` /
//     `modelStyling` → `{css}`
//   * `createModel {modelName, inOrderFields, css, isCloze, cardTemplates}` /
//     `createDeck {deck}` / `updateModelTemplates {model:{name, templates}}` /
//     `updateModelStyling {model:{name, css}}`
//   * `addNote {note:{deckName, modelName, fields, options, tags}}` → 自增 noteId；
//     重复时 error 文案与真 AnkiConnect 一字不差（`kAnkiConnectDuplicateError`）
//   * `canAddNotes` → `[bool]`；`canAddNotesWithErrorDetail` → `[{canAdd, error?}]`
//     （查重 `isDuplicateForAdd` 走的是后者）
//   * `findNotes {query}` / `findCards {query}` / `guiBrowse {query}`：
//     支持本仓实际发出的几种搜索式——`deck:"X" "Field:value"`（findNotesByField）、
//     `(did:a OR did:b) ("dupe:mid,text" OR …)`（ankiDuplicateSearchQuery）、
//     `nid:a,b,c`（guiBrowse）、`did:N is:new -deck:filtered`（重排）、
//     `"<文件名>"` / `sourceId=…` 裸文本（媒体去重 / 来源反查）
//   * `notesInfo {notes:[id]}` → `[{noteId, modelName, tags, fields:{name:{value, order}}, cards}]`，
//     不存在的 note 回 `{}`；`cardsInfo {cards:[id]}` 同理（`AnkiCardInfo.fromJson` 认的键）
//   * `updateNoteFields {note:{id, fields}}` / `addTags {notes, tags}` /
//     `setSpecificValueOfCard {card, keys, newValues}` → `[true]`
//   * `storeMediaFile {filename, data|path}` / `deleteMediaFile` / `getMediaFilesNames {pattern}` /
//     `getMediaDirPath`（真的落在一个临时目录里，`close()` 时删除）
//   * `multi {actions:[{action, version, params}]}` 逐条分发，子项带 version 就回
//     `{result, error}` 信封、不带就回裸值——与插件 `format_success_reply` 同口径
//
// 未知 action 回 `{"result": null, "error": "unsupported: <action>"}`。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_anki/fushi_anki_core.dart'
    show LapisNoteType, kAnkiConnectDuplicateError;

/// 一个假 AnkiConnect 实例。用 [FakeAnkiConnect.start] 起，完了 [close]。
class FakeAnkiConnect {
  FakeAnkiConnect._({
    required HttpServer server,
    required this.deckName,
    required this.apiKey,
    required Directory mediaDir,
  }) : _server = server,
       _mediaDir = mediaDir {
    _decks['Default'] = 1;
    _decks[deckName] = _kDeckIdBase;
    _models[modelName] = _FakeModel(
      id: _kModelIdBase,
      name: modelName,
      fields: List<String>.of(LapisNoteType.fields),
      templates: <String, Map<String, String>>{
        LapisNoteType.cardName: <String, String>{
          'Front': LapisNoteType.front,
          'Back': LapisNoteType.back,
        },
      },
      css: LapisNoteType.css,
    );
    // 第二个非 Lapis 笔记类型：让 `selectNoteTypeAfterFetch` 的「按 Lapis 匹配」
    // 与 addNote 的 `checkAllModels` 都有东西可跨。
    _models['Basic'] = _FakeModel(
      id: _kModelIdBase + 1,
      name: 'Basic',
      fields: <String>['Front', 'Back'],
      templates: <String, Map<String, String>>{
        'Card 1': <String, String>{
          'Front': '{{Front}}',
          'Back': '{{FrontSide}}<hr id=answer>{{Back}}',
        },
      },
      css: '.card { font-family: arial; }',
    );
    _subscription = _server.listen(_onRequest);
  }

  static const int _kDeckIdBase = 1700000000001;
  static const int _kModelIdBase = 1700000000010;

  /// 默认卡组名（`deckNames` 里除 `Default` 外的那一个）。
  final String deckName;

  /// 默认笔记类型名 = app 出厂 Lapis 模板名（`LapisNoteType.modelName`），
  /// 字段清单 = `LapisNoteType.fields`，于是「获取」后 `LapisPreset.matches` 命中、
  /// 字段映射自动套 Lapis 默认。
  String get modelName => LapisNoteType.modelName;

  /// 非空时每个请求（含 `multi` 子项）必须带同值 `key`，否则回
  /// `valid api key must be provided`（真插件文案）。
  final String apiKey;

  final HttpServer _server;
  final Directory _mediaDir;
  late final StreamSubscription<HttpRequest> _subscription;

  final Map<String, int> _decks = <String, int>{};
  final Map<String, _FakeModel> _models = <String, _FakeModel>{};
  int _nextNoteId = DateTime.now().millisecondsSinceEpoch;
  bool _closed = false;

  /// 收到的每个顶层请求体（解码后的 JSON 对象，`{action, version, params?, key?}`），
  /// 按到达顺序。`multi` 的子项不单独登记，在其 `params.actions` 里。
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  /// 已加进来的 notes，按 `addNote` 顺序。每条：
  /// `{noteId, cardId, deckName, modelName, fields: Map<String,String>, tags: List<String>, due}`。
  /// `updateNoteFields` / `addTags` / `setSpecificValueOfCard` 原地改这里的 map。
  final List<Map<String, Object?>> notes = <Map<String, Object?>>[];

  int get port => _server.port;

  /// `http://127.0.0.1:<port>`。
  Uri get uri => Uri(scheme: 'http', host: _server.address.address, port: port);

  /// `getMediaDirPath` 回的真实目录。
  String get mediaDirPath => _mediaDir.path;

  /// 当前媒体目录里的文件名（`storeMediaFile` 写进来的）。
  List<String> get mediaFileNames => _mediaDir.existsSync()
      ? (_mediaDir
            .listSync()
            .whereType<File>()
            .map((File f) => f.uri.pathSegments.last)
            .toList()
          ..sort())
      : const <String>[];

  /// 顶层 [requests] 里 action 为 [action] 的那些；`multi` 子项也展开计入。
  List<Map<String, Object?>> requestsFor(String action) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final Map<String, Object?> r in requests) {
      if (r['action'] == action) out.add(r);
      if (r['action'] == 'multi') {
        final Object? params = r['params'];
        final Object? actions = params is Map ? params['actions'] : null;
        if (actions is List) {
          for (final Object? sub in actions) {
            if (sub is Map && sub['action'] == action) {
              out.add(Map<String, Object?>.from(sub));
            }
          }
        }
      }
    }
    return out;
  }

  /// 在 loopback 随机端口起服务。
  static Future<FakeAnkiConnect> start({
    String deckName = 'FushiItest',
    String apiKey = '',
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Directory mediaDir = await Directory.systemTemp.createTemp(
      'fake_ankiconnect_media_',
    );
    return FakeAnkiConnect._(
      server: server,
      deckName: deckName,
      apiKey: apiKey,
      mediaDir: mediaDir,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close(force: true);
    if (_mediaDir.existsSync()) {
      await _mediaDir.delete(recursive: true);
    }
  }

  // ── HTTP 层 ────────────────────────────────────────────────────────────

  Future<void> _onRequest(HttpRequest request) async {
    try {
      if (request.method != 'POST') {
        // 真插件对 GET 回一个纯文本落地页；本仓不依赖它。
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write('AnkiConnect v.6 (fake)');
        await request.response.close();
        return;
      }
      final String body = await utf8.decoder.bind(request).join();
      Object? decoded;
      Map<String, Object?>? envelope;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map) {
        envelope = Map<String, Object?>.from(decoded);
        requests.add(envelope);
      }
      final Object? reply = envelope == null
          ? <String, Object?>{'result': null, 'error': 'invalid request body'}
          : _reply(envelope);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.connectionHeader, 'close')
        ..write(jsonEncode(reply));
      await request.response.close();
    } catch (error) {
      // 处理器自己炸了也要把连接收尾，不然客户端要等到超时。
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('fake ankiconnect crashed: $error');
        await request.response.close();
      } catch (_) {
        // 连接已断，无事可做。
      }
    }
  }

  /// 一条请求（顶层或 `multi` 子项）→ 应答值。带 `version` 回 `{result, error}`
  /// 信封；不带回裸结果（失败时仍回信封，与插件 `format_exception_reply` 同）。
  Object? _reply(Map<String, Object?> envelope) {
    final bool versioned = envelope.containsKey('version');
    try {
      final Object? result = _dispatch(envelope);
      return versioned
          ? <String, Object?>{'result': result, 'error': null}
          : result;
    } on _AnkiError catch (e) {
      return <String, Object?>{'result': null, 'error': e.message};
    }
  }

  Object? _dispatch(Map<String, Object?> envelope) {
    final String action = envelope['action']?.toString() ?? '';
    if (apiKey.isNotEmpty && envelope['key'] != apiKey) {
      throw _AnkiError('valid api key must be provided');
    }
    final Object? rawParams = envelope['params'];
    final Map<String, Object?> params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : <String, Object?>{};
    switch (action) {
      case 'version':
        return 6;
      case 'requestPermission':
        return <String, Object?>{
          'permission': 'granted',
          'requireApiKey': apiKey.isNotEmpty,
          'version': 6,
        };
      case 'deckNames':
        return _decks.keys.toList();
      case 'deckNamesAndIds':
        return Map<String, Object?>.from(_decks);
      case 'createDeck':
        final String name = _requireString(params, 'deck');
        return _decks[name] ??= _kDeckIdBase + _decks.length;
      case 'modelNames':
        return _models.keys.toList();
      case 'modelNamesAndIds':
        return <String, Object?>{
          for (final _FakeModel m in _models.values) m.name: m.id,
        };
      case 'modelFieldNames':
        return List<String>.of(
          _model(_requireString(params, 'modelName')).fields,
        );
      case 'modelTemplates':
        final _FakeModel m = _model(_requireString(params, 'modelName'));
        return <String, Object?>{
          for (final MapEntry<String, Map<String, String>> e
              in m.templates.entries)
            e.key: Map<String, Object?>.from(e.value),
        };
      case 'modelStyling':
        return <String, Object?>{
          'css': _model(_requireString(params, 'modelName')).css,
        };
      case 'createModel':
        return _createModel(params);
      case 'updateModelTemplates':
        _updateModelTemplates(params);
        return null;
      case 'updateModelStyling':
        _updateModelStyling(params);
        return null;
      case 'addNote':
        return _addNote(params);
      case 'canAddNotes':
        return <Object?>[
          for (final Object? n in _requireList(params, 'notes'))
            _noteRejection(n is Map ? Map<String, Object?>.from(n) : null) ==
                null,
        ];
      case 'canAddNotesWithErrorDetail':
        return <Object?>[
          for (final Object? n in _requireList(params, 'notes'))
            _canAddDetail(n is Map ? Map<String, Object?>.from(n) : null),
        ];
      case 'findNotes':
        return _findNotes(
          params['query']?.toString() ?? '',
        ).map((Map<String, Object?> n) => n['noteId']).toList();
      case 'findCards':
        return _findNotes(
          params['query']?.toString() ?? '',
        ).map((Map<String, Object?> n) => n['cardId']).toList();
      case 'guiBrowse':
        return _findNotes(
          params['query']?.toString() ?? '',
        ).map((Map<String, Object?> n) => n['cardId']).toList();
      case 'notesInfo':
        return <Object?>[
          for (final Object? id in _requireList(params, 'notes'))
            _noteInfo(_asInt(id)),
        ];
      case 'cardsInfo':
        return <Object?>[
          for (final Object? id in _requireList(params, 'cards'))
            _cardInfo(_asInt(id)),
        ];
      case 'updateNoteFields':
        _updateNoteFields(params);
        return null;
      case 'addTags':
        _addTags(params);
        return null;
      case 'setSpecificValueOfCard':
        return _setSpecificValueOfCard(params);
      case 'storeMediaFile':
        return _storeMediaFile(params);
      case 'deleteMediaFile':
        final File f = File(_mediaPath(_requireString(params, 'filename')));
        if (f.existsSync()) f.deleteSync();
        return null;
      case 'getMediaFilesNames':
        final RegExp re = _globToRegExp(params['pattern']?.toString() ?? '*');
        return mediaFileNames.where(re.hasMatch).toList();
      case 'getMediaDirPath':
        return _mediaDir.path;
      case 'multi':
        return <Object?>[
          for (final Object? sub in _requireList(params, 'actions'))
            sub is Map
                ? _reply(Map<String, Object?>.from(sub))
                : <String, Object?>{
                    'result': null,
                    'error': 'invalid multi action',
                  },
        ];
      case 'sync':
        return null;
      default:
        throw _AnkiError('unsupported: $action');
    }
  }

  // ── 笔记类型 ───────────────────────────────────────────────────────────

  _FakeModel _model(String name) {
    final _FakeModel? m = _models[name];
    if (m == null) throw _AnkiError('model was not found: $name');
    return m;
  }

  Map<String, Object?> _createModel(Map<String, Object?> params) {
    final String name = _requireString(params, 'modelName');
    if (_models.containsKey(name)) {
      throw _AnkiError('Model name already exists');
    }
    final List<String> fields = <String>[
      for (final Object? f in _requireList(params, 'inOrderFields'))
        f.toString(),
    ];
    final Map<String, Map<String, String>> templates =
        <String, Map<String, String>>{};
    final Object? rawTemplates = params['cardTemplates'];
    if (rawTemplates is List) {
      for (int i = 0; i < rawTemplates.length; i++) {
        final Object? t = rawTemplates[i];
        if (t is! Map) continue;
        final String tplName = t['Name']?.toString() ?? 'Card ${i + 1}';
        templates[tplName] = <String, String>{
          'Front': t['Front']?.toString() ?? '',
          'Back': t['Back']?.toString() ?? '',
        };
      }
    }
    final _FakeModel m = _FakeModel(
      id: _kModelIdBase + _models.length,
      name: name,
      fields: fields,
      templates: templates,
      css: params['css']?.toString() ?? '',
    );
    _models[name] = m;
    return <String, Object?>{'id': m.id, 'name': m.name, 'flds': fields};
  }

  Map<String, Object?> _requireModelParam(Map<String, Object?> params) {
    final Object? model = params['model'];
    if (model is! Map) throw _AnkiError('model was not provided');
    return Map<String, Object?>.from(model);
  }

  void _updateModelTemplates(Map<String, Object?> params) {
    final Map<String, Object?> model = _requireModelParam(params);
    final _FakeModel m = _model(model['name']?.toString() ?? '');
    final Object? templates = model['templates'];
    if (templates is! Map) throw _AnkiError('templates were not provided');
    templates.forEach((Object? tplName, Object? sides) {
      final Map<String, String> target = m.templates[tplName.toString()] ??=
          <String, String>{};
      if (sides is Map) {
        if (sides.containsKey('Front')) {
          target['Front'] = sides['Front']?.toString() ?? '';
        }
        if (sides.containsKey('Back')) {
          target['Back'] = sides['Back']?.toString() ?? '';
        }
      }
    });
  }

  void _updateModelStyling(Map<String, Object?> params) {
    final Map<String, Object?> model = _requireModelParam(params);
    final _FakeModel m = _model(model['name']?.toString() ?? '');
    m.css = model['css']?.toString() ?? '';
  }

  // ── notes ──────────────────────────────────────────────────────────────

  int _addNote(Map<String, Object?> params) {
    final Object? rawNote = params['note'];
    final Map<String, Object?>? note = rawNote is Map
        ? Map<String, Object?>.from(rawNote)
        : null;
    final String? rejection = _noteRejection(note);
    if (rejection != null) throw _AnkiError(rejection);
    final Map<String, Object?> n = note!;
    final _FakeModel model = _model(n['modelName']!.toString());
    final Map<String, String> fields = <String, String>{
      for (final String f in model.fields) f: '',
    };
    final Object? rawFields = n['fields'];
    if (rawFields is Map) {
      rawFields.forEach((Object? k, Object? v) {
        // 真 Anki 静默丢弃笔记类型里不存在的字段名（BUG-1900 说的就是这个）。
        if (fields.containsKey(k.toString())) {
          fields[k.toString()] = v?.toString() ?? '';
        }
      });
    }
    final Object? rawTags = n['tags'];
    final List<String> tags = <String>[
      if (rawTags is List)
        for (final Object? t in rawTags) t.toString(),
    ];
    final int noteId = _nextNoteId;
    _nextNoteId += 2;
    notes.add(<String, Object?>{
      'noteId': noteId,
      'cardId': noteId + 1,
      'deckName': n['deckName']!.toString(),
      'modelName': model.name,
      'fields': fields,
      'tags': tags,
      'due': notes.length + 1,
    });
    return noteId;
  }

  Map<String, Object?> _canAddDetail(Map<String, Object?>? note) {
    final String? rejection = _noteRejection(note);
    return rejection == null
        ? <String, Object?>{'canAdd': true}
        : <String, Object?>{'canAdd': false, 'error': rejection};
  }

  /// `addNote` / `canAddNotes*` 共用的一条判据（与真插件同：两者都走
  /// `createNote` 那段校验，文案完全一样）。null = 能加。
  String? _noteRejection(Map<String, Object?>? note) {
    if (note == null) return 'note was not provided';
    final String modelName = note['modelName']?.toString() ?? '';
    final _FakeModel? model = _models[modelName];
    if (model == null) return 'model was not found: $modelName';
    final String deckName = note['deckName']?.toString() ?? '';
    if (!_decks.containsKey(deckName)) return 'deck was not found: $deckName';
    final Object? rawFields = note['fields'];
    final String firstValue = rawFields is Map
        ? _stripHtml(rawFields[model.fields.first]?.toString() ?? '')
        : '';
    if (firstValue.isEmpty) return 'cannot create note because it is empty';

    final Object? rawOptions = note['options'];
    final Map<String, Object?> options = rawOptions is Map
        ? Map<String, Object?>.from(rawOptions)
        : <String, Object?>{};
    if (options['allowDuplicate'] == true) return null;
    final bool collectionWide = options['duplicateScope'] == 'collection';
    final Object? rawScopeOptions = options['duplicateScopeOptions'];
    final Map<String, Object?> scopeOptions = rawScopeOptions is Map
        ? Map<String, Object?>.from(rawScopeOptions)
        : <String, Object?>{};
    final String scopeDeck =
        scopeOptions['deckName']?.toString().trim().isNotEmpty == true
        ? scopeOptions['deckName']!.toString()
        : deckName;
    final bool checkChildren = scopeOptions['checkChildren'] == true;
    final bool checkAllModels = scopeOptions['checkAllModels'] == true;
    for (final Map<String, Object?> existing in notes) {
      if (!checkAllModels && existing['modelName'] != model.name) continue;
      if (!collectionWide &&
          !_deckInScope(
            existing['deckName'].toString(),
            scopeDeck,
            includeChildren: checkChildren,
          )) {
        continue;
      }
      if (_firstFieldText(existing) == firstValue) {
        return kAnkiConnectDuplicateError;
      }
    }
    return null;
  }

  static bool _deckInScope(
    String noteDeck,
    String scopeDeck, {
    required bool includeChildren,
  }) =>
      noteDeck == scopeDeck ||
      (includeChildren && noteDeck.startsWith('$scopeDeck::'));

  String _firstFieldText(Map<String, Object?> note) {
    final _FakeModel? model = _models[note['modelName'].toString()];
    final Map<String, String> fields = _fieldsOf(note);
    if (model == null || model.fields.isEmpty) return '';
    return _stripHtml(fields[model.fields.first] ?? '');
  }

  static Map<String, String> _fieldsOf(Map<String, Object?> note) =>
      note['fields']! as Map<String, String>;

  static List<String> _tagsOf(Map<String, Object?> note) =>
      note['tags']! as List<String>;

  Map<String, Object?>? _noteById(int? id) {
    if (id == null) return null;
    for (final Map<String, Object?> n in notes) {
      if (n['noteId'] == id) return n;
    }
    return null;
  }

  Map<String, Object?>? _noteByCardId(int? id) {
    if (id == null) return null;
    for (final Map<String, Object?> n in notes) {
      if (n['cardId'] == id) return n;
    }
    return null;
  }

  Map<String, Object?> _noteInfo(int? id) {
    final Map<String, Object?>? n = _noteById(id);
    if (n == null) return <String, Object?>{};
    final _FakeModel model = _model(n['modelName'].toString());
    final Map<String, String> fields = _fieldsOf(n);
    return <String, Object?>{
      'noteId': n['noteId'],
      'profile': 'User 1',
      'modelName': model.name,
      'tags': List<String>.of(_tagsOf(n)),
      'fields': <String, Object?>{
        for (int i = 0; i < model.fields.length; i++)
          model.fields[i]: <String, Object?>{
            'value': fields[model.fields[i]] ?? '',
            'order': i,
          },
      },
      'mod': n['noteId'],
      'cards': <Object?>[n['cardId']],
    };
  }

  Map<String, Object?> _cardInfo(int? id) {
    final Map<String, Object?>? n = _noteByCardId(id);
    if (n == null) return <String, Object?>{};
    final _FakeModel model = _model(n['modelName'].toString());
    final Map<String, String> fields = _fieldsOf(n);
    return <String, Object?>{
      'cardId': n['cardId'],
      'note': n['noteId'],
      'ord': 0,
      'due': n['due'],
      'type': 0,
      'queue': 0,
      'interval': 0,
      'reps': 0,
      'lapses': 0,
      'modelName': model.name,
      'deckName': n['deckName'],
      'fields': <String, Object?>{
        for (int i = 0; i < model.fields.length; i++)
          model.fields[i]: <String, Object?>{
            'value': fields[model.fields[i]] ?? '',
            'order': i,
          },
      },
    };
  }

  void _updateNoteFields(Map<String, Object?> params) {
    final Object? rawNote = params['note'];
    if (rawNote is! Map) throw _AnkiError('note was not provided');
    final int? id = _asInt(rawNote['id']);
    final Map<String, Object?>? n = _noteById(id);
    if (n == null) throw _AnkiError('note was not found: $id');
    final Map<String, String> fields = _fieldsOf(n);
    final Object? incoming = rawNote['fields'];
    if (incoming is Map) {
      incoming.forEach((Object? k, Object? v) {
        if (fields.containsKey(k.toString())) {
          fields[k.toString()] = v?.toString() ?? '';
        }
      });
    }
  }

  void _addTags(Map<String, Object?> params) {
    final List<String> incoming = (params['tags']?.toString() ?? '')
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        .toList();
    for (final Object? rawId in _requireList(params, 'notes')) {
      final Map<String, Object?>? n = _noteById(_asInt(rawId));
      if (n == null) continue;
      final List<String> tags = _tagsOf(n);
      for (final String t in incoming) {
        if (!tags.contains(t)) tags.add(t);
      }
    }
  }

  /// 与插件同形：成功 `[true]`；卡不存在 `[[false, "<msg>"]]`；参数形状不对裸 `false`。
  Object? _setSpecificValueOfCard(Map<String, Object?> params) {
    final Object? keys = params['keys'];
    final Object? values = params['newValues'];
    if (keys is! List || values is! List || keys.length != values.length) {
      return false;
    }
    final Map<String, Object?>? n = _noteByCardId(_asInt(params['card']));
    if (n == null) {
      return <Object?>[
        <Object?>[false, 'card was not found: ${params['card']}'],
      ];
    }
    for (int i = 0; i < keys.length; i++) {
      if (keys[i].toString() == 'due') {
        n['due'] = _asInt(values[i]) ?? n['due'];
      }
    }
    return <Object?>[true];
  }

  // ── 搜索式 ─────────────────────────────────────────────────────────────

  List<Map<String, Object?>> _findNotes(String query) {
    final List<String> tokens = _tokenize(query);
    if (tokens.isEmpty) return List<Map<String, Object?>>.of(notes);
    return <Map<String, Object?>>[
      for (final Map<String, Object?> n in notes)
        if (_QueryEvaluator(this, tokens, n).evaluate()) n,
    ];
  }

  /// 按空白切 token，引号里的空白不切，`(` / `)` 各自成 token。
  static List<String> _tokenize(String query) {
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    bool inQuote = false;
    void flush() {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    }

    for (int i = 0; i < query.length; i++) {
      final String c = query[i];
      if (inQuote) {
        if (c == r'\' && i + 1 < query.length) {
          buf.write(query[i + 1]);
          i++;
          continue;
        }
        if (c == '"') {
          inQuote = false;
          continue;
        }
        buf.write(c);
        continue;
      }
      if (c == '"') {
        inQuote = true;
        continue;
      }
      if (c == '(' || c == ')') {
        flush();
        out.add(c);
        continue;
      }
      if (c.trim().isEmpty) {
        flush();
        continue;
      }
      buf.write(c);
    }
    flush();
    return out;
  }

  /// 一个原子搜索项是否命中 [note]（Anki 搜索语法子集）。
  bool _matchesAtom(String atom, Map<String, Object?> note) {
    final int colon = atom.indexOf(':');
    if (colon > 0) {
      final String key = atom.substring(0, colon);
      final String value = atom.substring(colon + 1);
      switch (key.toLowerCase()) {
        case 'deck':
          if (value.toLowerCase() == 'filtered') return false;
          final RegExp re = _globToRegExp(value, ankiStyle: true);
          final String deck = note['deckName'].toString();
          // Anki 的 `deck:X` 含 X 的子卡组，不含父/兄弟卡组。
          return re.hasMatch(deck) || _deckChildOf(deck, value);
        case 'did':
          final int? id = int.tryParse(value);
          return id != null && _decks[note['deckName'].toString()] == id;
        case 'nid':
          return value
              .split(',')
              .any((String s) => _asInt(s) == note['noteId']);
        case 'cid':
          return value
              .split(',')
              .any((String s) => _asInt(s) == note['cardId']);
        case 'mid':
          return _models[note['modelName'].toString()]?.id ==
              int.tryParse(value);
        case 'note':
          return note['modelName'].toString().toLowerCase() ==
              value.toLowerCase();
        case 'dupe':
          final int comma = value.indexOf(',');
          if (comma < 0) return false;
          final int? mid = int.tryParse(value.substring(0, comma));
          final String text = value.substring(comma + 1);
          return _models[note['modelName'].toString()]?.id == mid &&
              _firstFieldText(note) == text;
        case 'tag':
          final RegExp re = _globToRegExp(value, ankiStyle: true);
          return _tagsOf(note).any(re.hasMatch);
        case 'is':
          // 假库里所有卡都是新卡、没复习过；`is:new` 恒真，其它状态恒假。
          return value.toLowerCase() == 'new';
        default:
          // `Field:value`：字段名（大小写不敏感）命中就按字段值整串匹配。
          final Map<String, String> fields = _fieldsOf(note);
          for (final MapEntry<String, String> e in fields.entries) {
            if (e.key.toLowerCase() == key.toLowerCase()) {
              return _globToRegExp(
                value,
                ankiStyle: true,
              ).hasMatch(_stripHtml(e.value));
            }
          }
          // 不是字段名：整个 token 当裸文本。
          return _anyFieldContains(note, atom);
      }
    }
    return _anyFieldContains(note, atom);
  }

  static bool _deckChildOf(String deck, String parent) =>
      deck.toLowerCase().startsWith('${parent.toLowerCase()}::');

  static bool _anyFieldContains(Map<String, Object?> note, String text) {
    final String needle = text.toLowerCase();
    return _fieldsOf(
      note,
    ).values.any((String v) => v.toLowerCase().contains(needle));
  }

  // ── 媒体 ───────────────────────────────────────────────────────────────

  String _mediaPath(String filename) =>
      '${_mediaDir.path}${Platform.pathSeparator}$filename';

  String _storeMediaFile(Map<String, Object?> params) {
    final String filename = _requireString(params, 'filename');
    final File target = File(_mediaPath(filename));
    final Object? data = params['data'];
    final Object? path = params['path'];
    if (data is String) {
      target.writeAsBytesSync(base64Decode(data));
    } else if (path is String) {
      final File source = File(path);
      if (!source.existsSync()) {
        throw _AnkiError('file not found: $path');
      }
      source.copySync(target.path);
    } else {
      throw _AnkiError('one of data, path or url must be provided');
    }
    return filename;
  }

  // ── 小工具 ─────────────────────────────────────────────────────────────

  static String _requireString(Map<String, Object?> params, String key) {
    final Object? v = params[key];
    if (v is! String) throw _AnkiError('$key was not provided');
    return v;
  }

  static List<Object?> _requireList(Map<String, Object?> params, String key) {
    final Object? v = params[key];
    if (v is! List) throw _AnkiError('$key was not provided');
    return v;
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? ''));

  static String _stripHtml(String html) =>
      html.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  /// `*` → 任意串；[ankiStyle] 再把 `_` 当单字符（Anki 搜索通配）。整串匹配，
  /// 大小写不敏感。
  static RegExp _globToRegExp(String glob, {bool ankiStyle = false}) {
    final StringBuffer sb = StringBuffer('^');
    for (int i = 0; i < glob.length; i++) {
      final String c = glob[i];
      if (c == '*') {
        sb.write('.*');
      } else if (ankiStyle && c == '_') {
        sb.write('.');
      } else {
        sb.write(RegExp.escape(c));
      }
    }
    sb.write(r'$');
    return RegExp(sb.toString(), caseSensitive: false);
  }
}

class _FakeModel {
  _FakeModel({
    required this.id,
    required this.name,
    required this.fields,
    required this.templates,
    required this.css,
  });

  final int id;
  final String name;
  final List<String> fields;
  final Map<String, Map<String, String>> templates;
  String css;
}

class _AnkiError implements Exception {
  _AnkiError(this.message);
  final String message;
}

/// 递归下降求值：`expr := and (OR and)*`，`and := term+`，
/// `term := '(' expr ')' | '-' term | atom`。每个 note 单独跑一遍（数据量极小）。
class _QueryEvaluator {
  _QueryEvaluator(this._server, this._tokens, this._note);

  final FakeAnkiConnect _server;
  final List<String> _tokens;
  final Map<String, Object?> _note;
  int _pos = 0;

  bool evaluate() => _or();

  String? get _peek => _pos < _tokens.length ? _tokens[_pos] : null;

  bool _or() {
    bool acc = _and();
    while (_peek == 'OR' || _peek == 'or') {
      _pos++;
      final bool rhs = _and();
      acc = acc || rhs;
    }
    return acc;
  }

  bool _and() {
    bool acc = true;
    while (_peek != null && _peek != ')' && _peek != 'OR' && _peek != 'or') {
      final bool t = _term();
      acc = acc && t;
    }
    return acc;
  }

  bool _term() {
    final String tok = _tokens[_pos];
    if (tok == '(') {
      _pos++;
      final bool inner = _or();
      if (_peek == ')') _pos++;
      return inner;
    }
    if (tok == ')') {
      // 多出来的右括号：跳过，别死循环。
      _pos++;
      return true;
    }
    _pos++;
    if (tok.startsWith('-') && tok.length > 1) {
      return !_server._matchesAtom(tok.substring(1), _note);
    }
    return _server._matchesAtom(tok, _note);
  }
}
