import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 「高级制卡」卡组覆盖在 AnkiMobile 后端与制卡请求载体上的契约：
//   * AnkiMobile：覆盖卡组按名命中 → addnote URL 的 deck 参数是它、success.deckName
//     是它；找不到 → 退回设置卡组；`miningOverrides` 不变成任何 fld* 字段。
//   * 载体保键：「看完再制卡」暂存（fields 落 JSON 再解回）与互联转发 / 待发队列
//     （ForwardedMinePayload 逐字携带 rawPayloadJson）都原样保留 `miningOverrides`。

const AnkiSettings _settings = AnkiSettings(
  selectedDeckId: 0,
  selectedDeckName: 'Japanese',
  selectedNoteTypeId: 0,
  selectedNoteTypeName: 'Lapis',
  availableDecks: <AnkiDeck>[
    AnkiDeck(id: 0, name: 'Japanese'),
    AnkiDeck(id: 1, name: 'Japanese::Manga'),
  ],
  availableNoteTypes: <AnkiNoteType>[
    AnkiNoteType(id: 0, name: 'Lapis', fields: <String>['Expression']),
  ],
  fieldMappings: <String, String>{'Expression': '{expression}'},
);

String _rawPayload(String deck) => jsonEncode(
  MiningRequestOverrides.attach(<String, String>{
    'expression': '猫',
  }, MiningRequestOverrides(deckName: deck)),
);

Future<(MineOutcome, List<Uri>)> _mine(String rawPayloadJson) async {
  final List<Uri> launched = <Uri>[];
  final AnkiMobileRepository repo = AnkiMobileRepository(
    openUrl: (Uri uri) async {
      launched.add(uri);
      return true;
    },
    readInfoForAddingJson: () async => const AnkiMobilePasteboardRead.empty(),
    mediaServerLifetime: Duration.zero,
  );
  await repo.saveSettings(_settings);
  final MineOutcome outcome = await repo.mineEntry(
    rawPayloadJson: rawPayloadJson,
    context: const AnkiMiningContext(sentence: '黒い猫です。'),
  );
  return (outcome, launched);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('AnkiMobile：卡组覆盖', () {
    test('按名命中 → addnote 的 deck 是覆盖卡组，success.deckName 是它', () async {
      final (MineOutcome outcome, List<Uri> launched) = await _mine(
        _rawPayload('Japanese::Manga'),
      );
      expect(outcome.result, MineResult.success, reason: outcome.errorDetail);
      expect(outcome.deckName, 'Japanese::Manga');
      final Map<String, String> query = launched.single.queryParameters;
      expect(query['deck'], 'Japanese::Manga');
      expect(query['fldExpression'], '猫');
      // 覆盖项不会被当成笔记字段送进 AnkiMobile。
      expect(query.keys.where((String k) => k.startsWith('fld')), <String>[
        'fldExpression',
      ]);
    });

    test('找不到 → 退回设置卡组（不新建）', () async {
      final (MineOutcome outcome, List<Uri> launched) = await _mine(
        _rawPayload('Nope'),
      );
      expect(outcome.result, MineResult.success, reason: outcome.errorDetail);
      expect(outcome.deckName, 'Japanese');
      expect(launched.single.queryParameters['deck'], 'Japanese');
    });
  });

  group('制卡请求载体原样保留 miningOverrides', () {
    final Map<String, String> fields = MiningRequestOverrides.attach(
      <String, String>{'expression': '猫'},
      const MiningRequestOverrides(
        deckName: 'Japanese::Manga',
        omitAudio: true,
      ),
    );

    test('「看完再制卡」暂存：fields JSON 往返不丢键', () {
      final Map<String, String> back = decodeWebMineFields(jsonEncode(fields));
      expect(back, fields);
      expect(
        MiningRequestOverrides.readFrom(back)?.deckName,
        'Japanese::Manga',
      );
    });

    test('互联转发 / 待发队列：ForwardedMinePayload 逐字携带 rawPayloadJson', () {
      final ForwardedMinePayload payload = ForwardedMinePayload(
        rawPayloadJson: jsonEncode(fields),
        sentence: '黒い猫です。',
      );
      final ForwardedMinePayload back = ForwardedMinePayload.fromJson(
        jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>,
      );
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
        jsonDecode(back.rawPayloadJson) as Map<String, dynamic>,
      );
      expect(parsed.overrides?.deckName, 'Japanese::Manga');
      expect(parsed.overrides?.omitAudio, isTrue);
    });
  });
}
