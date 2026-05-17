import 'dart:convert';
import 'package:http/http.dart' as http;
import '../anki_service.dart';
import '../anki_models.dart';

class AnkiConnectService implements AnkiService {
  final String host;
  final int port;

  AnkiConnectService({this.host = 'localhost', this.port = 8765});

  Future<dynamic> _request(String action, [Map<String, dynamic>? params]) async {
    final body = jsonEncode({
      'action': action,
      'version': 6,
      if (params != null) 'params': params,
    });
    final response = await http.post(
      Uri.parse('http://$host:$port'),
      body: body,
      headers: {'Content-Type': 'application/json'},
    );
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
      'query': 'deck:"$deckName" $fieldName:"$fieldValue"',
    });
    return (result as List).isNotEmpty;
  }
}

class AnkiConnectException implements Exception {
  final String message;
  AnkiConnectException(this.message);
  @override
  String toString() => 'AnkiConnectException: $message';
}
