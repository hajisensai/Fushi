import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/listening_reminder.dart';

/// 可变的偏好桩：改值后 [changed] 通知服务。
class _FakeSettings extends ChangeNotifier {
  bool enabled = false;
  int minutes = 60;

  void changed() => notifyListeners();
}

void main() {
  group('normalizeListeningReminderMinutes', () {
    test('choices include the default', () {
      expect(
        kListeningReminderMinutesChoices,
        contains(kListeningReminderMinutesDefault),
      );
    });

    test('snaps stored values to the nearest choice', () {
      expect(normalizeListeningReminderMinutes(60), 60);
      expect(normalizeListeningReminderMinutes(1), 15);
      expect(normalizeListeningReminderMinutes(50), 45);
      expect(normalizeListeningReminderMinutes(1000), 120);
      // 等距取较大档。
      expect(normalizeListeningReminderMinutes(75), 90);
    });
  });

  group('ListeningReminderTracker', () {
    const Duration threshold = Duration(minutes: 10);
    const Duration step = Duration(minutes: 1);

    test('fires once the continuous listening time reaches the threshold', () {
      final ListeningReminderTracker tracker = ListeningReminderTracker();
      for (int i = 0; i < 9; i++) {
        expect(
          tracker.record(playing: true, elapsed: step, threshold: threshold),
          isFalse,
        );
      }
      expect(
        tracker.record(playing: true, elapsed: step, threshold: threshold),
        isTrue,
      );
      // 提醒后从零重计下一轮。
      expect(tracker.listened, Duration.zero);
    });

    test('a short pause does not reset the count', () {
      final ListeningReminderTracker tracker = ListeningReminderTracker();
      for (int i = 0; i < 5; i++) {
        tracker.record(playing: true, elapsed: step, threshold: threshold);
      }
      tracker.record(
        playing: false,
        elapsed: const Duration(minutes: 4),
        threshold: threshold,
      );
      expect(tracker.listened, const Duration(minutes: 5));
    });

    test('a break of at least breakDuration resets the count', () {
      final ListeningReminderTracker tracker = ListeningReminderTracker();
      for (int i = 0; i < 9; i++) {
        tracker.record(playing: true, elapsed: step, threshold: threshold);
      }
      tracker.record(
        playing: false,
        elapsed: kListeningReminderBreak,
        threshold: threshold,
      );
      expect(tracker.listened, Duration.zero);
      expect(
        tracker.record(playing: true, elapsed: step, threshold: threshold),
        isFalse,
      );
    });

    test('idle time between short pauses is not cumulative across playing', () {
      final ListeningReminderTracker tracker = ListeningReminderTracker();
      tracker.record(playing: true, elapsed: step, threshold: threshold);
      tracker.record(
        playing: false,
        elapsed: const Duration(minutes: 3),
        threshold: threshold,
      );
      tracker.record(playing: true, elapsed: step, threshold: threshold);
      tracker.record(
        playing: false,
        elapsed: const Duration(minutes: 3),
        threshold: threshold,
      );
      expect(tracker.listened, const Duration(minutes: 2));
    });
  });

  group('ListeningReminderService', () {
    late _FakeSettings settings;
    late bool playing;
    late int reminders;

    ListeningReminderService build(FakeAsync fake) {
      return ListeningReminderService(
        enabled: () => settings.enabled,
        threshold: () => Duration(minutes: settings.minutes),
        isPlaying: () => playing,
        onReminder: () async => reminders++,
        settings: settings,
        clock: () => fake.getClock(DateTime(2026, 11, 16)).now(),
      );
    }

    setUp(() {
      settings = _FakeSettings();
      playing = true;
      reminders = 0;
    });

    test('does nothing while disabled (no timer)', () {
      fakeAsync((FakeAsync fake) {
        final ListeningReminderService service = build(fake)..start();
        expect(service.running, isFalse);
        fake.elapse(const Duration(hours: 3));
        expect(reminders, 0);
        service.dispose();
      });
    });

    test('reminds every interval while something keeps playing', () {
      fakeAsync((FakeAsync fake) {
        settings
          ..enabled = true
          ..minutes = 30;
        final ListeningReminderService service = build(fake)..start();
        expect(service.running, isTrue);
        fake.elapse(const Duration(minutes: 29));
        expect(reminders, 0);
        fake.elapse(const Duration(minutes: 1));
        expect(reminders, 1);
        fake.elapse(const Duration(minutes: 30));
        expect(reminders, 2);
        service.dispose();
      });
    });

    test('does not count time when nothing plays', () {
      fakeAsync((FakeAsync fake) {
        settings.enabled = true;
        playing = false;
        final ListeningReminderService service = build(fake)..start();
        fake.elapse(const Duration(hours: 2));
        expect(reminders, 0);
        service.dispose();
      });
    });

    test('turning it off stops the timer and clears the count', () {
      fakeAsync((FakeAsync fake) {
        settings
          ..enabled = true
          ..minutes = 30;
        final ListeningReminderService service = build(fake)..start();
        fake.elapse(const Duration(minutes: 20));
        settings
          ..enabled = false
          ..changed();
        expect(service.running, isFalse);
        expect(service.listened, Duration.zero);
        fake.elapse(const Duration(hours: 1));
        expect(reminders, 0);
        // 再打开从零计：20 分钟的旧累计不带过来。
        settings
          ..enabled = true
          ..changed();
        fake.elapse(const Duration(minutes: 29));
        expect(reminders, 0);
        fake.elapse(const Duration(minutes: 1));
        expect(reminders, 1);
        service.dispose();
      });
    });

    test('a changed interval applies to the running round', () {
      fakeAsync((FakeAsync fake) {
        settings
          ..enabled = true
          ..minutes = 60;
        final ListeningReminderService service = build(fake)..start();
        fake.elapse(const Duration(minutes: 20));
        settings
          ..minutes = 15
          ..changed();
        // 已累计 20 分钟 ≥ 15 分钟：下一次采样就提醒。
        fake.elapse(kListeningReminderTick);
        expect(reminders, 1);
        service.dispose();
      });
    });

    test('a huge gap after suspension is not credited as listening', () {
      fakeAsync((FakeAsync fake) {
        settings
          ..enabled = true
          ..minutes = 60;
        // 时钟可额外前跳：模拟应用被挂起几小时、计时器没触发，唤醒后补发一次 tick。
        Duration jump = Duration.zero;
        final ListeningReminderService service = ListeningReminderService(
          enabled: () => settings.enabled,
          threshold: () => Duration(minutes: settings.minutes),
          isPlaying: () => playing,
          onReminder: () async => reminders++,
          settings: settings,
          clock: () => fake.getClock(DateTime(2026, 11, 16)).now().add(jump),
        )..start();
        fake.elapse(const Duration(minutes: 10));
        expect(service.listened, const Duration(minutes: 10));
        jump = const Duration(hours: 5);
        fake.elapse(kListeningReminderTick);
        // 几小时不计入：挂起部分按休息清零，只认最近 2×tick。
        expect(reminders, 0);
        expect(service.listened, kListeningReminderTick * 2);
        // 之后正常节拍照常累计，满 60 分钟才提醒。
        fake.elapse(const Duration(minutes: 58));
        expect(reminders, 0);
        fake.elapse(const Duration(minutes: 1));
        expect(reminders, 1);
        service.dispose();
      });
    });

    test('a gap shorter than the break keeps the earlier count', () {
      fakeAsync((FakeAsync fake) {
        settings
          ..enabled = true
          ..minutes = 60;
        Duration jump = Duration.zero;
        final ListeningReminderService service = ListeningReminderService(
          enabled: () => settings.enabled,
          threshold: () => Duration(minutes: settings.minutes),
          isPlaying: () => playing,
          onReminder: () async => reminders++,
          settings: settings,
          clock: () => fake.getClock(DateTime(2026, 11, 16)).now().add(jump),
        )..start();
        fake.elapse(const Duration(minutes: 10));
        // 多出 2 分钟（< 5 分钟休息）：超出部分不算收听，也不清零。
        jump = const Duration(minutes: 2);
        fake.elapse(kListeningReminderTick);
        expect(
          service.listened,
          const Duration(minutes: 10) + kListeningReminderTick * 2,
        );
        service.dispose();
      });
    });

    test('dispose stops the timer', () {
      fakeAsync((FakeAsync fake) {
        settings
          ..enabled = true
          ..minutes = 15;
        final ListeningReminderService service = build(fake)..start();
        service.dispose();
        fake.elapse(const Duration(hours: 1));
        expect(reminders, 0);
      });
    });
  });
}
