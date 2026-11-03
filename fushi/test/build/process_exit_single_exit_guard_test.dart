import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 有意结束进程只经 `AppExitCoordinator`（先写退出意图 / 标 clean，再结束）。
///
/// 过去 `exit(0)` 散在看门狗、备份导入 / 数据根迁移兜底、更新交接里，各自记不记得
/// 先标 clean 全凭自觉：漏一处，下次启动就把这次有意退出判成「停在前台时没了，疑似
/// 闪退」自动上报（反馈 GrZ_kLCjue / WwuPr8PwDY / 24q7Ni3J4G / _SA2_Gv53t …）。
void main() {
  const String coordinator = 'lib/src/platform/app_exit_coordinator.dart';

  /// 插件式结束进程只允许在移动端生命周期服务里，且必须包在 `terminateVia` 里。
  const Set<String> pluginKillOwners = <String>{
    'lib/src/platform/android/android_lifecycle_service.dart',
    'lib/src/platform/ios/ios_lifecycle_service.dart',
  };

  // 进程级 exit：`exit(0)` / `io.exit(...)` / 作为 tear-off 传出去（`?? exit)`）。
  // 名为 exit 的普通方法（`void exit()`、`exit(call)`）不算。
  final RegExp bareExit = RegExp(
    r'(?<![\w.$])exit\(\s*-?\d+\s*\)|(?<![\w.$])io\.exit\(|\?\?\s*exit\)',
  );
  final RegExp pluginKill = RegExp(
    r'FlutterExitApp\.exitApp\(|Restart\.restartApp\(',
  );

  List<File> libDartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (File f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'),
      )
      .toList();

  String rel(File f) => f.path.replaceAll(r'\', '/');

  test('lib/ 下只有退出协调器能裸调 exit(', () {
    final List<String> offenders = <String>[];
    for (final File f in libDartFiles()) {
      final String path = rel(f);
      if (path.endsWith(coordinator)) continue;
      final List<String> lines = maskComments(f.readAsStringSync()).split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (bareExit.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '结束进程改调 AppExitCoordinator.instance.terminate(...)',
    );
  });

  test('插件式结束进程只在移动端生命周期服务里、且经 terminateVia', () {
    final List<String> offenders = <String>[];
    for (final File f in libDartFiles()) {
      final String path = rel(f);
      final String code = maskComments(f.readAsStringSync());
      if (!pluginKill.hasMatch(code)) continue;
      final bool owner = pluginKillOwners.any(path.endsWith);
      if (!owner ||
          !code.contains('AppExitCoordinator.instance.terminateVia(')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('协调器先落意图 / clean，再 exit', () {
    final String src = maskComments(File(coordinator).readAsStringSync());
    final String terminate = methodBody(src, 'void terminate(');
    final int clean = terminate.indexOf('_marker.cleanExit(');
    final int exit = terminate.indexOf('(exitWith ?? _exitProcess)(code)');
    expect(terminate.indexOf('begin('), allOf(isNonNegative, lessThan(clean)));
    expect(clean, allOf(isNonNegative, lessThan(exit)));
  });

  test('关窗退出链第一条语句（任何 await 之前）就写退出意图', () {
    final String main = maskComments(File('lib/main.dart').readAsStringSync());
    final String body = methodBody(
      main,
      'Future<void> _flushAndExitForWindowClose() async',
    );
    final int begin = body.indexOf(
      "AppExitCoordinator.instance.begin('windowClose')",
    );
    final int firstAwait = body.indexOf('await ');
    expect(begin, isNonNegative);
    expect(begin, lessThan(firstAwait));
    // 看门狗时长由预算推出，不再是拍的常数。
    expect(
      compactCode(main).contains(
        'staticfinalDuration_exitWatchdogTimeout=AppExitCoordinator.watchdogTimeoutFor(',
      ),
      isTrue,
    );
  });
}
