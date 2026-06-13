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
  final File overlay = File('lib/src/media/video/video_subtitle_overlay.dart');

  late String src;
  late String styleSrc;
  late String overlaySrc;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    expect(style.existsSync(), isTrue, reason: '字幕样式源文件应存在');
    expect(overlay.existsSync(), isTrue, reason: '字幕 overlay 源文件应存在');
    src = page.readAsStringSync();
    styleSrc = style.readAsStringSync();
    overlaySrc = overlay.readAsStringSync();
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

  test('视频页显式传入按平台真实几何 + 随缩放的 reserve（BUG-238，不回退裸常量 56）', () {
    // 根因守卫：overlay 默认 controlsBottomReserve = 常量 56，既不随缩放、又 < 默认基线
    // 75，移动端 max(75,56)=75 把字幕留在被抬高的进度条下面被遮（用户报「只动一点点」）。
    // 视频页必须显式传入按真实控制条几何加总的 reserve（移动 ≈140×缩放 > 75）才真正抬升。
    expect(src,
        contains('controlsBottomReserve: _subtitleControlsBottomReserve()'),
        reason: 'overlay 必须接上视频页计算的真实几何 reserve，否则回退裸常量 56 被遮');
    // 计算函数由真实控制条 getter 加总（均已 ×_videoUiScale），故随界面缩放。
    final int fn = src.indexOf('double _subtitleControlsBottomReserve()');
    expect(fn, greaterThanOrEqualTo(0),
        reason: '应有 _subtitleControlsBottomReserve 计算真实几何 reserve');
    final int fnEnd = src.indexOf('\n  }', fn);
    final String body = src.substring(fn, fnEnd);
    expect(body, contains('videoSubtitleControlsReserve('),
        reason: 'reserve 应经纯函数 videoSubtitleControlsReserve 按几何加总（页面/测试同源）');
    for (final String getter in <String>[
      '_videoButtonBarHeight',
      '_videoSeekBarButtonGap',
      '_videoSeekBarContainerHeight',
      '_videoBottomChromeBaseline',
      '_videoBottomSystemInset()',
    ]) {
      expect(body, contains(getter),
          reason: 'reserve 必须由真实控制条几何项 $getter 加总（随缩放、盖过移动进度条）');
    }
    expect(body, contains('_isDesktopVideoControls'),
        reason: 'reserve 应按平台分桌面/移动几何（桌面只让一个按钮行，移动让进度条上缘）');
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
    // hover 时序绑到专用 handler（enter/move 唤起、exit 收起），handler 内再翻镜像。
    expect(wrapBody, contains('onEnter: _handleVideoControlsHover'),
        reason: 'hover enter 应绑 _handleVideoControlsHover');
    expect(wrapBody, contains('onHover: _handleVideoControlsHover'),
        reason: 'hover move 应绑 _handleVideoControlsHover');
    expect(wrapBody, contains('onExit: _handleVideoControlsHoverExit'),
        reason: 'hover exit 应绑 _handleVideoControlsHoverExit');
    // enter/move handler 翻镜像可见（字幕上顶避让进度条）。
    final int enter = src.indexOf('void _handleVideoControlsHover(');
    expect(enter, greaterThanOrEqualTo(0),
        reason: '应有 _handleVideoControlsHover');
    final String enterBody = src.substring(enter, src.indexOf('\n  }', enter));
    expect(enterBody, contains('_markControlsVisible(true)'),
        reason: 'hover enter/move 应翻镜像可见');
    // exit handler 收起镜像（字幕落回基线）。
    final int exit = src.indexOf('void _handleVideoControlsHoverExit(');
    expect(exit, greaterThanOrEqualTo(0),
        reason: '应有 _handleVideoControlsHoverExit');
    final String exitBody = src.substring(exit, src.indexOf('\n  }', exit));
    expect(exitBody, contains('_onVideoControlsHoverExit()'),
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

  test('避让对控制条高度取下限（max），不是 bottomPadding + reserve 加法（TODO-161）', () {
    // 根因守卫：TODO-129 原把可见时底部 padding 算成 `bottomPadding + extraBottom`，
    // 基线 75 < 控制条高 98 时得 173px，凭空多抬一个基线把字幕顶飞出画面（桌面 hover
    // 字幕「消失」）。TODO-161 改成对控制条高取下限 max(bottomPadding, reserve)。撤回成
    // 加法（恢复 `bottomPadding + extraBottom` / `+ widget.controlsBottomReserve`）即露。
    final int fn = overlaySrc.indexOf('EdgeInsets _paddingFor(');
    expect(fn, greaterThanOrEqualTo(0), reason: '_paddingFor 应存在');
    final int fnEnd = overlaySrc.indexOf('\n  }', fn);
    final String body = overlaySrc.substring(fn, fnEnd);
    // 底部分支用「基线 vs 控制条高」取下限的三元，非加法。
    expect(
        body, contains('widget.bottomPadding > widget.controlsBottomReserve'),
        reason: '底部避让应对控制条高度取下限（max），让字幕底缘骑控制条顶、不飞');
    expect(body, isNot(contains('bottomPadding + ')),
        reason: '避让不能用 `bottomPadding + reserve` 加法（173px 把字幕顶飞，TODO-161）');
    // _anchoredPadded 应把可见性布尔直接喂给 _paddingFor，不再算 extraBottom 数值叠加。
    expect(overlaySrc, isNot(contains('extraBottom')),
        reason: '不应残留 extraBottom 加法量（已改为取下限的布尔驱动）');
  });
}
