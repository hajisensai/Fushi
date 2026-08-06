import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';
import 'package:hibiki/src/reader/reader_chapter_perf_trace.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// 跨章性能实测 itest —— 只产出分段计时，不做性能断言（避免机器差异假红）。
///
/// 驱动路径是**生产通道**：`window.flutter_inappwebview.callHandler('onBoundarySwipe')`
/// —— 与用户在章末继续滚轮/滑动时 JS 侧发出的完全同一个事件，因此测的是真实
/// `onBoundarySwipe → _handlePageTurnLimit → _navigateToVirtualPage → loadUrl →
/// onLoadStop → setup 脚本 → 桥接/高亮 → JS initialize+restore` 全链路。
///
/// 输出（grep command.log）：
///   - `[chapter-perf]`：每次跨章一行分段 breakdown（[ReaderChapterPerfTrace]）。
///   - `[xchapter-perf]`：本测试的汇总（每段中位数/总和）。
///
/// Run (PowerShell, from hibiki/)：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
///     -RunId xchapter-01 integration_test/reader_cross_chapter_perf_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cross-chapter turn: measure per-stage latency',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: 'Home must render');
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(appModel.isInitialised, isTrue);

      await appModel.database
          .setPref('src:reader_ttu:ttu_view_mode', 'pagination');
      await appModel.database
          .setPref('src:reader_ttu:ttu_writing_mode', 'horizontal-tb');
      await ReaderHibikiSource.readerSettings?.refreshFromDb();

      // 带**真实体量**插图（1600×2400 PNG）的书：合成 fixture 原来的「图片章」是内联
      // SVG，解码几乎免费，跨章计时里完全测不到图片这一段——而真实书的整页插图正是
      // 用户感知「跨章要半秒」的主因。withRealImages 追加两章：纯整页插图（eager 路径）
      // 与图文混排（lazy 路径）。
      final String bookKey = await EpubImporter.import(
        db: appModel.database,
        bytes: const EpubGenerator(withRealImages: true).generate(),
        fileName: 'perf_cross_chapter_images.epub',
      );

      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      final MediaItem item = MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
        title: bookKey,
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 0,
        canDelete: false,
        canEdit: true,
      );

      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => source.buildLaunchPage(item: item),
      )));
      await tester.pump(const Duration(seconds: 3));

      const Key webViewKey = ValueKey<String>('hoshi_webview');
      for (int i = 0;
          i < 80 && find.byKey(webViewKey).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byKey(webViewKey), findsOneWidget);

      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 140; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue, reason: 'reader content must be ready');
      await tester.pump(const Duration(seconds: 3));

      final Future<dynamic> Function(String source)? runInWebView =
          ReaderHibikiPage.debugEvaluateJavascript;
      expect(runInWebView, isNotNull);

      ReaderChapterPerfTrace.reset();
      ReaderChapterPerfTrace.enabled = true;

      // 8 章 fixture：前进翻到末章，再后退翻回首章（后退带 progress=0.99 的章末
      // 恢复，与前进的章首恢复是两条不同的 JS restore 路径）。章体量差异很大
      // （420 markers 长章 / 5 markers 短章 / 图片章 / ruby 章 / 500 markers 最长章），
      // 逐章日志里的 `chapter=N` 可用来看耗时是否随章体量线性增长。
      // 10 章：前 8 章同旧 fixture（文本/短章/SVG/ruby），第 9、10 章是真实插图章。
      // 一路前进到末章再退回来，日志里的 chapter=8/9 就是带真实插图的两章。
      const int forwardTurns = 9;
      const int backwardTurns = 9;
      // 落点正确性基线：跨章不只要快，还必须落对章、落对位置（前进=章首、
      // 后退=章末）。每次跨章后读真实 DOM（baseURI = 当前章文档）与 JS 侧
      // calculateProgress()，任何优化都必须保住这两条。
      // 注意：一律走 `ReaderHibikiPage.debugEvaluateJavascript` 的**当下**值，不缓存
      // 闭包——中段落点用例会 pop + 重新 push 阅读器，缓存的旧引用指向已销毁的控制器。
      Future<String> currentChapterFile() async {
        final dynamic raw = await ReaderHibikiPage.debugEvaluateJavascript!(
            "(document.baseURI || '').split('/').pop()");
        return raw?.toString() ?? '';
      }

      Future<double> currentProgress() async {
        final dynamic raw = await ReaderHibikiPage.debugEvaluateJavascript!(
            'window.fushiReader ? window.fushiReader.calculateProgress() : -1');
        if (raw is num) return raw.toDouble();
        return double.tryParse(raw?.toString() ?? '') ?? -1;
      }

      final List<String> visited = <String>[await currentChapterFile()];

      for (int i = 0; i < forwardTurns + backwardTurns; i++) {
        final String dir = i < forwardTurns ? 'forward' : 'backward';
        final String from = visited.last;
        final int before = ReaderChapterPerfTrace.completed.length;
        await runInWebView!(
          "window.flutter_inappwebview.callHandler('onBoundarySwipe', '$dir');",
        );
        bool landed = false;
        for (int p = 0; p < 1500; p++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (ReaderChapterPerfTrace.completed.length > before) {
            landed = true;
            break;
          }
        }
        if (!landed) {
          debugPrint('[xchapter-perf] turn #$i ($dir) did not land in 30s');
        }
        // 让新章 settle（重锚/进度刷新等尾沿）跑完，并越过 450ms 跨章冷却窗，
        // 避免下一次 onBoundarySwipe 被当成同一手势的残余惯性丢弃。
        //
        // 停留时长保持 1500ms 不动：这个值的判据是「settle 尾沿 + 冷却窗」，不是
        // 「预热跑完」。把它拉长到 4s 会让每次跨章都稳稳命中下一章插图预热 —— 那是把
        // 测量条件调到最有利于新代码的稳态，测出来的数字不再代表用户快速翻章 /
        // 目录跳转时的表现。预热命中与否的差异应当从逐次 `[chapter-perf]` 的分布里读，
        // 不该由测试的等待时长预先决定。
        await tester.pump(const Duration(milliseconds: 1500));

        final String to = await currentChapterFile();
        final double progress = await currentProgress();
        debugPrint('[xchapter-land] #$i $dir $from -> $to '
            'progress=${progress.toStringAsFixed(3)}');
        expect(landed, isTrue, reason: 'turn #$i ($dir) must land');
        expect(to, isNot(equals(from)),
            reason: 'turn #$i ($dir) must actually change chapter');
        visited.add(to);
        // 前进落章首、后退落章末（progress>=0.99 语义）。图片/短章可能整章一页
        // （progress 恒 0），故后退只要求「不在章首之前」且允许整章单页的 0。
        if (dir == 'forward') {
          expect(progress, lessThan(0.2),
              reason: 'forward turn #$i must land at chapter start');
        }
      }

      ReaderChapterPerfTrace.enabled = false;

      // ── 中段落点回归（BUG-1140 第二轮审查）──────────────────────────────
      //
      // 上面的循环只断言「前进落章首 / 后退落章末」，恰好是两个已被
      // forceLoadPendingImages / scroll-0 天然安全覆盖的分支。真正新增风险的是
      // **章内中段**的精确字符锚恢复：`loading="lazy"` 提前写进 HTML 源码后，恢复
      // 必然跑在插图 decode 之前，锚换算用的是「插图 0×0」的塌缩布局；插图随后 load、
      // 几何后移，冻结的 scrollTop 就指向别的内容，而进度轮询会把这个漂掉的读数落库。
      //
      // 这里走**真实的退出重进路径**（pop 阅读器 → 重新 push 同一本书），在图文混排
      // 的真实插图章中段取锚，重进后要求落回同一位置。容差自校准：用同一章、同一版式
      // 下「翻一页」实测跨过的字符数当上界 —— 漂一张整页插图 ≥ 一页，必然超出。
      Future<int> firstVisibleChar() async {
        final dynamic raw = await ReaderHibikiPage.debugEvaluateJavascript!(
            'window.fushiReader ? window.fushiReader.getFirstVisibleCharOffset() : -1');
        if (raw is num) return raw.toInt();
        return int.tryParse(raw?.toString() ?? '') ?? -1;
      }

      Future<void> swipe(String dir) async {
        final int before = ReaderChapterPerfTrace.completed.length;
        await ReaderHibikiPage.debugEvaluateJavascript!(
          "window.flutter_inappwebview.callHandler('onBoundarySwipe', '$dir');",
        );
        for (int p = 0; p < 1500; p++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (ReaderChapterPerfTrace.completed.length > before) break;
        }
        await tester.pump(const Duration(milliseconds: 1200));
      }

      // 回到图文混排的真实插图章（fixture 最后一章 chapter_10_photo_text）。
      for (int i = 0; i < forwardTurns; i++) {
        await swipe('forward');
      }
      final String midChapter = await currentChapterFile();
      debugPrint('[xchapter-mid] landed chapter=$midChapter');

      // 翻进章内中段（不是章首、不是章末）。
      for (int i = 0; i < 3; i++) {
        await ReaderHibikiPage.debugEvaluateJavascript!(
            "window.fushiReader.paginate('forward');");
        await tester.pump(const Duration(milliseconds: 400));
      }
      final int anchorChar = await firstVisibleChar();
      // 位置落库走 500ms 去抖 + 进度轮询，留足窗口。
      await tester.pump(const Duration(seconds: 3));
      debugPrint('[xchapter-mid] anchor char=$anchorChar in $midChapter');

      // 退出重进：真实的「关书 → 再开」恢复路径。
      navigator.pop();
      await tester.pump(const Duration(seconds: 2));
      for (int i = 0;
          i < 40 && ReaderHibikiPage.debugEvaluateJavascript != null;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => source.buildLaunchPage(item: item),
      )));
      await tester.pump(const Duration(seconds: 3));
      bool reopened = false;
      for (int i = 0; i < 140; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          reopened = true;
          break;
        }
      }
      expect(reopened, isTrue, reason: '重进后阅读器必须就绪');
      // 留出插图真正 load + 语义重锚落定的窗口（重锚由图片 load 事件驱动）。
      await tester.pump(const Duration(seconds: 5));

      final String restoredChapter = await currentChapterFile();
      final int restoredChar = await firstVisibleChar();
      // 自校准容差：同章同版式下翻一页跨过多少字符。
      await ReaderHibikiPage
          .debugEvaluateJavascript!("window.fushiReader.paginate('forward');");
      await tester.pump(const Duration(milliseconds: 600));
      final int nextPageChar = await firstVisibleChar();
      final int pageSpan = (nextPageChar - restoredChar).abs();
      debugPrint('[xchapter-mid] restored chapter=$restoredChapter '
          'char=$restoredChar anchor=$anchorChar pageSpan=$pageSpan');

      expect(restoredChapter, equals(midChapter), reason: '重进必须落回同一章');
      expect(anchorChar, greaterThan(0), reason: '中段锚必须非章首，否则这条用例测不到中段落点');
      expect(restoredChar, greaterThan(0),
          reason: '重进落点不得塌缩回章首（插图 0×0 塌缩布局的典型症状）');
      // restoreToCharOffset 把锚所在页对齐到页首 → 首可见字符 <= 锚，且相差不超过一页。
      expect(restoredChar, lessThanOrEqualTo(anchorChar + 1),
          reason: '恢复落点不应越过锚');
      if (pageSpan > 0) {
        expect(anchorChar - restoredChar, lessThanOrEqualTo(pageSpan),
            reason: '重进落点与中段锚的偏差必须在一页之内——超出即恢复算在了'
                '插图未 decode 的塌缩布局上（BUG-1140 第二轮）');
      }

      final List<Map<String, int>> runs = ReaderChapterPerfTrace.completed;
      debugPrint('[xchapter-perf] turns=${runs.length}');
      final Set<String> stages = <String>{};
      for (final Map<String, int> run in runs) {
        stages.addAll(run.keys);
      }
      for (final String stage in stages) {
        final List<int> values = runs
            .map((Map<String, int> r) => r[stage])
            .whereType<int>()
            .toList()
          ..sort();
        if (values.isEmpty) continue;
        final int median = values[values.length ~/ 2];
        debugPrint('[xchapter-perf] $stage median=${median}ms '
            'min=${values.first}ms max=${values.last}ms n=${values.length}');
      }

      navigator.pop();
      await tester.pump(const Duration(seconds: 2));
      for (int i = 0;
          i < 40 && ReaderHibikiPage.debugEvaluateJavascript != null;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    },
  );
}
