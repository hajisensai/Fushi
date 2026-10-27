import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show buildSpreadPageHtml;
import 'package:fushi/src/reader/reader_search_navigation.dart';

import '../../helpers/source_guard.dart';
import '../../pages/reader_fushi_page_source_corpus.dart';

/// BUG-3796：有声书跨章守卫 `_chapterTransition` 只能由「这次导航的结局」释放——
/// 落地回执（`_onRestoreComplete` → `notifySectionRestoreCompleted`）或明确的
/// 中止 / 取消信号（`_failNavigation` → `abortChapterTransition`、
/// `cancelChapterTransition`）。本文件钉住此前三条**结局不发信号**的路径：
///
/// 1. `_navigateToChapter` 被拒（页面卸载 / 书或 WebView 未就绪 / 越界 / 被动导航
///    的目标经图片合并重定向后落在目录页）时**静默 return**：没有 `_beginNavigation`
///    → 没有回执、没有中止收尾、连 content-ready 兜底计时都没武装。持守卫的
///    `_handleCueCrossChapter` 却照常 await 完就走，守卫永久卡 true。
/// 2. WebView 主框架 `onReceivedError`：手写四行只解开导航态，不解守卫，要白等 8s
///    兜底计时器；且不核对出错的是不是当前导航那份文档——被新导航顶掉的旧加载报
///    abort 会把正在飞的导航错杀。
/// 3. `_reloadWithCurrentSettings` 装载失败：已递增代际（上一代回执此后判旧丢弃），
///    又不走统一中止收尾，守卫同样只能等 8s 兜底。
///
/// 不采用「reader 当前章 == cue 所属章就放守卫」的自愈判据（第三方 PR #2544）：
/// `_beginNavigation` 在导航一开始就同步写 `_currentChapter = chapter`，这个等式在
/// 回执到来前就成立，会把在飞导航的守卫提前放掉。
void main() {
  final String corpus = readReaderPageSource();

  group('① 被拒的导航必须让持守卫的调用方知道', () {
    final String nav = maskComments(
      methodBody(corpus, 'Future<bool> _navigateToChapter('),
    );

    test('_beginNavigation 之前的每个 return 都报「未开始」', () {
      final int begin = nav.indexOf('_beginNavigation(');
      expect(begin, isNonNegative);
      final String prelude = nav.substring(0, begin);
      final List<String> returns = RegExp(
        r'return\b[^;]*;',
      ).allMatches(prelude).map((Match m) => m.group(0)!).toList();
      expect(returns, isNotEmpty, reason: '拒绝分支必须存在（越界 / 未就绪 / 目录页）');
      expect(
        returns.every((String r) => r == 'return false;'),
        isTrue,
        reason: '被拒时没有回执也没有中止收尾，必须以 false 告知调用方：$returns',
      );
      expect(
        containsCodeLine(
          prelude,
          'if (!manual && _book!.isChapterNav(index)) {',
        ),
        isTrue,
        reason: '被动导航落目录页的拒绝在重定向之后判定——正是调用方事先挡不住的那条',
      );
    });

    test('开始之后报「已开始」（结局由导航自己通知控制器）', () {
      final int begin = nav.indexOf('_beginNavigation(');
      final String rest = nav.substring(begin);
      expect(containsCodeLine(rest, 'return true;'), isTrue);
      expect(
        containsIdentifierCall(rest, '_failNavigation'),
        isTrue,
        reason: '装载抛错仍经统一中止收尾（BUG-2529）',
      );
    });

    test('_handleCueCrossChapter 在导航被拒时当场释放守卫', () {
      final String body = maskComments(
        methodBody(corpus, 'Future<void> _handleCueCrossChapter('),
      );
      final int branch = body.indexOf(
        'if (!await _navigateToChapter(newSection, charOffset: studyOffset)) {',
      );
      expect(branch, isNonNegative, reason: '跨章导航的「是否开始」不得丢弃');
      expect(
        containsIdentifierCall(
          body.substring(branch),
          'cancelChapterTransition',
        ),
        isTrue,
        reason: '守卫是这次请求竖的，请求被拒 = 已取消，不放就永久卡 true',
      );
    });

    test('_navigateToChapterAndWait 不去等别人的 restore completer', () {
      final String body = maskComments(
        methodBody(corpus, 'Future<bool> _navigateToChapterAndWait('),
      );
      final int started = body.indexOf('if (!started) return false;');
      final int wait = body.indexOf('_restoreCompleter?.future');
      expect(started, isNonNegative);
      expect(wait, greaterThan(started), reason: '被拒必须在等待 completer 之前返回');
    });
  });

  group('② / ③ 导航失败一律走统一中止收尾', () {
    test('onReceivedError：只认当前导航文档，失败走 _failNavigation', () {
      final String source = maskComments(corpus);
      final int start = source.indexOf(
        'onReceivedError: (controller, request, error) async {',
      );
      expect(start, isNonNegative);
      final String handler = balancedBlockFrom(source, start);
      final int correlate = handler.indexOf(
        '_isCurrentChapterDocumentUrl(request.url.toString())',
      );
      final int fail = handler.indexOf('_failNavigation();');
      expect(correlate, isNonNegative, reason: '被顶掉的旧加载报错不是当前导航的结局');
      expect(fail, greaterThan(correlate));
      expect(
        handler.contains('_restoreInFlight = false;'),
        isFalse,
        reason: '手写收尾会绕过跨章守卫解除，必须收敛到 _failNavigation',
      );
    });

    test('_reloadWithCurrentSettings 装载失败走 _failNavigation', () {
      final String body = maskComments(
        methodBody(corpus, 'Future<void> _reloadWithCurrentSettings() async'),
      );
      final int load = body.indexOf(
        'await _loadChapterDirectly(_currentChapter);',
      );
      expect(load, isNonNegative);
      final String afterLoad = body.substring(load);
      expect(containsIdentifierCall(afterLoad, '_failNavigation'), isTrue);
      expect(afterLoad.contains('_restoreInFlight = false;'), isFalse);
    });
  });
  group('④ spread 就绪回报带代际，旧文档晚到的就绪不算当前导航完成', () {
    test('spread 文档把装载时的导航代际随 spreadReady 回报', () {
      final String html = buildSpreadPageHtml(
        navigationGeneration: 42,
        leftUrl: 'l.png',
        rightUrl: 'r.png',
        swipeDistThreshold: 44,
        swipeFastDistThreshold: 22,
        swipeFastVelocity: 300,
      );
      expect(html, contains("callHandler('spreadReady', 42)"));
      expect(html.contains("callHandler('spreadReady')"), isFalse);
    });

    test('代际解析：缺失 / 非数字 / 非整数一律不属于任何导航', () {
      expect(readerReportedNavigationGeneration(<dynamic>[7], 0), 7);
      expect(readerReportedNavigationGeneration(<dynamic>[7.0], 0), 7);
      expect(readerReportedNavigationGeneration(<dynamic>[], 0), isNull);
      expect(readerReportedNavigationGeneration(<dynamic>['7'], 0), isNull);
      expect(readerReportedNavigationGeneration(<dynamic>[7.5], 0), isNull);
      expect(
        readerReportedNavigationGeneration(<dynamic>[double.nan], 0),
        isNull,
      );
      expect(readerReportedNavigationGeneration(<dynamic>[null, 3], 1), 3);
      // 旧文档代际 3、当前导航代际 4：不是当前导航的回执。
      expect(
        isCurrentReaderRestoreCompletion(
          reportedGeneration: 3,
          currentGeneration: 4,
          expectedGeneration: 4,
        ),
        isFalse,
      );
    });

    test('spreadReady 处理器先核代际再收尾，并把落地通知有声书控制器', () {
      final String source = maskComments(corpus);
      final int start = source.indexOf("handlerName: 'spreadReady',");
      expect(start, isNonNegative);
      final int callback = source.indexOf('callback:', start);
      final String handler = balancedBlockFrom(source, callback);
      final int parse = handler.indexOf(
        'readerReportedNavigationGeneration(args, 0)',
      );
      final int gate = handler.indexOf('isCurrentReaderRestoreCompletion(');
      final int unwind = handler.indexOf('_restoreInFlight = false;');
      expect(parse, isNonNegative);
      expect(gate, greaterThan(parse));
      expect(unwind, greaterThan(gate), reason: '核过代际才能结束当前导航');
      expect(
        handler.indexOf('notifySectionRestoreCompleted('),
        greaterThan(unwind),
        reason: 'spread 就绪是这次导航的落地回执，必须解除跨章守卫',
      );
    });

    test('_loadSpreadPage 把当前代际交给 spread 文档', () {
      final String body = maskComments(
        methodBody(corpus, 'Future<void> _loadSpreadPage('),
      );
      expect(
        compactCode(body),
        contains(compactCode('navigationGeneration: _navigateGeneration,')),
      );
    });
  });
}
