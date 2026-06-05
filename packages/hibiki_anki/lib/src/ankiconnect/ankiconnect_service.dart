import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../anki_service.dart';
import '../lapis_note_type.dart';

class AnkiConnectService implements AnkiService {
  final String host;
  final int port;

  /// AnkiConnect API key. When the AnkiConnect add-on has `apiKey` configured,
  /// every request must carry a matching `key`; otherwise it replies with
  /// "valid api key must be provided". Empty means no key (the default).
  final String apiKey;

  final http.Client _client;

  AnkiConnectService({
    this.host = 'localhost',
    this.port = 8765,
    this.apiKey = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const _timeout = Duration(seconds: 10);

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
      throw AnkiConnectException(result['error'].toString());
    }
    return result['result'];
  }

  /// Actions that mutate Anki state and are NOT safe to re-send. package:http
  /// wraps the write *and* the response-header read in one try, so a connection
  /// drop (e.g. "Connection reset") can surface *after* the request reached
  /// AnkiConnect — re-sending `addNote`/`createModel` would then create a
  /// duplicate card or hit "model already exists". We never auto-retry these;
  /// the error is surfaced for the user to retry. Every other action
  /// (version/deckNames/modelNames/modelFieldNames/findNotes/storeMediaFile/
  /// createDeck) is idempotent, so re-sending has no side effect.
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
  /// java.net.http): we gate on action idempotency instead of trying to infer
  /// from the error text whether the request was already delivered, which is not
  /// reliable. Genuine refusals/timeouts are not connection-drops and fall
  /// through to the caller (a retry would not help).
  Future<http.Response> _postWithStaleConnectionRetry(
    String body, {
    required bool idempotent,
  }) async {
    try {
      return await _post(body);
    } on http.ClientException catch (e) {
      if (!idempotent || !_isConnectionDrop(e)) rethrow;
      return await _post(body);
    }
  }

  Future<http.Response> _post(String body) {
    return _client.post(
      Uri.parse('http://$host:$port'),
      body: body,
      headers: {'Content-Type': 'application/json'},
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

  @override
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
    } on SocketException {
      return 'Connection refused — is Anki Desktop running?\n'
          'Check that AnkiConnect add-on (2055492159) is installed.';
    } on TimeoutException {
      return 'Connection timed out ($host:$port).\n'
          'Check firewall settings or verify the host and port.';
    } on http.ClientException catch (e) {
      return 'HTTP error: $e';
    } catch (e) {
      return 'Cannot connect to AnkiConnect: $e';
    }
  }

  @override
  Future<List<String>> getDeckNames() async {
    return _asStringList(await _request('deckNames'), 'deckNames');
  }

  @override
  Future<List<String>> getModelNames() async {
    return _asStringList(await _request('modelNames'), 'modelNames');
  }

  @override
  Future<List<String>> getModelFields(String modelName) async {
    return _asStringList(
      await _request('modelFieldNames', {'modelName': modelName}),
      'modelFieldNames',
    );
  }

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
  }) async {
    // AnkiConnect rejects duplicates by default; allowDuplicate must be sent
    // explicitly or the user's "allow duplicates" setting has no effect.
    final result = await _request('addNote', {
      'note': {
        'deckName': deckName,
        'modelName': modelName,
        'fields': fields,
        'options': {'allowDuplicate': allowDuplicate},
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

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async {
    // Quote the whole "field:value" term so field names containing spaces
    // (e.g. "Sentence Audio") are not split by Anki's query parser.
    final query = 'deck:"${_escapeAnkiQuery(deckName)}" '
        '"${_escapeAnkiQuery(fieldName)}:${_escapeAnkiQuery(fieldValue)}"';
    final result = await _request('findNotes', {'query': query});
    if (result is! List) {
      throw AnkiConnectException(
        'Unexpected AnkiConnect response for findNotes (expected a list)',
      );
    }
    return result.isNotEmpty;
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
}

String _escapeAnkiQuery(String value) => value.replaceAll('"', '\\"');

class AnkiConnectException implements Exception {
  final String message;
  AnkiConnectException(this.message);
  @override
  String toString() => 'AnkiConnectException: $message';
}
