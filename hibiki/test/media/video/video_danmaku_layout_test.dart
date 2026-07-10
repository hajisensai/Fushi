import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_danmaku_layout.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';

VideoDanmakuItem _item(int startMs, String text) => VideoDanmakuItem(
      startMs: startMs,
      text: text,
      mode: VideoDanmakuMode.scroll,
      colorArgb: 0xFFFFFFFF,
    );

void main() {
  group('VideoDanmakuLayout', () {
    test('does not place simultaneous active comments on the same lane', () {
      final VideoDanmakuLayoutSnapshot snapshot = VideoDanmakuLayout.layout(
        items: <VideoDanmakuItem>[
          _item(0, 'a'),
          _item(100, 'b'),
          _item(200, 'c'),
        ],
        positionMs: 1000,
        viewportSize: const Size(400, 160),
        maxActive: 10,
        maxLanes: 4,
      );

      expect(snapshot.entries, hasLength(3));
      expect(
        snapshot.entries.map((VideoDanmakuLayoutEntry entry) => entry.lane),
        hasLength(3),
      );
      expect(
        snapshot.entries
            .map((VideoDanmakuLayoutEntry entry) => entry.lane)
            .toSet(),
        hasLength(3),
        reason: '同一时间活跃的滚动弹幕不能共享 lane，否则会重叠',
      );
    });

    test('caps active comments before rendering to protect frame time', () {
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        for (int i = 0; i < 50; i++) _item(i * 10, 'c$i'),
      ];

      final VideoDanmakuLayoutSnapshot snapshot = VideoDanmakuLayout.layout(
        items: items,
        positionMs: 1000,
        viewportSize: const Size(500, 240),
        maxActive: 5,
        maxLanes: 12,
      );

      expect(snapshot.entries, hasLength(5));
      expect(snapshot.droppedForDensity, greaterThan(0));
    });

    test('rebuilds from playback position after seek without stale entries',
        () {
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        _item(0, 'opening'),
        _item(10000, 'after seek'),
      ];

      final VideoDanmakuLayoutSnapshot beforeSeek = VideoDanmakuLayout.layout(
        items: items,
        positionMs: 1000,
        viewportSize: const Size(400, 160),
        maxActive: 10,
        maxLanes: 4,
      );
      expect(
        beforeSeek.entries.map((VideoDanmakuLayoutEntry e) => e.item.text),
        <String>['opening'],
      );

      final VideoDanmakuLayoutSnapshot afterSeek = VideoDanmakuLayout.layout(
        items: items,
        positionMs: 10500,
        viewportSize: const Size(400, 160),
        maxActive: 10,
        maxLanes: 4,
      );
      expect(
        afterSeek.entries.map((VideoDanmakuLayoutEntry e) => e.item.text),
        <String>['after seek'],
      );
    });

    test('areaFraction shrinks the vertical band danmaku occupy', () {
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        for (int i = 0; i < 4; i++) _item(i, 'c$i'),
      ];
      double maxYFor(double frac) => VideoDanmakuLayout.layout(
            items: items,
            positionMs: 100,
            viewportSize: const Size(400, 200),
            maxActive: 10,
            maxLanes: 4,
            areaFraction: frac,
          )
              .entries
              .map((VideoDanmakuLayoutEntry e) => e.position.dy)
              .reduce((double a, double b) => a > b ? a : b);
      final double full = maxYFor(1.0);
      final double half = maxYFor(0.5);
      expect(half, lessThan(full), reason: '缩小显示区域把弹幕挤进更小的顶部带（最低一行的 y 更小）');
    });

    test('fontScale widens scrolling danmaku so mid-flight x shifts left', () {
      final VideoDanmakuItem scroll = _item(0, 'wide wide wide');
      double xFor(double fontScale) => VideoDanmakuLayout.layout(
            items: <VideoDanmakuItem>[scroll],
            positionMs: 2000,
            viewportSize: const Size(400, 200),
            maxActive: 10,
            maxLanes: 4,
            fontScale: fontScale,
          ).entries.single.position.dx;
      expect(xFor(2.0), lessThan(xFor(1.0)), reason: '大字号弹幕更宽，飞行途中 x 更靠左');
    });
  });
}
