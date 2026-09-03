import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-1915：查词弹窗的「可制卡 +」与 `addNote` 的判重必须是**同一条判据**。
///
/// 用户实测现场（本仓 2026-08-28 用真机 AnkiConnect 取证，本文件的 fake 就是照它建的）：
/// 目标卡组 `正在背::Kaishi 1.5k  zh-CH` 里混装两种笔记类型——1501 张 `Kaishi 1.5k zh-CH`
/// （第一字段名 `Word`）+ 12 张 `Lapis`（第一字段名 `Expression`）。词 `たっぷり` 已作为
/// 一张 Kaishi 卡存在。于是：
///
///   * `findNotes 'deck:"…" "Expression:たっぷり"'` → **0 命中**（Kaishi 笔记类型
///     压根没有 `Expression` 这个字段，按字段名永远查不到它）；
///   * Anki 自己按**第一字段**判 → **命中**，`addNote` 以重复拒绝。
///
/// 旧实现拿前者画按钮、拿后者拒绝制卡，于是弹窗画 `+`、点下去弹「重复卡片，未导出」，
/// 而按钮纹丝不动。这里钉死修复后的行为：查重问的是 Anki 自己。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String kWord = 'たっぷり';
  const String kDeck = '正在背::Kaishi 1.5k  zh-CH';
  const String kDuplicateError = 'cannot create note because it is a duplicate';

  const AnkiNoteType lapis = AnkiNoteType(
    id: 6,
    name: 'Lapis',
    fields: <String>[
      'Expression',
      'ExpressionFurigana',
      'ExpressionReading',
      'Sentence',
    ],
  );

  Future<void> installSettings({bool allowDupes = false}) async {
    final AnkiSettings settings = AnkiSettings(
      selectedDeckId: 21,
      selectedDeckName: kDeck,
      selectedNoteTypeId: lapis.id,
      selectedNoteTypeName: lapis.name,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 21, name: kDeck)],
      availableNoteTypes: const <AnkiNoteType>[lapis],
      fieldMappings: const <String, String>{'Expression': '{expression}'},
      allowDupes: allowDupes,
      duplicateScope: AnkiDuplicateScope.deck,
    );
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AnkiConnectRepository().saveSettings(settings);
  }

  /// 一台**照实测行为建模**的假 AnkiConnect：
  /// 按字段名查恒 0 命中，按 Anki 自己的第一字段判恒重复。
  /// 两条判据在这台机器上给出相反答案——这正是回归的判别力所在。
  MockClient crossModelDuplicateHost(List<Map<String, dynamic>> sink) {
    return MockClient((http.Request request) async {
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      sink.add(body);
      final String action = body['action'] as String;
      Object? result;
      Object? error;
      switch (action) {
        case 'findNotes':
          // 按 `Expression:` 查不到那张 Kaishi 卡。
          result = const <int>[];
        case 'canAddNotesWithErrorDetail':
          result = const <Map<String, Object?>>[
            <String, Object?>{'canAdd': false, 'error': kDuplicateError},
          ];
        case 'addNote':
          error = kDuplicateError;
        default:
          error = 'unsupported action';
      }
      return http.Response(
        jsonEncode(<String, Object?>{'result': result, 'error': error}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
  }

  AnkiConnectRepository repoWith(http.Client client) {
    AnkiConnectRepository.resetDuplicateCheckCooldown();
    return AnkiConnectRepository(
      service: AnkiConnectService(host: '127.0.0.1', port: 8765, client: client),
    );
  }

  Map<String, dynamic> onlyCall(
    List<Map<String, dynamic>> sink,
    String action,
  ) =>
      sink.singleWhere((Map<String, dynamic> b) => b['action'] == action);

  group('BUG-1915 跨笔记类型的重复必须被查重看见', () {
    test('第一字段撞车但字段名不同的卡 → isDuplicate 为 true', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      final repo = repoWith(crossModelDuplicateHost(sink));

      expect(await repo.isDuplicate(kWord, ''), isTrue);

      // 判别力：旧实现走 findNotes（这台假机恒回 0 命中）会得到 false。
      expect(
        sink.map((Map<String, dynamic> b) => b['action']),
        contains('canAddNotesWithErrorDetail'),
      );
      expect(
        sink.map((Map<String, dynamic> b) => b['action']),
        isNot(contains('findNotes')),
      );
    });

    test('查重与 addNote 发出的 duplicate options 逐字段相同', () async {
      await installSettings();

      final probeSink = <Map<String, dynamic>>[];
      await repoWith(crossModelDuplicateHost(probeSink)).isDuplicate(kWord, '');

      final addSink = <Map<String, dynamic>>[];
      final AnkiConnectService service = AnkiConnectService(
        host: '127.0.0.1',
        port: 8765,
        client: crossModelDuplicateHost(addSink),
      );
      await expectLater(
        service.addNote(
          deckName: kDeck,
          modelName: lapis.name,
          fields: const <String, String>{'Expression': kWord},
          duplicateScope: AnkiDuplicateScope.deck,
        ),
        throwsA(isA<AnkiConnectDuplicateException>()),
      );

      // 两侧来自两条独立调用路径（repo.isDuplicate / service.addNote），
      // 比的是各自真正发出去的 HTTP 请求体，不是同一次取值。
      final Map<String, dynamic> probeNote =
          ((onlyCall(probeSink, 'canAddNotesWithErrorDetail')['params']
                  as Map)['notes'] as List)
              .single as Map<String, dynamic>;
      final Map<String, dynamic> addedNote =
          (onlyCall(addSink, 'addNote')['params'] as Map)['note']
              as Map<String, dynamic>;

      expect(probeNote['options'], addedNote['options']);
      expect(probeNote['deckName'], addedNote['deckName']);
      expect(probeNote['modelName'], addedNote['modelName']);
    });

    test('探测的 duplicateScopeOptions 必须开着 checkAllModels', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelDuplicateHost(sink)).isDuplicate(kWord, '');

      final Map<String, dynamic> note =
          ((onlyCall(sink, 'canAddNotesWithErrorDetail')['params']
                  as Map)['notes'] as List)
              .single as Map<String, dynamic>;
      final Map<String, dynamic> options =
          note['options'] as Map<String, dynamic>;
      final Map<String, dynamic> scopeOptions =
          options['duplicateScopeOptions'] as Map<String, dynamic>;

      // 这一条就是「跨笔记类型也算重复」的开关；关掉它本 bug 立刻复发。
      expect(scopeOptions['checkAllModels'], isTrue);
      expect(scopeOptions['deckName'], kDeck);
      expect(options['duplicateScope'], 'deck');
    });

    test('用户开了「允许重复」时，探测仍以 allowDuplicate:false 提问', () async {
      // 探测问的是「Anki 认不认为这是重复」，不是「用户允不允许」。跟着 allowDupes
      // 走会让这些用户的 ✓ 永远画不出来。
      await installSettings(allowDupes: true);
      final sink = <Map<String, dynamic>>[];
      final repo = repoWith(crossModelDuplicateHost(sink));

      expect(await repo.isDuplicate(kWord, ''), isTrue);

      final Map<String, dynamic> note =
          ((onlyCall(sink, 'canAddNotesWithErrorDetail')['params']
                  as Map)['notes'] as List)
              .single as Map<String, dynamic>;
      expect(
        (note['options'] as Map<String, dynamic>)['allowDuplicate'],
        isFalse,
      );
    });

    test('只发第一字段，不在查词路径上构造整张卡', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelDuplicateHost(sink)).isDuplicate(kWord, '');

      final Map<String, dynamic> note =
          ((onlyCall(sink, 'canAddNotesWithErrorDetail')['params']
                  as Map)['notes'] as List)
              .single as Map<String, dynamic>;
      expect(note['fields'], <String, String>{'Expression': kWord});
    });
  });

  group('BUG-1915 边界', () {
    test('canAdd:false 但原因不是重复 → 不画已制卡', () async {
      await installSettings();
      final client = MockClient((http.Request request) async {
        final String action =
            (jsonDecode(request.body) as Map<String, dynamic>)['action']
                as String;
        final Object? result = action == 'canAddNotesWithErrorDetail'
            ? const <Map<String, Object?>>[
                <String, Object?>{
                  'canAdd': false,
                  'error': 'deck was not found: 正在背::Kaishi 1.5k  zh-CH',
                },
              ]
            : null;
        return http.Response(
          jsonEncode(<String, Object?>{'result': result, 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      expect(await repoWith(client).isDuplicate(kWord, ''), isFalse);
    });

    test('老版 AnkiConnect 不认识该动作 → 退回按字段名查的旧判据，不集体失去 ✓',
        () async {
      await installSettings();
      final actions = <String>[];
      final client = MockClient((http.Request request) async {
        final String action =
            (jsonDecode(request.body) as Map<String, dynamic>)['action']
                as String;
        actions.add(action);
        if (action == 'canAddNotesWithErrorDetail') {
          return http.Response(
            jsonEncode(
              <String, Object?>{'result': null, 'error': 'unsupported action'},
            ),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{'result': const <int>[42], 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      expect(await repoWith(client).isDuplicate(kWord, ''), isTrue);
      expect(actions, <String>['canAddNotesWithErrorDetail', 'findNotes']);
    });

    test('空词不问 Anki', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      expect(await repoWith(crossModelDuplicateHost(sink)).isDuplicate('', ''),
          isFalse);
      expect(sink, isEmpty);
    });
  });
}
