import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：字幕动态避让进度条（TODO-129，反转 TODO-089 的恒抬升）的接线不被回退，
/// 且 TODO-364 的「单一真相源」修复不被退回旧镜像 + 第二个 Timer。
///
/// 背景：media_kit 用自绘 [VideoSubtitleOverlay]（禁用了内置 SubtitleView）。089 曾把
/// 控制条避让恒加进默认 bottomPadding（字幕恒抬高、进度条隐藏时也留空白）。129 改成
/// 「控制条出现时把字幕往上顶对应高度、隐藏落回」的动态避让。
///
/// TODO-364 根因：旧实现 Hibiki 侧自建一份**镜像** `_videoControlsVisible` + **独立隐藏
/// Timer** `_videoControlsHideTimer`，与 media_kit 私有 `visible` + 私有 Timer 各自计时、
/// 各入口（hover/移动 tap/键盘 poke）独立维护 → 与真实控制条相位会反（进度条起落时并发
/// 操作字幕方向反）。修复：vendored media_kit_video fork 给两套控制主题加 `visibilityNotifier`，
/// 控制条把**真实** `visible` 推进它（[_mediaKitControlsVisible]），字幕避让消费的
/// [_videoControlsVisible] 改由唯一派生函数 [_applyControlsVisibilityFromMediaKit]
/// （= !gated && 真实可见）写入，删掉镜像独立 Timer / 移动镜像 toggle / hover-poke 乐观翻镜像。
///
/// 显隐时序依赖 media_kit 私有 State + 真实 hover/timer，widget 测试难稳定复现，故用
/// 源码扫描守卫这些不变式；动态 padding 的几何与方向由 video_subtitle_overlay_test.dart 验。
void main() {
  final File style = File('lib/src/media/video/video_subtitle_style.dart');
  final File overlay = File('lib/src/media/video/video_subtitle_overlay.dart');

  late String src;
  late String styleSrc;
  late String overlaySrc;
  setUpAll(() {
    expect(style.existsSync(), isTrue, reason: '字幕样式源文件应存在');
    expect(overlay.existsSync(), isTrue, reason: '字幕 overlay 源文件应存在');
    src = readVideoHibikiSource();
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

  test('TODO-364 单一真相源：State 持有 media_kit 真实可见性 + 派生可见性，dispose 释放', () {
    expect(src, contains('ValueNotifier<bool> _mediaKitControlsVisible'),
        reason: '应有 _mediaKitControlsVisible 接收 media_kit 控制条真实可见性（单一真相源）');
    expect(src, contains('ValueNotifier<bool> _videoControlsVisible'),
        reason: '应有派生的 _videoControlsVisible 供字幕避让消费');
    expect(src, contains('_mediaKitControlsVisible.dispose()'),
        reason: '真相源 notifier 必须在 dispose 释放');
    expect(src, contains('_videoControlsVisible.dispose()'),
        reason: '派生 notifier 必须在 dispose 释放，避免泄漏');
  });

  test('TODO-364 反退回：不再有 Hibiki 侧独立隐藏 Timer / 移动镜像 toggle', () {
    // 旧实现的镜像独立 Timer 与 media_kit 私有 Timer 相位反（根因），修复后删除。
    expect(src, isNot(contains('_videoControlsHideTimer')),
        reason: '不应残留 Hibiki 侧独立隐藏 Timer（media_kit 自己的 Timer 是唯一计时，TODO-364）');
    expect(src, isNot(contains('_toggleControlsVisibleForTap')),
        reason: '不应残留移动端镜像 toggle（移动 tap 由 media_kit onTap 决定并推送，TODO-364）');
  });

  test('TODO-364 media_kit 真实可见性经 visibilityNotifier 注入两套控制主题', () {
    // 桌面 + 移动主题都注入同一个真相源 notifier，窗口/全屏复用同一 builder 故跨全屏。
    final int count =
        'visibilityNotifier: _mediaKitControlsVisible'.allMatches(src).length;
    expect(count, greaterThanOrEqualTo(2),
        reason: '桌面与移动两套控制主题都必须注入 _mediaKitControlsVisible 作真相源');
  });

  test('TODO-364 字幕避让消费的 _videoControlsVisible 只由唯一派生函数写入', () {
    expect(src, contains('controlsVisible: _videoControlsVisible'),
        reason: 'overlay 必须接上派生的 _videoControlsVisible 才能动态避让进度条');
    expect(src, contains('void _applyControlsVisibilityFromMediaKit()'),
        reason: '应有唯一派生函数把 media_kit 真实可见性 + 门控派生进 _videoControlsVisible');
    final int fn = src.indexOf('void _applyControlsVisibilityFromMediaKit()');
    final int fnEnd = src.indexOf('\n  }', fn);
    final String body = src.substring(fn, fnEnd);
    expect(body, contains('_mediaKitControlsVisible.value'),
        reason: '派生必须读 media_kit 真实可见性（单一真相源）');
    expect(body, contains('_videoControlsVisible.value ='),
        reason: '派生是 _videoControlsVisible 的唯一写入点');
    // 订阅四输入（真相源 + 三门控）任一变化即重派生。
    for (final String sub in <String>[
      '_mediaKitControlsVisible.addListener(_applyControlsVisibilityFromMediaKit)',
      '_immersiveLocked.addListener(_applyControlsVisibilityFromMediaKit)',
      '_videoSidePanel.addListener(_applyControlsVisibilityFromMediaKit)',
      '_subtitleListVisible.addListener(_applyControlsVisibilityFromMediaKit)',
    ]) {
      expect(src, contains(sub), reason: 'initState 必须订阅 $sub，任一输入变化即重派生避让方向');
    }
  });

  test('视频页显式传入按平台真实几何 + 随缩放的 reserve（BUG-238，不回退裸常量 56）', () {
    // 根因守卫：overlay 默认 controlsBottomReserve = 常量 56，既不随缩放、又 < 默认基线
    // 75，移动端 max(75,56)=75 把字幕留在被抬高的进度条下面被遮（用户报「只动一点点」）。
    // 视频页必须显式传入按真实控制条几何加总的 reserve（移动 ≈140×缩放 > 75）才真正抬升。
    expect(
        RegExp(r'controlsBottomReserve:\s*_subtitleControlsBottomReserve\(\)')
            .hasMatch(src),
        isTrue,
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
      // TODO-568：移动 reserve 抬到「可见轨道上缘 + 呼吸间距」（不再用整段触摸热区高
      // _videoSeekBarContainerHeight，那会顶飞 ~47×缩放 透明命中区空白）。
      '_videoSeekBarTrackHeight',
      '_videoSubtitleSeekBarBreathingGap',
      '_videoBottomChromeBaseline',
      '_videoBottomSystemInset()',
    ]) {
      expect(body, contains(getter),
          reason: 'reserve 必须由真实控制条几何项 $getter 加总（随缩放、盖过移动进度条）');
    }
    expect(body, contains('_isDesktopVideoControls'),
        reason: 'reserve 应按平台分桌面/移动几何（桌面只让一个按钮行，移动让进度条上缘）');
    // TODO-568 防回退：reserve 计算不应再用整段触摸热区高（顶飞根因）。撤回成
    // `seekBarContainerHeight: _videoSeekBarContainerHeight` → 本条红。
    expect(body, isNot(contains('_videoSeekBarContainerHeight')),
        reason: 'reserve 不应再用整段触摸热区高 _videoSeekBarContainerHeight'
            '（字幕被顶飞 ~47×缩放 空白，TODO-568 改用可见轨道高 + 呼吸间距）');
  });

  test('桌面 hover 包裹层 non-opaque 下探 media_kit 自己的 MouseRegion（TODO-364）', () {
    expect(src, contains('Widget _videoControlsHoverWrap('),
        reason: '应有桌面 hover 包裹层（唤回光标 / 锁按钮）');
    // non-opaque：不阻断 hover 下探到 media_kit 自己的 MouseRegion（BUG-198 纪律）——这正是
    // TODO-364 把可见性交还 media_kit 的前提：真实 hover 命中其 onHover 翻 visible 并推送。
    final int wrap = src.indexOf('Widget _videoControlsHoverWrap(');
    final int wrapEnd = src.indexOf('\n  }', wrap);
    final String wrapBody = src.substring(wrap, wrapEnd);
    expect(wrapBody, contains('opaque: false'),
        reason: 'hover 包裹层必须 non-opaque，否则吞 hover、media_kit 控制条不再被唤起/推送');
    expect(wrapBody, contains('onEnter: _handleVideoControlsHover'),
        reason: 'hover enter 应绑 _handleVideoControlsHover');
    expect(wrapBody, contains('onHover: _handleVideoControlsHover'),
        reason: 'hover move 应绑 _handleVideoControlsHover');
    expect(wrapBody, contains('onExit: _handleVideoControlsHoverExit'),
        reason: 'hover exit 应绑 _handleVideoControlsHoverExit');
    // TODO-364：hover handler 不再乐观翻镜像可见（避免与 media_kit 真实态相位反）；
    // 可见性交给 media_kit 自己的 onHover 推送。撤回成 `_markControlsVisible(true)` → 红。
    final int enter = src.indexOf('void _handleVideoControlsHover(');
    expect(enter, greaterThanOrEqualTo(0),
        reason: '应有 _handleVideoControlsHover');
    final String enterBody = src.substring(enter, src.indexOf('\n  }', enter));
    expect(enterBody, isNot(contains('_markControlsVisible(true)')),
        reason: 'hover 不应再乐观翻镜像可见（可见性由 media_kit 真实态推送，TODO-364）');
  });

  test('键盘/seek 唤起（_pokeControlsVisible）派合成 hover 给 media_kit、不乱翻镜像', () {
    final int poke = src.indexOf('void _pokeControlsVisible()');
    expect(poke, greaterThanOrEqualTo(0));
    final int pokeEnd = src.indexOf('\n  void _clearRailHover()', poke);
    expect(pokeEnd, greaterThan(poke),
        reason: '_clearRailHover 应紧随 poke 方法（TODO-590 batch3 抽出 part 后的相邻成员）');
    final String pokeBody = src.substring(poke, pokeEnd);
    // poke 仍派发合成 hover 命中 media_kit MouseRegion（其 onHover 翻 visible 并推送）。
    expect(pokeBody, contains('PointerHoverEvent('),
        reason: 'poke 应派发合成 hover 驱动 media_kit 自己的可见性 / Timer（单一真相源）');
    // TODO-364：poke 不再另翻镜像可见（旧 `_markControlsVisible(true)` 是相位反根因之一）。
    expect(pokeBody, isNot(contains('_markControlsVisible(true)')),
        reason: 'poke 不应再乐观翻镜像（可见性由 media_kit 收到合成 hover 后推送，TODO-364）');
  });

  test('移动端点画面 toggle 交给 media_kit onTap（不再 Hibiki 镜像旁路，TODO-364）', () {
    final int handler = src.indexOf('void _handleVideoPointerUp(');
    expect(handler, greaterThanOrEqualTo(0));
    final int handlerEnd =
        src.indexOf('\n  bool _isVideoChromePointer(', handler);
    final String body = src.substring(handler, handlerEnd);
    expect(body, isNot(contains('_toggleControlsVisibleForTap()')),
        reason:
            '移动端点画面不应再走 Hibiki 镜像 toggle（由 media_kit onTap 决定并推送，TODO-364）');
  });

  test('锁定 / 沉浸 / 侧栏 / 字幕列表门控下派生强制不可见（字幕不避让）', () {
    final int fn = src.indexOf('void _applyControlsVisibilityFromMediaKit()');
    expect(fn, greaterThanOrEqualTo(0), reason: '应有唯一派生函数');
    final int fnEnd = src.indexOf('\n  }', fn);
    final String body = src.substring(fn, fnEnd);
    for (final String gate in <String>[
      '_immersiveLocked.value',
      '_videoSidePanel.value != null',
      '_subtitleListVisible.value',
    ]) {
      expect(body, contains(gate), reason: '派生的门控必须含 $gate（门控成立时强制不可见、字幕不避让）');
    }
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
