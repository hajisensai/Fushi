import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../anki_models.dart';
import '../anki_note_type_definition.dart';
import '../lapis_note_type.dart';

class AnkiConnectService {
  final String host;
  final int port;

  /// Whether this endpoint runs on the same machine and can read a local path
  /// passed to AnkiConnect's `storeMediaFile`.
  bool get canReadLocalMediaPaths => ankiConnectHostIsLoopback(host);

  /// AnkiConnect API key. When the AnkiConnect add-on has `apiKey` configured,
  /// every request must carry a matching `key`; otherwise it replies with
  /// "valid api key must be provided". Empty means no key (the default).
  final String apiKey;

  /// Injected transport, or null to build [_defaultClient] lazily on first use.
  final http.Client? _injectedClient;

  /// Overall per-request budget (connect + send + receive). A reachable
  /// AnkiConnect answers findNotes/addNote well under a second; 10s tolerates a
  /// busy collection or a mid-sync Anki without hanging a mine indefinitely.
  final Duration _timeout;

  /// Connection-establishment budget for the lazily-built default client
  /// (BUG-665). A live AnkiConnect (localhost/LAN) connects near-instantly, so
  /// 5s is generous while still failing an unreachable host fast.
  final Duration _connectionTimeout;

  http.Client? _builtDefaultClient;

  /// The transport. The default client is built on the **first request**, not
  /// in the constructor, so subclasses that override the network methods — and
  /// tests that install an HttpOverrides fake for the separate remote-audio
  /// `HttpClient()` — never trigger a real [HttpClient] at construction time.
  http.Client get _client =>
      _injectedClient ??
      (_builtDefaultClient ??= _defaultClient(_connectionTimeout));

  AnkiConnectService({
    this.host = 'localhost',
    this.port = 8765,
    this.apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
    Duration connectionTimeout = const Duration(seconds: 5),
  })  : _injectedClient = client,
        _timeout = timeout,
        _connectionTimeout = connectionTimeout;

  /// Default HTTP client with an explicit **connection-establishment** timeout.
  ///
  /// BUG-665: the bare `http.Client()` had no connection timeout, so when the
  /// configured AnkiConnect host is unreachable/black-holed (wrong host, VPN
  /// down, firewall dropping SYNs, a remote host that never answers) the connect
  /// phase dangled up to the full [_timeout] response budget before the combined
  /// `.timeout` killed it as an opaque `TimeoutException: Future not completed`.
  /// Bounding the connect phase separately (mirrors [syncHttpClient] in
  /// sync_http.dart) makes an unreachable host fail fast with a clean
  /// SocketException — classified as a connection error with an actionable
  /// "is Anki running?" hint — instead of making a remote/extension mine wait
  /// the whole response budget on every doomed AnkiConnect call.
  static http.Client _defaultClient(Duration connectionTimeout) =>
      IOClient(HttpClient()..connectionTimeout = connectionTimeout);

  Future<dynamic> _request(String action,
      [Map<String, dynamic>? params]) async {
    final body = jsonEncode({
      'action': action,
      'version': 6,
      if (params != null) 'params': params,
      // Only send `key` when configured: AnkiConnect with no apiKey set does
      // not expect the field, and sending an empty one is needless.
      if (apiKey.isNotEmpty) 'key': apiKey,
    });
    final response = await _postWithStaleConnectionRetry(
      body,
      action: action,
      idempotent: !_nonIdempotentActions.contains(action),
    );
    // A process other than AnkiConnect (proxy, captive portal, wrong port)
    // can answer with a non-200 or non-JSON body; surface a clear error
    // instead of an opaque FormatException.
    if (response.statusCode != 200) {
      throw AnkiConnectException(
        'AnkiConnect returned HTTP ${response.statusCode} from $host:$port '
        '(is AnkiConnect listening on this port?)',
      );
    }
    final dynamic result;
    try {
      result = jsonDecode(response.body);
    } on FormatException {
      throw AnkiConnectException(
        'Invalid (non-JSON) response from $host:$port — not AnkiConnect?',
      );
    }
    // The v6 contract guarantees an object with both 'result' and 'error'.
    if (result is! Map ||
        !result.containsKey('result') ||
        !result.containsKey('error')) {
      throw AnkiConnectException(
        'Unexpected response shape from AnkiConnect (action: $action)',
      );
    }
    if (result['error'] != null) {
      final String message = result['error'].toString();
      if (action == 'addNote' &&
          message == 'cannot create note because it is a duplicate') {
        throw AnkiConnectDuplicateException(message);
      }
      throw AnkiConnectException(message);
    }
    return result['result'];
  }

  /// Actions that mutate Anki state and are NOT safe to *blindly* re-send.
  /// package:http wraps the write *and* the response-header read in one try, so
  /// a connection drop can surface *after* the request reached AnkiConnect —
  /// re-sending `addNote`/`createModel` would then create a duplicate card or
  /// hit "model already exists". So we retry these only on a *pre-delivery
  /// write failure* (the request provably never left the client — see
  /// [_isPreDeliveryWriteFailure] / BUG-091), never on a response-phase drop.
  /// Every other action (version/deckNames/modelNames/modelFieldNames/
  /// findNotes/storeMediaFile/createDeck) is idempotent, so re-sending on any
  /// connection drop has no side effect.
  static const Set<String> _nonIdempotentActions = {'addNote', 'createModel'};

  /// Posts [body] to AnkiConnect, retrying exactly once on a dropped connection
  /// — but only when [idempotent].
  ///
  /// BUG-065: AnkiConnect's minimal HTTP server closes idle keep-alive
  /// connections. The persistent [http.Client] pools connections and can hand a
  /// request one the server has already closed; the first use fails with a
  /// connection-drop error (Windows errno=10053 WSAECONNABORTED / 10054
  /// WSAECONNRESET, POSIX EPIPE/ECONNRESET — surfaced as "Write failed",
  /// "Connection reset", "Broken pipe"), so the user sees an instant failure
  /// rather than the 10s timeout. Re-issuing on a fresh connection (the dead one
  /// is dropped from the pool) fixes it. This is the standard "retry an
  /// idempotent request on a stale pooled connection" strategy (cf. Go net/http,
  /// java.net.http). Genuine refusals/timeouts are not connection-drops and fall
  /// through to the caller (a retry would not help).
  ///
  /// BUG-091: idempotent actions retry on *any* connection drop. Non-idempotent
  /// actions (addNote/createModel) retry only on a *pre-delivery write failure*
  /// — when the `write()` itself failed, the request bytes never reached
  /// AnkiConnect, so no note/model was created and re-sending cannot duplicate.
  /// A response-phase drop (write succeeded, the read reset) is still surfaced,
  /// because the server may already have processed the request. This fixes the
  /// real failure where the first mine after an idle period reuses a stale
  /// pooled socket → instant "Write failed (errno 10053)" with no retry.
  Future<http.Response> _postWithStaleConnectionRetry(
    String body, {
    required String action,
    required bool idempotent,
  }) async {
    try {
      return await _post(body);
    } on http.ClientException catch (e) {
      final bool retryable =
          idempotent ? _isConnectionDrop(e) : _isPreDeliveryWriteFailure(e);
      if (retryable) {
        try {
          return await _post(body);
        } on http.ClientException catch (retryError) {
          if (!idempotent &&
              _isConnectionDrop(retryError) &&
              !_isPreDeliveryWriteFailure(retryError)) {
            throw AnkiConnectCommitUnknownException(action, retryError);
          }
          rethrow;
        }
      }
      if (!idempotent &&
          _isConnectionDrop(e) &&
          !_isPreDeliveryWriteFailure(e)) {
        throw AnkiConnectCommitUnknownException(action, e);
      }
      rethrow;
    }
  }

  /// True only for a connection drop that happened *while writing the request*,
  /// proving the server never received a complete request — so re-sending even
  /// a non-idempotent action (addNote/createModel) cannot create a duplicate.
  ///
  /// dart:io raises "Write failed" from the `write()` syscall path and "Broken
  /// pipe" (EPIPE) when the peer closed its read end mid-write; both mean the
  /// request was not delivered. A response-phase reset surfaces as "Connection
  /// reset"/"closed" without the write signature, and is deliberately NOT
  /// matched here (it could be post-delivery). The errno alone can't tell write
  /// from read phase, so this gates on the message text — the only reliable
  /// pre-/post-delivery discriminator.
  static bool _isPreDeliveryWriteFailure(http.ClientException e) {
    final String message = e.message.toLowerCase();
    return message.contains('write failed') || message.contains('broken pipe');
  }

  Future<http.Response> _post(String body) {
    return _client.post(
      Uri.parse('http://$host:$port'),
      body: body,
      headers: {
        'Content-Type': 'application/json',
        'Connection': 'close',
      },
    ).timeout(_timeout);
  }

  /// True when [e] is a transient connection-drop (stale pooled socket) worth
  /// one retry on a fresh connection. Prefers the OS error code — an ABI
  /// constant, stable across platforms and package:http versions — over the
  /// human-readable message, falling back to text only when no [OSError] is
  /// available. package:http wraps a dart:io [SocketException] in a type that
  /// implements both [http.ClientException] and [SocketException], so [osError]
  /// is usually reachable here.
  static bool _isConnectionDrop(http.ClientException e) {
    if (e is SocketException) {
      final int? code = (e as SocketException).osError?.errorCode;
      if (code != null) {
        // Win: 10053 WSAECONNABORTED, 10054 WSAECONNRESET.
        // POSIX: 32 EPIPE, 104 ECONNRESET (Linux), 54 ECONNRESET (macOS).
        return code == 10053 ||
            code == 10054 ||
            code == 32 ||
            code == 104 ||
            code == 54;
      }
    }
    final String message = e.message.toLowerCase();
    return message.contains('write failed') ||
        message.contains('connection reset') ||
        message.contains('broken pipe') ||
        message.contains('connection aborted');
  }

  List<String> _asStringList(dynamic result, String action) {
    if (result is! List) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for $action (expected a list)',
      );
    }
    return result.cast<String>();
  }

  Future<bool> isAvailable() async {
    try {
      await _request('version');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> checkConnection() async {
    try {
      await _request('version');
      return null;
    } on AnkiConnectException catch (e) {
      // AnkiConnect 自己的 error 字段 / HTTP / 非 JSON 形状错误：这是**真 AnkiConnect**
      // 的英文语义文本（如 'unauthorized'、'valid api key must be provided'），安全可
      // 直接展示在设置页，便于排障；不属于 TODO-752a 的 socket/proxy 乱码源。
      return e.message;
    } catch (e) {
      // socket / timeout / http 等连接层异常：按稳定码（TODO-752a）返回设置页用的
      // 英文提示——绝不把异常 toString() 透传（其中可能含 latin1 误解码的乱码）。
      final String code = classifyAnkiConnectError(e);
      return ankiConnectErrorHint(code, host: host, port: port);
    }
  }

  Future<List<String>> getDeckNames() async {
    return _asStringList(await _request('deckNames'), 'deckNames');
  }

  Future<List<String>> getModelNames() async {
    return _asStringList(await _request('modelNames'), 'modelNames');
  }

  Future<List<String>> getModelFields(String modelName) async {
    return _asStringList(
      await _request('modelFieldNames', {'modelName': modelName}),
      'modelFieldNames',
    );
  }

  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    // Let addNote perform the duplicate check atomically. AnkiConnect implements
    // this path as a first-field checksum lookup, whereas a separate findNotes
    // field query runs synchronously on Anki's GUI thread and can make Anki
    // appear frozen on a large/busy collection.
    final result = await _request('addNote', {
      'note': {
        'deckName': deckName,
        'modelName': modelName,
        'fields': fields,
        'options': _addNoteDuplicateOptions(
          deckName: deckName,
          allowDuplicate: allowDuplicate,
          scope: duplicateScope,
        ),
        if (tags != null) 'tags': tags,
      },
    });
    // A successful addNote returns the new note id. A null id with no error
    // means the add did not actually happen — treat it as a failure.
    if (result == null) {
      throw AnkiConnectException('AnkiConnect returned no note id for addNote');
    }
    return result is int ? result : int.tryParse(result.toString());
  }

  /// [scope] 默认 [AnkiDuplicateScope.deck]（= 旧行为：只查选中卡组及其子卡组），
  /// 所以未传该参数的旧调用点与测试行为逐字不变。
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
    AnkiDuplicateScope scope = AnkiDuplicateScope.deck,
  }) async {
    return (await findNotesByField(
      deckName: deckName,
      fieldName: fieldName,
      fieldValue: fieldValue,
      scope: scope,
    ))
        .isNotEmpty;
  }

  Future<List<int>> findNotesByField({
    required String deckName,
    required String fieldName,
    required String fieldValue,
    AnkiDuplicateScope scope = AnkiDuplicateScope.deck,
  }) async {
    final result = await _request('findNotes', {
      'query': _fieldValueQuery(
        deckName: deckName,
        fieldName: fieldName,
        fieldValue: fieldValue,
        scope: scope,
      ),
    });
    if (result is! List) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for findNotes (expected a list)',
      );
    }
    return result.map((dynamic id) {
      if (id is int) return id;
      return int.parse(id.toString());
    }).toList();
  }

  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    await _request('storeMediaFile', {
      'filename': filename,
      if (data != null) 'data': data,
      if (path != null) 'path': path,
    });
  }

  // ── 媒体维护（字节级去重）────────────────────────────────────────────
  // getMediaDirPath / findNotes 读取类幂等；deleteMediaFile 同名重删是 no-op，
  // 也幂等——均不列入 [_nonIdempotentActions]。

  /// Anki 当前 profile 的 collection.media 绝对路径（本机扫描用，避免把
  /// 整个媒体库经 base64 拉过 HTTP）。
  Future<String> getMediaDirPath() async {
    final result = await _request('getMediaDirPath');
    if (result is! String || result.isEmpty) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for getMediaDirPath',
      );
    }
    return result;
  }

  /// 删除媒体文件（按文件名）。只在引用已全部改写干净后调用。
  Future<void> deleteMediaFile(String filename) async {
    await _request('deleteMediaFile', {'filename': filename});
  }

  /// 按任意 Anki 搜索式查 note id（去重用 `"<文件名>"` 全字段文本检索）。
  Future<List<int>> findNotesByQuery(String query) async {
    final result = await _request('findNotes', {'query': query});
    if (result is! List) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for findNotes (expected a list)',
      );
    }
    return result.map((dynamic id) {
      if (id is int) return id;
      return int.parse(id.toString());
    }).toList();
  }

  Future<void> createModel(AnkiNoteTypeTemplate template) async {
    await _request('createModel', {
      'modelName': template.name,
      'inOrderFields': template.fields,
      'css': template.css,
      'isCloze': false,
      'cardTemplates': [
        {
          'Name': template.cardName,
          'Front': template.front,
          'Back': template.back,
        },
      ],
    });
  }

  Future<void> createDeck(String name) async {
    await _request('createDeck', {'deck': name});
  }

  // ── note type 模板读写（Lapis 客制化/备份/自动迁移）────────────────────
  // 读取类天然幂等；updateModelStyling / updateModelTemplates 同载荷重发结果
  // 一致，也幂等——都不列入 [_nonIdempotentActions]，掉线可安全重试。

  /// 读取 [modelName] 的全部卡模板正/反面。AnkiConnect `modelTemplates`
  /// 返回 `{模板名: {Front, Back}}`。
  Future<List<AnkiCardTemplate>> modelTemplates(String modelName) async {
    final result = await _request('modelTemplates', {'modelName': modelName});
    if (result is! Map) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for modelTemplates (expected a map)',
      );
    }
    return result.entries.map((MapEntry<dynamic, dynamic> e) {
      final dynamic sides = e.value;
      return AnkiCardTemplate(
        name: e.key.toString(),
        front: sides is Map ? sides['Front']?.toString() ?? '' : '',
        back: sides is Map ? sides['Back']?.toString() ?? '' : '',
      );
    }).toList();
  }

  /// 读取 [modelName] 的 styling（CSS）。AnkiConnect `modelStyling` 返回
  /// `{css: ...}`。
  Future<String> modelStyling(String modelName) async {
    final result = await _request('modelStyling', {'modelName': modelName});
    if (result is! Map || result['css'] is! String) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for modelStyling (expected {css})',
      );
    }
    return result['css'] as String;
  }

  /// 覆写 [modelName] 的 styling（CSS）。
  Future<void> updateModelStyling(String modelName, String css) async {
    await _request('updateModelStyling', {
      'model': {'name': modelName, 'css': css},
    });
  }

  /// 覆写 [modelName] 的卡模板正/反面（按模板名匹配）。
  Future<void> updateModelTemplates(
      String modelName, List<AnkiCardTemplate> templates) async {
    await _request('updateModelTemplates', {
      'model': {
        'name': modelName,
        'templates': <String, dynamic>{
          for (final AnkiCardTemplate t in templates)
            t.name: <String, String>{'Front': t.front, 'Back': t.back},
        },
      },
    });
  }

  // TODO-270 C1：更新已存在 note 的字段。AnkiConnect `updateNoteFields` 接收
  // `{note: {id, fields}}`，只覆盖给出的字段，其余保留。带固定 [noteId]，重发
  // 幂等（同 id + 同 fields 结果一致），故不列入 [_nonIdempotentActions]——可像
  // storeMediaFile 一样在连接掉线时安全重试。
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    await _request('updateNoteFields', {
      'note': {
        'id': noteId,
        'fields': fields,
      },
    });
  }

  // TODO-270 C1：读取一个 note 的现有字段。AnkiConnect `notesInfo` 接收
  // `{notes: [id]}`，返回每个 note 一项 `{noteId, modelName, tags,
  // fields: {<name>: {value, order}}}`。我们只取 `fields` 拍平成 `name → value`。
  // note 不存在时 AnkiConnect 返回一个空对象项（无 noteId/fields）；这里统一以
  // 「无 fields」当作不存在返回 `null`。
  Future<Map<String, String>?> notesInfo(int noteId) async {
    final result = await _request('notesInfo', {
      'notes': [noteId],
    });
    if (result is! List || result.isEmpty) return null;
    final first = result.first;
    if (first is! Map) return null;
    final rawFields = first['fields'];
    if (rawFields is! Map) return null;
    final fields = <String, String>{};
    rawFields.forEach((dynamic key, dynamic value) {
      // 每个字段是 `{value: <html>, order: <int>}`；取 value。
      if (value is Map && value['value'] is String) {
        fields[key.toString()] = value['value'] as String;
      } else if (value is String) {
        // 容错：某些代理/版本可能直接给字符串值。
        fields[key.toString()] = value;
      }
    });
    return fields;
  }

  // TODO-1007/1008：批量读取多张 note 的字段（字段名 -> 值），供命中多张时一次往返
  // 拉全部预览。AnkiConnect `notesInfo` 接收 `{notes: [id...]}`，按 id 顺序返回每项
  // `{noteId, fields:{<name>:{value,order}}}`。返回 `noteId -> (name -> value)`；
  // 形状异常项跳过（fail-soft）。
  Future<Map<int, Map<String, String>>> notesInfoMany(List<int> noteIds) async {
    if (noteIds.isEmpty) return <int, Map<String, String>>{};
    final result = await _request('notesInfo', {'notes': noteIds});
    final out = <int, Map<String, String>>{};
    if (result is! List) return out;
    for (final item in result) {
      if (item is! Map) continue;
      final rawId = item['noteId'];
      final int? id =
          rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
      if (id == null) continue;
      final rawFields = item['fields'];
      if (rawFields is! Map) continue;
      final fields = <String, String>{};
      rawFields.forEach((dynamic key, dynamic value) {
        if (value is Map && value['value'] is String) {
          fields[key.toString()] = value['value'] as String;
        } else if (value is String) {
          fields[key.toString()] = value;
        }
      });
      out[id] = fields;
    }
    return out;
  }

  // TODO-1007/1008：在 Anki 桌面端打开浏览器并选中 [noteId]（`guiBrowse` 接收
  // `{query: 'nid:<id>'}`，把 Anki 主窗口的 Browse 视图过滤到该 note）。需要 Anki GUI
  // 在前台才有视觉效果；纯远程/无 GUI 时 AnkiConnect 仍返回成功（不抛）。
  Future<void> guiBrowse(int noteId) async {
    await _request('guiBrowse', {'query': 'nid:$noteId'});
  }
}

String _escapeAnkiQuery(String value) => value.replaceAll('"', '\\"');

/// TODO-752a：把一个 AnkiConnect 网络异常分类成**与 locale 无关、永不乱码**的稳定码
/// （见 [AnkiErrorCode]）。优先用 OS 错误码（ABI 常量，跨平台/跨 package:http 版本稳定）
/// 区分超时与连接失败，再按异常类型兜底。这是 checkConnection / mineEntry 共用的单一来源，
/// 取代各处对 SocketException / http.ClientException 的 toString() 透传。
String classifyAnkiConnectError(Object error) {
  if (error is TimeoutException) {
    return AnkiErrorCode.connectionTimeout;
  }
  if (error is SocketException) {
    // 连接被拒（POSIX ECONNREFUSED=111/61，Win WSAECONNREFUSED=10061）或任何建连失败：
    // AnkiConnect 没在监听 / Anki 没开。osError 缺失时仍按 socket 归为「拒绝/不可达」，
    // 比透传英文原文好。
    return AnkiErrorCode.connectionRefused;
  }
  if (error is http.ClientException) {
    return AnkiErrorCode.httpError;
  }
  return AnkiErrorCode.connectionUnknown;
}

/// 给**设置页**（非 toast）用的英文可读提示：toast 走主 app 的本地化映射，这里仅服务
/// checkConnection，文案与旧实现一致，但来源统一到稳定码（不再透传异常原文）。
/// [host]/[port] 仅用于丰富英文回退文案；缺省时省略（用户看到的 toast 由主 app 按
/// [code] 本地化，本回退串不含地址也无碍）。
String ankiConnectErrorHint(String code, {String? host, int? port}) {
  final String where =
      (host != null && host.isNotEmpty && port != null) ? ' ($host:$port)' : '';
  switch (code) {
    case AnkiErrorCode.connectionRefused:
      return 'Connection refused$where (is Anki Desktop running?).\n'
          'Check that AnkiConnect add-on (2055492159) is installed.';
    case AnkiErrorCode.connectionTimeout:
      return 'Connection timed out$where.\n'
          'Check firewall settings or verify the host and port.';
    case AnkiErrorCode.httpError:
      return 'HTTP error connecting to AnkiConnect$where.';
    default:
      return 'Cannot connect to AnkiConnect$where.';
  }
}

bool ankiConnectHostIsLoopback(String host) {
  final String normalized = host.trim().toLowerCase();
  if (normalized == 'localhost') return true;
  final String unbracketed =
      normalized.startsWith('[') && normalized.endsWith(']')
          ? normalized.substring(1, normalized.length - 1)
          : normalized;
  return InternetAddress.tryParse(unbracketed)?.isLoopback ?? false;
}

/// 由查重范围 [scope] 解析出的 Anki 搜索卡组子句；空串 = 不限卡组（整个收藏集）。
///
/// Anki 的 `deck:X` **本来就包含** X 的子卡组，但不含父卡组与兄弟子卡组——这正是
/// 「目标选了 `Lapis::Vocab` 就查不到 `Lapis` 其它子卡组里的同词卡」的原因。
/// [AnkiDuplicateScope.deckRoot] 把卡组名截到第一段（`Lapis::Vocab::N5` → `Lapis`），
/// 于是整棵 Lapis 树都在范围内。
///
/// 纯函数（不碰网络/设置），供单测直接钉查询语义。
String ankiDuplicateDeckFilter(String deckName, AnkiDuplicateScope scope) {
  switch (scope) {
    case AnkiDuplicateScope.collection:
      return '';
    case AnkiDuplicateScope.deckRoot:
      // `::` 是 Anki 的层级分隔符；没有分隔符时根卡组就是它自己。
      final String root = deckName.split('::').first;
      // 卡组名本身为空（配置异常）时不要发出 `deck:""` 这种恒不命中的子句，
      // 退化成不限卡组，宁可多查也不要静默查不到（fail-open 与本设置的意图一致）。
      if (root.isEmpty) return '';
      return 'deck:"${_escapeAnkiQuery(root)}"';
    case AnkiDuplicateScope.deck:
      if (deckName.isEmpty) return '';
      return 'deck:"${_escapeAnkiQuery(deckName)}"';
  }
}

Map<String, Object> _addNoteDuplicateOptions({
  required String deckName,
  required bool allowDuplicate,
  required AnkiDuplicateScope scope,
}) {
  final bool collectionWide = scope == AnkiDuplicateScope.collection;
  final String scopedDeckName = switch (scope) {
    AnkiDuplicateScope.deck => deckName,
    AnkiDuplicateScope.deckRoot => deckName.split('::').first,
    AnkiDuplicateScope.collection => '',
  };
  return <String, Object>{
    'allowDuplicate': allowDuplicate,
    'duplicateScope': collectionWide ? 'collection' : 'deck',
    'duplicateScopeOptions': <String, Object>{
      if (!collectionWide && scopedDeckName.isNotEmpty)
        'deckName': scopedDeckName,
      'checkChildren': !collectionWide,
      // The old field query was not restricted to the selected note type.
      // Preserve that cross-model scope while switching to AnkiConnect's
      // indexed primary-field checksum lookup.
      'checkAllModels': true,
    },
  };
}

String _fieldValueQuery({
  required String deckName,
  required String fieldName,
  required String fieldValue,
  required AnkiDuplicateScope scope,
}) {
  // Quote the whole "field:value" term so field names containing spaces
  // (e.g. "Sentence Audio") are not split by Anki's query parser.
  final String fieldTerm =
      '"${_escapeAnkiQuery(fieldName)}:${_escapeAnkiQuery(fieldValue)}"';
  final String deckFilter = ankiDuplicateDeckFilter(deckName, scope);
  return deckFilter.isEmpty ? fieldTerm : '$deckFilter $fieldTerm';
}

class AnkiConnectException implements Exception {
  final String message;
  AnkiConnectException(this.message);
  @override
  String toString() => 'AnkiConnectException: $message';
}

class AnkiConnectDuplicateException extends AnkiConnectException {
  AnkiConnectDuplicateException(super.message);
}

class AnkiConnectCommitUnknownException extends AnkiConnectException {
  AnkiConnectCommitUnknownException(this.action, this.cause)
      : super(
          'AnkiConnect lost the $action response after the request may have '
          'reached Anki. The operation may have completed; verify Anki before '
          'retrying.',
        );

  final String action;
  final Object cause;
}
