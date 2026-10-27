// KKxMNpG99t：进度条 hover 缩略图被字幕盖住。
//
// 视频控件 Stack（`video_fushi/layout.part.dart`）里子节点的先后就是绘制层级：缩略图层
// 原先挂在弹幕 / 文本字幕 / 图形字幕各层**之前**，控制条可见时字幕又恰好被抬到进度条
// 上方，于是字幕压在缩略图上。整页 widget 在 headless 下拉不起来（libmpv / 平台通道），
// 层序只能在源码里钉：缩略图层必须排在所有字幕类层之后。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('缩略图预览层排在弹幕 / 文本字幕 / 图形字幕各层之后', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/layout.part.dart',
    ).readAsStringSync();
    final int thumb = src.indexOf('_buildThumbnailPreviewOverlay(controller)');
    expect(thumb, greaterThan(0), reason: '缩略图层必须挂在视频控件 Stack 上');
    expect(
      '_buildThumbnailPreviewOverlay(controller)'.allMatches(src).length,
      1,
      reason: '缩略图层只挂一处',
    );
    for (final String layer in <String>[
      'VideoDanmakuOverlay(',
      'VideoSubtitleOverlay(',
      'VideoGraphicSubtitleObscureLayer(',
      '_buildGraphicSubtitleOcrOverlay(controller)',
      '_buildGraphicSubtitleOcrProgressOverlay()',
    ]) {
      final int at = src.indexOf(layer);
      expect(at, greaterThan(0), reason: '找不到 $layer，层名改了就同步本守卫');
      expect(
        thumb,
        greaterThan(at),
        reason: '缩略图层必须画在 $layer 之上（Stack 里排在它之后）',
      );
    }
  });
}
