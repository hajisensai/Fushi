import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：桌面音量 / 倍速改为固定锚点轻浮层 + 顶栏设置入口去重（TODO-438）。
///
/// 子A：桌面 [_buildVolumeButton] 曾用 media_kit 的 [MaterialDesktopVolumeButton]，
///      hover 时内部 AnimatedContainer 宽度 12→82px 实时挤走右邻全屏键（BUG-248A）。
///      TODO-438 起音量底栏只保留图标占位，hover/click/tap 打开锚定在按钮上方的紧凑
///      浮层；滑条在浮层内竖向渲染，继续走 [_setVolumeFromSlider] / [_volumeDisplay]，
///      点击静音仍走 [_toggleMute]。底栏按钮自身不含 Slider，几何不随 hover 改变。
/// 子B：倍速按钮同样只占图标/短标签位，[_showSpeedMenu] 打开紧凑浮层而不是右侧 side
///      panel；浮层复用 [_speedMenuPresets] 与 [_setSpeed]，提供 0.5x 到 2.0x slider 和
///      1.0x 复位。长按倍速 / 快捷键仍走原通道，本测试只锁入口与控件形态。
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
    // 到浮层调度方法为止，只检查底栏按钮本体，不把浮层里的 Slider 算进去。
    final int end = src.indexOf('void _showControlPopover(', start);
    expect(end, greaterThan(start), reason: '需有 _showControlPopover 作为终点');
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

  group('子A：音量与倍速使用固定锚点轻浮层（TODO-438）', () {
    test('全文不再用 hover 展开的 MaterialDesktopVolumeButton', () {
      final RegExp ctor = RegExp(r'MaterialDesktopVolumeButton\s*\(');
      expect(ctor.hasMatch(src), isFalse,
          reason: '音量控件不应再用 hover 展开的 MaterialDesktopVolumeButton（挤走右邻）');
    });

    test('底栏音量按钮只占图标位，hover / click 打开音量浮层（底栏不含 Slider）', () {
      final String body = volumeButtonBody();
      expect(body.contains('Slider('), isFalse,
          reason: '底栏只保留图标/锚点，滑条必须移入浮层，避免 hover 改宽或常驻占位');
      expect(
          RegExp(
            r'_toggleControlPopover\(\s*_VideoControlPopoverKind\.volume',
          ).hasMatch(body),
          isTrue,
          reason: '音量按钮 click/tap 应打开或固定锚点音量浮层');
      expect(body.contains('_controlPopoverAnchor('), isTrue,
          reason: '音量按钮应包固定锚点 helper，桌面 hover 逻辑在 helper 内复用');
      final String anchor = methodBody('Widget _controlPopoverAnchor({');
      expect(anchor.contains('MouseRegion('), isTrue,
          reason: '桌面 hover 应由 MouseRegion 打开音量 / 倍速浮层');
      expect(RegExp(r'_showControlPopover\(\s*kind').hasMatch(anchor), isTrue,
          reason: '锚点 hover 应打开对应浮层');
      final String toggle = methodBody('void _toggleControlPopover(');
      expect(toggle.contains('_controlPopoverPinned'), isTrue,
          reason: 'hover 已打开时点击应固定浮层，已固定后再点才关闭');
      expect(toggle.contains('pinned: true'), isTrue,
          reason: 'click/tap 必须以 pinned=true 打开浮层');
      expect(
          body.contains('PointerScrollEvent') &&
              body.contains('_onVolumeWheel(controller'),
          isTrue,
          reason: '桌面悬停音量控件时滚轮应调音量（_onVolumeWheel）');
    });

    test('音量浮层保留静音按钮和竖向滑条，滑条仍走现有音量同步通道', () {
      final String body = methodBody('Widget _buildVolumePopover(');
      expect(body.contains('RotatedBox('), isTrue,
          reason: '音量浮层应使用竖向滑条形态（B站式紧凑竖条）');
      expect(body.contains('Slider('), isTrue, reason: '音量浮层内必须有 Slider');
      expect(body.contains('_toggleMute()'), isTrue, reason: '浮层内保留静音按钮');
      expect(body.contains('_setVolumeFromSlider('), isTrue,
          reason: '浮层滑条拖动继续走 _setVolumeFromSlider');
      expect(body.contains('_volumeDisplay'), isTrue,
          reason: '浮层显示值应读 _volumeDisplay，与滚轮/键盘/移动竖滑共用同步通道');
    });

    test('倍速按钮打开紧凑浮层，复用 presets / _setSpeed / 1.0x 复位', () {
      final String show = methodBody('void _showSpeedMenu({');
      expect(
          RegExp(
            r'_toggleControlPopover\(\s*_VideoControlPopoverKind\.speed',
          ).hasMatch(show),
          isTrue,
          reason: '有锚点的倍速入口应打开或固定紧凑锚点浮层');
      expect(show.contains('if (popoverLink == null)'), isTrue,
          reason: '无按钮锚点的入口（如右键菜单）必须走可见 fallback，不能打开 unlinked 浮层');
      expect(show.contains('_showVideoSidePanel(_VideoSidePanelKind.speed)'),
          isTrue,
          reason: '无 source link 的倍速入口应退回可见 speed side panel');

      final String body = methodBody('Widget _buildSpeedPopover(');
      expect(body.contains('_speedMenuPresets()'), isTrue,
          reason: '倍速浮层继续复用既有预设生成逻辑');
      expect(body.contains('Slider('), isTrue,
          reason: '倍速浮层应提供 0.5x 到 2.0x 紧凑 slider');
      expect(body.contains('min: 0.5'), isTrue);
      expect(body.contains('max: 2.0'), isTrue);
      expect(body.contains('_setSpeed('), isTrue,
          reason: '倍速浮层改速必须走 _setSpeed');
      expect(body.contains('_setSpeed(1.0'), isTrue,
          reason: '倍速浮层应提供 1.0x 快捷复位');
    });

    test('可移动 speed 控件在 top bar / side rail / bottom 都有自己的浮层锚点', () {
      expect(src.contains('_controlPopoverLinkFor('), isTrue,
          reason: '可移动 speed 控件需要按所在 slot 取稳定 LayerLink');
      expect(src.contains('LayerLink? popoverLink'), isTrue,
          reason: '_activateVideoControlItem / _showSpeedMenu 必须传递触发源 link');

      final String top = methodBody('List<Widget> _topBarSlotButtons(');
      expect(top.contains('_controlPopoverLinkFor(slot, item)'), isTrue,
          reason: 'top bar speed 来自 _slotChipItems(slot)，必须使用该 slot 的锚点');
      expect(top.contains('_controlPopoverAnchor('), isTrue,
          reason: 'top bar speed 按钮必须渲染 CompositedTransformTarget');
      expect(top.contains('popoverLink: popoverLink'), isTrue,
          reason: 'top bar 点击 speed 时必须把自身 link 传给 _showSpeedMenu');

      final String rail = methodBody('Widget _buildVideoSideRailFor(');
      expect(rail.contains('_controlPopoverLinkFor(slot, item)'), isTrue,
          reason: 'side rail speed 来自 _slotChipItems(slot)，必须使用该 slot 的锚点');
      expect(rail.contains('_controlPopoverAnchor('), isTrue,
          reason: 'side rail speed 按钮必须渲染 CompositedTransformTarget');
      expect(rail.contains('popoverLink: popoverLink'), isTrue,
          reason: 'side rail 点击 speed 时必须把自身 link 传给 _showSpeedMenu');

      final String bottom = methodBody('Widget _buildVideoControlButton(');
      expect(
          bottom
              .contains('_controlPopoverLinkFor(slot, VideoControlItem.speed)'),
          isTrue,
          reason: 'bottom speed 也应走同一套 source-specific link，避免单例锚点误跟随');
    });

    test('零布局位移：禁旧 hover 改宽，不写控制条可见性真相源', () {
      final String body = volumeButtonBody();
      expect(body.contains('AnimatedContainer'), isFalse,
          reason: 'hover 不得用 AnimatedContainer 撑宽（BUG-248A 原症状）');
      expect(src.contains('_showVolumeMenu'), isFalse,
          reason: '旧的 showModalBottomSheet 音量菜单 _showVolumeMenu 必须移除');
      expect(src.contains('AnimatedContainer('), isFalse,
          reason: '不能恢复 hover 改宽 AnimatedContainer');
      expect(src.contains('_markControlsVisible(true)'), isFalse,
          reason: '浮层交互不得乐观写控制条可见，控制条真相源仍归 media_kit');
      expect(src.contains('_videoControlsVisible.value = true'), isFalse,
          reason: '浮层交互不得直接把派生可见性写 true');
      expect(src.contains('_pokeControlsVisible();'), isTrue,
          reason: '浮层 hover/click 只能用 _pokeControlsVisible 续命控制条');
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
      final int actStart = src.indexOf('void _activateVideoControlButton(');
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

String methodBody(String startSig) {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );
  final String src = page.readAsStringSync();
  final int start = src.indexOf(startSig);
  expect(start, greaterThanOrEqualTo(0), reason: '需有 $startSig');
  final List<int> ends = <int>[
    src.indexOf('\n  Widget ', start + startSig.length),
    src.indexOf('\n  void ', start + startSig.length),
    src.indexOf('\n  Future', start + startSig.length),
    src.indexOf('\n  List<', start + startSig.length),
    src.indexOf('\n  Material', start + startSig.length),
  ].where((int i) => i > start).toList();
  final int end =
      ends.isEmpty ? src.length : ends.reduce((int a, int b) => a < b ? a : b);
  return src.substring(start, end);
}
