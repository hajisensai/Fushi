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
          return http.Response(
            jsonEncode({
              'result': [123],
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

  test('cooldown window is bounded, not permanent', () {
    expect(AnkiConnectRepository.kDuplicateCheckUnreachableCooldown,
        lessThanOrEqualTo(const Duration(minutes: 1)),
        reason: 'Anki coming back online must be picked up quickly');
    expect(AnkiConnectRepository.kDuplicateCheckUnreachableCooldown,
        greaterThan(Duration.zero));
  });
}
