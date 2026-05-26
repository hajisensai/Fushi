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
    final result = jsonDecode(response.body);
    if (result['error'] != null) {
      throw AnkiConnectException(result['error'] as String);
    }
    return result['result'];
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
    final result = await _request('deckNames');
    return (result as List).cast<String>();
  }

  @override
  Future<List<String>> getModelNames() async {
    final result = await _request('modelNames');
    return (result as List).cast<String>();
  }

  @override
  Future<List<String>> getModelFields(String modelName) async {
    final result = await _request('modelFieldNames', {'modelName': modelName});
    return (result as List).cast<String>();
  }

  @override
  Future<void> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
  }) async {
    await _request('addNote', {
      'note': {
        'deckName': deckName,
        'modelName': modelName,
        'fields': fields,
        if (tags != null) 'tags': tags,
      },
    });
  }

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async {
    final result = await _request('findNotes', {
      'query':
          'deck:"${_escapeAnkiQuery(deckName)}" $fieldName:"${_escapeAnkiQuery(fieldValue)}"',
    });
    return (result as List).isNotEmpty;
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
