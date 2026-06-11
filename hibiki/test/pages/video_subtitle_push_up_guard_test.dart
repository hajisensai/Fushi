import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：字幕动态避让进度条（TODO-129，反转 TODO-089 的恒抬升）的接线不被回退。
///
/// 背景：media_kit 用自绘 [VideoSubtitleOverlay]（禁用了内置 SubtitleView）。089 曾把
/// 控制条避让恒加进默认 bottomPadding（字幕恒抬高、进度条隐藏时也留空白）。129 改成
/// 「控制条出现时把字幕往上顶对应高度、隐藏落回」的动态避让。难点：media_kit 控制条
/// 可见性 `visible` 藏在私有 State、不暴露任何回调 / notifier / 公开 API（已查证
/// `setSubtitleViewPadding` 也只写进 SubtitleView 私有 State）。故 Hibiki 侧自建一份镜像
/// （[_videoControlsVisible]），复刻 media_kit 同一套触发源（桌面 hover、移动 tap、键盘
/// /seek poke、controlsHoverDuration 自动隐藏）喂给 overlay。
///
/// 显隐时序依赖 media_kit 私有 State + 真实 hover/timer，widget 测试难稳定复现，故用
/// 源码扫描守卫这些不变式；动态 padding 的几何由 video_subtitle_overlay_test.dart 验。
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');
  final File style = File('lib/src/media/video/video_subtitle_style.dart');

  late String src;
  late String styleSrc;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    expect(style.existsSync(), isTrue, reason: '字幕样式源文件应存在');
    src = page.readAsStringSync();
    styleSrc = style.readAsStringSync();
  });

  test('反转 089：默认 bottomPadding 是自然基线 75，不再恒含控制条避让', () {
    // 撤回 129（默认改回 100=75+98 折中的恒抬升）→ 本条变红。
    expect(styleSrc, contains('bottomPadding: 75'),
        reason: '默认位置应回到自然基线 75，避让改由 overlay 动态叠加');
    expect(styleSrc, isNot(contains('bottomPadding: 100')),
        reason: '默认不应把控制条避让恒含进 bottomPadding（那是 089 的恒抬升）');
  });

  test('State 持有控制条可见性镜像 ValueNotifier 并在 dispose 释放', () {
    expect(src, contains('ValueNotifier<bool> _videoControlsVisible'),
        reason: '应有 State 级别的 _videoControlsVisible 镜像 media_kit 控制条可见性');
    expect(src, contains('_videoControlsVisible.dispose()'),
        reason: 'notifier 必须在 dispose 释放，避免泄漏');
    expect(src, contains('_videoControlsHideTimer'),
        reason: '应有自动隐藏定时器复刻 media_kit controlsHoverDuration 时序');
    expect(src, contains('_videoControlsHideTimer?.cancel()'),
        reason: '隐藏定时器必须在 dispose / 重置时取消');
  });

  test('可见性镜像喂给字幕 overlay（驱动动态避让，全屏复用同一 builder 故跨全屏）', () {
    expect(src, contains('controlsVisible: _videoControlsVisible'),
        reason: 'overlay 必须接上 _videoControlsVisible 才能动态避让进度条');
  });

  test('桌面 hover 镜像 media_kit onEnter/onHover/onExit', () {
    expect(src, contains('Widget _videoControlsHoverWrap('),
        reason: '应有桌面 hover 包裹层镜像 media_kit MouseRegion 时序');
    // non-opaque：不阻断 hover 下探到 media_kit 自己的 MouseRegion（BUG-198 纪律）。
    final int wrap = src.indexOf('Widget _videoControlsHoverWrap(');
    final int wrapEnd = src.indexOf('\n  }', wrap);
    final String wrapBody = src.substring(wrap, wrapEnd);
    expect(wrapBody, contains('opaque: false'),
        reason: 'hover 包裹层必须 non-opaque，否则吞 hover、media_kit 控制条不再被唤起');
    expect(wrapBody, contains('_markControlsVisible(true)'),
        reason: 'hover enter/move 应翻镜像可见');
    expect(wrapBody, contains('_onVideoControlsHoverExit()'),
        reason: 'hover exit 应收起镜像（字幕落回基线）');
  });

  test('键盘/seek 唤起控制条（_pokeControlsVisible）同步翻镜像可见', () {
    final int poke = src.indexOf('void _pokeControlsVisible()');
    expect(poke, greaterThanOrEqualTo(0));
    final int pokeEnd = src.indexOf(
        '\n  static const Duration '
        '_videoControlsHoverDuration',
        poke);
    expect(pokeEnd, greaterThan(poke),
        reason: '_videoControlsHoverDuration 常量应紧随 poke 方法');
    final String pokeBody = src.substring(poke, pokeEnd);
    expect(pokeBody, contains('_markControlsVisible(true)'),
        reason: '键盘 / seek 唤起控制条时字幕也应跟着上顶');
  });

  test('移动端点画面 toggle 镜像 media_kit 移动控制条 onTap', () {
    final int handler = src.indexOf('void _handleVideoPointerUp(');
    expect(handler, greaterThanOrEqualTo(0));
    final int handlerEnd =
        src.indexOf('\n  bool _isVideoChromePointer(', handler);
    final String body = src.substring(handler, handlerEnd);
    expect(body, contains('_toggleControlsVisibleForTap()'),
        reason: '移动端点画面应 toggle 控制条镜像可见性（镜像 media_kit onTap）');
  });

  test('锁定 / 沉浸模式下镜像强制不可见（控制条本就不弹、字幕不避让）', () {
    final int mark = src.indexOf('void _markControlsVisible(');
    expect(mark, greaterThanOrEqualTo(0));
    final int markEnd = src.indexOf('\n  /// 桌面鼠标移出视频区', mark);
    final String body = src.substring(mark, markEnd);
    expect(body, contains('_immersiveLocked.value'),
        reason: '锁定态下镜像应强制不可见（无控制条可遮挡）');
  });
}
