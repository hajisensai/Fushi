import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-869 的**当前形态**守卫。
///
/// 旧形态：macOS 无条件开透明标题栏 + full-size content view，Flutter 内容画到窗口
/// 左上角，交通灯浮在其上且不计入 `MediaQuery.padding.top`，于是桌面壳两条分支都用
/// `SafeArea.minimum` 预留一条 `kMacTitleBarHeight`，把 rail / 返回箭头整体下压。
///
/// 现在 macOS 与 Windows 同壳：`main()` 用
/// `setTitleBarStyle(hidden, windowButtonVisibility: Platform.isMacOS)` 隐藏系统标题栏，
/// macOS 保留三个系统交通灯（用户 2026-10-04：macOS 无论设计系统一律用原生红绿灯），
/// 再由 `FushiDesktopTitleBar` 画顶栏，并在 macOS 上于顶栏左侧给交通灯留位。交通灯
/// 落在顶栏那一行里，顶栏又吃掉真实布局高度，rail 与返回箭头本来就落在它下面——再留
/// 28pt 就是一条纯空白。所以不变式反过来了：桌面壳里不能再出现那条 macOS 专用的
/// SafeArea 预留带。
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
      reason: 'macOS 交通灯落在自绘顶栏左侧的留位里，顶栏又真占布局高度；'
          '再留 kMacTitleBarHeight 会在顶栏下面多出一条空白。',
    );
    expect(
      body.contains('kMacTitleBarHeight'),
      isFalse,
      reason: '桌面壳不该再引用交通灯预留高。',
    );
  });

  test('macOS 交通灯落在自绘顶栏的留位里，而不是浮在内容上（BUG-869 根因消除）', () {
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
      main.contains('windowButtonVisibility: Platform.isMacOS'),
      isTrue,
      reason: 'macOS 一律用系统原生红绿灯，Windows 不显示（用 MD3 三键）。',
    );
    final String titleBar = File(
      'lib/src/utils/components/fushi_desktop_title_bar.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'if\s*\(\s*trafficLights\s*\)\s*const\s+SizedBox\(\s*width:\s*'
        r'_kTrafficLightsReserve',
      ).hasMatch(titleBar),
      isTrue,
      reason: '交通灯是浮在 full-size content view 上的：自绘顶栏必须在 macOS 上给它们'
          '留位，否则它们压住顶栏内容（BUG-869 的原始症状换个位置复发）。',
    );
  });
}
