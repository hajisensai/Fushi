import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_hibiki_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

/// BUG-712 查词时延实测 itest —— 只产出计时数据，不做性能断言（避免机器差异假红）。
///
/// 数据源两级：
///   - 真实词典：`$FUSHI_TEST_ROOT/fixtures/perf-dicts/*.zip`（term+freq+pitch 组合，
///     ASCII 文件名）逐个经真实 [AppModel.importDictionary] FFI 导入；同一 RunId 复跑
///     时已装词典直接复用（导入成本只付一次）。
///   - 没有该目录时退回 [seedDictionary] 的 2 词条生成词典（数字标注 tiny-dict）。
///
/// 输出（grep command.log）：
///   - `[perf-e2e]`：真实 DOM 点击派发 → `isDictionaryShown` 的端到端时延；
///     冷查词 1 次 + 复查同词 4 次（全缓存 + 热槽复用路径）。
///   - `[perf-engine]`：engine-only `searchDictionary` 批量计时（首查/复查两遍），
///     与 `[dict-perf]` 分项日志对照可拆出 native/convert/build/popupJson 占比。
///
/// Run (PowerShell, from hibiki/)：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
///     -RunId perf-real-01 integration_test/lookup_latency_perf_itest.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-712: measure real lookup latency (e2e + engine segments)',
    timeout: const Timeout(Duration(minutes: 40)),
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

      // ── 词典：真实组合优先，缺省退回生成词典 ──
      final bool realDicts = await _importPerfDictionaries(appModel, tester);
      if (!realDicts) {
        final bool dictOk = await seedDictionary(tester);
        expect(dictOk, isTrue, reason: 'fallback tiny dictionary must seed');
      }
      debugPrint('[perf-e2e] dictionaries: '
          '${appModel.dictionaries.map((d) => d.name).join(" | ")} '
          '(real=$realDicts)');

      await appModel.database
          .setPref('src:reader_fushi:view_mode', 'pagination');
      await appModel.database
          .setPref('src:reader_fushi:writing_mode', 'horizontal-tb');
      await ReaderHibikiSource.readerSettings?.refreshFromDb();

      final String bookKey = await EpubImporter.import(
        db: appModel.database,
        bytes: EpubGenerator().generate(),
        fileName: 'perf_lookup_latency.epub',
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

      final Future<dynamic> Function(String source)? runInWebView =
          ReaderHibikiPage.debugEvaluateJavascript;
      expect(runInWebView, isNotNull);

      final dynamic rawPts = await runInWebView!(_wordPointJs());
      final Map<String, dynamic> pts =
          jsonDecode(rawPts as String) as Map<String, dynamic>;
      expect(pts['ok'], isTrue, reason: 'need a visible 猫 point: $pts');
      final double x = (pts['x'] as num).toDouble();
      final double y = (pts['y'] as num).toDouble();

      final State rawState = tester.state(find.byType(ReaderHibikiPage));
      final dynamic readerState = rawState;
      bool dictShown() => readerState.isDictionaryShown as bool;

      // BUG-712 ①运行时证据：门控镜像必须已注入且放行（chrome+lookup 都 true 时
      // tap 走 JS 直选路径，3 跳并 1 跳）；fushiSelection 就绪是直选前提。
      final dynamic gateRaw = await runInWebView(
        'JSON.stringify({gate: window.__fushiTapGate || null, '
        'sel: !!window.fushiSelection})',
      );
      debugPrint('[perf-e2e] tapGate=$gateRaw');

      // ── e2e：冷查词 1 次 + 复查 4 次 ──
      // 计时=派发点击瞬间到 isDictionaryShown 翻真；pump(8ms) 轮询，分辨率 ~10ms。
      for (int round = 0; round < 5; round++) {
        expect(dictShown(), isFalse,
            reason: 'popup must be closed before round $round');
        final Stopwatch sw = Stopwatch()..start();
        await runInWebView(_dispatchClickJs(x, y));
        while (sw.elapsedMilliseconds < 15000 && !dictShown()) {
          await tester.pump(const Duration(milliseconds: 8));
        }
        sw.stop();
        final String kind = round == 0 ? 'cold' : 'repeat#$round';
        debugPrint('[perf-e2e] lookup $kind: shown=${dictShown()} '
            'e2e=${sw.elapsedMilliseconds}ms');
        expect(dictShown(), isTrue, reason: 'lookup $kind must show a popup');
        // 让尾批渲染/高亮等异步收尾跑完再关，避免下一轮串扰。
        await tester.pump(const Duration(milliseconds: 800));
        readerState.clearDictionaryResult();
        for (int i = 0; i < 100 && dictShown(); i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.pump(const Duration(milliseconds: 400));
      }

      // ── engine-only：真实词形批量计时（不经弹窗）──
      // 模拟阅读器传参：searchTerm 是从点击处向后抓的正文片段（≤400 字符），
      // 引擎自己做前缀扫描+去屈折。首遍=真实查询，第二遍=全缓存命中。
      const List<String> probes = <String>[
        '食べたことがなかったので、彼はゆっくりと箸を取り上げて味わった。',
        '世界のどこかで同じ夢を見ている人がいるかもしれないと彼女は思った。',
        '図書館の奥にある古い辞書には不思議な言葉がたくさん載っていた。',
        '美しかった景色を思い出しながら、長い坂道を下りていく。',
        '見られていることに気づかないふりをして、静かに本を閉じた。',
        '走り出した電車の窓から、知らない町の灯りが流れていった。',
        '日本語',
        'ゆっくり',
        '取り上げて',
        '灯り',
      ];
      for (int pass = 0; pass < 2; pass++) {
        for (final String probe in probes) {
          final Stopwatch sw = Stopwatch()..start();
          final result = await appModel.searchDictionary(
            searchTerm: probe,
            searchWithWildcards: false,
          );
          sw.stop();
          final String head = probe.length > 8 ? probe.substring(0, 8) : probe;
          debugPrint(
              '[perf-engine] pass=$pass total=${sw.elapsedMilliseconds}ms '
              'entries=${result.entries.length} "$head"');
        }
      }

      await takeScreenshot(binding, 'lookup_latency_perf_done');

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

/// 从 `$FUSHI_TEST_ROOT/fixtures/perf-dicts/` 逐个导入真实词典 zip。
/// 已装同名词典跳过（同一 RunId 复跑不重复导入）。返回是否装上了至少一部。
Future<bool> _importPerfDictionaries(
  AppModel appModel,
  WidgetTester tester,
) async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  if (testRoot.isEmpty) return appModel.dictionaries.length > 1;
  final Directory dir = Directory('$testRoot/fixtures/perf-dicts');
  if (!dir.existsSync()) return appModel.dictionaries.length > 1;

  final List<File> zips = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.zip'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (zips.isEmpty) return appModel.dictionaries.length > 1;

  // 复跑复用：任何一部真实词典已在库即认为整组装过（导入是本测试最贵的一步）。
  if (appModel.dictionaries.length >= zips.length) {
    debugPrint('[perf-e2e] perf-dicts already imported, reusing');
    return true;
  }

  for (final File zip in zips) {
    final Stopwatch sw = Stopwatch()..start();
    final ValueNotifier<String> progress = ValueNotifier<String>('');
    bool ok = false;
    try {
      await appModel.importDictionary(
        file: zip,
        progressNotifier: progress,
        onImportSuccess: () => ok = true,
      );
    } catch (e) {
      debugPrint('[perf-e2e] import FAILED ${zip.path}: $e');
    } finally {
      progress.dispose();
    }
    sw.stop();
    debugPrint('[perf-e2e] import ${zip.uri.pathSegments.last}: '
        'ok=$ok ${sw.elapsedMilliseconds}ms');
    await tester.pump(const Duration(milliseconds: 300));
  }
  return appModel.dictionaries.isNotEmpty;
}

/// 找一个可见的 "猫"（生成 EPUB 正文重复出现）返回视口坐标。
String _wordPointJs() => r'''
(function() {
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  var node = walker.nextNode();
  while (node) {
    var text = node.nodeValue || '';
    var idx = text.indexOf('猫');
    while (idx !== -1) {
      var range = document.createRange();
      range.setStart(node, idx);
      range.setEnd(node, idx + 1);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (r.width > 2 && r.height > 2 && r.right > 0 && r.bottom > 0 &&
            r.left < window.innerWidth && r.top < window.innerHeight) {
          return JSON.stringify({ok: true,
            x: Math.max(1, Math.min(window.innerWidth - 1, (r.left + r.right) / 2)),
            y: Math.max(1, Math.min(window.innerHeight - 1, (r.top + r.bottom) / 2))});
        }
      }
      idx = text.indexOf('猫', idx + 1);
    }
    node = walker.nextNode();
  }
  return JSON.stringify({ok: false, error: 'no visible 猫'});
})()
''';

/// 派发一次真实单击（pointerdown/up + click），走生产 onTap 全链。
String _dispatchClickJs(double x, double y) => '''
(function() {
  var px = $x, py = $y;
  var target = document.elementFromPoint(px, py) || document.body;
  function fire(type, buttons, button) {
    var init = {
      bubbles: true, cancelable: true, view: window,
      clientX: px, clientY: py, button: button, buttons: buttons
    };
    var ev;
    try { ev = new PointerEvent(type, Object.assign({pointerType:'mouse', pointerId: 7, isPrimary:true}, init)); }
    catch (e) { ev = new MouseEvent(type, init); }
    target.dispatchEvent(ev);
  }
  fire('pointerdown', 1, 0);
  fire('pointerup', 0, 0);
  var click = new MouseEvent('click', {
    bubbles: true, cancelable: true, view: window,
    clientX: px, clientY: py, button: 0, detail: 1
  });
  target.dispatchEvent(click);
  return 'dispatched';
})()
''';
