import 'dart:io';

import 'package:test/test.dart';

/// BUG-4124：iOS 灵动岛 / 主屏小组件的封面与布局不变式。
///
/// 三处都是 SwiftUI 层「编得过、模拟器 / analyze 看不出、真机才露馅」的错：
/// 1. Live Activity 的图片不能大于所在呈现区域，原图塞进灵动岛紧凑位只会画成一块灰
///    占位 → 封面解码必须按显示尺寸降采样（`FushiPlatformImage.load(_, maxPoint:)`）。
/// 2. `.aspectRatio(contentMode: .fill)` 的图会按原图比例撑出父框，直接 clipShape 裁的是
///    撑大后的自身 → 大号「继续」封面溢出盖满整块组件。必须先 `Color.clear` 吃下父框
///    再 overlay 铺图。
/// 3. 灵动岛展开态总高约 160pt，底部区域必须用紧凑版原文 / 控件，否则控件行被截掉。
void main() {
  const String dir = 'apple/HomeWidgets/Extension';
  final String timeline = File(
    '$dir/FushiWidgetTimeline.swift',
  ).readAsStringSync();
  final String live = File('$dir/FushiLiveActivities.swift').readAsStringSync();
  final String views = File(
    '$dir/FushiHomeWidgetViews.swift',
  ).readAsStringSync();

  test('cover decoding is always downsampled to the display size', () {
    expect(
      timeline,
      contains('static func load(_ path: String?, maxPoint: CGFloat)'),
    );
    expect(timeline, contains('kCGImageSourceThumbnailMaxPixelSize'));
    // 没有不带尺寸的整图解码入口。
    expect(timeline, isNot(contains('UIImage(contentsOfFile:')));
    expect(timeline, isNot(contains('NSImage(contentsOf:')));
    expect(live, contains('FushiPlatformImage.load(path, maxPoint: size)'));
  });

  test('fill-mode covers are bounded by Color.clear before clipping', () {
    for (final String source in <String>[timeline, live]) {
      final int fill = source.indexOf('.aspectRatio(contentMode: .fill)');
      expect(fill, isNonNegative);
      final int clear = source.lastIndexOf('Color.clear.overlay', fill);
      expect(
        clear,
        isNonNegative,
        reason: 'fill image must sit inside Color.clear.overlay',
      );
    }
  });

  test('expanded Dynamic Island bottom region uses the compact variants', () {
    final int bottom = live.indexOf('DynamicIslandExpandedRegion(.bottom)');
    final int end = live.indexOf('compactLeading:', bottom);
    final String region = live.substring(bottom, end);
    expect(region, contains('compact: true'));
    expect(
      region,
      contains('FushiPlaybackControls(context: context, compact: true)'),
    );
  });

  test('large Continue widget lays out per media orientation', () {
    expect(views, contains('isLandscape(main)'));
    expect(views, contains('ViewThatFits(in: .vertical)'));
  });
}
