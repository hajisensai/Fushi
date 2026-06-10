import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-184）：移动端视频控制条的进度条 / 底部按钮条必须留出底部空间，
/// 不能落回 media_kit 构造器默认的 `bottom: 0`（贴屏幕物理最底，Android 上「进度条
/// 在最下面」）。
///
/// 根因：[MaterialVideoControlsThemeData] 构造器把 `seekBarMargin` 默认成
/// [EdgeInsets.zero]、`bottomButtonBarMargin` 默认成只有左右无底部（与导出常量
/// [kDefaultMaterialVideoControlsThemeData] 含 `bottom: 42` 的那套留白不同）。本页的
/// [_mobileControlsTheme] 直接 new 主题、若不显式传这两个 margin，进度条就贴在屏幕
/// 最底被手势条/物理边缘吞掉。修复是显式给两者底部留白 = 基线 + 系统导航栏/手势栏
/// inset（[_videoBottomSystemInset] 读 viewPadding.bottom）。
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
      reason: '底部按钮条也要与进度条同一底部基线，整体抬离屏幕最底',
    );
  });

  test('进度条 / 按钮条底部留白叠加系统导航栏 inset', () {
    // margin 的 bottom 来自 _videoBottomChromeBaseline + _videoBottomSystemInset()，
    // 保证既有最小基线（隐栏时不贴底），又能避开唤回的手势/导航条。
    expect(
      mobileThemeBody,
      contains('bottom: bottomChromeInset'),
      reason: 'seekBar / bottomButtonBar 的 bottom 应取统一的 bottomChromeInset',
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

  test('底部留白基线常量存在且非零', () {
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
}
