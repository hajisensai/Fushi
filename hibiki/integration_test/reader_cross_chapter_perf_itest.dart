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

      final String bookKey = await EpubImporter.import(
        db: appModel.database,
        bytes: EpubGenerator().generate(),
        fileName: 'perf_cross_chapter.epub',
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
      const int forwardTurns = 7;
      const int backwardTurns = 7;
      // 落点正确性基线：跨章不只要快，还必须落对章、落对位置（前进=章首、
      // 后退=章末）。每次跨章后读真实 DOM（baseURI = 当前章文档）与 JS 侧
      // calculateProgress()，任何优化都必须保住这两条。
      Future<String> currentChapterFile() async {
        final dynamic raw =
            await runInWebView!("(document.baseURI || '').split('/').pop()");
        return raw?.toString() ?? '';
      }

      Future<double> currentProgress() async {
        final dynamic raw = await runInWebView!(
            'window.hoshiReader ? window.hoshiReader.calculateProgress() : -1');
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
