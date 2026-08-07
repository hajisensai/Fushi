// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

import '../helpers/source_guard.dart';
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
      // TODO-2527: 两份语料都先掩码——`downSPos` / `_wheelBoundaryArmed` 这类符号
      // 本来就原样写在生产注释里（webview.part.dart 的 TODO-656 说明段就有），裸
      // contains 会被注释满足：把实现删光只留注释，旧写法照样全绿。
      paginationScripts = maskCommentsAndScriptLines(
        File('lib/src/reader/reader_pagination_scripts.dart')
            .readAsStringSync()
            .replaceAll('\r\n', '\n'),
      );
      corpus = maskCommentsAndScriptLines(readReaderPageSource());
    });

    test('_bStart 记手势起点滚动量 downSPos/downSMax', () {
      expect(containsCodeLine(paginationScripts, 'downSPos'), isTrue,
          reason: 'touchstart 必须记手势起点沿内容轴的滚动量');
      expect(containsCodeLine(paginationScripts, 'downSMax'), isTrue,
          reason: 'touchstart 必须记最大可滚量供边界判定');
    });
    test('_bEnd 用手势起点在边界判据，不再用 touchend 瞬时 atTop', () {
      expect(containsCodeLine(paginationScripts, 'downAtStart'), isTrue,
          reason: '跨章必须看手势起点是否在章首（downSPos<=2）');
      expect(containsCodeLine(paginationScripts, 'downAtEnd'), isTrue,
          reason: '跨章必须看手势起点是否在章末');
      expect(
          containsCodeLine(
              paginationScripts, 'var atTop = root.scrollTop <= 2'),
          isFalse,
          reason: '_bEnd 不得再用 touchend 瞬时 scrollTop<=2 判跨章（提前跨章根因）');
    });
    test('滚轮跨章用真试滚（scrollBy + moved），不再用 stuck 推算/瞬时几何', () {
      final String wheel = _wheelBlock(corpus);
      // 锚点自检：窗口必须落在**正文引擎**那份 wheel 监听上。spread 独立文档那份
      // 逐字同签名、在语料里更靠前（见 _wheelBlock 注释），锚错时下面的 needle 会
      // 集体落空 —— 但那时报的是「实现没了」，会把人引向生产代码。这条先红，直接
      // 说清是守卫自己锚歪了。
      expect(wheel.contains('fushiContinuousMode'), isTrue,
          reason: '窗口锚到了没有连续/分页门控的那份 wheel 监听（spread 独立文档），'
              '守卫在守错对象');
      expect(wheel.contains('onSpreadTapEmpty'), isFalse,
          reason: '窗口吃进了 spread 独立文档的脚本段，右边界塌了');
      expect(
          containsCodeLine(wheel, 'var moved = Math.abs(after - before) > 1'),
          isTrue,
          reason: '滚轮跨章须靠真试滚的实际位移判边界');
      expect(containsCodeLine(wheel, 'window.scrollBy'), isTrue,
          reason: '横排/竖排都真的 window.scrollBy 一步再读位移（已验证原语）');
      expect(containsCodeLine(wheel, 'atStart = root.scrollTop <= 2'), isFalse,
          reason: '不得再用瞬时 scrollTop<=2 几何');
      expect(containsCodeLine(wheel, '_wheelLastScrollPos'), isFalse,
          reason: '不得再用相邻拍位置推算（时序坏 → 横排中部误翻）');
      // arm-then-fire 二次确认仍在。
      expect(containsCodeLine(wheel, '_wheelBoundaryArmed'), isTrue,
          reason: '保留 arm-then-fire 二次确认吸收单帧擦边');
    });
  });
}

/// 正文引擎那份 wheel 监听的**回调体**窗口。
///
/// 两件事必须分开定，合在一起就出错：
/// - **起点**：BUG-1426 之后语料里有两份 wheel 监听，签名逐字相同
///   （`'wheel', function(e)`）。spread 独立文档自带那份在主壳
///   `reader_hibiki_page.dart:566`，正文引擎那份在
///   `reader_hibiki/webview.part.dart:1408`，而语料是「主壳在前」⇒ 按签名文本
///   `indexOf`（含 `methodBody` 的内建定位）必然锚到 spread 那份，守错对象。所以起点
///   走语义判据 [bodyEngineWheelListenerStart]（按块内 `fushiContinuousMode` 认）。
/// - **右边界**：旧写法 `indexOf('}, {passive:')` 一旦监听器漏写 passive 选项就一路
///   吞到下一个监听器，所以改成 [balancedBlockFrom] 的花括号配对。
String _wheelBlock(String source) {
  final int start = bodyEngineWheelListenerStart(source);
  expect(start, isNonNegative, reason: 'missing body-engine wheel listener');
  return balancedBlockFrom(source, start,
      lexicon: SourceLexicon.js, what: '正文引擎 wheel 监听回调体');
}
