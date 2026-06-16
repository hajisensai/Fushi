import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-438）：视频底栏音量控件是「图标锚点 + 上方紧凑浮层」，且布局尺寸
/// 与 hover / tap 状态无关（零位移）。media_kit 控制条 headless 渲染不全，无法用纯 widget
/// 测试拉起整条控制条，故在源码层钉死结构不变式：
///
/// 1. 底栏只保留图标按钮锚点：[_buildVolumeButton] 内不含 `Slider` / `Row` 横向占位。
/// 2. 零位移：浮层通过 `CompositedTransformFollower` 锚定按钮上方，hover / click / tap
///    只切换浮层，不改变底栏 widget 尺寸；旧的 hover 改宽 / OverlayEntry 几何测量实现不恢复。
/// 3. 单一真相源：滑条 / 滚轮 / 键盘音量键 / 静音切换 / media_kit 移动竖滑都经
///    [_syncVolumeDisplay] 写 [_volumeDisplay]，并经 controller.setVolume 落到播放器。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  final String page =
      read('lib/src/pages/implementations/video_hibiki_page.dart');

  String methodBody(String src, RegExp re, String label) {
    final RegExpMatch? m = re.firstMatch(src);
    if (m == null) {
      throw StateError('找不到 $label 方法体（源码守卫正则失配）');
    }
    return m.group(1)!;
  }

  group('TODO-438 紧凑音量入口结构', () {
    final String build = methodBody(
      page,
      RegExp(
        r'Widget _buildVolumeButton\(\s*VideoPlayerController controller, \{\s*required bool desktop,\s*\}\) \{(.*?)\n  \}',
        dotAll: true,
      ),
      '_buildVolumeButton',
    );

    test('音量控件是图标锚点，底栏不内联 Slider 或 Row', () {
      expect(build, contains('_controlPopoverAnchor('),
          reason: '底栏音量按钮必须是固定尺寸锚点，由锚点打开浮层');
      expect(build, contains('_VideoControlPopoverKind.volume'),
          reason: '音量入口必须打开 volume 浮层');
      expect(build, contains('_volumeControlPopoverLink'),
          reason: '音量浮层必须锚定音量按钮，而非参与底栏布局');
      expect(build, isNot(contains('Slider(')),
          reason: '底栏按钮内不得内联 Slider，避免占位随需求回退到横向滑条');
      expect(build, isNot(contains('Row(')),
          reason: '底栏音量入口只占图标空间，不再渲染图标 + 横滑条 Row');
    });

    test('浮层锚定按钮上方，hover / tap 不改变底栏几何', () {
      expect(page, contains('CompositedTransformFollower('),
          reason: '浮层应通过固定锚点跟随按钮，而非插入底栏布局');
      expect(page, contains('showWhenUnlinked: false'),
          reason: '锚点消失时浮层必须自动不可见');
      expect(page, contains('targetAnchor: Alignment.topCenter'),
          reason: '浮层应锚定按钮上方');
      expect(page, isNot(contains('_volumeSliderWidth')),
          reason: 'TODO-438 不再保留底栏横滑条固定宽度占位');
      expect(page, isNot(contains('MaterialDesktopVolumeButton')),
          reason: '不得恢复旧 MaterialDesktopVolumeButton / hover 改宽实现');
    });

    test('桌面悬停滑条区域滚轮调音量，但不改任何尺寸', () {
      expect(build, contains('PointerScrollEvent'), reason: '桌面须保留滚轮调音量');
      expect(build, contains('_onVolumeWheel('), reason: '滚轮走 _onVolumeWheel');
      // 控件体内不应再有任何「随 hover 改尺寸」的痕迹。
      expect(build.contains('AnimatedContainer'), isFalse,
          reason: 'hover 不得用 AnimatedContainer 撑宽（BUG-248A 原症状）');
      expect(build.contains('OverlayEntry'), isFalse,
          reason: '浮层由 controls Stack 内固定 overlay 渲染，不用 OverlayEntry');
    });

    test('点击图标打开浮层；浮层内保留静音与竖向滑条', () {
      expect(build, contains('_toggleControlPopover('),
          reason: '点击 / tap 图标应打开或固定音量浮层');
      expect(build, isNot(contains('_toggleMute()')),
          reason: '底栏图标现在是浮层入口，静音按钮保留在浮层内');

      final String toggle = methodBody(
        page,
        RegExp(
          r'void _toggleControlPopover\(\s*_VideoControlPopoverKind kind,\s*\{\s*required LayerLink popoverLink,\s*\}\s*\) \{(.*?)\n  \}',
          dotAll: true,
        ),
        '_toggleControlPopover',
      );
      expect(toggle, contains('_controlPopoverPinned'),
          reason: 'hover 已打开时点击应 pin；已 pin 时再点击才关闭');
      expect(toggle, contains('popoverLink: popoverLink'),
          reason: 'click / tap 应沿用触发按钮自己的 LayerLink 锚点');
      expect(toggle, contains('pinned: true'), reason: 'click / tap 应打开并固定浮层');

      final String popover = methodBody(
        page,
        RegExp(
          r'Widget _buildVolumePopover\(\) \{(.*?)\n  \}',
          dotAll: true,
        ),
        '_buildVolumePopover',
      );
      expect(popover, contains('_toggleMute()'), reason: '浮层内保留静音按钮');
      expect(popover, contains('RotatedBox('), reason: '浮层内是竖向滑条');
      expect(popover, contains('quarterTurns: -1'),
          reason: '竖向音量滑条用 RotatedBox 转向');
      expect(popover, contains('Slider('), reason: '浮层内保留可拖动 Slider');
      expect(popover, contains('_setVolumeFromSlider('),
          reason: '浮层滑条拖动走现有同步通道');
    });
  });

  group('TODO-377 音量显示单一真相源', () {
    test('_volumeDisplay 是 ValueNotifier 并被 ValueListenableBuilder 消费', () {
      expect(
        page,
        contains('final ValueNotifier<double> _volumeDisplay'),
        reason: '音量显示真相源是一个 ValueNotifier<double>',
      );
      expect(page, contains('ValueListenableBuilder<double>'),
          reason: '音量图标与浮层经 ValueListenableBuilder 消费显示真相源');
    });

    test('_setVolumeFromSlider 即时写 controller + 同步显示真相源', () {
      final String body = methodBody(
        page,
        RegExp(r'void _setVolumeFromSlider\(double value\) \{(.*?)\n  \}',
            dotAll: true),
        '_setVolumeFromSlider',
      );
      expect(body, contains('controller.setVolume('),
          reason: '滑条拖动须真写穿 controller.setVolume');
      expect(body, contains('_syncVolumeDisplay('), reason: '滑条拖动须同步显示真相源');
    });

    test('_syncVolumeDisplay 写 _volumeDisplay.value 并 clamp 到 0..100', () {
      final String body = methodBody(
        page,
        RegExp(r'void _syncVolumeDisplay\(double volume\) \{(.*?)\n  \}',
            dotAll: true),
        '_syncVolumeDisplay',
      );
      expect(body, contains('_volumeDisplay.value'),
          reason: '同步真相源 = 写 _volumeDisplay.value');
      expect(body, contains('clamp(0.0, 100.0)'), reason: '音量须 clamp 到 0..100');
    });

    test('键盘音量键 / 静音切换 / media_kit 移动竖滑都同步显示真相源', () {
      final String adjust = methodBody(
        page,
        RegExp(
            r'Future<void> _adjustVolume\(double delta\) async \{(.*?)\n  \}',
            dotAll: true),
        '_adjustVolume',
      );
      expect(adjust, contains('_syncVolumeDisplay('), reason: '键盘音量键调音量须同步显示');
      final String mute = methodBody(
        page,
        RegExp(r'Future<void> _toggleMute\(\) async \{(.*?)\n  \}',
            dotAll: true),
        '_toggleMute',
      );
      expect(mute, contains('_syncVolumeDisplay('), reason: '静音切换须同步显示');
      final String mk = methodBody(
        page,
        RegExp(r'void _onMediaKitVolumeChanged\(double value\) \{(.*?)\n  \}',
            dotAll: true),
        '_onMediaKitVolumeChanged',
      );
      expect(mk, contains('_syncVolumeDisplay('),
          reason: 'media_kit 移动端竖滑调音量须同步显示');
    });

    test('换集 / 加载后用 controller 实际音量初始化显示真相源', () {
      expect(page, contains('_syncVolumeDisplay(controller.volume)'),
          reason: '加载视频后须把显示真相源对齐 controller 实际音量');
    });
  });

  group('TODO-438 旧 hover 改宽 / OverlayEntry 复杂度不恢复', () {
    test('页面不再含任何旧音量 OverlayEntry 实现符号', () {
      const List<String> banned = <String>[
        '_volumeOverlayEntry',
        '_volumeButtonKey',
        '_volumePopoverValue',
        '_volumePopoverSetState',
        '_volumeAnchorHovered',
        '_volumePopoverHovered',
        '_volumePopoverHoverCloseTimer',
        '_showVolumePopover',
        '_dismissVolumePopover',
        '_syncVolumePopover',
        '_toggleVolumePopover',
        '_volumeAnchorRectInOverlay',
        '_onVolumeAnchorHover',
        '_scheduleVolumePopoverHoverClose',
      ];
      for (final String sym in banned) {
        expect(page.contains(sym), isFalse,
            reason: '旧 popover 符号「$sym」应已随一行式重构删除');
      }
    });

    test('dispose 释放音量显示与浮层状态', () {
      final RegExpMatch? m = RegExp(
        r'void dispose\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(m, isNotNull, reason: '找不到 dispose 方法体');
      expect(m!.group(1), contains('_volumeDisplay.dispose()'),
          reason: 'dispose 须释放 _volumeDisplay');
      expect(m.group(1), contains('_controlPopoverHideTimer?.cancel()'),
          reason: 'dispose 须取消浮层延迟关闭 timer');
      expect(m.group(1), contains('_videoControlPopover.dispose()'),
          reason: 'dispose 须释放浮层 ValueNotifier');
    });
  });
}
