import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 反馈 63DhJLTAHW 日志（Linux 3.0.1）：
/// `Null check operator used on a null value`
/// `State.context ← _DictStylePreviewState._pushTheme ← _bootstrap`（UncaughtZone）。
///
/// `_bootstrap` 由平台 WebView 的 `onLoadStop` 触发，里面先 `await evaluateJavascript`
/// 再推主题 / 样式；往返期间用户离开词典样式页，续体读 `Theme.of(context)` 就在已卸载的
/// State 上空断言。平台 WebView 的加载回调与 JS 往返都不随 widget 生命周期撤销，所以
/// 每个 await 之后、以及每个可能被续体调用的入口，都要先确认还挂载。
///
/// 只能做源码守卫：单元测试环境没有真 WebView，无法让 onLoadStop 在卸载后到达
/// （与 `dict_style_preview_eink_guard_test` 同处境）。
void main() {
  const String previewPath =
      'lib/src/pages/implementations/dict_style_preview.dart';
  late String source;

  setUpAll(() {
    // 注释掩成空白：注释里提到 `Theme.of(context)` / `await` 不算代码。
    source = maskComments(File(previewPath).readAsStringSync());
  });

  /// [name] 方法体（首个 `{` 到配对的 `}`）。
  String body(String name) {
    final int sig = source.indexOf('Future<void> $name() async {');
    expect(sig, greaterThanOrEqualTo(0), reason: '找不到 $name');
    final int open = source.indexOf('{', sig);
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      final String c = source[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('$name 方法体不完整');
  }

  test('_pushTheme 读 context 之前先确认还挂载', () {
    final String b = body('_pushTheme');
    final int guard = b.indexOf('!mounted');
    final int themeRead = b.indexOf('Theme.of(context)');
    expect(guard, greaterThanOrEqualTo(0));
    expect(themeRead, greaterThan(guard));
  });

  test('_pushStyles 读 widget 之前先确认还挂载', () {
    final String b = body('_pushStyles');
    expect(b.indexOf('!mounted'), greaterThanOrEqualTo(0));
    expect(b.indexOf('widget.'), greaterThan(b.indexOf('!mounted')));
  });

  test('_bootstrap 入口与每个 await 之后都先确认还挂载', () {
    final String b = body('_bootstrap');
    final int entryGuard = b.indexOf('!mounted');
    expect(entryGuard, greaterThanOrEqualTo(0));
    expect(b.indexOf('Theme.of(context)'), greaterThan(entryGuard));
    // 除最后一个 await 外，每个 await 语句结束后到下一个 await / 读状态之前都要有守卫。
    final List<int> awaits = RegExp(
      r'await ',
    ).allMatches(b).map((Match m) => m.start).toList();
    expect(awaits.length, greaterThanOrEqualTo(3));
    for (int i = 0; i < awaits.length - 1; i++) {
      final String between = b.substring(awaits[i], awaits[i + 1]);
      expect(
        between,
        contains('if (!mounted) return;'),
        reason: '第 ${i + 1} 个 await 之后没有挂载守卫就继续往下走',
      );
    }
  });
}
