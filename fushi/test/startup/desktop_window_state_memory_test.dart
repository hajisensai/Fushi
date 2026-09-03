import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/desktop_window_placement.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「记住上次关闭时的窗口大小/位置」曾被用户报成"没有这个功能"。几何本身一直是记的
/// （x/y/宽/高 四个键），真正丢的是**最大化状态**：`saveCurrentBoundsNow` 遇到最大化
/// 直接 return，于是习惯最大化使用的用户每次冷启动都退回默认居中尺寸。
///
/// 这里锁住两件事：① 最大化 flag 真的落盘且与 restore 几何正交；② 退出路径的可见性
/// 与有界性（先隐藏窗口再 flush，且每个无界等待都有上界）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopWindowPlacement 最大化记忆', () {
    setUp(() {
      DesktopWindowPlacement.resetSaveCacheForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('rememberMaximized(true) 落盘最大化 flag', () async {
      await DesktopWindowPlacement.rememberMaximized(true);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('desktop_main_window_maximized'), isTrue);
    });

    test('rememberMaximized 不碰四个 restore 几何键', () async {
      // 最大化时窗口的真实 bounds 是整个工作区。若把它写进 restore 键，用户按
      // 「向下还原」就永久拿不回自己的窗口尺寸了——这两组状态必须正交。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'desktop_main_window_x': 120.0,
        'desktop_main_window_y': 80.0,
        'desktop_main_window_width': 1024.0,
        'desktop_main_window_height': 768.0,
      });

      await DesktopWindowPlacement.rememberMaximized(true);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('desktop_main_window_x'), 120.0);
      expect(prefs.getDouble('desktop_main_window_y'), 80.0);
      expect(prefs.getDouble('desktop_main_window_width'), 1024.0);
      expect(prefs.getDouble('desktop_main_window_height'), 768.0);
      expect(prefs.getBool('desktop_main_window_maximized'), isTrue);
    });

    test('rememberMaximized(false) 复位，还原态不会被记成最大化', () async {
      await DesktopWindowPlacement.rememberMaximized(true);
      await DesktopWindowPlacement.rememberMaximized(false);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('desktop_main_window_maximized'), isFalse);
    });

    test('启动期在 setBounds 之后才 maximize（先落还原几何再最大化）', () {
      final String source =
          File('lib/src/startup/desktop_window_placement.dart')
              .readAsStringSync();
      final int setBoundsAt = source.indexOf('windowManager.setBounds(');
      final int maximizeAt = source.indexOf('windowManager.maximize()');

      expect(setBoundsAt, isNonNegative);
      expect(maximizeAt, isNonNegative,
          reason: '启动期必须恢复最大化状态，否则最大化用户每次都退回默认尺寸。');
      expect(maximizeAt, greaterThan(setBoundsAt),
          reason: '先 setBounds 再 maximize，「向下还原」才能拿回上次的窗口尺寸。');
    });
  });

  group('退出路径：先隐藏窗口，且每步有界', () {
    late String main;

    setUpAll(() {
      main = File('lib/main.dart').readAsStringSync();
    });

    test('最大化/还原事件直连记忆（不能只靠 resize 去抖）', () {
      // Windows 上最大化不保证伴随 onWindowResized，只挂 resize 会漏记状态。
      expect(main, contains('void onWindowMaximize()'));
      expect(main, contains('void onWindowUnmaximize()'));
      expect(main, contains('DesktopWindowPlacement.rememberMaximized('));
    });

    test('窗口在 flush 之前隐藏，但在保存几何之后', () {
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      expect(hookAt, isNonNegative);

      final int saveAt =
          main.indexOf('DesktopWindowPlacement.saveCurrentBoundsNow()', hookAt);
      final int hideAt = main.indexOf('windowManager.hide()', hookAt);
      final int flushAt =
          main.indexOf('ExitFlushRegistry.instance.flushAll()', hookAt);

      expect(saveAt, isNonNegative);
      expect(hideAt, isNonNegative,
          reason: '点 X 后必须立刻隐藏主窗：用户感知的「关闭」到此为止，剩下的清理'
              '在看不见的窗口背后跑。');
      expect(hideAt, greaterThan(saveAt), reason: '窗口隐藏之后读到的几何不可信，保存必须排在隐藏之前。');
      expect(flushAt, greaterThan(hideAt),
          reason: 'flush / checkpoint 都应发生在窗口已经消失之后。');
    });

    test('退出总预算看门狗存在且会强制终止', () {
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      final int watchdogAt = main.indexOf('_exitWatchdogTimeout', hookAt);
      expect(watchdogAt, isNonNegative,
          reason: '窗口已隐藏后若清理不归，进程就成了用户看不见也关不掉的僵尸。');
      expect(main, contains('exit watchdog fired after'));
      // 原断言只查到那句日志为止 —— 把回调体里的 exit(0) 删掉它照样绿，用例名
      // 承诺的「会强制终止」根本没被钉住。取 Timer 到其闭合之间的片段。
      final int timerAt = main.indexOf('Timer(_exitWatchdogTimeout', hookAt);
      expect(timerAt, isNonNegative);
      final int closeAt = main.indexOf('});', timerAt);
      expect(closeAt, greaterThan(timerAt));
      expect(main.substring(timerAt, closeAt), contains('exit(0)'),
          reason: '看门狗到点必须真的终止进程，只打一行日志等于没有兜底');
    });

    test('看门狗不得在最后一步之前 cancel', () {
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      final int exitAppAt =
          main.indexOf('platformServices.lifecycle.exitApp()', hookAt);
      final int cancelAt = main.indexOf('exitWatchdog.cancel()', hookAt);
      expect(exitAppAt, isNonNegative);
      expect(cancelAt, isNonNegative);
      // exitApp() = WindowsNativePreExit + exit(0)，历史上最会不归的就是它（原生
      // WebView2 / DirectComposition 同步析构）。窗口此刻已 hide，卡在这里就是
      // 「用户看不见也关不掉的僵尸」—— 而看门狗恰恰在它之前被撤了岗。
      expect(cancelAt, greaterThan(exitAppAt),
          reason: '看门狗必须一直守到 exitApp 之后；exit(0) 生效时它根本没机会跑');
    });

    test('关库有超时上界（退出链上过去唯一的无界等待）', () {
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      final int closeAt = main.indexOf('.closeDatabase(', hookAt);
      expect(closeAt, isNonNegative);
      expect(
        main.substring(closeAt, closeAt + 240),
        contains('_closeDatabaseOnExitTimeout'),
        reason: '数据根迁移路径早就有这层保护，退出路径一直缺。',
      );
    });
  });

  group('下载管线 stop 不再无界忙等', () {
    test('while (_running) 有超时放行', () {
      final String source = File(
        'lib/src/media/video/download/video_download_pipeline_service.dart',
      ).readAsStringSync();

      // 同文件里 VideoDownloadLeaseGuard 也有 stop()，锚点必须先框到目标类，
      // 否则守卫会去检查一个跟退出路径无关的方法体（断言恒假 / 恒真都不对）。
      final int classAt = source.indexOf('class VideoDownloadPipelineService {');
      expect(classAt, isNonNegative);
      final int stopAt =
          source.indexOf('Future<void> stop({Duration? drainTimeout}) async {',
              classAt);
      expect(stopAt, isNonNegative,
          reason: '上界必须是**可选参数**，不能是 stop() 的全局语义');
      final String body = source.substring(stopAt, stopAt + 600);

      expect(body, contains('while (_running)'));
      expect(
        body,
        contains('drainTimeout != null && waited.elapsed >= drainTimeout'),
        reason: '不传上界时必须等到真收尾：迁移导入 / 备份导入 / 数据根迁移也走 '
            'closeDatabase，它们关库后要在文件层动整个 DB 目录，放行一个在飞的 '
            '_process 是数据安全问题（BUG-1505），不是噪声问题。',
      );
    });

    test('1.5s 上界只由退出路径传进来', () {
      // 守卫必须钉「谁传」，而不只是「有没有这个常量」：把上界写死回 stop() 里，
      // 上面那条断言换个写法也能绿，而 BUG-1505 会在迁移路径上原地复活。
      final String mainSource = File('lib/main.dart').readAsStringSync();
      final int hookAt =
          mainSource.indexOf('_flushAndExitForWindowClose() async');
      final int closeAt = mainSource.indexOf('.closeDatabase(', hookAt);
      expect(closeAt, isNonNegative);
      expect(
        mainSource.substring(closeAt, closeAt + 240),
        contains(
            'pipelineDrainTimeout: VideoDownloadPipelineService.stopDrainTimeout'),
        reason: '退出路径必须显式传上界；其余 closeDatabase 调用方一律等到真收尾',
      );
    });

    test('正在退出的首实例不得接管第二实例的文件（Windows 单实例）', () {
      final String runner = File('windows/runner/main.cpp').readAsStringSync();
      // main.dart 的退出链第一步就 windowManager.hide()，此后进程最长还活约 6s，
      // 互斥量一直被它持有、隐藏窗口也照样被 FindWindowW 找得到。转交给它 = 路径
      // 整个丢掉；只前置一个看不见的窗口 = 用户双击视频「点了没反应」。
      expect(runner, contains('::IsWindowVisible(exiting)'),
          reason: '必须能把「正在退出」和「正常运行」区分开');
      final int probeAt = runner.indexOf('::IsWindowVisible(exiting)');
      final int waitAt =
          runner.indexOf('WaitForSingleInstanceMutex', probeAt);
      expect(waitAt, greaterThan(probeAt),
          reason: '认出它在退出之后要等它释放互斥量，然后本进程按首实例正常启动');
      final int handoffAt =
          runner.indexOf('SendExternalVideoPath', probeAt);
      expect(handoffAt, greaterThan(waitAt),
          reason: '转交分支必须排在这道判定之后，否则仍会把路径交给一个将死的进程');
    });
  });

  group('Windows 原生 pre-exit 有超时', () {
    test('prepareForProcessExit 不再无界等待', () {
      final String source =
          File('lib/src/platform/desktop/windows_native_pre_exit.dart')
              .readAsStringSync();

      expect(source, contains('prepareTimeout'));
      final int invokeAt =
          source.indexOf("invokeMethod<void>('prepareForProcessExit')");
      expect(invokeAt, isNonNegative);
      expect(
        source.substring(invokeAt, invokeAt + 120),
        contains('.timeout('),
        reason: '原生侧在平台线程上同步拆 WebView2 / DirectComposition，每个几百 ms；'
            'Dart 侧只是等回执，超时能真正放行。',
      );
    });
  });
}
