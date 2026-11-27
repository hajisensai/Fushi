import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-5609：Windows 上从提权（管理员、UAC 拆分令牌）进程启动 Chrome 时，Chrome 会
/// 经 shell 降权自重启，被我们 spawn 的那个进程 ~60 ms 内 exit 0、不写 stderr，
/// 「DevTools listening」那行永远等不到（CDP 驱动报 `chrome exited before DevTools
/// was ready (code 0 …)`），`--dump-dom` / `--screenshot` 拿到空输出；重启出来的
/// 浏览器还会成为孤儿进程。Chrome 给自己的重启加的就是 `--do-not-de-elevate`，
/// 所以每一处测试 / 工具里拉起真 Chrome 的参数表都必须带它（非 Windows / 未提权时
/// 是 no-op）。这里按类守住：仓库里凡写了 headless 启动参数的文件，同一文件里
/// `--do-not-de-elevate` 参数字面量的个数不少于 headless 参数字面量的个数。
void main() {
  // 拼出来，避免本文件自己被扫到。
  final RegExp headlessArg = RegExp(
    '[\'"]--head'
    r'less(=\w+)?['
    "'\"]",
  );
  final RegExp optOutArg = RegExp(
    '[\'"]--do-not-'
    r'de-elevate['
    "'\"]",
  );
  const Set<String> extensions = <String>{'.dart', '.mjs', '.js', '.cjs'};

  Iterable<File> sources(String root) sync* {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final String p = e.path.replaceAll('\\', '/');
      if (p.contains('/node_modules/') || p.contains('/.dart_tool/')) continue;
      final int dot = p.lastIndexOf('.');
      if (dot < 0 || !extensions.contains(p.substring(dot))) continue;
      yield e;
    }
  }

  test('every real-Chrome launch passes --do-not-de-elevate (BUG-5609)', () {
    final List<String> roots = <String>['test', '../tool', '../tools'];
    final List<String> offenders = <String>[];
    int launchFiles = 0;
    for (final String root in roots) {
      for (final File f in sources(root)) {
        final String text;
        try {
          text = f.readAsStringSync();
        } on FileSystemException {
          continue; // 非 UTF-8 的素材文件不可能是启动代码。
        }
        final int launches = headlessArg.allMatches(text).length;
        if (launches == 0) continue;
        launchFiles++;
        final int optOuts = optOutArg.allMatches(text).length;
        if (optOuts < launches) {
          offenders.add(
            '${f.path}: $launches headless launch arg(s), '
            '$optOuts --do-not-de-elevate',
          );
        }
      }
    }
    // 扫描本身失效（路径错 / 正则错）时不能静默变绿。
    expect(launchFiles, greaterThanOrEqualTo(10));
    expect(
      offenders,
      isEmpty,
      reason:
          'Add \'--do-not-de-elevate\' next to the headless flag; without it '
          'Chrome started from an elevated Windows shell relaunches itself and '
          'the spawned process exits 0 before DevTools is ready.',
    );
  });
}
