import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：桌面音量按钮不再 hover 展开挤按钮 + 顶栏设置入口去重（BUG-248 / TODO-283）。
///
/// 子A：桌面 [_buildVolumeButton] 曾用 media_kit 的 [MaterialDesktopVolumeButton]，
///      hover 时内部 AnimatedContainer 宽度 12→82px 实时挤走右邻全屏键。改用固定宽度的
///      [MaterialDesktopCustomButton]；TODO-337 起桌面 hover 弹竖向 popover
///      ([_showVolumePopover])、点击切静音 ([_toggleMute])、滚轮调音量，绝不再用
///      居中 dialog / showModalBottomSheet。
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

  group('子A：桌面音量按钮非 hover 展开条', () {
    test('_buildVolumeButton 桌面分支不再用 MaterialDesktopVolumeButton 渲染', () {
      // 注释里可保留命名解释，但不应再有该 widget 的构造调用。
      final RegExp ctor = RegExp(r'MaterialDesktopVolumeButton\s*\(');
      expect(ctor.hasMatch(src), isFalse,
          reason: '桌面音量按钮不应再用 hover 展开的 MaterialDesktopVolumeButton');
    });

    test(
        '_buildVolumeButton 桌面 hover 弹 popover / 点击静音 / 滚轮调音量（非 modal，TODO-337）',
        () {
      final String body = volumeButtonBody();
      expect(body.contains('MaterialDesktopCustomButton('), isTrue,
          reason: '桌面音量按钮改用固定宽度 MaterialDesktopCustomButton');
      // 桌面：hover 进出走 _onVolumeAnchorHover → _showVolumePopover（就地竖滑条 popover）。
      expect(body.contains('_onVolumeAnchorHover(controller'), isTrue,
          reason: '桌面 hover 音量按钮应弹竖向滑条 popover（_onVolumeAnchorHover）');
      // 点击图标 = 静音 / 取消静音。
      expect(body.contains('_toggleMute()'), isTrue,
          reason: '点击音量图标应切换静音（_toggleMute）');
      // 悬停时鼠标滚轮调音量。
      expect(
          body.contains('PointerScrollEvent') &&
              body.contains('_onVolumeWheel(controller'),
          isTrue,
          reason: '悬停音量按钮时滚轮应调音量（_onVolumeWheel）');
    });

    test('音量交互彻底去 modal：不再用 _showVolumeMenu / showModalBottomSheet（TODO-337）',
        () {
      // 全文不应再有旧的 modal 音量菜单方法名（连同其 showModalBottomSheet 弹法）。
      expect(src.contains('_showVolumeMenu'), isFalse,
          reason: '旧的 showModalBottomSheet 音量菜单 _showVolumeMenu 必须移除');
      // popover 走独立 OverlayEntry 锚定音量按钮（非 modal）。
      expect(
          src.contains('void _showVolumePopover(VideoPlayerController') &&
              src.contains('OverlayEntry? _volumeOverlayEntry'),
          isTrue,
          reason: '音量改用锚定到按钮的 OverlayEntry popover（非 modal）');
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
