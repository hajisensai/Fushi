import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// 查重范围（[AnkiDuplicateScope]）守卫。
///
/// 用户报告：Yomitan 在把制卡目标选成 Lapis 的某个子卡组时，仍能查到整个 Lapis
/// （含全部子卡组）里的卡；Hibiki 只查所选的那一个。根因不是 bug 而是缺配置——
/// Anki 的 `deck:X` 包含 X 的子卡组，但不含父卡组与兄弟子卡组，而 Hibiki 恒发
/// `deck:"<所选卡组>"`。这里钉死新配置项的查询语义与默认值。
void main() {
  group('ankiDuplicateDeckFilter — 范围到 Anki 搜索子句', () {
    test('deck（默认）= 所选卡组本身（Anki 语义已含其子卡组）', () {
      expect(
        ankiDuplicateDeckFilter('Lapis::Vocab', AnkiDuplicateScope.deck),
        'deck:"Lapis::Vocab"',
      );
    });

    test('deckRoot = 截到根卡组，于是整棵子树都在范围内', () {
      expect(
        ankiDuplicateDeckFilter('Lapis::Vocab', AnkiDuplicateScope.deckRoot),
        'deck:"Lapis"',
      );
      // 多级同理，只保留第一段。
      expect(
        ankiDuplicateDeckFilter(
            'Lapis::Vocab::N5', AnkiDuplicateScope.deckRoot),
        'deck:"Lapis"',
      );
      // 本来就是根卡组时 deckRoot 与 deck 等价。
      expect(
        ankiDuplicateDeckFilter('Lapis', AnkiDuplicateScope.deckRoot),
        'deck:"Lapis"',
      );
    });

    test('collection = 不限卡组（空子句）', () {
      expect(
        ankiDuplicateDeckFilter('Lapis::Vocab', AnkiDuplicateScope.collection),
        '',
      );
    });

    test('卡组名里的引号被转义，不会截断查询', () {
      expect(
        ankiDuplicateDeckFilter('My "Deck"', AnkiDuplicateScope.deck),
        r'deck:"My \"Deck\""',
      );
    });

    test('卡组名为空时退化成不限卡组，而不是恒不命中的 deck:""', () {
      expect(ankiDuplicateDeckFilter('', AnkiDuplicateScope.deck), '');
      expect(ankiDuplicateDeckFilter('', AnkiDuplicateScope.deckRoot), '');
    });
  });

  group('findNotes 真实查询串', () {
    Future<String> queryFor(AnkiDuplicateScope? scope) async {
      final List<http.Request> sink = <http.Request>[];
      final client = MockClient((http.Request request) async {
        sink.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{'result': <int>[], 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service =
          AnkiConnectService(host: '127.0.0.1', port: 8765, client: client);
      await service.findNotesByField(
        deckName: 'Lapis::Vocab',
        fieldName: 'Word',
        fieldValue: '散乱',
        // null = 调用方根本不传 scope（旧调用点）。
        scope: scope ?? AnkiDuplicateScope.deck,
      );
      final Map<String, dynamic> body =
          jsonDecode(sink.single.body) as Map<String, dynamic>;
      return (body['params'] as Map<String, dynamic>)['query'] as String;
    }

    test('默认（deck）与改动前逐字节一致', () async {
      expect(await queryFor(null), 'deck:"Lapis::Vocab" "Word:散乱"');
    });

    test('deckRoot 查整棵 Lapis 树', () async {
      expect(await queryFor(AnkiDuplicateScope.deckRoot),
          'deck:"Lapis" "Word:散乱"');
    });

    test('collection 完全不带 deck 子句（前面也不留空格）', () async {
      expect(await queryFor(AnkiDuplicateScope.collection), '"Word:散乱"');
    });
  });

  group('addNote 原生查重范围', () {
    Future<Map<String, dynamic>> optionsFor(AnkiDuplicateScope scope) async {
      final List<http.Request> sink = <http.Request>[];
      final client = MockClient((http.Request request) async {
        sink.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{'result': 42, 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service =
          AnkiConnectService(host: '127.0.0.1', port: 8765, client: client);
      await service.addNote(
        deckName: 'Lapis::Vocab',
        modelName: 'Lapis',
        fields: const <String, String>{'Expression': '散乱'},
        duplicateScope: scope,
      );
      final Map<String, dynamic> body =
          jsonDecode(sink.single.body) as Map<String, dynamic>;
      final Map<String, dynamic> note = (body['params']
          as Map<String, dynamic>)['note'] as Map<String, dynamic>;
      return note['options'] as Map<String, dynamic>;
    }

    test('deck 使用目标卡组及其子卡组', () async {
      expect(await optionsFor(AnkiDuplicateScope.deck), <String, dynamic>{
        'allowDuplicate': false,
        'duplicateScope': 'deck',
        'duplicateScopeOptions': <String, dynamic>{
          'deckName': 'Lapis::Vocab',
          'checkChildren': true,
          'checkAllModels': true,
        },
      });
    });

    test('deckRoot 截到根卡组并包含整棵子树', () async {
      expect(await optionsFor(AnkiDuplicateScope.deckRoot), <String, dynamic>{
        'allowDuplicate': false,
        'duplicateScope': 'deck',
        'duplicateScopeOptions': <String, dynamic>{
          'deckName': 'Lapis',
          'checkChildren': true,
          'checkAllModels': true,
        },
      });
    });

    test('collection 使用全收藏范围且不附带卡组名', () async {
      expect(await optionsFor(AnkiDuplicateScope.collection), <String, dynamic>{
        'allowDuplicate': false,
        'duplicateScope': 'collection',
        'duplicateScopeOptions': <String, dynamic>{
          'checkChildren': false,
          'checkAllModels': true,
        },
      });
    });
  });

  group('AnkiSettings 持久化', () {
    test('默认是 deck（= 旧行为）', () {
      expect(const AnkiSettings().duplicateScope, AnkiDuplicateScope.deck);
    });

    test('旧存档没有该字段 → 回落 deck，绝不改变既有用户的查重范围', () {
      final s = AnkiSettings.fromJson(<String, dynamic>{'tags': 'x'});
      expect(s.duplicateScope, AnkiDuplicateScope.deck);
    });

    test('JSON 往返保真', () {
      for (final scope in AnkiDuplicateScope.values) {
        final s = AnkiSettings(duplicateScope: scope);
        expect(
          AnkiSettings.fromJson(s.toJson()).duplicateScope,
          scope,
          reason: '$scope 往返丢失',
        );
      }
    });

    test('未知值容错回 deck', () {
      expect(ankiDuplicateScopeFromName('nonsense'), AnkiDuplicateScope.deck);
      expect(ankiDuplicateScopeFromName(null), AnkiDuplicateScope.deck);
    });
  });
}
