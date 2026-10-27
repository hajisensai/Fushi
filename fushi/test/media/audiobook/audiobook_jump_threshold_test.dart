import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_jump_threshold.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/fake_just_audio.dart';
import '../../helpers/source_guard.dart';

// 反馈 0AwuVqrNFn：有声书「返回原位置」胶囊的跳转阈值。
//   1) 出厂默认 2 分钟（旧值写死 15 秒：往回拖 1 分钟也弹胶囊）；
//   2) 档位 15 秒–30 分钟，任意存值归到最近档位；
//   3) 偏好读写往返 + 跨 reload；
//   4) 控制器按注入的实时阈值判「跳转」，会话 / AppModel 把设置接进控制器。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  test('出厂默认 2 分钟，档位落在 15 秒–30 分钟', () {
    expect(kAudiobookJumpThresholdSecDefault, 120);
    expect(kAudiobookJumpThresholdSecChoices.first, 15);
    expect(kAudiobookJumpThresholdSecChoices.last, 1800);
    expect(
      kAudiobookJumpThresholdSecChoices,
      contains(kAudiobookJumpThresholdSecDefault),
    );
    final List<int> sorted = List<int>.of(kAudiobookJumpThresholdSecChoices)
      ..sort();
    expect(kAudiobookJumpThresholdSecChoices, sorted);
  });

  test('任意存值归到最近档位（区间外夹到两端，等距取较大档）', () {
    expect(normalizeAudiobookJumpThresholdSec(0), 15);
    expect(normalizeAudiobookJumpThresholdSec(-30), 15);
    expect(normalizeAudiobookJumpThresholdSec(15), 15);
    expect(normalizeAudiobookJumpThresholdSec(45), 60);
    expect(normalizeAudiobookJumpThresholdSec(130), 120);
    expect(normalizeAudiobookJumpThresholdSec(99999), 1800);
    for (final int choice in kAudiobookJumpThresholdSecChoices) {
      expect(normalizeAudiobookJumpThresholdSec(choice), choice);
    }
  });

  group('控制器真实 seek 漏斗（onBeforeAudioJump）', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // 每个场景从固定的出发点（载入位置 10:00）只做一次拖动：出发点就是载入位置，
    // 与假后端 seek 后位置回报的时序无关。
    Future<List<int>> dragFrom10Min({
      required int toMs,
      int Function()? thresholdSec,
    }) async {
      final AudiobookPlayerController c = await loadFakeAudiobookController(
        initialPositionMs: 600000,
        duration: const Duration(minutes: 40),
      );
      addTearDown(c.dispose);
      if (thresholdSec != null) c.audioJumpThresholdSec = thresholdSec;
      final List<int> departures = <int>[];
      c.onBeforeAudioJump = departures.add;
      await c.seekGlobalMs(toMs);
      return departures;
    }

    test('未注入设置按 2 分钟：从 10:00 拖回 9:00 不进历史，拖回 8:00 进', () async {
      // 反馈原场景：没听清往回拖 1 分钟——旧 15 秒阈值会弹返回胶囊。
      expect(
        await dragFrom10Min(toMs: 540000),
        isEmpty,
        reason: '1 分钟的回拖不是「跳转」',
      );
      expect(await dragFrom10Min(toMs: 480000), <int>[
        600000,
      ], reason: '2 分钟的跳转记下出发点');
    });

    test('设置是实时读的：同一次 20 秒拖动，2 分钟档不进、15 秒档进', () async {
      int thresholdSec = 120;
      final AudiobookPlayerController c = await loadFakeAudiobookController(
        initialPositionMs: 600000,
        duration: const Duration(minutes: 40),
      );
      addTearDown(c.dispose);
      c.audioJumpThresholdSec = () => thresholdSec;
      final List<int> departures = <int>[];
      c.onBeforeAudioJump = departures.add;
      // 只看阈值判据：出发点取的是控制器当时的全书位置。
      final int from = c.globalPosition.inMilliseconds;
      await c.seekGlobalMs(from + 20000);
      expect(departures, isEmpty);

      thresholdSec = 15;
      final int from2 = c.globalPosition.inMilliseconds;
      await c.seekGlobalMs(from2 + 20000);
      expect(departures, <int>[from2]);
    });

    test('调成 30 分钟：10 分钟的跳转也不进历史', () async {
      expect(
        await dragFrom10Min(toMs: 1200000, thresholdSec: () => 1800),
        isEmpty,
      );
    });
  });

  test('用户调成 15 秒：20 秒的跳转就进历史；调成 30 分钟：10 分钟不进', () {
    expect(
      AudiobookPlayerController.isAudioJump(
        fromGlobalMs: 0,
        targetGlobalMs: 20000,
        thresholdSec: 15,
      ),
      isTrue,
    );
    expect(
      AudiobookPlayerController.isAudioJump(
        fromGlobalMs: 0,
        targetGlobalMs: 600000,
        thresholdSec: 1800,
      ),
      isFalse,
    );
  });

  group('PreferencesRepository 跳转距离', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('没写过 = 2 分钟；写入归档位并跨 reload 持久化', () async {
      expect(repo.audiobookJumpThresholdSec, 120);
      await repo.setAudiobookJumpThresholdSec(600);
      expect(repo.audiobookJumpThresholdSec, 600);
      await repo.setAudiobookJumpThresholdSec(7);
      expect(repo.audiobookJumpThresholdSec, 15);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.audiobookJumpThresholdSec, 15);
    });
  });

  test('设置接线：AppModel → 会话闭包 → 控制器每次跳转读实时值', () {
    final String appModel = maskComments(
      File('lib/src/models/app_model.dart').readAsStringSync(),
    );
    expect(
      appModel,
      contains('audioJumpThresholdSec: () => audiobookJumpThresholdSec'),
    );
    final String session = maskComments(
      File('lib/src/media/audiobook/audiobook_session.dart').readAsStringSync(),
    );
    expect(
      session,
      contains('..audioJumpThresholdSec = _audioJumpThresholdSec'),
    );
    final String controller = maskComments(
      File(
        'lib/src/media/audiobook/audiobook_controller.dart',
      ).readAsStringSync(),
    );
    expect(controller, contains('thresholdSec: audioJumpThresholdSec()'));
    final String schema = maskComments(
      File(
        'lib/src/settings/settings_schema_listening.dart',
      ).readAsStringSync(),
    );
    expect(schema, contains("id: 'listening.audiobook_jump_threshold'"));
    expect(schema, contains('setAudiobookJumpThresholdSec(value)'));
  });
}
