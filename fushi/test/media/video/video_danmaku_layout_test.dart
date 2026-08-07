import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_danmaku_layout.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_source.dart';
import 'package:fushi/src/media/video/video_danmaku_text_metrics.dart';

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

/// 参考实现：BUG-907 优化前的原始「每帧 O(N) 全量扫描」筛活动集逻辑，逐条复刻，
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
  // layout 现在用 TextPainter 实测文本宽度，需要测试 binding 提供字体集合。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoDanmakuLayout 退场几何（BUG-1297）', () {
    // 滚动弹幕的行程 = 视口宽 + 自身宽；progress 走到 1 的同一刻它离开活动集。
    // 因此「宽度」必须是真实渲染宽度，且滚动弹幕不得在画面内被淡出。
    const Size viewport = Size(400, 200);
    const int scrollMs = 8000;

    VideoDanmakuLayoutEntry entryAt(String text, int positionMs,
        {double fontScale = 1.0}) {
      return VideoDanmakuLayout.layout(
        items: <VideoDanmakuItem>[_item(0, text)],
        positionMs: positionMs,
        viewportSize: viewport,
        maxActive: 10,
        maxLanes: 4,
        fontScale: fontScale,
      ).entries.single;
    }

    test('scroll danmaku is fully off-screen on the last frame it renders', () {
      // 短、中、长三档：旧实现按「每字 18px 且封顶 720px」估宽，长弹幕在右半截
      // 仍可见时就被判过期，表现为走到一半突然消失。
      for (final String text in <String>[
        'あ',
        '短いコメント',
        'とても長いコメントです' * 6,
      ]) {
        final VideoDanmakuLayoutEntry entry = entryAt(text, scrollMs);
        // 右边缘用**独立测得**的宽度算，不用 entry.width——否则几何一旦退回估算，
        // 断言基准会跟着一起偏，守卫自洽成一句废话。
        final double renderedWidth =
            VideoDanmakuTextMetrics.shared.widthOf(text, 1.0);
        expect(
          entry.position.dx + renderedWidth,
          lessThanOrEqualTo(0.0),
          reason: '过期那一帧文本右边缘必须已越过视口左边界（len=${text.length}）',
        );
        expect(entry.width, renderedWidth, reason: 'entry.width 必须是实测渲染宽度');
      }
    });

    test('scroll danmaku still overlaps the viewport one frame before expiry',
        () {
      // 反向守卫：不能靠「提前很久就把弹幕推出屏外」蒙混过关——退场必须刚好衔接。
      final VideoDanmakuLayoutEntry entry = entryAt('短いコメント', scrollMs - 100);
      expect(
        entry.position.dx + entry.width,
        greaterThan(0.0),
        reason: '尚未过期时弹幕仍应与视口有交集，退场时刻要与过期时刻严丝合缝',
      );
    });

    test('scroll danmaku never fades out inside the viewport', () {
      for (int positionMs = 0; positionMs <= scrollMs; positionMs += 100) {
        expect(
          entryAt('短いコメント', positionMs).opacity,
          1.0,
          reason: '滚动弹幕靠位移退场，任何时刻都不得渐隐（positionMs=$positionMs）',
        );
      }
    });

    test('fixed danmaku keeps the tail fade-out', () {
      // 固定弹幕不移动，不淡出就是凭空消失——淡出只属于它们。
      double opacityAt(int positionMs, VideoDanmakuMode mode) =>
          VideoDanmakuLayout.layout(
            items: <VideoDanmakuItem>[_itemMode(0, 'ピン留め', mode)],
            positionMs: positionMs,
            viewportSize: viewport,
            maxActive: 10,
            maxLanes: 4,
          ).entries.single.opacity;
      for (final VideoDanmakuMode mode in <VideoDanmakuMode>[
        VideoDanmakuMode.top,
        VideoDanmakuMode.bottom,
      ]) {
        expect(opacityAt(2000, mode), 1.0, reason: '$mode 停留期间完全不透明');
        expect(opacityAt(3900, mode), lessThan(1.0), reason: '$mode 末段应渐隐');
        expect(opacityAt(4000, mode), 0.0, reason: '$mode 到期时已淡到全透明');
      }
    });

    test('measured width is not capped, and scales with font size', () {
      // 旧估算把宽度封在 720px：40 个全角字（测试字体每字 = 字号）已经超过它。
      final VideoDanmakuLayoutEntry long = entryAt('あ' * 40, 0);
      expect(long.width, greaterThan(720.0), reason: '长弹幕宽度不得被硬上限截断');
      final VideoDanmakuLayoutEntry small = entryAt('あ' * 10, 0);
      final VideoDanmakuLayoutEntry big = entryAt('あ' * 10, 0, fontScale: 2.0);
      expect(big.width, greaterThan(small.width), reason: '宽度随字号缩放');
    });
  });

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

    // BUG-907 缺陷 A：二分定位活动窗口，与原全量筛选逐条等价。
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

  group('VideoDanmakuSource (BUG-907 缺陷 B)', () {
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
