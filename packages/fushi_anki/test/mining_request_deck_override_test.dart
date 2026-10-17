import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

// 「高级制卡」卡组覆盖：用户在对话框里为**这一张卡**挑的卡组随 fields map 的
// `miningOverrides` 键走到后端（与 BUG-2605 allowDuplicate 同一先例）。这里钉死：
//   * MiningRequestOverrides 两条 wire 线（JSON 字符串 / Map）编解码，空覆盖不留键、
//     坏输入返回 null 而不是抛；
//   * AnkiMiningPayload.fromJson 读得出覆盖；旧 payload → null；
//   * AnkiConnect / AnkiDroid：覆盖卡组按名命中 → addNote 写进它、success.deckName 是它；
//     找不到 → 退回设置卡组、不新建；设置没选卡组但覆盖命中 → 照样落卡；
//   * `miningOverrides` 这串 JSON 不会被写进任何 Anki 字段。

class _RecordingAnkiConnectService extends AnkiConnectService {
  final List<String> addedDecks = <String>[];
  final List<Map<String, String>> addedFields = <Map<String, String>>[];

  @override
  Future<bool> mediaFileExists(String filename) async => false;

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {}

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    addedDecks.add(deckName);
    addedFields.add(Map<String, String>.of(fields));
    return 42;
  }
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings({int selectedDeckId = 1, String? selectedDeckName}) =>
    AnkiSettings(
      selectedDeckId: selectedDeckId,
      selectedDeckName: selectedDeckName,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[
        AnkiDeck(id: 1, name: 'Mining'),
        AnkiDeck(id: 3, name: 'Mining::Manga'),
      ],
      availableNoteTypes: const <AnkiNoteType>[
        AnkiNoteType(
          id: 2,
          name: 'Fushi',
          fields: <String>['Expression', 'Reading'],
        ),
      ],
      fieldMappings: const <String, String>{
        'Expression': '{expression}',
        'Reading': '{reading}',
      },
      allowDupes: true,
    );

/// 应用内桥形态（全字符串）的一次制卡请求，可选地拍上卡组覆盖。
String _rawPayload({String? deck}) {
  final Map<String, String> fields = <String, String>{
    'expression': '勉強',
    'reading': 'べんきょう',
  };
  return jsonEncode(
    deck == null
        ? fields
        : MiningRequestOverrides.attach(
            fields,
            MiningRequestOverrides(deckName: deck),
          ),
  );
}

Future<(MineOutcome, _RecordingAnkiConnectService)> _mineViaAnkiConnect(
  AnkiSettings settings,
  String rawPayloadJson,
) async {
  final _RecordingAnkiConnectService service = _RecordingAnkiConnectService();
  final _ConfiguredAnkiConnectRepository repo =
      _ConfiguredAnkiConnectRepository(service: service, settings: settings);
  final MineOutcome outcome = await repo.mineEntry(
    rawPayloadJson: rawPayloadJson,
    context: const AnkiMiningContext(sentence: ''),
  );
  return (outcome, service);
}

Future<(MineOutcome, List<String>)> _mineViaAnkiDroid(
  AnkiSettings settings,
  String rawPayloadJson,
) async {
  const MethodChannel channel = MethodChannel('app.fushi.reader/anki');
  final List<String> addedDecks = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'requestAnkidroidPermissions':
            return true;
          case 'addNote':
            final Map<String, dynamic> args = Map<String, dynamic>.from(
              call.arguments as Map,
            );
            addedDecks.add(args['deck'] as String);
            return 42;
          default:
            fail('Unexpected AnkiDroid channel call: ${call.method}');
        }
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  final MineOutcome outcome = await _ConfiguredAnkiRepository(settings)
      .mineEntry(
        rawPayloadJson: rawPayloadJson,
        context: const AnkiMiningContext(sentence: ''),
      );
  return (outcome, addedDecks);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiningRequestOverrides wire 编解码', () {
    test('toJson → fromJson 往返保留全部字段', () {
      const MiningRequestOverrides o = MiningRequestOverrides(
        deckName: 'Mining::Manga',
        omitAudio: true,
        audioStartDeltaMs: -250,
        audioEndDeltaMs: 400,
        omitImage: true,
        videoImageMode: 'current_frame',
        coverFrameAtMs: 12345,
        crop: MiningImageCrop(
          pageIndex: 3,
          left: 0.1,
          top: 0.2,
          right: 0.6,
          bottom: 0.9,
        ),
      );
      final MiningRequestOverrides back = MiningRequestOverrides.fromJson(
        jsonDecode(jsonEncode(o.toJson())) as Map<String, dynamic>,
      );
      expect(back.deckName, 'Mining::Manga');
      expect(back.omitAudio, isTrue);
      expect(back.audioStartDeltaMs, -250);
      expect(back.audioEndDeltaMs, 400);
      expect(back.omitImage, isTrue);
      expect(back.videoImageMode, 'current_frame');
      expect(back.coverFrameAtMs, 12345);
      expect(back.crop, o.crop);
    });

    test('attach 空覆盖原样返回、不留键', () {
      final Map<String, String> fields = <String, String>{'expression': '猫'};
      final Map<String, String> out = MiningRequestOverrides.attach(
        fields,
        const MiningRequestOverrides(),
      );
      expect(out, isNot(contains(MiningRequestOverrides.wireKey)));
      expect(out, fields);
    });

    test('attach → readFrom：全字符串线（JSON 字符串）', () {
      final Map<String, String> out = MiningRequestOverrides.attach(
        <String, String>{'expression': '猫'},
        const MiningRequestOverrides(deckName: 'Mining::Manga'),
      );
      expect(out[MiningRequestOverrides.wireKey], isA<String>());
      expect(out['expression'], '猫');
      final MiningRequestOverrides? read = MiningRequestOverrides.readFrom(
        Map<String, dynamic>.of(out),
      );
      expect(read?.deckName, 'Mining::Manga');
    });

    test('readFrom：保类型线（直接是 Map）', () {
      final MiningRequestOverrides? read = MiningRequestOverrides.readFrom(
        <String, dynamic>{
          'expression': '猫',
          MiningRequestOverrides.wireKey: <String, dynamic>{
            'deck': 'Mining',
            'omitImage': true,
          },
        },
      );
      expect(read?.deckName, 'Mining');
      expect(read?.omitImage, isTrue);
    });

    test('readFrom：缺键 / 空串 / 坏 JSON / 非 Map / 空对象 → null，不抛', () {
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{'expression': '猫'}),
        isNull,
      );
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{
          MiningRequestOverrides.wireKey: '',
        }),
        isNull,
      );
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{
          MiningRequestOverrides.wireKey: '{not json',
        }),
        isNull,
      );
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{
          MiningRequestOverrides.wireKey: '[1,2]',
        }),
        isNull,
      );
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{
          MiningRequestOverrides.wireKey: '{}',
        }),
        isNull,
      );
    });

    test('空白卡组名当作没覆盖', () {
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{
          MiningRequestOverrides.wireKey: '{"deck":"   "}',
        }),
        isNull,
      );
    });

    test('crop 缺字段 / 退化矩形 → null（宁可整页也不裁出空图）', () {
      expect(
        MiningImageCrop.fromJson(<String, dynamic>{
          'page': 0,
          'l': 0.1,
          't': 0.1,
          'r': 0.5,
        }),
        isNull,
      );
      expect(
        MiningImageCrop.fromJson(<String, dynamic>{
          'page': 0,
          'l': 0.5,
          't': 0.1,
          'r': 0.505,
          'b': 0.9,
        }),
        isNull,
      );
      // 退化 crop 是唯一的覆盖项时，整个覆盖读成 null。
      expect(
        MiningRequestOverrides.readFrom(<String, dynamic>{
          MiningRequestOverrides.wireKey:
              '{"crop":{"page":0,"l":0.2,"t":0.2,"r":0.2,"b":0.8}}',
        }),
        isNull,
      );
      // 越界坐标夹进 0..1、左右颠倒自动摆正。
      final MiningImageCrop? clamped = MiningImageCrop.fromJson(
        <String, dynamic>{'page': 1, 'l': 0.8, 't': -0.5, 'r': 0.2, 'b': 1.5},
      );
      expect(clamped?.left, 0.2);
      expect(clamped?.right, 0.8);
      expect(clamped?.top, 0);
      expect(clamped?.bottom, 1);
    });
  });

  group('AnkiMiningPayload.fromJson 读出 overrides', () {
    test('旧 payload 无此键 → null（行为不变）', () {
      final AnkiMiningPayload p = AnkiMiningPayload.fromJson(
        jsonDecode(_rawPayload()) as Map<String, dynamic>,
      );
      expect(p.overrides, isNull);
    });

    test('全字符串线上的覆盖被读出', () {
      final AnkiMiningPayload p = AnkiMiningPayload.fromJson(
        jsonDecode(_rawPayload(deck: 'Mining::Manga')) as Map<String, dynamic>,
      );
      expect(p.overrides?.deckName, 'Mining::Manga');
      expect(p.expression, '勉強');
    });
  });

  group('AnkiConnect：卡组覆盖', () {
    test('按名命中 → addNote 写进覆盖卡组，success.deckName 是它', () async {
      final (
        MineOutcome outcome,
        _RecordingAnkiConnectService service,
      ) = await _mineViaAnkiConnect(
        _settings(),
        _rawPayload(deck: 'Mining::Manga'),
      );
      expect(outcome.result, MineResult.success, reason: outcome.errorDetail);
      expect(service.addedDecks, <String>['Mining::Manga']);
      expect(outcome.deckName, 'Mining::Manga');
    });

    test('找不到 → 退回设置卡组（不新建）', () async {
      final (MineOutcome outcome, _RecordingAnkiConnectService service) =
          await _mineViaAnkiConnect(_settings(), _rawPayload(deck: 'Nope'));
      expect(outcome.result, MineResult.success, reason: outcome.errorDetail);
      expect(service.addedDecks, <String>['Mining']);
      expect(outcome.deckName, 'Mining');
    });

    test('无覆盖 → 设置卡组', () async {
      final (MineOutcome outcome, _RecordingAnkiConnectService service) =
          await _mineViaAnkiConnect(_settings(), _rawPayload());
      expect(outcome.result, MineResult.success);
      expect(service.addedDecks, <String>['Mining']);
      expect(outcome.deckName, 'Mining');
    });

    test('设置没选卡组：覆盖命中照样落卡；没覆盖仍 notConfigured', () async {
      final AnkiSettings noDeck = _settings(selectedDeckId: -1);
      final (MineOutcome hit, _RecordingAnkiConnectService s1) =
          await _mineViaAnkiConnect(noDeck, _rawPayload(deck: 'Mining::Manga'));
      expect(hit.result, MineResult.success, reason: hit.errorDetail);
      expect(s1.addedDecks, <String>['Mining::Manga']);

      final (MineOutcome miss, _) = await _mineViaAnkiConnect(
        noDeck,
        _rawPayload(deck: 'Nope'),
      );
      expect(miss.result, MineResult.notConfigured);

      // 旧判定次序：设置没卡组时，坏 payload 仍报 notConfigured 而非 failure。
      final (MineOutcome bad, _) = await _mineViaAnkiConnect(noDeck, '{oops');
      expect(bad.result, MineResult.notConfigured);
    });

    test('miningOverrides 不进任何 Anki 字段', () async {
      final (
        MineOutcome outcome,
        _RecordingAnkiConnectService service,
      ) = await _mineViaAnkiConnect(
        _settings(),
        _rawPayload(deck: 'Mining::Manga'),
      );
      expect(outcome.result, MineResult.success);
      final Map<String, String> fields = service.addedFields.single;
      expect(fields.keys, unorderedEquals(<String>['Expression', 'Reading']));
      for (final String v in fields.values) {
        expect(v, isNot(contains('Mining::Manga')));
        expect(v, isNot(contains(MiningRequestOverrides.wireKey)));
      }
    });
  });

  group('AnkiDroid：卡组覆盖', () {
    test('按名命中 → addNote 写进覆盖卡组，success.deckName 是它', () async {
      final (MineOutcome outcome, List<String> decks) = await _mineViaAnkiDroid(
        _settings(),
        _rawPayload(deck: 'Mining::Manga'),
      );
      expect(outcome.result, MineResult.success, reason: outcome.errorDetail);
      expect(decks, <String>['Mining::Manga']);
      expect(outcome.deckName, 'Mining::Manga');
    });

    test('找不到 → 退回设置卡组（不新建）', () async {
      final (MineOutcome outcome, List<String> decks) = await _mineViaAnkiDroid(
        _settings(),
        _rawPayload(deck: 'Nope'),
      );
      expect(outcome.result, MineResult.success, reason: outcome.errorDetail);
      expect(decks, <String>['Mining']);
      expect(outcome.deckName, 'Mining');
    });
  });
}
