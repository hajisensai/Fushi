/// BUG-4072 方案 C 守卫：无界面拉起的引擎停在精简入口，完整初始化（含会话标记 / 闪退
/// 报告 / 只在 MainActivity 上注册的通道）一律排在这一关之后。
///
/// 这些写错都不会报错：把任何一步挪到 `holdHeadlessLaunchUntilUi` 前面，无界面引擎就会
/// 又去覆写上一个会话的标记、在没人看见的引擎里判闪退，或者对着没配置的引擎调
/// tts / process_exit / flutter_logs 吃 MissingPluginException——测试全绿、只在用户手机上复发。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String mainSrc = maskComments(File('lib/main.dart').readAsStringSync());
  final int mainStart = mainSrc.indexOf(
    'void main([List<String> args = const <String>[]])',
  );
  final int mainEnd = mainSrc.indexOf('class FushiReaderApp ', mainStart);
  final String mainBody = mainSrc.substring(mainStart, mainEnd);

  int at(String needle) {
    final int i = mainBody.indexOf(needle);
    expect(i, isNonNegative, reason: 'main() 里找不到 $needle');
    return i;
  }

  test('精简入口是 binding 初始化之后的第一步', () {
    final int binding = at('FushiWidgetsFlutterBinding.ensureInitialized();');
    final int gate = at('await holdHeadlessLaunchUntilUi(binding: binding);');
    expect(gate, greaterThan(binding));
    // binding 与这一关之间不许夹别的语句（只允许空白）。
    final String between = mainBody.substring(
      mainBody.indexOf(';', binding) + 1,
      gate,
    );
    expect(between.trim(), isEmpty, reason: '这一关之前跑的都会在无界面引擎里执行');
    expect(
      'await holdHeadlessLaunchUntilUi('.allMatches(mainBody).length,
      1,
      reason: '只拦一次',
    );
  });

  test('完整初始化的每一步都排在这一关之后', () {
    final int gate = at('await holdHeadlessLaunchUntilUi(');
    for (final String step in <String>[
      // 数据目录搬迁 / prefs：完整初始化的第一批 IO。
      'await migrateLegacySupportDir();',
      // 只在 MainActivity.configureFlutterEngine 注册的 tts 通道。
      'TtsChannel.markHostPlaybackRegistered();',
      // UI。
      'runApp(',
      'SystemChrome.setPreferredOrientations(',
      // 会话标记 / 进程退出记录（process_exit 通道）/ 闪退判定。
      'await ErrorLogService.instance.init();',
      'PreviousExitLog.foldIntoErrorLog()',
      // 闪退提示与 auto_send。
      'CrashReporter.instance',
      'await runCrashReportStartupGate(CrashReporter.instance);',
      // flutter_logs。
      'await FlutterLogs.initLogs(',
      // 数据库 / 同步 / 词典。
      'await appModel.initialise();',
    ]) {
      expect(at(step), greaterThan(gate), reason: '$step 必须在精简入口之后');
    }
  });

  test('等过界面的进程在错误日志里留证据', () {
    final int logInit = at('await ErrorLogService.instance.init();');
    final int note = at('lastHeadlessLaunchOutcome?.describe()');
    expect(note, greaterThan(logInit));
    expect(mainBody, contains('kHeadlessLaunchLogSource'));
  });

  test('Android：放行后调用的通道都在 configureFlutterEngine 里注册（onResume 之前）', () {
    final String java = maskComments(
      File(
        'android/app/src/main/java/app/fushi/reader/MainActivity.java',
      ).readAsStringSync(),
    );
    // 缓存引擎被 Activity 接管的前提：MainActivity 用 audio_service 的缓存引擎。
    expect(java, contains('class MainActivity extends AudioServiceActivity'));
    final int cfg = java.indexOf(
      'public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine)',
    );
    expect(cfg, isNonNegative);
    final int cfgEnd = java.indexOf('\n    }\n', cfg);
    final String body = java.substring(cfg, cfgEnd);
    expect(body, contains('ProcessExitChannel.registerWith(flutterEngine'));
    expect(body, contains('ttsChannelHandler.register(flutterEngine);'));
  });

  test('放行条件只认前台生命周期，不靠计时', () {
    final String gate = maskComments(
      File('lib/src/startup/headless_launch_gate.dart').readAsStringSync(),
    );
    expect(gate, isNot(contains('Future.delayed')));
    expect(gate, isNot(contains('Timer(')));
    expect(gate, contains('AppLifecycleState.resumed'));
    expect(gate, contains('AppLifecycleState.inactive'));
    expect(gate, contains('queryLaunchPresence('));
  });
}
