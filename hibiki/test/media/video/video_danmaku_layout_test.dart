import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_danmaku_layout.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';

VideoDanmakuItem _item(int startMs, String text) => VideoDanmakuItem(
      startMs: startMs,
      text: text,
      mode: VideoDanmakuMode.scroll,
      colorArgb: 0xFFFFFFFF,
    );

VideoDanmakuItem _itemMode(int startMs, String text, VideoDanmakuMode mode) =>
    VideoDanmakuItem(
      startMs: startMs,
      text: text,
      mode: mode,
      colorArgb: 0xFFFFFFFF,
    );

/// 参考实现：BUG-900 优化前的原始「每帧 O(N) 全量扫描」筛活动集逻辑，逐条复刻，
/// 用作二分优化后的等价性基准（identity 集合必须逐条一致）。
List<VideoDanmakuItem> _referenceActive(
  List<VideoDanmakuItem> items,
  int positionMs, {
  required int scrollMs,
  required int fixedMs,
}) {
  final List<VideoDanmakuItem> result = <VideoDanmakuItem>[];
  for (final VideoDanmakuItem item in items) {
    final int elapsed = positionMs - item.startMs;
    final int durationMs =
        item.mode == VideoDanmakuMode.scroll ? scrollMs : fixedMs;
    if (elapsed < 0 || elapsed > durationMs) continue;
    result.add(item);
  }
  return result;
}

/// 把弹幕列表映射成可排序比较的稳定键（identity 判等，与遍历顺序无关）。
List<String> _keys(Iterable<VideoDanmakuItem> items) {
  final List<String> keys = items
      .map((VideoDanmakuItem e) => '${e.startMs}|${e.mode.name}|${e.text}')
      .toList();
  keys.sort();
  return keys;
}

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

    // BUG-900 缺陷 A：二分定位活动窗口，与原全量筛选逐条等价。
    // 默认时长：scroll 8000ms / fixed 4000ms（maxDuration=8000）。
    const int scrollMs = 8000;
    const int fixedMs = 4000;

    // 用超大 maxActive/maxLanes 关掉截断与丢帧，让每个活动弹幕都落一个 entry，
    // 于是 entries 的 identity 集合 == 内部活动集，可直接与参考实现对比。
    List<VideoDanmakuItem> layoutActive(
      List<VideoDanmakuItem> items,
      int positionMs,
    ) =>
        VideoDanmakuLayout.layout(
          items: items,
          positionMs: positionMs,
          viewportSize: const Size(800, 400),
          maxActive: kMaxVideoDanmakuActive,
          maxLanes: 200,
        ).entries.map((VideoDanmakuLayoutEntry e) => e.item).toList();

    test('binary-search active set equals full-scan reference across sweep',
        () {
      // 升序、混合模式（scroll/top/bottom 时长不同，验证下界仍逐条精确判定）。
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        _itemMode(0, 's0', VideoDanmakuMode.scroll),
        _itemMode(1000, 't1', VideoDanmakuMode.top),
        _itemMode(1000, 'b1', VideoDanmakuMode.bottom),
        _itemMode(3000, 's3', VideoDanmakuMode.scroll),
        _itemMode(5000, 't5', VideoDanmakuMode.top),
        _itemMode(5000, 's5', VideoDanmakuMode.scroll),
        _itemMode(9000, 's9', VideoDanmakuMode.scroll),
        _itemMode(12000, 'b12', VideoDanmakuMode.bottom),
        _itemMode(12000, 's12', VideoDanmakuMode.scroll),
        _itemMode(20000, 's20', VideoDanmakuMode.scroll),
      ];
      for (int positionMs = -500; positionMs <= 30000; positionMs += 250) {
        final List<VideoDanmakuItem> reference = _referenceActive(
          items,
          positionMs,
          scrollMs: scrollMs,
          fixedMs: fixedMs,
        );
        expect(
          _keys(layoutActive(items, positionMs)),
          _keys(reference),
          reason: '二分活动集在 positionMs=$positionMs 处与全量扫描不一致',
        );
      }
    });

    test('binary-search equivalence holds on edge inputs', () {
      // 空列表。
      expect(layoutActive(const <VideoDanmakuItem>[], 1000), isEmpty);
      // 单条：窗口内 / 窗口外（过早、过晚）。
      final List<VideoDanmakuItem> one = <VideoDanmakuItem>[
        _item(5000, 'solo')
      ];
      for (final int positionMs in <int>[0, 4999, 5000, 9000, 13000, 13001]) {
        expect(
          _keys(layoutActive(one, positionMs)),
          _keys(_referenceActive(one, positionMs,
              scrollMs: scrollMs, fixedMs: fixedMs)),
          reason: '单条 positionMs=$positionMs',
        );
      }
      // 全部落在窗口内 vs 全部在窗口外。
      final List<VideoDanmakuItem> cluster = <VideoDanmakuItem>[
        _item(1000, 'a'),
        _item(1200, 'b'),
        _item(1400, 'c'),
      ];
      expect(layoutActive(cluster, 1500), hasLength(3), reason: '全在窗口内');
      expect(layoutActive(cluster, 50000), isEmpty, reason: '全部过期');
      expect(layoutActive(cluster, -1), isEmpty, reason: '全部尚未出现');
    });
  });

  group('VideoDanmakuSource (BUG-900 缺陷 B)', () {
    test('parseBilibiliDanmakuXml maps p-attr and mode correctly', () {
      const String xml = '<i>'
          '<d p="1.5,1,25,16777215,0,0,0,0">hello</d>'
          '<d p="3,5,25,16711680,0,0,0,0">pinned top</d>'
          '<d p="2,4,25,255,0,0,0,0">pinned bottom</d>'
          '</i>';
      final List<VideoDanmakuItem> items = parseBilibiliDanmakuXml(xml);
      expect(items, hasLength(3));
      // 解析后按 startMs 升序（二分优化的前置契约）。
      expect(
        items.map((VideoDanmakuItem e) => e.startMs).toList(),
        <int>[1500, 2000, 3000],
      );
      final VideoDanmakuItem scroll =
          items.firstWhere((VideoDanmakuItem e) => e.text == 'hello');
      expect(scroll.mode, VideoDanmakuMode.scroll);
      final VideoDanmakuItem top =
          items.firstWhere((VideoDanmakuItem e) => e.text == 'pinned top');
      expect(top.mode, VideoDanmakuMode.top);
      final VideoDanmakuItem bottom =
          items.firstWhere((VideoDanmakuItem e) => e.text == 'pinned bottom');
      expect(bottom.mode, VideoDanmakuMode.bottom);
    });

    test('parseDandanplayDanmakuJson maps comments correctly', () {
      const String json = '{"comments":['
          '{"p":"2.5,1,16777215","m":"first"},'
          '{"p":"1.0,1,16777215","m":"second"}'
          ']}';
      final List<VideoDanmakuItem> items = parseDandanplayDanmakuJson(json);
      expect(items, hasLength(2));
      // 升序排序：second(1000) 在前，first(2500) 在后。
      expect(
        items.map((VideoDanmakuItem e) => e.startMs).toList(),
        <int>[1000, 2500],
      );
      expect(items.first.text, 'second');
      expect(items.first.mode, VideoDanmakuMode.scroll);
    });

    test('loadDanmakuSidecarFile parses off the main isolate via compute', () {
      // 20MB sidecar 的解析（XmlDocument.parse/jsonDecode + 遍历 + sort）搬进后台
      // isolate 无法在 headless widget 测试直接驱动/断言帧时；用源码守卫钉住
      // loadDanmakuSidecarFile 走 compute 路径，防有人回退到主 isolate 同步解析。
      final File source = File('lib/src/media/video/video_danmaku_source.dart');
      expect(source.existsSync(), isTrue, reason: '源文件应存在: ${source.path}');
      final String src = source.readAsStringSync();
      expect(
        src.contains('await compute('),
        isTrue,
        reason: 'loadDanmakuSidecarFile 必须用 compute 把解析搬到后台 isolate',
      );
      expect(
        src.contains('_parseDanmakuContent'),
        isTrue,
        reason: 'compute 入口应为顶层纯函数 _parseDanmakuContent',
      );
      // 确认 loadDanmakuSidecarFile 内不再直接同步分派解析（旧路径 `items = ext ==`）。
      expect(
        src.contains('items = ext =='),
        isFalse,
        reason: '不得在主 isolate 同步分派 parseDandanplay/parseBilibili',
      );
    });
  });
}
