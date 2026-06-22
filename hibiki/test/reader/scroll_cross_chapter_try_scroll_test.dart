import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-656「试滚范式」根治：跨章不再用瞬时坐标阈值 `scrollTop<=2`，而是「内容真的
/// 滚不动」才到边界。触摸看手势起点是否已在边界，滚轮看相邻拍位置是否无变化 / 竖排
/// 缓动 target 是否被 clamp 卡死。本测试锁纯函数判据 + JS 接线（防回退到瞬时几何）。
void main() {
  group('touchBoundaryCrossDir：手势起点在边界才跨章', () {
    test('从章中向上滑到顶：起点不在边界 → 不跨章（消除提前跨章）', () {
      expect(
        ReaderPaginationScripts.touchBoundaryCrossDir(
            gestureDir: 'backward', downScrollPos: 400, scrollMax: 2000),
        isNull,
      );
    });
    test('已在章首再向上滑：起点在边界 → 跨上一章', () {
      expect(
        ReaderPaginationScripts.touchBoundaryCrossDir(
            gestureDir: 'backward', downScrollPos: 1, scrollMax: 2000),
        'backward',
      );
    });
    test('已在章末再向前滑：起点在边界 → 跨下一章', () {
      expect(
        ReaderPaginationScripts.touchBoundaryCrossDir(
            gestureDir: 'forward', downScrollPos: 1999, scrollMax: 2000),
        'forward',
      );
    });
    test('在章末向后滑回看：方向与边界不匹配 → 不跨章', () {
      expect(
        ReaderPaginationScripts.touchBoundaryCrossDir(
            gestureDir: 'backward', downScrollPos: 1999, scrollMax: 2000),
        isNull,
      );
    });
    test('在章首向前滑：方向与边界不匹配 → 不跨章', () {
      expect(
        ReaderPaginationScripts.touchBoundaryCrossDir(
            gestureDir: 'forward', downScrollPos: 1, scrollMax: 2000),
        isNull,
      );
    });
  });

  group('wheelBoundaryStuckDir：内容真滚不动才算到边界', () {
    test('位置仍在变（还能滚）→ null', () {
      expect(
        ReaderPaginationScripts.wheelBoundaryStuckDir(
            wheelDir: 'backward', scrollFrom: 80, scrollTo: 40),
        isNull,
      );
    });
    test('横排相邻拍位置无变化（原生卡边界）→ 返回越界方向', () {
      expect(
        ReaderPaginationScripts.wheelBoundaryStuckDir(
            wheelDir: 'backward', scrollFrom: 0, scrollTo: 0),
        'backward',
      );
    });
    test('竖排 clamp 卡死（target==base）→ 返回越界方向', () {
      expect(
        ReaderPaginationScripts.wheelBoundaryStuckDir(
            wheelDir: 'forward', scrollFrom: -1200, scrollTo: -1200),
        'forward',
      );
    });
    test('无滚轮方向 → null', () {
      expect(
        ReaderPaginationScripts.wheelBoundaryStuckDir(
            wheelDir: null, scrollFrom: 0, scrollTo: 0),
        isNull,
      );
    });
  });

  group('滚轮 stuck + arm-then-fire 组合：卡边界二次确认才跨章', () {
    test('卡边界首次只武装、同向二次才跨章', () {
      final String? d1 = ReaderPaginationScripts.wheelBoundaryStuckDir(
          wheelDir: 'backward', scrollFrom: 0, scrollTo: 0);
      final arm1 = ReaderPaginationScripts.continuousWheelBoundaryEmit(
          boundaryDir: d1, armedDir: null);
      expect(arm1.emit, isFalse);
      expect(arm1.nextArmedDir, 'backward');
      final String? d2 = ReaderPaginationScripts.wheelBoundaryStuckDir(
          wheelDir: 'backward', scrollFrom: 0, scrollTo: 0);
      final arm2 = ReaderPaginationScripts.continuousWheelBoundaryEmit(
          boundaryDir: d2, armedDir: arm1.nextArmedDir);
      expect(arm2.emit, isTrue);
    });
    test('武装后又能滚（位置变了）→ 解武装不跨章', () {
      final String? d = ReaderPaginationScripts.wheelBoundaryStuckDir(
          wheelDir: 'backward', scrollFrom: 0, scrollTo: 60);
      final arm = ReaderPaginationScripts.continuousWheelBoundaryEmit(
          boundaryDir: d, armedDir: 'backward');
      expect(arm.emit, isFalse);
      expect(arm.nextArmedDir, isNull);
    });
  });

  group('JS 接线守卫：触摸/滚轮跨章不再用瞬时几何', () {
    late String paginationScripts;
    late String corpus;
    setUpAll(() {
      paginationScripts = File('lib/src/reader/reader_pagination_scripts.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      corpus = readReaderPageSource();
    });

    test('_bStart 记手势起点滚动量 downSPos/downSMax', () {
      expect(paginationScripts, contains('downSPos'),
          reason: 'touchstart 必须记手势起点沿内容轴的滚动量');
      expect(paginationScripts, contains('downSMax'),
          reason: 'touchstart 必须记最大可滚量供边界判定');
    });
    test('_bEnd 用手势起点在边界判据，不再用 touchend 瞬时 atTop', () {
      expect(paginationScripts, contains('downAtStart'),
          reason: '跨章必须看手势起点是否在章首（downSPos<=2）');
      expect(paginationScripts, contains('downAtEnd'),
          reason: '跨章必须看手势起点是否在章末');
      expect(
          paginationScripts, isNot(contains('var atTop = root.scrollTop <= 2')),
          reason: '_bEnd 不得再用 touchend 瞬时 scrollTop<=2 判跨章（提前跨章根因）');
    });
    test('滚轮跨章用真试滚（scrollBy + moved），不再用 stuck 推算/瞬时几何', () {
      final String wheel = _wheelBlock(corpus);
      expect(wheel, contains('var moved = Math.abs(after - before) > 1'),
          reason: '滚轮跨章须靠真试滚的实际位移判边界');
      expect(wheel, contains('root.scrollBy'),
          reason: '横排/竖排都真的 scrollBy 一步再读位移');
      expect(wheel, isNot(contains('atStart = root.scrollTop <= 2')),
          reason: '不得再用瞬时 scrollTop<=2 几何');
      expect(wheel, isNot(contains('_wheelLastScrollPos')),
          reason: '不得再用相邻拍位置推算（时序坏 → 横排中部误翻）');
      // arm-then-fire 二次确认仍在。
      expect(wheel, contains('_wheelBoundaryArmed'),
          reason: '保留 arm-then-fire 二次确认吸收单帧擦边');
    });
  });
}

String _wheelBlock(String source) {
  final int start = source.indexOf("addEventListener('wheel'");
  expect(start, isNonNegative, reason: 'missing wheel listener');
  final int end = source.indexOf('}, {passive:', start);
  expect(end, isNonNegative);
  return source.substring(start, end);
}
