import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-2605：「卡已在 Anki」对话框的「新增为重复卡」必须真的能加出第二张。
///
/// 用户实测：设置里「允许重复」是默认关，点 ✓ → 弹对话框 → 点「新增为重复卡」→
/// toast「重复卡片，未导出」。根因：那颗按钮复用普通制卡回调，而两后端 `addNote`
/// 只看 `settings.allowDupes`——用户在对话框里的裁决根本没传到后端。
///
/// 修法：裁决走 payload 位 [AnkiMiningPayload.allowDuplicate]（对话框调用方用
/// [AnkiMiningPayload.withAllowDuplicate] 拍上），三个后端按
/// `settings.allowDupes || payload.allowDuplicate` 放行。这里钉死：
///   * payload 两条 wire 线（布尔 / 全字符串）都能解出该位，缺省 false；
///   * AnkiConnect：allowDupes=false 时带位的请求 `options.allowDuplicate` 为 true，
///     不带位的仍为 false（全局偏好不被顺手改掉）；
///   * AnkiDroid：allowDupes=false 时带位的请求**不发** `checkForDuplicates`，直接
///     `addNote`；不带位的仍先查重。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String kPayload = '{"expression":"掛かる","reading":"かかる"}';

  group('AnkiMiningPayload.allowDuplicate wire 解析', () {
    test('缺省 false（旧 payload 行为不变）', () {
      final AnkiMiningPayload p = AnkiMiningPayload.fromJson(
        jsonDecode(kPayload) as Map<String, dynamic>,
      );
      expect(p.allowDuplicate, isFalse);
    });

    test('应用内桥的全字符串线：\'true\' → true，其它字符串 → false', () {
      final Map<String, String> tagged = AnkiMiningPayload.withAllowDuplicate(
        <String, String>{'expression': '掛かる'},
      );
      expect(tagged[AnkiMiningPayload.allowDuplicateKey], 'true');
      expect(
        AnkiMiningPayload.fromJson(
          jsonDecode(jsonEncode(tagged)) as Map<String, dynamic>,
        ).allowDuplicate,
        isTrue,
      );
      expect(
        AnkiMiningPayload.fromJson(<String, dynamic>{
          'expression': 'x',
          AnkiMiningPayload.allowDuplicateKey: 'yes',
        }).allowDuplicate,
        isFalse,
      );
    });

    test('保类型的 JSON 线：布尔原样', () {
      expect(
        AnkiMiningPayload.fromJson(<String, dynamic>{
          'expression': 'x',
          AnkiMiningPayload.allowDuplicateKey: true,
        }).allowDuplicate,
        isTrue,
      );
    });

    test('withAllowDuplicate 不改原 map、其它键原样保留', () {
      final Map<String, String> original = <String, String>{
        'expression': '掛かる',
        'reading': 'かかる',
      };
      final Map<String, String> tagged =
          AnkiMiningPayload.withAllowDuplicate(original);
      expect(
          original.containsKey(AnkiMiningPayload.allowDuplicateKey), isFalse);
      expect(tagged['expression'], '掛かる');
      expect(tagged['reading'], 'かかる');
    });
  });

  group('AnkiConnect：payload 位放行这一次 addNote', () {
    const AnkiNoteType lapis = AnkiNoteType(
      id: 6,
      name: 'Lapis',
      fields: <String>['Expression', 'ExpressionReading'],
    );
    AnkiSettings settings() => const AnkiSettings(
          selectedDeckId: 1,
          selectedDeckName: 'Mining',
          selectedNoteTypeId: 6,
          selectedNoteTypeName: 'Lapis',
          availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
          availableNoteTypes: <AnkiNoteType>[lapis],
          fieldMappings: <String, String>{
            'Expression': '{expression}',
            'ExpressionReading': '{reading}',
          },
          allowDupes: false,
        );

    Future<Map<String, dynamic>> addNoteOptionsFor(String rawPayload) async {
      final List<Map<String, dynamic>> sink = <Map<String, dynamic>>[];
      final MockClient client = MockClient((http.Request request) async {
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        sink.add(body);
        return http.Response(
          jsonEncode(<String, Object?>{
            'result': body['action'] == 'addNote' ? 4242 : null,
            'error': null,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final _ConfiguredConnectRepo repo = _ConfiguredConnectRepo(
        service: AnkiConnectService(
          host: '127.0.0.1',
          port: 8765,
          client: client,
        ),
        settings: settings(),
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: rawPayload,
        context: const AnkiMiningContext(sentence: 's'),
      );
      expect(outcome.result, MineResult.success);
      final Map<String, dynamic> add = sink.singleWhere(
        (Map<String, dynamic> b) => b['action'] == 'addNote',
      );
      final Map<String, dynamic> note = (add['params']
          as Map<String, dynamic>)['note'] as Map<String, dynamic>;
      return note['options'] as Map<String, dynamic>;
    }

    test('带位：allowDupes=false 仍发 allowDuplicate:true', () async {
      final String tagged = jsonEncode(
        AnkiMiningPayload.withAllowDuplicate(
          Map<String, String>.from(jsonDecode(kPayload) as Map),
        ),
      );
      expect((await addNoteOptionsFor(tagged))['allowDuplicate'], isTrue);
    });

    test('不带位：仍按全局偏好 allowDuplicate:false（回归钉）', () async {
      expect((await addNoteOptionsFor(kPayload))['allowDuplicate'], isFalse);
    });
  });

  group('AnkiDroid：payload 位跳过 checkForDuplicates', () {
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');
    AnkiSettings settings() => const AnkiSettings(
          selectedDeckId: 1,
          selectedNoteTypeId: 2,
          availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
          availableNoteTypes: <AnkiNoteType>[
            AnkiNoteType(
              id: 2,
              name: 'Hibiki',
              fields: <String>['Expression', 'Reading'],
            ),
          ],
          fieldMappings: <String, String>{
            'Expression': '{expression}',
            'Reading': '{reading}',
          },
          allowDupes: false,
        );

    Future<List<String>> channelCallsFor(String rawPayload) async {
      final List<String> calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'requestAnkidroidPermissions') return true;
        calls.add(call.method);
        switch (call.method) {
          case 'checkForDuplicates':
            // 这台假机上这个词**确实**已有——不带位的请求必须在这里被拦。
            return true;
          case 'addNote':
            return 1654000000123;
          default:
            fail('unexpected channel call: ${call.method}');
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final MineOutcome outcome =
          await _ConfiguredDroidRepo(settings()).mineEntry(
        rawPayloadJson: rawPayload,
        context: const AnkiMiningContext(sentence: 's'),
      );
      calls.add('=> ${outcome.result.name}');
      return calls;
    }

    test('带位：不查重、直接 addNote 成功', () async {
      final String tagged = jsonEncode(
        AnkiMiningPayload.withAllowDuplicate(
          Map<String, String>.from(jsonDecode(kPayload) as Map),
        ),
      );
      expect(
        await channelCallsFor(tagged),
        <String>['addNote', '=> success'],
      );
    });

    test('不带位：仍先查重并被拦成 duplicate（回归钉）', () async {
      expect(
        await channelCallsFor(kPayload),
        <String>['checkForDuplicates', '=> duplicate'],
      );
    });
  });
}

class _ConfiguredConnectRepo extends AnkiConnectRepository {
  _ConfiguredConnectRepo({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConfiguredDroidRepo extends AnkiRepository {
  _ConfiguredDroidRepo(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}
