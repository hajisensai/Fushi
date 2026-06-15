import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：桌面音量按钮不再 hover 展开挤按钮 + 顶栏设置入口去重（BUG-248 / TODO-283）。
///
/// 子A：桌面 [_buildVolumeButton] 曾用 media_kit 的 [MaterialDesktopVolumeButton]，
///      hover 时内部 AnimatedContainer 宽度 12→82px 实时挤走右邻全屏键（BUG-248A）。
///      TODO-377 起音量是底栏一行式常驻控件（图标 + 横滑条内联），布局尺寸与 hover 完全
///      无关 → 零位移、零叠开；点击图标切静音 ([_toggleMute])、滚轮调音量 ([_onVolumeWheel])、
///      滑条拖动 ([_setVolumeFromSlider])，绝不再用 hover 展开条 / 弹出 popover / modal。
/// 子B：桌面/移动 topButtonBar 各写死一枚 tune→_showPlayerSettings，与右侧 rail 的
///      可配置 settings 按钮（默认 placement=rightRail）功能完全重复。修复删掉顶栏写死
///      入口，统一由 rightRail settings 按钮负责（_showPlayerSettings 方法 + rightRail
///      接线保留）。
///
/// media_kit controls 跑不了 headless，故锁源码结构不变量。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  String volumeButtonBody() {
    final int start = src.indexOf('Widget _buildVolumeButton(');
    expect(start, greaterThanOrEqualTo(0), reason: '需有 _buildVolumeButton 方法');
    // 到下一个方法定义为止。
    final int end = src.indexOf('_desktopControlsTheme(', start);
    expect(end, greaterThan(start), reason: '需有 _desktopControlsTheme 作为终点');
    return src.substring(start, end);
  }

  /// 截某套主题的 topButtonBar 段（从 `topButtonBar:` 到 `bottomButtonBar:`）。
  String topBar(String themeSig) {
    final int themeIdx = src.indexOf(themeSig);
    expect(themeIdx, greaterThanOrEqualTo(0), reason: '需有 $themeSig');
    final int top = src.indexOf('topButtonBar: <Widget>[', themeIdx);
    final int bottom = src.indexOf('bottomButtonBar:', top);
    expect(top, greaterThanOrEqualTo(0), reason: '$themeSig 缺 topButtonBar');
    expect(bottom, greaterThan(top), reason: '$themeSig 缺 bottomButtonBar');
    return src.substring(top, bottom);
  }

  group('子A：桌面音量控件不再 hover 展开 / 不弹浮层（BUG-248A / TODO-377）', () {
    test('全文不再用 hover 展开的 MaterialDesktopVolumeButton', () {
      final RegExp ctor = RegExp(r'MaterialDesktopVolumeButton\s*\(');
      expect(ctor.hasMatch(src), isFalse,
          reason: '音量控件不应再用 hover 展开的 MaterialDesktopVolumeButton（挤走右邻）');
    });

    test('_buildVolumeButton 是一行式：图标静音 + 横滑条 + 滚轮调音量（非浮层 / 非 modal）', () {
      final String body = volumeButtonBody();
      // 图标按钮（点击 = 静音）+ 横向 Slider 同处一个 Row（一行式）。
      expect(body.contains('Row('), isTrue, reason: '一行式：图标与滑条同处一个 Row');
      expect(body.contains('Slider('), isTrue, reason: '一行式须含横向 Slider（非弹出浮层）');
      expect(body.contains('_toggleMute()'), isTrue,
          reason: '点击音量图标应切换静音（_toggleMute）');
      expect(body.contains('_setVolumeFromSlider('), isTrue,
          reason: '滑条拖动走 _setVolumeFromSlider');
      expect(
          body.contains('PointerScrollEvent') &&
              body.contains('_onVolumeWheel(controller'),
          isTrue,
          reason: '桌面悬停音量控件时滚轮应调音量（_onVolumeWheel）');
    });

    test('零位移：占位宽度是常量、不随 hover 变化（无 AnimatedContainer / 无浮层）', () {
      final String body = volumeButtonBody();
      expect(body.contains('_volumeSliderWidth'), isTrue,
          reason: '滑条用固定占位宽度常量（hover 零位移的根）');
      expect(src.contains('static const double _volumeSliderWidthBase'), isTrue,
          reason: '占位宽度须是源码常量，不随运行时 hover 状态计算');
      expect(body.contains('AnimatedContainer'), isFalse,
          reason: 'hover 不得用 AnimatedContainer 撑宽（BUG-248A 原症状）');
      expect(body.contains('OverlayEntry'), isFalse, reason: '不再弹独立浮层');
    });

    test('音量交互彻底去 modal / 去 popover：无 _showVolumeMenu / 无 popover 残留', () {
      expect(src.contains('_showVolumeMenu'), isFalse,
          reason: '旧的 showModalBottomSheet 音量菜单 _showVolumeMenu 必须移除');
      // 旧 hover 弹出 popover 整套（TODO-337）已随一行式重构删除。
      for (final String sym in <String>[
        '_volumeOverlayEntry',
        '_showVolumePopover',
        '_buildVolumePopover',
        '_volumeButtonKey',
        '_volumeAnchorRectInOverlay',
      ]) {
        expect(src.contains(sym), isFalse,
            reason: '旧音量 popover 符号「$sym」应已随一行式重构删除');
      }
    });
  });

  group('子B：顶栏设置入口去重', () {
    test('桌面顶栏不再写死 _showPlayerSettings 入口', () {
      expect(
          topBar('MaterialDesktopVideoControlsThemeData')
              .contains('onPressed: _showPlayerSettings'),
          isFalse,
          reason: '桌面顶栏不应再有写死的 tune→_showPlayerSettings（与 rightRail 重复）');
    });

    test('移动顶栏不再写死 _showPlayerSettings 入口', () {
      expect(
          topBar('MaterialVideoControlsThemeData _mobileControlsTheme(')
              .contains('onPressed: _showPlayerSettings'),
          isFalse,
          reason: '移动顶栏不应再有写死的 tune→_showPlayerSettings（与 rightRail 重复）');
    });

    test('_showPlayerSettings 方法 + rightRail settings 接线保留（设置仍可打开）', () {
      expect(src.contains('void _showPlayerSettings() {'), isTrue,
          reason: '_showPlayerSettings 方法必须保留（rightRail settings 按钮引用）');
      // _activateVideoControlButton 的 settings 分支调 _showPlayerSettings。
      final int actStart =
          src.indexOf('void _activateVideoControlButton(VideoControlButton');
      expect(actStart, greaterThanOrEqualTo(0),
          reason: '需有 _activateVideoControlButton');
      final int actEnd =
          src.indexOf('}', src.indexOf('switch (button)', actStart));
      final String actBody = src.substring(actStart, actEnd);
      expect(
          actBody.contains('case VideoControlButton.settings:') &&
              actBody.contains('_showPlayerSettings();'),
          isTrue,
          reason:
              'rightRail settings 按钮经 _activateVideoControlButton 仍打开 _showPlayerSettings');
    });
  });
}
