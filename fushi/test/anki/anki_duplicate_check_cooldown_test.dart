import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-1302 ②：AnkiConnect 查重的「传输层不可达」熔断守卫。
///
/// 为什么这条在查词热路径上：`popup.js` 的 `createEntryHeader` 对结果里**每个
/// 词条**都发一次 `duplicateCheck` 桥调用，而 `createAnkiRepository()` 每次都
/// 新建一个 [AnkiConnectRepository]（所以冷却必须是**静态**的，实例字段存不住）。
/// AnkiConnect 主机被防火墙静默丢包 / VPN 断开 / 配成不在线的远程主机时，每次
/// 都要挂满连接超时（5s），N 个词条就是 N 条并发挂起的 HTTP 压在弹窗渲染路径上。
///
/// 熔断的红线是**只对传输层失败生效**：主机应答了业务错误说明它活着，短路它会
/// 让查重永久失灵（那是比慢更糟的正确性 bug）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 进程级静态状态：不清会跨用例污染。
    AnkiConnectRepository.resetDuplicateCheckCooldown();
  });

  tearDown(() {
    AnkiConnectRepository.resetDuplicateCheckCooldown();
  });

  /// 预置一份配置完整的 Anki 设置（有牌组 + 有笔记类型 + 第一字段），否则
  /// `isDuplicate` 会在触网之前就走 `deck == null` 早退，测不到熔断。
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
    );
    SharedPreferences.setMockInitialValues(
      {'fushi_anki_settings': jsonEncode(settings.toJson())},
    );
  }

  test(
      'transport-dead host is probed once, then short-circuited inside the '
      'cooldown window (BUG-1302)', () async {
    await seedSettings();
    var calls = 0;
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(
        client: MockClient((http.Request request) async {
          calls++;
          throw const SocketException('Connection refused');
        }),
      ),
    );

    expect(await repo.isDuplicate('日本語', 'にほんご'), isFalse);
    final int callsAfterFirst = calls;
    expect(callsAfterFirst, greaterThan(0),
        reason: 'the first probe must actually try the host');
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isTrue,
        reason: 'a transport failure must arm the cooldown');

    // 模拟一次多词条渲染：后续每个词条都不该再触网。
    for (var i = 0; i < 5; i++) {
      expect(await repo.isDuplicate('単語$i', 'たんご'), isFalse);
    }

    expect(calls, callsAfterFirst,
        reason: 'cooldown window must issue zero further HTTP requests');
  });

  test(
      'cooldown is shared across repository instances (createAnkiRepository '
      'builds a fresh one per bridge call)', () async {
    await seedSettings();
    var calls = 0;
    AnkiConnectRepository newRepo() => AnkiConnectRepository(
          service: AnkiConnectService(
            client: MockClient((http.Request request) async {
              calls++;
              throw const SocketException('Connection refused');
            }),
          ),
        );

    expect(await newRepo().isDuplicate('日本語', 'にほんご'), isFalse);
    final int callsAfterFirst = calls;

    // 每个词条一个全新 repo —— 实例字段版的冷却在这里会完全失效。
    for (var i = 0; i < 5; i++) {
      expect(await newRepo().isDuplicate('単語$i', 'たんご'), isFalse);
    }

    expect(calls, callsAfterFirst,
        reason: 'the cooldown must be process-wide, not per-instance');
  });

  test(
      'a reachable host answering a business error does NOT arm the cooldown '
      '(short-circuiting it would break duplicate detection for good)',
      () async {
    await seedSettings();
    var calls = 0;
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(
        client: MockClient((http.Request request) async {
          calls++;
          // 主机活着，只是这个 action 报了业务错误。
          return http.Response(
            jsonEncode(
                {'result': null, 'error': 'collection is not available'}),
            200,
          );
        }),
      ),
    );

    expect(await repo.isDuplicate('日本語', 'にほんご'), isFalse);
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isFalse,
        reason: 'an answering host is reachable — never cool it down');

    expect(await repo.isDuplicate('単語', 'たんご'), isFalse);
    expect(calls, greaterThan(1),
        reason: 'a reachable host must keep being queried');
  });

  test('a successful probe clears an armed cooldown immediately', () async {
    await seedSettings();
    var fail = true;
    var calls = 0;
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(
        client: MockClient((http.Request request) async {
          calls++;
          if (fail) throw const SocketException('Connection refused');
          // BUG-1915：查重现在问 `canAddNotesWithErrorDetail`（与 addNote 同源），
          // 应答形状随之改变；本用例断言的冷却语义不变。
          return http.Response(
            jsonEncode({
              'result': [
                {
                  'canAdd': false,
                  'error': 'cannot create note because it is a duplicate',
                },
              ],
              'error': null,
            }),
            200,
          );
        }),
      ),
    );

    expect(await repo.isDuplicate('日本語', 'にほんご'), isFalse);
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isTrue);

    // Anki 重新上线：手动解除冷却模拟窗口到期，第一次成功探测必须清零状态。
    AnkiConnectRepository.resetDuplicateCheckCooldown();
    fail = false;
    final int callsBefore = calls;

    expect(await repo.isDuplicate('日本語', 'にほんご'), isTrue,
        reason: 'a live host must report the duplicate');
    expect(calls, greaterThan(callsBefore));
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isFalse);
  });

  /// 与 [seedSettings] 同一份配置，另外把第一字段映射好——否则 `mineEntry` 会在触网
  /// 之前就以「All fields are empty」早退，测不到 addNote 那一步。
  Future<void> seedMineSettings() async {
    final settings = AnkiSettings(
      selectedDeckId: 0,
      selectedDeckName: 'Mining',
      selectedNoteTypeId: 0,
      selectedNoteTypeName: 'Vocab',
      availableDecks: const [AnkiDeck(id: 0, name: 'Mining')],
      availableNoteTypes: const [
        AnkiNoteType(id: 0, name: 'Vocab', fields: ['Expression', 'Meaning']),
      ],
      fieldMappings: const {'Expression': '{expression}'},
      allowDupes: true,
    );
    SharedPreferences.setMockInitialValues(
      {'fushi_anki_settings': jsonEncode(settings.toJson())},
    );
  }

  http.Response ankiJson(Object? result, {String? error}) => http.Response(
        jsonEncode({'result': result, 'error': error}),
        200,
      );

  // 用户的原始路径：Anki 没开着时查了词（冷却武装）→ 打开 Anki → 点「+」制卡成功 →
  // popup.js 紧跟着回问 duplicateCheck。冷却此前只在 isDuplicate 自己成功时清零，
  // 于是这次回问还在窗内被短路成 false，刚制好的卡停在「+」——与 iOS 上「加完卡没出
  // 打勾」同一个症状，只是成因在冷却而不在时序。
  test('mineEntry 成功解除查重冷却：刚制好的卡必须画得出 ✓', () async {
    await seedMineSettings();
    var transportDead = true;
    var cardInAnki = false;
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(
        client: MockClient((http.Request request) async {
          if (transportDead) throw const SocketException('Connection refused');
          final body = jsonDecode(request.body) as Map<String, Object?>;
          switch (body['action'] as String?) {
            case 'addNote':
              cardInAnki = true;
              return ankiJson(1701);
            case 'canAddNotesWithErrorDetail':
              return ankiJson([
                cardInAnki
                    ? {
                        'canAdd': false,
                        'error': 'cannot create note because it is a duplicate',
                      }
                    : {'canAdd': true},
              ]);
            default:
              return ankiJson(null);
          }
        }),
      ),
    );

    expect(await repo.isDuplicate('日本語', 'にほんご'), isFalse);
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isTrue,
        reason: '主机不可达时武装冷却是 BUG-1302 的正常行为');

    // 用户打开了 Anki，然后点「+」。制卡链路不看冷却，照常成功。
    transportDead = false;
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: '{"expression":"日本語","reading":"にほんご"}',
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(outcome.result, MineResult.success);
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isFalse,
        reason: '制卡拿到应答就是「主机可达」的铁证，冷却必须撤掉');
    expect(await repo.isDuplicate('日本語', 'にほんご'), isTrue,
        reason: '制卡后的回问必须问到真 Anki，否则 ✓ 画不出来');
  });

  test('mineEntry 撞重复也解除冷却（Anki 明确应答了，就是可达）', () async {
    await seedMineSettings();
    var transportDead = true;
    final repo = AnkiConnectRepository(
      service: AnkiConnectService(
        client: MockClient((http.Request request) async {
          if (transportDead) throw const SocketException('Connection refused');
          final body = jsonDecode(request.body) as Map<String, Object?>;
          if (body['action'] == 'addNote') {
            return ankiJson(null,
                error: 'cannot create note because it is a duplicate');
          }
          return ankiJson(null);
        }),
      ),
    );

    expect(await repo.isDuplicate('日本語', 'にほんご'), isFalse);
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isTrue);

    transportDead = false;
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: '{"expression":"日本語","reading":"にほんご"}',
      context: const AnkiMiningContext(sentence: ''),
    );
    // 「这张卡已经有了」是 Anki 给的应答：popup 会据此画 ✓，冷却更没有理由还拦着
    // 后续查重。
    expect(outcome.result, MineResult.duplicate);
    expect(AnkiConnectRepository.isDuplicateCheckInCooldown, isFalse);
  });

  test('cooldown window is bounded, not permanent', () {
    expect(AnkiConnectRepository.kDuplicateCheckUnreachableCooldown,
        lessThanOrEqualTo(const Duration(minutes: 1)),
        reason: 'Anki coming back online must be picked up quickly');
    expect(AnkiConnectRepository.kDuplicateCheckUnreachableCooldown,
        greaterThan(Duration.zero));
  });
}
