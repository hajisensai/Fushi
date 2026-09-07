import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/source_guard.dart';

/// 可见字符区间 `[start, end)` 的 shell 侧守卫（统计口径「翻走即计 + 覆盖并集」）。
///
/// Dart 侧每次进度采样要拿到当前可见区间两端：起点是既有的
/// `getFirstVisibleCharOffset`，终点是本批新增的 `getLastVisibleCharOffset`，经
/// `fushiProgressDetails()` 第四段回传。三种 shell 各有一份实现，口径都必须与起点同源
/// （章内学习单位偏移）。
///
/// 守的是结构不变式，不是数值：
///   · 三个 shell 都暴露 `getLastVisibleCharOffset`（漏一个，该模式的区间终点恒缺省 -1，
///     统计静默退化成只记起点）；
///   · 分页版**不得**用 `countCharsBeforeViewportPaged`（它比较的轴与分页滚动轴不一致：
///     竖排比 rect.left 而滚动轴是 y，算不出页尾）、**不得**临时 `setPagePosition` 探测再
///     滚回（触发 snap 监听 / scroll 回传递归 / 闪屏）；降级只能走
///     `calculateProgress(atScroll)` 的二分（节点粒度、单调）；
///   · `fushiProgressDetails` 返回四段，末段 = end，atEnd 时钳到 total。
/// 真渲染数值（start < end、逐页单调、并集覆盖全章）由本机 headless 探针
/// `tool/reader_pitch_headless/visible_range_probe.mjs` 断言（CI 跑不到真 WebView）。
void main() {
  late String paginated;
  late String continuous;
  late String vn;
  late String webview;

  setUpAll(() {
    paginated = ReaderPaginationScripts.paginatedShellSource();
    continuous = ReaderPaginationScripts.continuousShellSource();
    vn = ReaderVisualNovelScripts.vnShellScript();
    webview = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
  });

  group('三个 shell 都暴露 getLastVisibleCharOffset', () {
    test('分页 shell：getLastVisibleCharOffset(startOffset)', () {
      expect(
        paginated.contains('getLastVisibleCharOffset: function(startOffset) {'),
        isTrue,
        reason: '分页 shell 缺 getLastVisibleCharOffset → 分页模式区间终点恒 -1',
      );
    });

    test('连续 shell：getLastVisibleCharOffset()', () {
      expect(
        continuous.contains('getLastVisibleCharOffset: function() {'),
        isTrue,
        reason: '连续 shell 缺 getLastVisibleCharOffset → 连续模式区间终点恒 -1',
      );
    });

    test('VN shell：屏尾口径 screenEndCharCount', () {
      final String body = maskJsComments(
        methodBody(
          vn,
          'vn.getLastVisibleCharOffset = function()',
          lexicon: SourceLexicon.js,
        ),
      );
      expect(
        body.contains('this.screenEndCharCount(screen)'),
        isTrue,
        reason: 'VN 的 progress 口径是屏尾，end 必须取屏表 screenEndCharCount',
      );
    });
  });

  group('分页版 getLastVisibleCharOffset 的实现边界', () {
    late String body;

    setUpAll(() {
      body = maskJsComments(
        methodBody(
          paginated,
          'getLastVisibleCharOffset: function(startOffset)',
          lexicon: SourceLexicon.js,
        ),
      );
    });

    test('不用 countCharsBeforeViewportPaged（轴与分页滚动轴不一致）', () {
      expect(
        body.contains('countCharsBeforeViewportPaged'),
        isFalse,
        reason: '竖排它比 rect.left 而分页滚动轴是 y，算不出页尾',
      );
    });

    test('不临时 setPagePosition 探测再滚回', () {
      expect(
        body.contains('setPagePosition('),
        isFalse,
        reason: '临时滚动会触发 snap 监听 / scroll 回传递归 / 闪屏',
      );
    });

    test('对角 caret 探测 + isAtEnd 钳总数 + 二分降级', () {
      expect(body.contains('this._charOffsetAtPoint(x, y)'), isTrue);
      expect(
        body.contains('document.body.clientHeight - pb - 2'),
        isTrue,
        reason: '页尾角 y = clientHeight − paddingBottom − 2（body-relative 量纲）',
      );
      expect(
        body.contains(
          'context.vertical ? (pl + 2) : (document.body.clientWidth - pr - 2)',
        ),
        isTrue,
        reason: '竖排探左下角、横排探右下角',
      );
      expect(
        body.contains('if (this.isAtEnd()) return metrics.totalChars;'),
        isTrue,
        reason: '末页 end 必须等于章总字数',
      );
      expect(
        body.contains('this.getPagePosition(context) + context.pageSize'),
        isTrue,
        reason: '降级走「下一页页首之前的累计字数」二分（节点粒度、单调）',
      );
    });

    test('_charOffsetAtPoint 与 getFirstVisibleCharOffset 同口径', () {
      final String helper = maskJsComments(
        methodBody(
          paginated,
          '_charOffsetAtPoint: function(x, y)',
          lexicon: SourceLexicon.js,
        ),
      );
      expect(helper.contains('this.nodeStartOffsets.get(target)'), isTrue);
      expect(
        helper.contains('window.fushiStudyUnits.isUnitEnd(text, i)'),
        isTrue,
        reason: '偏移必须按学习单位累加（与 getFirstVisibleCharOffset 同口径）',
      );
      expect(helper.contains('document.caretRangeFromPoint(x, y)'), isTrue);
    });

    test('分页 calculateProgress 带可选 atScroll，共用 exploredCharsBeforeScroll', () {
      expect(
        paginated.contains('calculateProgress: function(atScroll) {'),
        isTrue,
      );
      expect(
        paginated.contains(
          'exploredCharsBeforeScroll: function(metrics, atScroll) {',
        ),
        isTrue,
      );
      final String progress = maskJsComments(
        methodBody(
          paginated,
          'calculateProgress: function(atScroll)',
          lexicon: SourceLexicon.js,
        ),
      );
      expect(
        progress.contains('this.exploredCharsBeforeScroll(metrics, atScroll)'),
        isTrue,
      );
    });
  });

  group('连续版：countCharsBeforeViewport 可选 edge，calculateProgress 不变', () {
    test('countCharsBeforeViewport 签名带 edge，缺省仍是视口首边', () {
      expect(
        continuous.contains(
          'countCharsBeforeViewport: function(node, vertical, edge) {',
        ),
        isTrue,
      );
      final String body = maskJsComments(
        methodBody(
          continuous,
          'countCharsBeforeViewport: function(node, vertical, edge)',
          lexicon: SourceLexicon.js,
        ),
      );
      expect(
        body.contains(
          'if (atFirstEdge) edge = vertical ? window.innerWidth : 0;',
        ),
        isTrue,
        reason: '缺省 edge = 视口首边（横排 0 / 竖排 window.innerWidth），行为零变化',
      );
    });

    test('getLastVisibleCharOffset 传视口末边一次 walk', () {
      final String body = maskJsComments(
        methodBody(
          continuous,
          'getLastVisibleCharOffset: function()',
          lexicon: SourceLexicon.js,
        ),
      );
      expect(
        body.contains('var edge = vertical ? 0 : window.innerHeight;'),
        isTrue,
        reason: '末边：横排 window.innerHeight / 竖排 0',
      );
      expect(
        body.contains('this.countCharsBeforeViewport(node, vertical, edge)'),
        isTrue,
      );
      expect(
        body.contains('return this.isAtEnd() ? totalChars : exploredChars;'),
        isTrue,
        reason: '物理到底时 end = 章总字数',
      );
    });

    test('连续 calculateProgress 仍按缺省首边调用（两参）', () {
      final String body = maskJsComments(
        methodBody(
          continuous,
          'calculateProgress: function()',
          lexicon: SourceLexicon.js,
        ),
      );
      expect(
        body.contains('this.countCharsBeforeViewport(node, vertical)'),
        isTrue,
        reason: '进度分子行为不变：不得把末边串进 calculateProgress',
      );
    });
  });

  group('fushiProgressDetails 协议：current,total,start,end', () {
    late String body;

    setUpAll(() {
      body = maskJsComments(
        methodBody(
          webview,
          'window.fushiProgressDetails = function()',
          lexicon: SourceLexicon.js,
        ),
      );
    });

    test('第四段 = getLastVisibleCharOffset(start)，atEnd 钳 total', () {
      expect(
        body.contains('r.getLastVisibleCharOffset(off)'),
        isTrue,
        reason: '终点必须来自 shell 的 getLastVisibleCharOffset（传已算好的 start）',
      );
      expect(
        body.contains('var end = atEnd ? total : (hasEnd ? '),
        isTrue,
        reason: 'atEnd 时 end 必须钳到 total',
      );
      expect(
        body.contains(
          "+ ',' + total + ',' + off\n        + (hasEnd ? ',' + end : '')",
        ),
        isTrue,
        reason:
            '返回 current,total,start,end 四段（无 getLastVisibleCharOffset 的旧 shell 不追加）',
      );
    });
  });
}
