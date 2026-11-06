@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// 翻页模式「存→取」不动点 + 竖排对开（折叠屏书本姿态）几何，真 Chrome 跑生产分页 shell。
///
/// ① BUG-3431 分页侧：页首字恰是软换行处的行首时，Chromium 把塌缩光标算到**上一行行尾**；
/// 那一行是上一页末行时，`scrollToCharOffset` 用光标锚把整页判进前一页——冷启动恢复没有
/// BUG-2205 的 ±1 hint 兜，每次重开退一页。修复后对齐目标字自己的字形盒。本测试逐页取页首字
/// 再 `restoreToCharOffset`，断言落回同一页（横排 / 竖排单条 / 竖排对开）。
///
/// ② 竖排对开：`ReaderContentStyles.verticalSpreadCss` 的生产 CSS（column-wrap 行换行）下，
/// 翻页轴识别为 xr、逐页前进与后退走同一组网格位置；章末页数奇偶两种都测（奇数页时末对开
/// 靠 `body::after` 补的空页才滚得到）。
///
/// 没有 node / Chrome 时 skip；Chrome 不支持 column-wrap（< 145）时 harness 只跳过对开两例。
void main() {
  test(
    'paginated restore of every page-first char lands on the same page, '
    'including the foldable vertical spread, in real Chrome',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Directory temp = Directory.systemTemp.createTempSync('pfixed-');
      try {
        final File payload = File('${temp.path}/engine.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'engine': ReaderPaginationScripts.engineShell(
                vnMode: false,
                continuousMode: false,
              ),
              'spreadCss': ReaderContentStyles.verticalSpreadCss(
                marginLeftCss: '20px',
                marginRightCss: '28px',
                gapPx: 40,
              ),
            }),
          );
        final ProcessResult result = await Process.run(nodeExe, <String>[
          'test/reader/paginated_page_first_fixed_point_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        if (result.exitCode == 77) {
          markTestSkipped('Chrome unavailable: ${result.stdout}');
          return;
        }
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('PASS paginated page-first fixed point'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    // 起真 Chrome 的套件在机器忙时会互相饿死；外层 90s，内层进程 80s。
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
