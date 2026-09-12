import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/rasterized_frame_size_reporter.dart';

/// BUG-2462：光栅化尺寸上报器的纯逻辑——帧号 ↔ build 尺寸对齐、只在变化时上报、
/// 无 build 记录的帧号（纹理帧重绘）不产生噪音。runner 的子窗 resize 闸门靠这条
/// 上报确认 surface 尺寸，错报 / 漏报都会把闸门带偏。
void main() {
  const Size a = Size(2560, 1440);
  const Size b = Size(2549, 1434);

  test('首帧上报一次，之后只在光栅化尺寸变化时上报', () {
    final RasterizedFrameSizeTracker tracker = RasterizedFrameSizeTracker();
    tracker.recordBuilt(1, a);
    tracker.recordBuilt(2, a);
    tracker.recordBuilt(3, b);
    tracker.recordBuilt(4, b);
    tracker.recordBuilt(5, a);
    expect(tracker.onFramesRasterized(<int>[1, 2]), <Size>[a]);
    expect(tracker.onFramesRasterized(<int>[3, 4, 5]), <Size>[b, a]);
    expect(tracker.trackedFrameCount, 0, reason: '已上报的帧记录被消费');
  });

  test('没有 build 记录的帧号（纹理帧 DrawLastLayerTrees）被跳过', () {
    final RasterizedFrameSizeTracker tracker = RasterizedFrameSizeTracker();
    tracker.recordBuilt(7, a);
    expect(tracker.onFramesRasterized(<int>[5, 6]), isEmpty);
    expect(tracker.onFramesRasterized(<int>[7, 8]), <Size>[a]);
  });

  test('一批里同尺寸重复只报一次；跨批同尺寸不重复', () {
    final RasterizedFrameSizeTracker tracker = RasterizedFrameSizeTracker();
    for (int i = 1; i <= 6; i++) {
      tracker.recordBuilt(i, i == 4 ? b : a);
    }
    expect(tracker.onFramesRasterized(<int>[1, 2, 3]), <Size>[a]);
    expect(tracker.onFramesRasterized(<int>[4, 5, 6]), <Size>[b, a]);
    tracker.recordBuilt(7, a);
    expect(tracker.onFramesRasterized(<int>[7]), isEmpty);
  });

  test('积压超过上限时淘汰最旧的 build 记录', () {
    final RasterizedFrameSizeTracker tracker = RasterizedFrameSizeTracker(
      maxTrackedFrames: 3,
    );
    tracker.recordBuilt(1, a);
    tracker.recordBuilt(2, a);
    tracker.recordBuilt(3, a);
    tracker.recordBuilt(4, b);
    expect(tracker.trackedFrameCount, 3);
    expect(tracker.onFramesRasterized(<int>[1]), isEmpty, reason: '帧 1 已被淘汰');
    expect(tracker.onFramesRasterized(<int>[2, 3, 4]), <Size>[a, b]);
  });
}
