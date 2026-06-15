import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-377）：视频底栏音量控件是「图标 + 常驻横滑条」一行式，且布局尺寸
/// 与 hover 状态无关（零位移）。media_kit 控制条 headless 渲染不全，无法用纯 widget
/// 测试拉起整条控制条，故在源码层钉死结构不变式：
///
/// 1. 一行式：[_buildVolumeButton] 内是 `Row`（图标 + 横向 `Slider`），不再弹独立浮层。
/// 2. 零位移：滑条占位宽度是常量 [_volumeSliderWidth]（仅随界面缩放），不随 hover 变化；
///    旧的 hover 弹出竖向 popover（OverlayEntry + 锚点几何 + 多个 hover bool + 延迟关闭
///    定时）整套已删——它是「鼠标放上去弹一块浮层 / 抖动」的根。
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

  group('TODO-377 一行式音量控件结构', () {
    final String build = methodBody(
      page,
      RegExp(
        r'Widget _buildVolumeButton\(\s*VideoPlayerController controller, \{\s*required bool desktop,\s*\}\) \{(.*?)\n  \}',
        dotAll: true,
      ),
      '_buildVolumeButton',
    );

    test('音量控件是图标 + 横向 Slider 同处一个 Row（一行式）', () {
      expect(build, contains('Row('), reason: '一行式：图标与滑条须在同一个 Row');
      expect(build, contains('Slider('), reason: '一行式须含横向 Slider（而非弹出浮层）');
      expect(build, contains('mainAxisSize: MainAxisSize.min'),
          reason: 'Row 用 min 紧凑占位，不撑满底栏');
    });

    test('滑条占位是固定宽度（与 hover 无关 → 零位移）', () {
      expect(build, contains('_volumeSliderWidth'),
          reason: '滑条须用固定占位宽度常量（hover 零位移的根）');
      expect(page, contains('static const double _volumeSliderWidthBase'),
          reason: '占位宽度须是源码常量，不随运行时 hover 状态计算');
    });

    test('桌面悬停滑条区域滚轮调音量，但不改任何尺寸', () {
      expect(build, contains('PointerScrollEvent'), reason: '桌面须保留滚轮调音量');
      expect(build, contains('_onVolumeWheel('), reason: '滚轮走 _onVolumeWheel');
      // 一行式控件体内不应再有任何「随 hover 改尺寸 / 弹浮层」的痕迹。
      expect(build.contains('AnimatedContainer'), isFalse,
          reason: 'hover 不得用 AnimatedContainer 撑宽（BUG-248A 原症状）');
      expect(build.contains('OverlayEntry'), isFalse, reason: '不再弹独立浮层');
    });

    test('点击图标 = 静音切换，滑条拖动经 controller + 显示真相源', () {
      expect(build, contains('_toggleMute()'), reason: '点击音量图标 = 静音切换');
      expect(build, contains('_setVolumeFromSlider('),
          reason: '滑条拖动走 _setVolumeFromSlider');
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
          reason: '音量控件经 ValueListenableBuilder 只重建自身子树');
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

  group('TODO-377 旧 hover 弹出 popover 复杂度已删除', () {
    test('页面不再含任何旧音量 popover 符号', () {
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
        '_buildVolumePopover',
        '_volumeAnchorRectInOverlay',
        '_onVolumeAnchorHover',
        '_scheduleVolumePopoverHoverClose',
      ];
      for (final String sym in banned) {
        expect(page.contains(sym), isFalse,
            reason: '旧 popover 符号「$sym」应已随一行式重构删除');
      }
    });

    test('dispose 释放 _volumeDisplay notifier', () {
      final RegExpMatch? m = RegExp(
        r'void dispose\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(m, isNotNull, reason: '找不到 dispose 方法体');
      expect(m!.group(1), contains('_volumeDisplay.dispose()'),
          reason: 'dispose 须释放 _volumeDisplay');
    });
  });
}
