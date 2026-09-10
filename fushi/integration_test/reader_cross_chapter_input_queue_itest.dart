import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_chapter_perf_trace.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// BUG-2424 真机回归：**跨章落地后立刻再跨，必须立刻响应**。
///
/// 用户报的是「来回跨章的时候会强制等待 / 按了没反应要再按一次」（鼠标滚轮）。
/// 修复前的等待账：跨章那一刻 stamp 450ms 冷却窗 → 加载期所有滚轮 tick 被静默丢弃
/// → 新章 content-ready 时冷却窗**重新 stamp 到当下** → 下一次跨章最早只能在
/// `T_load + 450ms`。于是「刚落地就再拨一格」必然被吞。
///
/// 既有的 `reader_cross_chapter_perf_itest.dart` 结构上测不到这个：它是「9 次前进 +
/// 9 次后退」的单向两趟，而且每次跨章后固定停留 1500ms —— 那个停留正是为了越过
/// 冷却窗，等于把闸门排除在测量之外。本文件反过来，**只等满用户配的那一道闸门**。
///
/// 两道闸门必须分清楚：
///   * `wheelPageTurnInterval`（默认 450ms）是**用户在设置里配的限速器**，统一管章内
///     翻页与跨章，窗口从**发起**那一刻算——保留。
///   * `_kChapterTurnCooldown`（450ms）是隐藏的、不可配的，而且锢点被重新 stamp 到
///     **新章 content-ready**，于是与节流相加成 `T_load + 450ms`——删除。
///
/// 本用例恰好等满 throttle 后发下一拍，就把两者分开了：新代码该放行，
/// 旧代码因为冷却窗还没过期而把输入吞掉。
///
/// 驱动走生产通道 `callHandler('onBoundarySwipe', dir)`（与用户滚轮滚到章末时 JS 侧
/// 发出的是同一事件；只传方向 ⇒ Dart 侧 pointerKind 缺省按鼠标推断，正是用户场景）。
///
/// Run (PowerShell, from fushi/)：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
///     -RunId xchapter-queue integration_test/reader_cross_chapter_input_queue_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cross-chapter turns land back-to-back with no forced wait',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      await launchFushiTestApp();
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
          .setPref('src:reader_fushi:view_mode', 'pagination');
      await appModel.database
          .setPref('src:reader_fushi:writing_mode', 'horizontal-tb');
      await ReaderFushiSource.readerSettings?.refreshFromDb();

      final String bookKey = await EpubImporter.import(
        db: appModel.database,
        bytes: const EpubGenerator().generate(),
        fileName: 'xchapter_input_queue.epub',
      );

      final ReaderFushiSource source = ReaderFushiSource.instance;
      final MediaItem item = MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
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

      const Key webViewKey = ValueKey<String>('fushi_webview');
      for (int i = 0;
          i < 80 && find.byKey(webViewKey).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byKey(webViewKey), findsOneWidget);

      const Key contentReadyKey = ValueKey<String>('fushi_content_ready');
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

      expect(ReaderFushiPage.debugEvaluateJavascript, isNotNull);

      Future<String> currentChapterFile() async {
        final dynamic raw = await ReaderFushiPage.debugEvaluateJavascript!(
            "(document.baseURI || '').split('/').pop()");
        return raw?.toString() ?? '';
      }

      ReaderChapterPerfTrace.reset();
      ReaderChapterPerfTrace.enabled = true;

      /// 发一次跨章手势，等它**落地**（content-ready），返回落地耗时。
      /// 落地判据是 [ReaderChapterPerfTrace.completed] 增长——它记在遮罩真正撤掉那一帧
      /// （overlayGone），即用户「看见新章」的时刻。
      Future<Duration> turnAndAwaitLanding(String dir) async {
        final int before = ReaderChapterPerfTrace.completed.length;
        final Stopwatch watch = Stopwatch()..start();
        await ReaderFushiPage.debugEvaluateJavascript!(
          "window.flutter_inappwebview.callHandler('onBoundarySwipe', '$dir');",
        );
        for (int p = 0; p < 1500; p++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (ReaderChapterPerfTrace.completed.length > before) {
            watch.stop();
            return watch.elapsed;
          }
        }
        watch.stop();
        return Duration.zero;
      }

      // ── 来回跨章：forward → backward → forward → backward，每次落地后**立刻**发下
      // 一次，中间只留一帧。修复前这四拍里除第一拍外全部会被 450ms 冷却窗吞掉
      // （冷却窗在每次 content-ready 被重新 stamp，所以「刚落地」恰好是窗口最满的时刻）。
      const List<String> script = <String>[
        'forward',
        'backward',
        'forward',
        'backward',
      ];
      final List<String> visited = <String>[await currentChapterFile()];
      final List<int> landingMs = <int>[];

      // 用户配的「滚轮翻页间隔」统一管章内翻页与跨章，所以两拍之间必须等满它。
      // 关键是等满的起算点：节流窗从**发起**那一刻算（加载耗时包含在窗内），
      // 而被删掉的冷却窗是从**新章 content-ready** 重新 stamp。所以恰好等满
      // throttle、不多等一毫秒，就能把两者分开：新代码放行，旧代码还在
      // `T_load + 450ms` 的冷却里被吞。别把这个等待改大，改大就测不出冷却窗了。
      final int throttleMs = ReaderFushiSource.instance.wheelPageTurnInterval;
      for (int i = 0; i < script.length; i++) {
        final String dir = script[i];
        final String from = visited.last;
        final DateTime firedAt = DateTime.now();
        final Duration elapsed = await turnAndAwaitLanding(dir);
        while (DateTime.now().difference(firedAt).inMilliseconds < throttleMs) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        final String to = await currentChapterFile();
        landingMs.add(elapsed.inMilliseconds);
        debugPrint('[xchapter-queue] #$i $dir $from -> $to '
            'landed=${elapsed.inMilliseconds}ms');

        expect(elapsed, isNot(Duration.zero),
            reason: '第 $i 拍（$dir）没有落地：跨章手势在 30s 内没产生任何跨章。'
                '修复前这里会因为跨章冷却窗（锚在上一次 content-ready）而被静默吞掉');
        expect(to, isNot(equals(from)), reason: '第 $i 拍（$dir）必须真的换章');
        visited.add(to);
      }

      // 来回四拍应当回到起点：A→B→A→B→A。
      expect(visited.first, equals(visited.last),
          reason: '来回等量的前进/后退必须回到起始章；对不上说明有一拍跨了两章');
      expect(visited[1], equals(visited[3]), reason: '两次 forward 必须落到同一章');

      // 每一拍都必须是**一次**跨章，不多不少：一次输入放大成两次跨章正是 TODO-1229
      // 那套时间窗当初要防的「跳两章」。队列的 1:1 消费取代了它，这里做行为端复核。
      expect(ReaderChapterPerfTrace.completed.length, script.length,
          reason: '${script.length} 次输入必须恰好产生 ${script.length} 次跨章');

      ReaderChapterPerfTrace.enabled = false;
      debugPrint('[xchapter-queue] landings=$landingMs visited=$visited');

      navigator.pop();
      await tester.pump(const Duration(seconds: 2));
      for (int i = 0;
          i < 40 && ReaderFushiPage.debugEvaluateJavascript != null;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    },
  );
}
