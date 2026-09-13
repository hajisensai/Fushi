import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-869 的**当前形态**守卫。
///
/// 旧形态：macOS 无条件开透明标题栏 + full-size content view，Flutter 内容画到窗口
/// 左上角，交通灯浮在其上且不计入 `MediaQuery.padding.top`，于是桌面壳两条分支都用
/// `SafeArea.minimum` 预留一条 `kMacTitleBarHeight`，把 rail / 返回箭头整体下压。
///
/// 现在 macOS 与 Windows 同壳：`main()` 用
/// `setTitleBarStyle(hidden, windowButtonVisibility: false)` 隐藏系统标题栏**和**三个
/// 交通灯，再由 `FushiDesktopTitleBar` 画 MD3 顶栏。顶栏吃掉真实布局高度，rail 与返回
/// 箭头本来就落在它下面——再留 28pt 就是一条纯空白。所以不变式反过来了：桌面壳里不能
/// 再出现那条 macOS 专用的 SafeArea 预留带。
///
/// 源码守卫仍是最强可落地层：分支门在 `dart:io` 的 `Platform.isMacOS` 上，
/// `debugDefaultTargetPlatformOverride` 伪装不了，Linux CI 上跑不出真 macOS 布局。
void main() {
  test('桌面壳不再为交通灯预留 SafeArea 顶部带（BUG-869 的旧形态）', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    final int start = source.indexOf('Widget _buildDesktopLayout(');
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: '_buildDesktopLayout must exist in home_page.dart.',
    );
    final int next = source.indexOf('\n  Widget ', start + 1);
    final String body =
        next > start ? source.substring(start, next) : source.substring(start);

    expect(
      RegExp(
        r'minimum:\s*EdgeInsets\.only\(\s*top:\s*Platform\.isMacOS',
      ).hasMatch(body),
      isFalse,
      reason: 'macOS 已无交通灯（main() 的 windowButtonVisibility: false），自绘顶栏又'
          '真占布局高度；再留 kMacTitleBarHeight 会在顶栏下面多出一条空白。',
    );
    expect(
      body.contains('kMacTitleBarHeight'),
      isFalse,
      reason: '桌面壳不该再引用交通灯预留高。',
    );
  });

  test('macOS 的窗口控制来自自绘顶栏，而不是系统交通灯（BUG-869 根因消除）', () {
    final String main = File('lib/main.dart').readAsStringSync();
    final int block = main.indexOf('Platform.isWindows || Platform.isMacOS');
    expect(
      block,
      greaterThanOrEqualTo(0),
      reason: 'macOS 必须与 Windows 走同一条自绘顶栏路径。',
    );
    expect(
      main.contains('TitleBarStyle.hidden'),
      isTrue,
      reason: '不隐藏系统标题栏 = 自绘顶栏之上再叠一条原生标题栏。',
    );
    expect(
      main.contains('windowButtonVisibility: false'),
      isTrue,
      reason: '交通灯必须在同一次调用里关掉，否则它们会浮在自绘顶栏的标题上。',
    );
  });
}
