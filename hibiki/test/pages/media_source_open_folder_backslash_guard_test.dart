import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-920 守卫：管理来源「打开文件夹」必须把 rootPath 的正斜杠转回反斜杠再交给
/// Windows explorer.exe。
///
/// 根因：normalizeSourceRootPath 把本地 rootPath 归一化为正斜杠（跨平台一致 +
/// dedup/label 依赖），而 explorer.exe 只认反斜杠路径参数——传正斜杠会被忽略、
/// 改开默认「文档」目录。存储层归一化不动，仅在 explorer 平台边界做方向转换。
void main() {
  late String source;

  setUp(() {
    source = File('lib/src/pages/implementations/media_sources_dialog.dart')
        .readAsStringSync();
  });

  test('_openFolder 把 rootPath 的 / 转成 \\ 再传 explorer', () {
    final int idx = source.indexOf('Future<void> _openFolder(');
    expect(idx, isNonNegative, reason: '必须存在 _openFolder');
    // 方法体窗口：到下一个方法前足够覆盖。
    final String body = source.substring(idx, idx + 600);

    expect(
      body.contains(r"replaceAll('/', r'\')"),
      isTrue,
      reason: 'explorer 只认反斜杠，rootPath 必须先 replaceAll(/ → \\)（BUG-920）',
    );
    expect(
      body.contains("Process.run('explorer'"),
      isTrue,
      reason: '仍复用 explorer 打开文件夹',
    );
  });

  test('不得把归一化的正斜杠 rootPath 裸传给 explorer（回归守卫）', () {
    expect(
      source.contains("Process.run('explorer', <String>[row.rootPath])"),
      isFalse,
      reason: '裸 row.rootPath（正斜杠）传 explorer 会打开错误目录（BUG-920 回归）',
    );
  });
}
