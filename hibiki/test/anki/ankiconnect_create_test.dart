import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_anki/src/ankiconnect/ankiconnect_service.dart';

void main() {
  test('createModel sends correct AnkiConnect v6 payload', () async {
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'result': 1, 'error': null}), 200);
    });
    final service = AnkiConnectService(client: client);

    await service.createModel(LapisNoteType.template);

    expect(captured['action'], 'createModel');
    expect(captured['version'], 6);
    final params = captured['params'] as Map<String, dynamic>;
    expect(params['modelName'], 'Lapis');
    expect(params['inOrderFields'], LapisNoteType.fields);
    expect(params['isCloze'], false);
    expect(params['css'], LapisNoteType.css);
    final templates = params['cardTemplates'] as List;
    expect(templates, hasLength(1));
    final card = templates.first as Map<String, dynamic>;
    expect(card['Name'], 'Card 1');
    expect(card['Front'], LapisNoteType.front);
    expect(card['Back'], LapisNoteType.back);
  });

  test('createDeck sends createDeck action', () async {
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'result': 1, 'error': null}), 200);
    });
    final service = AnkiConnectService(client: client);

    await service.createDeck('Lapis');

    expect(captured['action'], 'createDeck');
    expect((captured['params'] as Map)['deck'], 'Lapis');
  });
}
