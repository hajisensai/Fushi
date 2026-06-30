import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TODO-1007/1008：`findMatchingNotes` 行为守卫（AnkiConnect 后端）。
///
/// 与 `findOverwriteTargetNoteId`（只在 scope=all 时回最近一张）不同，
/// `findMatchingNotes` 恒尝试反查**全部**同词卡（不看 overwriteScope），
/// 返回 noteId + 一行预览（去 HTML），按 id 降序（最近在前），供宿主弹操作选择。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> seedSettings() async {
    final settings = AnkiSettings(
      selectedDeckId: 0,
      selectedDeckName: 'Mining',
      selectedNoteTypeId: 0,
      selectedNoteTypeName: 'Vocab',
      availableDecks: const [AnkiDeck(id: 0, name: 'Mining')],
      availableNoteTypes: const [
        AnkiNoteType(id: 0, name: 'Vocab', fields: ['Expression', 'Meaning']),
      ],
      // 即便默认 latest，findMatchingNotes 也必须照查（与 scope 解耦）。
      overwriteScope: AnkiOverwriteScope.latest,
    );
    SharedPreferences.setMockInitialValues(
      {'hoshi_anki_settings': jsonEncode(settings.toJson())},
    );
  }

  /// 用一个能区分 findNotes / notesInfo 两个 action 的 MockClient 构造仓库。
  AnkiConnectRepository repoWith({
    required List<int> findNotesResult,
    required Map<int, String> firstFieldByNoteId,
  }) {
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final action = body['action'] as String;
      if (action == 'findNotes') {
        return http.Response(
            jsonEncode({'result': findNotesResult, 'error': null}), 200);
      }
      if (action == 'notesInfo') {
        final ids = ((body['params'] as Map)['notes'] as List).cast<int>();
        final info = ids
            .map((id) => {
                  'noteId': id,
                  'modelName': 'Vocab',
                  'tags': <String>[],
                  'fields': {
                    'Expression': {
                      'value': firstFieldByNoteId[id] ?? '',
                      'order': 0
                    },
                    'Meaning': {'value': 'm', 'order': 1},
                  },
                })
            .toList();
        // UTF-8 bytes: the response carries Japanese; the default latin1 Response
        // ctor would throw on those code units.
        return http.Response.bytes(
            utf8.encode(jsonEncode({'result': info, 'error': null})), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response(jsonEncode({'result': null, 'error': null}), 200);
    });
    return AnkiConnectRepository(service: AnkiConnectService(client: client));
  }

  test('returns all matches newest-first regardless of overwriteScope=latest',
      () async {
    await seedSettings();
    final repo = repoWith(
      findNotesResult: [100, 305, 207],
      firstFieldByNoteId: {100: '日本語', 305: '<b>日本語</b>', 207: '日本語　&nbsp; '},
    );

    final matches = await repo.findMatchingNotes('日本語', 'にほんご');

    expect(matches.map((m) => m.noteId).toList(), [305, 207, 100],
        reason: 'newest (largest id) first');
    // 预览去 HTML / 折叠空白。
    expect(matches.firstWhere((m) => m.noteId == 305).preview, '日本語');
    expect(matches.firstWhere((m) => m.noteId == 207).preview, '日本語');
  });

  test('returns empty when no card matches', () async {
    await seedSettings();
    final repo = repoWith(findNotesResult: [], firstFieldByNoteId: {});
    final matches = await repo.findMatchingNotes('未登録', '');
    expect(matches, isEmpty);
  });

  test('swallows backend failure and returns empty (no throw)', () async {
    await seedSettings();
    final client = MockClient((req) async => http.Response('boom', 500));
    final repo =
        AnkiConnectRepository(service: AnkiConnectService(client: client));
    final matches = await repo.findMatchingNotes('日本語', 'にほんご');
    expect(matches, isEmpty,
        reason: 'a failed lookup must degrade, not crash mining');
  });

  test('openNoteInAnki issues guiBrowse with nid query and returns true',
      () async {
    await seedSettings();
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'result': null, 'error': null}), 200);
    });
    final repo =
        AnkiConnectRepository(service: AnkiConnectService(client: client));

    final ok = await repo.openNoteInAnki(305);

    expect(ok, isTrue);
    expect(captured['action'], 'guiBrowse');
    expect((captured['params'] as Map)['query'], 'nid:305');
  });
}
