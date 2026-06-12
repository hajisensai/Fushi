import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：移动端视频控制条的进度条 / 按钮条几何不变量，覆盖三个修复：
///
/// 【BUG-184】进度条 / 底部按钮条必须留出底部空间，不落回 media_kit 构造器默认的
/// `bottom: 0`（贴屏幕物理最底）。底部留白 = 基线 + 系统导航栏/手势栏 inset
/// （[_videoBottomSystemInset] 读 viewPadding.bottom）。
///
/// 【BUG-217 / TODO-156】进度条要抬到底部按钮条**上方**，而不是与按钮条同一底部基线
/// 重叠。media_kit 把进度条与按钮条放同一个 bottomCenter Stack、都按 `bottom` 对齐，
/// 进度条 `bottom` 必须 = 按钮条基线 + 按钮条高 + 间距，否则两者落同一基线、按钮压在
/// 进度条上（手机上「按钮没在进度条下面」）。
///
/// 【BUG-218 / TODO-157】进度条触摸热区 / 滑块 / 轨道必须抬高于 media_kit 默认
/// （seekBarContainerHeight=36 / seekBarThumbSize=12.8 / seekBarHeight=2.4），否则手机上
/// 太细难命中、滑不到 / 拖不动。三者随界面缩放（[_videoUiScale]）。
///
/// 用静态扫描守卫，因为真实 [MaterialVideoControls] 渲染依赖 host 平台分流 +
/// VideoController，widget 测试里难稳定复现移动控制条几何。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  late String mobileThemeBody;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();

    // 截取 _mobileControlsTheme 方法体（以紧随其后的 _hasRoomyVideoBottomBar 为下界）。
    final int start = src.indexOf(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(start, greaterThanOrEqualTo(0),
        reason: '应能定位 _mobileControlsTheme 方法');
    final int end = src.indexOf('bool _hasRoomyVideoBottomBar()', start);
    expect(end, greaterThan(start), reason: '应能界定 _mobileControlsTheme 方法体范围');
    mobileThemeBody = src.substring(start, end);
  });

  test('移动 controls 主题显式设置 seekBarMargin（不落回贴底默认）', () {
    expect(
      mobileThemeBody,
      contains('seekBarMargin: EdgeInsets.only('),
      reason: '不显式传 seekBarMargin 时 media_kit 构造器默认 EdgeInsets.zero → 进度条贴屏幕最底',
    );
  });

  test('移动 controls 主题显式设置 bottomButtonBarMargin', () {
    expect(
      mobileThemeBody,
      contains('bottomButtonBarMargin: EdgeInsets.only('),
      reason: '底部按钮条也要抬离屏幕最底（BUG-184）',
    );
  });

  test('按钮条底部留白叠加系统导航栏 inset（BUG-184）', () {
    // bottomButtonBarMargin 的 bottom 来自 _videoBottomChromeBaseline +
    // _videoBottomSystemInset()，保证既有最小基线（隐栏时不贴底），又能避开唤回的
    // 手势/导航条。
    expect(
      mobileThemeBody,
      contains('bottom: bottomChromeInset'),
      reason: 'bottomButtonBar 的 bottom 应取统一的 bottomChromeInset',
    );
    expect(
      mobileThemeBody,
      contains('_videoBottomChromeBaseline +'),
      reason: 'bottomChromeInset 应以底部留白基线打底',
    );
    expect(
      mobileThemeBody,
      contains('_videoBottomSystemInset()'),
      reason: 'bottomChromeInset 应叠加系统导航栏/手势栏 inset',
    );
  });

  test('_videoBottomSystemInset 读 viewPadding.bottom（反映物理安全区）', () {
    // 用 viewPadding 而非 padding：immersiveSticky 隐栏后 padding 被抹平为 0，
    // viewPadding 仍反映物理导航条高度；且 viewPadding 不受软键盘弹出影响。
    expect(
      src,
      contains('double _videoBottomSystemInset() =>'),
      reason: '应有独立的底部系统 inset helper',
    );
    final int hs = src.indexOf('double _videoBottomSystemInset() =>');
    final int he = src.indexOf(';', hs);
    final String helperBody = src.substring(hs, he);
    expect(
      helperBody,
      contains('viewPadding.bottom'),
      reason: '底部系统 inset 应读 MediaQuery.viewPadding.bottom',
    );
  });

  test('底部留白基线常量存在且非零（BUG-184）', () {
    final RegExpMatch? m = RegExp(
      r'static const double _videoBottomChromeBaseline = (\d+(?:\.\d+)?);',
    ).firstMatch(src);
    expect(m, isNotNull, reason: '应定义 _videoBottomChromeBaseline 常量');
    expect(
      double.parse(m!.group(1)!),
      greaterThan(0),
      reason: '底部留白基线必须非零，否则隐栏时进度条仍贴屏幕最底',
    );
  });

  // ── BUG-217 / TODO-156：进度条抬到按钮条上方 ────────────────────────────

  test('进度条 bottom 偏移含按钮条高（抬到按钮条上方，不与按钮重叠）', () {
    // seekBarBottom = bottomChromeInset + 按钮条高 + 间距，进度条整体落在按钮条上方。
    expect(
      mobileThemeBody,
      contains('seekBarBottom'),
      reason: 'seekBarMargin.bottom 应用单独抬高后的 seekBarBottom，'
          '而非与按钮条同基线的 bottomChromeInset',
    );
    final RegExpMatch? m = RegExp(
      r'final double seekBarBottom =\s*([^;]+);',
    ).firstMatch(mobileThemeBody);
    expect(m, isNotNull, reason: '应定义 seekBarBottom（进度条抬高基线）');
    final String expr = m!.group(1)!;
    expect(
      expr.contains('bottomChromeInset'),
      isTrue,
      reason: 'seekBarBottom 必须以按钮条基线 bottomChromeInset 打底（保留 BUG-184 抬离系统栏）',
    );
    expect(
      expr.contains('_videoButtonBarHeight'),
      isTrue,
      reason: 'seekBarBottom 必须叠加按钮条高，进度条才落在按钮条上方（BUG-217 核心）',
    );
    expect(
      expr.contains('_videoSeekBarButtonGap'),
      isTrue,
      reason: 'seekBarBottom 还应叠加进度条与按钮条间距',
    );
  });

  test('seekBarMargin.bottom 取 seekBarBottom（不再与按钮条同基线）', () {
    // 精确断言 seekBarMargin 块用 seekBarBottom。
    final int seekIdx =
        mobileThemeBody.indexOf('seekBarMargin: EdgeInsets.only(');
    final int seekEnd = mobileThemeBody.indexOf('),', seekIdx);
    final String seekBlock = mobileThemeBody.substring(seekIdx, seekEnd);
    expect(
      seekBlock.contains('bottom: seekBarBottom'),
      isTrue,
      reason: '进度条 margin.bottom 必须是抬高后的 seekBarBottom',
    );
  });

  // ── BUG-218 / TODO-157：触摸热区 / 滑块 / 轨道抬高 ─────────────────────

  test('进度条触摸热区 / 滑块 / 轨道字段接进主题（不是死代码）', () {
    expect(
      mobileThemeBody,
      contains('seekBarContainerHeight: _videoSeekBarContainerHeight'),
      reason: 'seekBarContainerHeight 必须接进主题，否则触摸热区仍是 media_kit 默认 36',
    );
    expect(
      mobileThemeBody,
      contains('seekBarThumbSize: _videoSeekBarThumbSize'),
      reason: 'seekBarThumbSize 必须接进主题，否则滑块仍是 media_kit 默认 12.8',
    );
    expect(
      mobileThemeBody,
      contains('seekBarHeight: _videoSeekBarTrackHeight'),
      reason: 'seekBarHeight 必须接进主题，否则轨道仍是 media_kit 默认 2.4',
    );
  });

  test('触摸热区 / 滑块 / 轨道基线抬高于 media_kit 默认（36 / 12.8 / 2.4）', () {
    double baseOf(String name) {
      final RegExpMatch? m = RegExp(
        'static const double $name = ' r'(\d+(?:\.\d+)?);',
      ).firstMatch(src);
      expect(m, isNotNull, reason: '应定义常量 $name');
      return double.parse(m!.group(1)!);
    }

    expect(baseOf('_videoSeekBarContainerHeightBase'), greaterThan(36.0),
        reason: '触摸热区基线必须高于 media_kit 默认 36（否则更难命中）');
    expect(baseOf('_videoSeekBarThumbSizeBase'), greaterThan(12.8),
        reason: '滑块基线必须高于 media_kit 默认 12.8');
    expect(baseOf('_videoSeekBarTrackHeightBase'), greaterThan(2.4),
        reason: '轨道基线必须高于 media_kit 默认 2.4');
  });

  test('三个 seekBar 尺寸 getter 随界面大小缩放（_videoUiScale）', () {
    for (final String getter in <String>[
      '_videoSeekBarContainerHeight',
      '_videoSeekBarThumbSize',
      '_videoSeekBarTrackHeight',
      '_videoSeekBarButtonGap',
    ]) {
      final RegExpMatch? m = RegExp(
        'double get $getter =>' r'\s*([^;]+);',
      ).firstMatch(src);
      expect(m, isNotNull, reason: '应定义 getter $getter');
      expect(
        m!.group(1)!.contains('_videoUiScale'),
        isTrue,
        reason: '$getter 必须乘 _videoUiScale，随界面大小缩放',
      );
    }
  });
}
