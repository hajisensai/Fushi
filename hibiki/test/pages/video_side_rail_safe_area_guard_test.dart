import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-658/BUG-383）：视频左 / 右浮动侧栏在圆角 / 刘海手机上**不得**把系统
/// 安全区（cutout）与控件自有 margin **相加**双重内缩，否则按钮被推离侧边、形成对称大
/// 留白。
///
/// 背景：Android `styles.xml` 设 `windowLayoutInDisplayCutoutMode=shortEdges`，画面画进
/// 圆角 / 刘海区 → Flutter 报 `viewPadding.left/right` 非零。旧实现 `SafeArea`（按
/// viewPadding 内缩四边）**外套** `Padding(left/right:12)` 的控件自有 margin = 两段相加。
/// 修复=逐边取 `max(控件 margin, 系统安全区)`：既不被圆角裁掉（≥ 安全区），又不在安全区
/// 已够大时再叠 12（结果 = max，不再额外加）。
///
/// 用静态扫描守卫：真实 [MaterialVideoControls] + 多种 cutout 几何在 widget 测试里难稳定
/// 复现（依赖 host 平台 / VideoController / 真实 MediaQuery.viewPadding），故钉死 rail 内缩
/// 的合并方式与「不再用 SafeArea 外套 Padding」的源码不变量。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  late String railBody;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();

    // 截取 _buildVideoSideRailFor 方法体（以紧随其后的 _mergeRailSafeAreaPadding 为下界）。
    final int start = src.indexOf('Widget _buildVideoSideRailFor(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '应能定位 _buildVideoSideRailFor 方法');
    final int end = src.indexOf(
      'EdgeInsets _mergeRailSafeAreaPadding(',
      start,
    );
    expect(end, greaterThan(start),
        reason: '应能界定 _buildVideoSideRailFor 方法体范围');
    railBody = src.substring(start, end);
  });

  test('浮动侧栏不再用 SafeArea 外套控件 margin（避免双重内缩）', () {
    expect(
      railBody.contains('SafeArea('),
      isFalse,
      reason: 'rail 不应再用 SafeArea（与控件 margin 相加 = cutout 手机双重内缩留白）',
    );
  });

  test('浮动侧栏内缩走 _mergeRailSafeAreaPadding（逐边取 max）', () {
    expect(
      railBody,
      contains('_mergeRailSafeAreaPadding('),
      reason: 'rail 的 Padding 应走 max 合并 helper，而非裸 SafeArea + Padding',
    );
  });

  test('_mergeRailSafeAreaPadding 逐边对系统安全区取 max', () {
    final int hs = src.indexOf('EdgeInsets _mergeRailSafeAreaPadding(');
    expect(hs, greaterThanOrEqualTo(0),
        reason: '应有 _mergeRailSafeAreaPadding helper');
    final int he = src.indexOf('\n  }', hs);
    final String helperBody = src.substring(hs, he);
    expect(
      helperBody,
      contains('viewPadding'),
      reason: 'helper 应读系统安全区 MediaQuery.viewPadding（含 cutout）',
    );
    // 四边都必须出现 math.max（控件 margin 与安全区逐边取较大者，而非相加）。
    final int maxCount = 'math.max'.allMatches(helperBody).length;
    expect(
      maxCount,
      greaterThanOrEqualTo(4),
      reason: '四边（L/T/R/B）都应 math.max(margin, safe)，逐边取较大者不相加',
    );
  });
}
