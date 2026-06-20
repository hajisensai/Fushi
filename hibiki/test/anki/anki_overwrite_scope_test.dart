import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TODO-614：`findOverwriteTargetNoteId` 行为守卫。
///
/// scope=latest（默认）时一律回 null，不查 Anki（现状不破）。scope=all 时复用与
/// 查重同一条件（deck + 第一字段=expression）经 findNotes 反查已存在 note id，多张
/// 命中取「最近一张」（note id 最大 = 创建最新），回单个 id 灌进弹窗使更早卡也能覆写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 预置一份已配置好牌组/笔记类型的 Anki 设置到 SharedPreferences，[scope] 决定
  /// 覆写范围。第一字段名固定为 `Expression`（findOverwriteTargetNoteId 用它查重）。
  Future<void> seedSettings(AnkiOverwriteScope scope) async {
    final settings = AnkiSettings(
      selectedDeckId: 0,
      selectedDeckName: 'Mining',
      selectedNoteTypeId: 0,
      selectedNoteTypeName: 'Vocab',
      availableDecks: const [AnkiDeck(id: 0, name: 'Mining')],
      availableNoteTypes: const [
        AnkiNoteType(id: 0, name: 'Vocab', fields: ['Expression', 'Meaning']),
      ],
      overwriteScope: scope,
    );
    SharedPreferences.setMockInitialValues(
      {'hoshi_anki_settings': jsonEncode(settings.toJson())},
    );
  }

  test('scope=latest never queries Anki and returns null', () async {
    await seedSettings(AnkiOverwriteScope.latest);
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response(
          jsonEncode({
            'result': [111],
            'error': null
          }),
          200);
    });
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(client: client),
    );

    final id = await repo.findOverwriteTargetNoteId('日本語', 'にほんご');

    expect(id, isNull, reason: 'latest scope must not promote older cards');
    expect(calls, 0, reason: 'latest scope must not hit AnkiConnect at all');
  });

  test('scope=all returns the most recent matching note id', () async {
    await seedSettings(AnkiOverwriteScope.all);
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      // Anki returns matches in arbitrary order; the newest note id is the max.
      return http.Response(
        jsonEncode({
          'result': [100, 305, 207],
          'error': null
        }),
        200,
      );
    });
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(client: client),
    );

    final id = await repo.findOverwriteTargetNoteId('日本語', 'にほんご');

    expect(id, 305, reason: 'newest (largest) note id wins');
    expect(captured['action'], 'findNotes');
    final query = (captured['params'] as Map)['query'] as String;
    expect(query, contains('deck:'));
    expect(query, contains('Expression:'),
        reason: 'must reuse first field = expression as the dupe condition');
    expect(query, contains('日本語'));
  });

  test('scope=all returns null when no card matches', () async {
    await seedSettings(AnkiOverwriteScope.all);
    final client = MockClient((req) async {
      return http.Response(jsonEncode({'result': [], 'error': null}), 200);
    });
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(client: client),
    );

    final id = await repo.findOverwriteTargetNoteId('未登録', '');

    expect(id, isNull);
  });

  test('scope=all swallows backend failure and returns null (no throw)',
      () async {
    await seedSettings(AnkiOverwriteScope.all);
    final client = MockClient((req) async {
      return http.Response('boom', 500);
    });
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(client: client),
    );

    final id = await repo.findOverwriteTargetNoteId('日本語', 'にほんご');

    expect(id, isNull,
        reason: 'a failed lookup must degrade, not crash mining');
  });
}
