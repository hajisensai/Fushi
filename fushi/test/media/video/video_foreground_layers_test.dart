import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_foreground_layers.dart';

/// BUG-1862：视频页「返回上一级」的逐级退出层序。
///
/// 这条顺序此前被抄成两份（Escape 快捷键回调一份、[PopScope] 退出汇聚点一份，而且
/// 后者只认词典浮层），漂出来的后果就是「设置侧栏开着按 Esc，视频页退了、侧栏还在」。
/// 收成纯函数后在这里直接断言规则本身。
void main() {
  /// 一次「按下返回上一级」：读当前状态、拿到该关的层。
  VideoForegroundLayer? top(Set<VideoForegroundLayer> open) =>
      topVideoForegroundLayer(
        hasVisibleDictionaryPopup:
            open.contains(VideoForegroundLayer.dictionaryPopup),
        controlEditActive: open.contains(VideoForegroundLayer.controlEdit),
        subtitleListVisible: open.contains(VideoForegroundLayer.subtitleList),
        episodeListVisible: open.contains(VideoForegroundLayer.episodeList),
        sidePanelOpen: open.contains(VideoForegroundLayer.sidePanel),
        immersiveLocked: open.contains(VideoForegroundLayer.immersiveLock),
      );

  test('没有任何前台层时返回 null（调用方这才可以退全屏 / 退出视频页）', () {
    expect(top(<VideoForegroundLayer>{}), isNull);
  });

  test('单独打开任意一层，按返回就关掉那一层', () {
    for (final VideoForegroundLayer layer in VideoForegroundLayer.values) {
      expect(
        top(<VideoForegroundLayer>{layer}),
        layer,
        reason: '只开着 $layer 时应该关它，而不是退页',
      );
    }
  });

  test('设置侧栏开着时返回的是侧栏，绝不越过它去退页（BUG-1862 原始症状）', () {
    expect(
      top(<VideoForegroundLayer>{VideoForegroundLayer.sidePanel}),
      VideoForegroundLayer.sidePanel,
    );
    // 侧栏 + 沉浸锁同时开：先关更前台的侧栏。
    expect(
      top(<VideoForegroundLayer>{
        VideoForegroundLayer.sidePanel,
        VideoForegroundLayer.immersiveLock,
      }),
      VideoForegroundLayer.sidePanel,
    );
  });

  test('词典浮层永远最前台，压过其它任何一层', () {
    for (final VideoForegroundLayer other in VideoForegroundLayer.values) {
      expect(
        top(<VideoForegroundLayer>{
          VideoForegroundLayer.dictionaryPopup,
          other,
        }),
        VideoForegroundLayer.dictionaryPopup,
      );
    }
  });

  test('六层全开时反复按返回：按视觉层序一层层剥到底，不重复也不跳过', () {
    final Set<VideoForegroundLayer> open = VideoForegroundLayer.values.toSet();
    final List<VideoForegroundLayer> dismissed = <VideoForegroundLayer>[];
    for (int i = 0; i < VideoForegroundLayer.values.length; i++) {
      final VideoForegroundLayer? layer = top(open);
      expect(layer, isNotNull, reason: '还有 ${open.length} 层开着就不该放行退出');
      dismissed.add(layer!);
      open.remove(layer);
    }
    expect(dismissed, VideoForegroundLayer.values);
    // 全部关完才轮到退全屏 / 退页。
    expect(top(open), isNull);
  });

  test('层序表本身：更靠前的枚举值就是更前台的层', () {
    // 两两比对：任意两层同时开着时，返回的必是枚举里更靠前的那个。
    const List<VideoForegroundLayer> values = VideoForegroundLayer.values;
    for (int i = 0; i < values.length; i++) {
      for (int j = i + 1; j < values.length; j++) {
        expect(
          top(<VideoForegroundLayer>{values[i], values[j]}),
          values[i],
          reason: '${values[i]} 应该比 ${values[j]} 更前台',
        );
      }
    }
  });
}
