import 'dart:io';

import 'package:fushi/src/engine_bindings.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// BUG-4940（反馈 IlyjkPUvJx）：安卓 app 外查词 / 悬浮字幕查词的在线 TTS 兜底
/// （Edge、Google 翻译等预设）永远没声音。
///
/// 根因：引擎宿主装配（`enginePaths` / `engineLog` …）只在 `main()` 里装，而
/// Android `:popup` / `:second_screen` 的副 FlutterEngine 跑的是 `popupMain` /
/// `secondScreenMain`，从不执行 `main()`；Dart 全局按 isolate 隔离，那边的
/// `enginePaths` 是 `UninstalledEnginePaths`，`TtsServices.cache()` 取数据根即抛
/// StateError，被归一化成「语音服务返回的音频无效」。系统语音不经缓存，所以只有在线
/// 预设坏。`flutter_test_config.dart` 全局装了这些装配，单测里永远看不到未装状态，
/// 只能用源码扫描钉住「每个入口都自己装」。
void main() {
  /// `lib/` 根下的 Dart 入口文件（`main.dart` 与各副 engine 的 `*_main.dart`）。
  List<File> entryFiles() =>
      Directory('lib')
          .listSync()
          .whereType<File>()
          .where(
            (File f) =>
                f.path.endsWith('.dart') &&
                File(
                  f.path,
                ).readAsStringSync().contains("@pragma('vm:entry-point')"),
          )
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  /// [src] 里名为 [name] 的顶层函数体（从签名后的 `{` 到配对的 `}`）。
  String functionBody(String src, String name) {
    final RegExpMatch? m = RegExp(
      r'^(?:Future<void>|void)\s+' +
          RegExp.escape(name) +
          r'\s*\([^)]*\)\s*(?:async\s*)?\{',
      multiLine: true,
    ).firstMatch(src);
    expect(m, isNotNull, reason: '找不到入口函数 $name');
    int depth = 0;
    for (int i = m!.end - 1; i < src.length; i++) {
      final String c = src[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return src.substring(m.end, i);
      }
    }
    fail('入口函数 $name 的花括号不配对');
  }

  /// 每个文件里的 entry point 名：`@pragma('vm:entry-point')` 下一行的顶层函数，
  /// 外加 `main.dart` 的 `main`。
  List<String> entryPointsOf(File file, String src) {
    final List<String> names = <String>[
      for (final RegExpMatch m in RegExp(
        r"@pragma\('vm:entry-point'\)\s*\n\s*(?:Future<void>|void)\s+(\w+)\s*\(",
      ).allMatches(src))
        m.group(1)!,
    ];
    if (file.path.replaceAll(r'\', '/').endsWith('lib/main.dart')) {
      names.add('main');
    }
    return names;
  }

  /// 纯转发（`main.dart` 里为了让引擎在根库找到入口而写的 `x.popupMain();`）：
  /// 真正的装配在被转发的那个函数里。
  bool isForwarder(String body) =>
      RegExp(r'^\s*\w+\.\w+\(\);\s*$').hasMatch(body);

  test('every Dart entry point installs host bindings before runApp', () {
    final List<File> files = entryFiles();
    final List<String> checked = <String>[];
    for (final File file in files) {
      final String src = file.readAsStringSync();
      for (final String name in entryPointsOf(file, src)) {
        final String body = functionBody(src, name);
        if (isForwarder(body)) continue;
        checked.add('${file.path}:$name');
        final int install = body.indexOf('installEntryPointHostBindings();');
        expect(
          install,
          greaterThanOrEqualTo(0),
          reason:
              '${file.path} 的入口 $name 没调 installEntryPointHostBindings()：'
              '副 engine 不跑 main()，引擎数据根 / 日志装配全是默认值，'
              '在线 TTS 兜底等引擎功能会在该进程里失败（BUG-4940）。',
        );
        final int runApp = body.indexOf('runApp(');
        if (runApp >= 0) {
          expect(
            install,
            lessThan(runApp),
            reason: '$name 必须在 runApp 之前装宿主装配（BUG-4940）。',
          );
        }
      }
    }
    // 防守卫自己空转：至少要扫到 main / popupMain / secondScreenMain。
    expect(
      checked.map((String s) => s.split(':').last),
      containsAll(<String>['main', 'popupMain', 'secondScreenMain']),
      reason: '扫到的入口：$checked',
    );
  });

  test('the two package binding installers are only called through '
      'installEntryPointHostBindings (or the test config)', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String path = e.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/src/engine_bindings.dart')) continue;
      final String src = e.readAsStringSync();
      for (final String call in <String>[
        'installEngineHostBindings();',
        'installAsrHostBindings();',
      ]) {
        if (src.contains(call)) offenders.add('$path: $call');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '入口直接调了单个包的装配：改调 installEntryPointHostBindings()，'
          '免得新入口只装了一半（BUG-4940）。',
    );
  });

  test('installEntryPointHostBindings wires the engine data root and log '
      'sink to the app implementations', () {
    enginePaths = const UninstalledEnginePaths();
    engineLog = const StderrEngineLogSink();
    addTearDown(installEngineHostBindings);

    installEntryPointHostBindings();

    expect(enginePaths, isA<AppPathsEngineBridge>());
    expect(identical(engineLog, ErrorLogService.instance), isTrue);
  });
}
