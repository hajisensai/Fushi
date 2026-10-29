import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/web_mine_background.dart';
import 'package:fushi/src/mining/web_mine_idle.dart';

/// 后台空闲自动制卡（`web_mine_background.dart`）：用户没开着网页播放页时，空闲也要逐本
/// 打开制卡页跑完队列；用户回来让位，不在顶层页时不打断。
void main() {
  late Duration? idle;
  late List<String> pending;
  late bool atSurface;
  late List<String> opened;
  late Completer<void> page;
  late WebMineBackgroundRunner runner;

  WebMineBackgroundRunner build() => WebMineBackgroundRunner(
    pendingBookUids: () async => pending,
    atIdleSurface: () => atSurface,
    openMiningPage: (String uid) {
      opened.add(uid);
      page = Completer<void>();
      return page.future;
    },
    inputIdle: () => idle,
    // 计时器由测试手动 tick()，不让真 Timer 介入。
    createTimer: (Duration d, void Function() f) =>
        Timer(const Duration(days: 1), f),
  );

  setUp(() async {
    WebMineIdleScheduler.silentCaptureUnavailable = false;
    idle = Duration.zero;
    pending = <String>['book-a', 'book-b'];
    atSurface = true;
    opened = <String>[];
    page = Completer<void>();
    runner = build()..start();
    await runner.refresh();
  });

  tearDown(() => runner.dispose());

  test('播放页没开：系统空闲满阈值就打开第一本有待办的书', () {
    idle = kWebMineIdleThreshold - const Duration(seconds: 1);
    runner.scheduler.tick();
    expect(opened, isEmpty);
    idle = kWebMineIdleThreshold;
    runner.scheduler.tick();
    expect(opened, <String>['book-a']);
    expect(runner.running, isTrue);
  });

  test('一本跑完关页、还空闲：接着下一本；跑过的不再开', () async {
    idle = const Duration(minutes: 5);
    runner.scheduler.tick();
    expect(opened, <String>['book-a']);
    // 页面放弃了（待办还在），仍不该在这次空闲里反复开同一本。
    page.complete();
    await pumpEventQueue();
    expect(runner.running, isFalse);
    runner.scheduler.tick();
    expect(opened, <String>['book-a', 'book-b']);
    page.complete();
    await pumpEventQueue();
    runner.scheduler.tick();
    expect(opened, <String>['book-a', 'book-b'], reason: '都试过了');
  });

  test('用户回来后清掉「已试过」：下次空闲可以重开同一本', () async {
    idle = const Duration(minutes: 5);
    runner.scheduler.tick();
    pending = <String>['book-a'];
    // 跑的期间来了输入（空闲时长变短）。
    idle = const Duration(seconds: 1);
    runner.scheduler.tick();
    page.complete();
    await pumpEventQueue();
    idle = const Duration(minutes: 5);
    runner.scheduler.tick();
    expect(opened, <String>['book-a', 'book-a']);
  });

  test('不在顶层页（用户开着别的页）/ 没待办 / 静音录音不可用：不开', () async {
    idle = const Duration(minutes: 5);
    atSurface = false;
    runner.scheduler.tick();
    expect(opened, isEmpty);

    atSurface = true;
    WebMineIdleScheduler.silentCaptureUnavailable = true;
    runner.scheduler.tick();
    expect(opened, isEmpty);

    WebMineIdleScheduler.silentCaptureUnavailable = false;
    pending = <String>[];
    await runner.refresh();
    runner.scheduler.tick();
    expect(opened, isEmpty);
  });
}
