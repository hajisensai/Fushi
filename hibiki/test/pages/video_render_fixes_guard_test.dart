import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// 视频渲染三修复的源码守卫（media_kit 驱动的 VideoHibikiPage 无法 headless 行为测试，
/// 故锁定关键配线）：
///  1. 「视频没画面」——所有打开视频页的入口都经 [VideoHibikiPage.neutralized] 在路由层
///     用 HibikiAppUiScaleNeutralizer 中和全局缩放，使 media_kit Texture 按原生密度渲染。
///  2. 「退视频红屏」——根 Overlay 浮层 builder 用自身 overlayContext + !mounted 守卫，
///     销毁期先摘 entry 再清栈，杜绝用失效 State context 重建浮层抛异常。
void main() {
  const String videoPage =
      'lib/src/pages/implementations/video_hibiki_page.dart';

  test('视频页打开入口统一经 neutralized 中和缩放（视频没画面）', () {
    final String src = File(videoPage).readAsStringSync();
    // 工厂存在，且确实用 HibikiAppUiScaleNeutralizer 包裹整页。
    expect(src, contains('static Widget neutralized('));
    expect(
      src,
      contains('HibikiAppUiScaleNeutralizer(\n        child: VideoHibikiPage('),
      reason: 'neutralized() 必须在路由层用中和器包裹整页',
    );

    // 三个 push 点都走 .neutralized，没有任何一处裸用 VideoHibikiPage( 构造（避免漏包）。
    const List<String> pushSites = <String>[
      'lib/main.dart',
      'lib/src/pages/implementations/home_video_page.dart',
    ];
    for (final String path in pushSites) {
      final String s = File(path).readAsStringSync();
      expect(s, contains('VideoHibikiPage.neutralized('),
          reason: '$path 必须经 VideoHibikiPage.neutralized 打开视频页');
      expect(s, isNot(contains('VideoHibikiPage(')),
          reason: '$path 不得裸用 VideoHibikiPage( 构造（会漏掉缩放中和→无画面）');
    }
    // reader_hibiki_history_page 拆成主壳 + reader_history/*.part.dart：视频打开入口
    // (_openVideoBook 的 VideoHibikiPage.neutralized) 现落在 video.part.dart，故读合并语料。
    final String shelfCorpus = readReaderHistorySource();
    expect(shelfCorpus, contains('VideoHibikiPage.neutralized('),
        reason: '书架视频入口必须经 VideoHibikiPage.neutralized 打开');
    expect(shelfCorpus, isNot(contains('VideoHibikiPage(')),
        reason: '书架不得裸用 VideoHibikiPage( 构造');
  });

  test('根 Overlay 浮层 builder 用自身 context + mounted 守卫（退视频红屏）', () {
    final String src = File(videoPage).readAsStringSync();

    // builder 顶部有 mounted 守卫：State 失效就不渲染浮层。
    expect(
      src,
      contains('Widget _buildPopupOverlay(BuildContext overlayContext) {\n'),
    );
    // BUG-121 强化：仅 !mounted 不够——deactivate（未 unmount）期 mounted 仍为 true，
    // 但同帧 layout 阶段 LayoutBuilder 重建仍会做失效祖先查找。守卫并入 _overlayInert。
    expect(
        src,
        contains(
            'if (!mounted || _overlayInert) return const SizedBox.shrink();'),
        reason: 'State 失效/销毁期根 Overlay 重建浮层不得触碰失效 context/appModel');
    // Theme 读 entry 自身的 overlayContext，而非更短命的 State context。
    expect(src, contains('Theme.of(overlayContext)'));

    // dispose：先摘/释放根 Overlay entry，再 clear 栈（entry 摘掉就不会被重建）。
    final int entryRemoveIdx = src.indexOf('_popupOverlayEntry = null;');
    final int clearIdx = src.indexOf('_popup.clear();');
    expect(entryRemoveIdx, greaterThanOrEqualTo(0));
    expect(clearIdx, greaterThan(entryRemoveIdx),
        reason: 'dispose 必须先摘除根 Overlay entry，再 clear 浮层栈');
  });
}
