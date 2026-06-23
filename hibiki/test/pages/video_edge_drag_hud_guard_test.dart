import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 桌面屏幕边缘竖拖手势（TODO-754）的守卫：左半区按住竖直拖动调亮度、右半区调
/// 音量，与移动端 media_kit 内建竖滑同语义，桌面自加 Flutter [GestureDetector] 竖拖。
///
/// **背景**：桌面主题（[_desktopControlsTheme]）不启用 media_kit 的 volumeGesture /
/// brightnessGesture（那是移动 Material 控制条特性），故桌面原本没有竖拖调音量 /
/// 亮度。本功能在 [layout.part.dart] 的 [GestureDetector] 上加 onVerticalDrag*，仅
/// 桌面接（移动端继续走 media_kit 内建手势避免双份）。
///
/// **根因（桌面亮度）**：桌面系统屏幕亮度不可控（[ScreenBrightnessController.canControl]
/// 为 false），假装能控只会静默 no-op。故左半区竖拖在系统亮度不可控时回退到 libmpv
/// `brightness` 属性（[VideoPlayerController.setVideoBrightness]，-100..100），给画面
/// 真实反馈。无论哪条都 [_showBrightnessOsd] 弹左侧亮度 HUD；右半区音量经
/// [_applyUserVideoVolume]（内部自动弹音量 HUD）。
///
/// media_kit/libmpv 在测试宿主不可用，无法纯单测真实拖动手势，故守两层：
/// 1. 纯函数 [VideoHibikiPage.edgeDragValueDeltaFor] 的竖位移→值增量映射；
/// 2. 源码守卫：手势绑了 onVerticalDrag*、handler 桌面门控 + 左右半区分流到亮度 /
///    音量通道 + 弹对应 HUD、桌面亮度走可控属性。
void main() {
  group('edgeDragValueDeltaFor — 竖位移→值增量映射', () {
    test('零位移 → 零增量', () {
      expect(VideoHibikiPage.edgeDragValueDeltaFor(0), 0.0);
    });

    test('向上拖动（dy 负）增大、向下拖动（dy 正）减小', () {
      // 满量程灵敏度像素竖拖 → ±100。
      const double full = VideoHibikiPage.edgeDragVerticalSensitivity;
      expect(VideoHibikiPage.edgeDragValueDeltaFor(-full), 100.0);
      expect(VideoHibikiPage.edgeDragValueDeltaFor(full), -100.0);
    });

    test('半量程位移 → ±50', () {
      const double half = VideoHibikiPage.edgeDragVerticalSensitivity / 2;
      expect(VideoHibikiPage.edgeDragValueDeltaFor(-half), 50.0);
      expect(VideoHibikiPage.edgeDragValueDeltaFor(half), -50.0);
    });

    test('灵敏度常量为正且与移动端竖滑量级一致（320）', () {
      expect(VideoHibikiPage.edgeDragVerticalSensitivity, 320.0);
    });
  });

  group('源码接线守卫', () {
    final String page = readVideoHibikiSource();

    test('GestureDetector 绑了 onVerticalDrag*（start/update/end）', () {
      expect(
        page.contains('onVerticalDragStart: _handleVideoEdgeDragStart,'),
        isTrue,
        reason: '没有 onVerticalDragStart 就没有竖拖手势入口（TODO-754）',
      );
      expect(
        page.contains('onVerticalDragUpdate: _handleVideoEdgeDragUpdate,'),
        isTrue,
      );
      expect(
        page.contains('onVerticalDragEnd: _handleVideoEdgeDragEnd,'),
        isTrue,
      );
    });

    test('start 仅桌面激活 + 门控对齐 + 左右半区按起手 x 判定', () {
      final String start = _functionSource(
        page,
        'void _handleVideoEdgeDragStart(',
        'void _handleVideoEdgeDragUpdate(',
      );
      // 仅桌面（移动端走 media_kit 内建竖滑，避免双份）。
      expect(start.contains('if (!_isDesktopVideoControls) return;'), isTrue,
          reason: '移动端不应接 Flutter 竖拖（双份）');
      // 门控对齐 _handleVideoPointerUp：沉浸锁 / 侧栏 / 剧集列表 / chrome 区不触发。
      expect(start.contains('if (_immersiveLocked.value) return;'), isTrue);
      expect(
          start.contains('if (_videoSidePanel.value != null) return;'), isTrue);
      expect(start.contains('if (_episodeListVisible.value) return;'), isTrue);
      expect(
        start.contains('if (_isVideoChromePointer('),
        isTrue,
        reason: '起手在控制条 chrome 区的竖拖让给底部 seek bar / 顶栏，不抢',
      );
      // 左右半区按起手点 dx 与控件宽度一半比较。
      expect(start.contains('final bool right = localDx >= width / 2;'), isTrue,
          reason: '按起手 x 判定左 / 右半区');
      // 默认不激活，满足条件才置位（门控未过 → update/end 早返回）。
      expect(start.contains('_edgeDragIsRightHalf = null;'), isTrue);
    });

    test('start 左半区亮度基准取当前 mpv 视频亮度（桌面唯一可控通道）', () {
      final String start = _functionSource(
        page,
        'void _handleVideoEdgeDragStart(',
        'void _handleVideoEdgeDragUpdate(',
      );
      // 根因：本组手势仅桌面接，桌面系统屏幕亮度不可控（canControl 恒 false，假装能控
      // 只静默 no-op）→ 亮度唯一可控通道是 mpv `brightness`（TODO-754）。基准取当前
      // mpv 视频亮度映射到 0..100。
      expect(start.contains('_controller?.videoBrightness'), isTrue,
          reason: '左半区基准取当前 mpv 视频亮度（桌面唯一可控亮度通道）');
    });

    test('update 右半区音量经 _applyUserVideoVolume（自动弹音量 HUD）', () {
      final String update = _functionSource(
        page,
        'void _handleVideoEdgeDragUpdate(',
        'void _handleVideoEdgeDragEnd(',
      );
      expect(update.contains('if (right == null) return;'), isTrue,
          reason: '本次拖动未激活（门控未过）不响应');
      // 竖位移经纯函数映射、clamp 到 0..100。
      expect(update.contains('VideoHibikiPage.edgeDragValueDeltaFor('), isTrue,
          reason: 'update 必须经纯函数映射竖位移');
      expect(update.contains('.clamp(0.0, 100.0)'), isTrue);
      // 右 = 音量统一入口（内部自动弹音量 HUD，零额外 HUD 代码）。
      expect(update.contains('_applyUserVideoVolume(value)'), isTrue,
          reason: '右半区音量走统一入口 _applyUserVideoVolume（自动弹音量 HUD）');
    });

    test('update 左半区亮度走 mpv brightness 属性 + 弹左侧亮度 HUD', () {
      final String update = _functionSource(
        page,
        'void _handleVideoEdgeDragUpdate(',
        'void _handleVideoEdgeDragEnd(',
      );
      // 桌面亮度走 libmpv brightness 属性（可控反馈，TODO-754 根因）。
      expect(update.contains('_controller?.setVideoBrightness('), isTrue,
          reason: '桌面亮度走 libmpv brightness 属性（可控反馈）');
      // 弹左侧亮度 HUD（复用现成 HUD，不重造）。
      expect(update.contains('_showBrightnessOsd(value)'), isTrue,
          reason: '亮度必须弹左侧亮度 HUD');
    });

    test('end 清拖动状态（下次重判左右半区与基准）', () {
      final String end = _functionSource(
        page,
        'void _handleVideoEdgeDragEnd(',
        'void _handleSecondaryTap(',
      );
      expect(end.contains('_edgeDragIsRightHalf = null;'), isTrue,
          reason: '松手必须清状态，否则下次拖动误判仍在上次半区');
    });
  });
}

/// 截取 [source] 中从 [start] 标记到 [end] 标记之间的源码片段（含 [start]、不含 [end]）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
