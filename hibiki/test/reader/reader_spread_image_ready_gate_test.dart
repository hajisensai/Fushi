import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show buildSpreadPageHtml;

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-1229（第三次复诉的新症状）守卫：漫画「图片合并章节」(双页 spread) 跳章后
/// **图片闪现即消失**。
///
/// 根因：spread 页内联 HTML 的 `<script>` 旧实现在**解析那一刻**就同步
/// `callHandler('spreadReady')`——**不等两张整页图 decode**。cf0adf642（BUG-568 v3）
/// 把跨章冷却窗重锚 `_noteChapterTurnSettledIfPending` 接在 spreadReady 上，本意是
/// 「新章一就绪就开一个完整 450ms 窗口挡住残余滚轮」；但 spreadReady 早于图片可见，
/// 整页大图 decode 常 >450ms → 冷却窗在图片 paint 之前就过期 → 图片刚出现（闪）时
/// 残余惯性滚轮不再被拦 → 二次跨章把图片翻走（消失）。
///
/// 修法：spread HTML 也等两张图 `load`/`error` 后再发 spreadReady（镜像分页壳
/// `Promise.all(imagePromises)` 契约），让冷却窗重锚对齐图片真实可见时刻。
///
/// 本守卫：① 直接断言 [buildSpreadPageHtml] 输出把 spreadReady 门控在图片 load 上；
/// ② 源码守卫 `_loadSpreadPage` 委托到 [buildSpreadPageHtml] 且 spreadReady 处理器仍
/// 保留 cf0adf642 的冷却窗重锚接线（撤回任一 → 对应用例转红）。
void main() {
  group('buildSpreadPageHtml gates spreadReady on image load (TODO-1229)', () {
    const String leftUrl = 'hoshi.local/OEBPS/img/left.png';
    const String rightUrl = 'hoshi.local/OEBPS/img/right.png';
    final String html = buildSpreadPageHtml(
      leftUrl: leftUrl,
      rightUrl: rightUrl,
      swipeDistThreshold: 44,
      swipeFastDistThreshold: 22,
    );

    test('两张整页图 URL 与 spreadReady 信号都在', () {
      expect(html, contains('src="$leftUrl"'));
      expect(html, contains('src="$rightUrl"'));
      expect(html, contains("callHandler('spreadReady')"));
    });

    test('spreadReady 只从 signalReady() 发出，且被图片 load 计数门控', () {
      // 图片就绪门控三件套：已就绪短路 + load/error 事件 + 计数器。撤回任一 → 转红。
      expect(html, contains('img.complete'));
      expect(html, contains("addEventListener('load'"));
      expect(html, contains("addEventListener('error'"));
      expect(html, contains('function signalReady'));
      expect(html, contains('var pending = imgs.length'));

      // callHandler('spreadReady') 只出现一次，且在 signalReady 定义之后（=被它包裹），
      // 不再在解析时同步触发。
      final int readyCount =
          "callHandler('spreadReady')".allMatches(html).length;
      expect(readyCount, 1, reason: 'spreadReady 应只由 signalReady 单点发出');
      final int signalDefIdx = html.indexOf('function signalReady');
      final int readyIdx = html.indexOf("callHandler('spreadReady')");
      expect(signalDefIdx, greaterThanOrEqualTo(0));
      expect(readyIdx, greaterThan(signalDefIdx),
          reason: 'spreadReady 必须在 signalReady 函数体内，而非解析时同步调用');

      // 图片就绪门控逻辑必须在脚本闭合前（=真的在这段脚本里生效）。
      final int completeIdx = html.indexOf('img.complete');
      final int scriptEndIdx = html.indexOf('</script>');
      expect(completeIdx, greaterThan(0));
      expect(scriptEndIdx, greaterThan(completeIdx));

      // 旧的同步尾（点击循环 `});` 后直接 `callHandler('spreadReady')`）必须已消除。
      expect(
        html.contains(
            "  });\nwindow.flutter_inappwebview.callHandler('spreadReady');"),
        isFalse,
        reason: '不得回退到解析时同步触发 spreadReady',
      );
    });
  });

  group('reader page source wiring (TODO-1229)', () {
    final String source = readReaderPageSource();

    test('_loadSpreadPage 委托到 buildSpreadPageHtml，不内联同步 spreadReady', () {
      final int loadSpreadIdx = source.indexOf('Future<void> _loadSpreadPage(');
      expect(loadSpreadIdx, greaterThan(0), reason: '_loadSpreadPage 应存在于合并语料');
      // _loadSpreadPage 到下一个方法（_resolveSpreadImageUrl）之间的函数体切片。
      final int nextIdx =
          source.indexOf('String _resolveSpreadImageUrl(', loadSpreadIdx);
      expect(nextIdx, greaterThan(loadSpreadIdx));
      final String body = source.substring(loadSpreadIdx, nextIdx);
      // 钉的是「委托给 builder」，不是调用点的换行方式——BUG-1426 给 builder 加了
      // 阈值/键桥参数后调用点被 dart format 折成多行，旧的 `buildSpreadPageHtml(leftUrl:`
      // 连写断言当场转红，那是拼写脆弱而不是契约破裂。
      expect(body, contains('buildSpreadPageHtml('),
          reason: '_loadSpreadPage 必须走 buildSpreadPageHtml 生成 spread HTML');
      expect(body, contains('leftUrl:'),
          reason: 'builder 的左右图入参必须由 _loadSpreadPage 解析后传入');
      expect(body.contains("callHandler('spreadReady')"), isFalse,
          reason: '_loadSpreadPage 函数体内不得再内联 spreadReady（已下沉到 builder）');
    });

    test('spreadReady 处理器仍保留 cf0adf642 冷却窗重锚接线', () {
      // BUG-568 v3：spread content-ready 消费 pending 并重 stamp 冷却窗，勿被本次修复破坏。
      final int handlerIdx = source.indexOf("handlerName: 'spreadReady'");
      expect(handlerIdx, greaterThan(0));
      final int handlerEnd =
          source.indexOf("handlerName: 'onCueTap'", handlerIdx);
      expect(handlerEnd, greaterThan(handlerIdx));
      final String handlerBody = source.substring(handlerIdx, handlerEnd);
      expect(handlerBody, contains('_noteChapterTurnSettledIfPending()'),
          reason: 'spreadReady 处理器必须保留跨章冷却窗重锚（cf0adf642 / BUG-568 v3）');
    });
  });
}
