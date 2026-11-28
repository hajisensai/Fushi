import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/startup_stall_deadline.dart';
import 'package:fushi/src/startup/startup_timeline.dart';
import 'package:fushi/src/utils/misc/hang_watchdog_log.dart';

/// 启动期限（Dart 侧）：主窗到点还没显示 → 已走到的启动阶段写进 hang_watchdog.log。
///
/// 起因：Surface Pro 7+ 升级 3.4 后进程常驻后台、窗口永远不出；dump 里所有线程都在
/// 空闲等待（Dart 卡在某个 await），而启动阶段计时只在显窗后才落盘，卡住时什么都没留下。
void main() {
  late Directory tmp;
  late File log;

  setUp(() {
    StartupTimeline.debugReset();
    tmp = Directory.systemTemp.createTempSync('startup_stall_');
    log = File('${tmp.path}${Platform.pathSeparator}hang_watchdog.log');
  });

  tearDown(() {
    StartupTimeline.debugReset();
    tmp.deleteSync(recursive: true);
  });

  test('到点仍未显窗：写一行，带最后到达的阶段', () {
    fakeAsync((FakeAsync async) {
      StartupTimeline.begin();
      StartupTimeline.mark('binding+headless-gate');
      StartupTimeline.mark('support-dir-migration');
      final Timer? timer = armStartupStallDeadline(
        isWindows: true,
        resolveLogFile: () => log,
        now: () => DateTime(2026, 11, 26, 9, 5, 7),
      );
      expect(timer, isNotNull);
      async.elapse(kStartupStallDeadline - const Duration(seconds: 1));
      expect(log.existsSync(), isFalse, reason: '期限之前不写');
      async.elapse(const Duration(seconds: 1));
      final String content = log.readAsStringSync();
      expect(content, startsWith('[2026-11-26 09:05:07] pid=$pid startup: '));
      expect(content, contains('last phase reached=support-dir-migration'));
      expect(content, contains('support-dir-migration='));
      expect(content, endsWith('\r\n'));
    });
  });

  test('期限前已显窗（timeline 已 seal）：什么都不写', () {
    fakeAsync((FakeAsync async) {
      StartupTimeline.begin();
      StartupTimeline.mark('home-build');
      StartupTimeline.seal();
      armStartupStallDeadline(isWindows: true, resolveLogFile: () => log);
      async.elapse(kStartupStallDeadline * 2);
      expect(log.existsSync(), isFalse);
    });
  });

  test('非 Windows 不挂（日志与原生期限都只在 Windows）', () {
    expect(
      armStartupStallDeadline(isWindows: false, resolveLogFile: () => log),
      isNull,
    );
  });

  test('期限早于原生 45 s：原生抓 dump 时 Dart 这条已在盘上', () {
    // 与 windows/runner/startup_reveal_policy.h 的 kStartupRevealDeadlineMs 对齐。
    final String header = File(
      'windows/runner/startup_reveal_policy.h',
    ).readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'kStartupRevealDeadlineMs = (\d+);',
    ).firstMatch(header);
    expect(m, isNotNull);
    final int nativeMs = int.parse(m!.group(1)!);
    expect(kStartupStallDeadline.inMilliseconds, lessThan(nativeMs));
  });

  test('原生接线：看门狗每轮查启动期限、二次启动按「显示过」区分启动中 / 退出中', () {
    final String watchdog = File(
      'windows/runner/hang_watchdog.cpp',
    ).readAsStringSync();
    expect(watchdog, contains('CheckStartupReveal(s);'));
    expect(
      watchdog,
      contains('PostMessageW(g_main_window, ForceStartupRevealMessage()'),
      reason: '强制显窗必须投递式：主线程真卡住时看门狗线程不能跟着阻塞',
    );
    expect(watchdog, contains('SetPropW(g_main_window, kMainWindowShownProp'));
    final String runnerMain = File(
      'windows/runner/main.cpp',
    ).readAsStringSync();
    expect(runnerMain, contains('ClassifyExistingInstance('));
    expect(
      runnerMain,
      isNot(contains('!::IsWindowVisible(exiting)')),
      reason: '「不可见 ⇔ 正在退出」是错的：启动中的首实例同样不可见',
    );
  });

  test('折入后的日志与原生行同一格式、同一文件（读后清）', () {
    HangWatchdogLog.appendLine(
      log,
      describeStartupStall(
        after: kStartupStallDeadline,
        lastPhase: null,
        firstFrameRasterized: null,
        reachedPhases: 'total=0ms',
      ),
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    final String? content = HangWatchdogLog.readAndClear(log);
    expect(content, contains('last phase reached=(none)'));
    expect(content, contains('firstFrameRasterized=unknown'));
    expect(log.readAsStringSync(), isEmpty);
  });
}
