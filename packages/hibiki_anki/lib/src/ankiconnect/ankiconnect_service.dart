import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../anki_service.dart';

class AnkiConnectService implements AnkiService {
  final String host;
  final int port;

  AnkiConnectService({this.host = 'localhost', this.port = 8765});

  static const _timeout = Duration(seconds: 10);

  Future<dynamic> _request(String action,
      [Map<String, dynamic>? params]) async {
    final body = jsonEncode({
      'action': action,
      'version': 6,
      if (params != null) 'params': params,
    });
    final response = await http.post(
      Uri.parse('http://$host:$port'),
      body: body,
      headers: {'Content-Type': 'application/json'},
    ).timeout(_timeout);
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
}

String _escapeAnkiQuery(String value) => value.replaceAll('"', '\\"');

class AnkiConnectException implements Exception {
  final String message;
  AnkiConnectException(this.message);
  @override
  String toString() => 'AnkiConnectException: $message';
}
