// 复习卡面换卡 / 翻面耗时探针 + 卡面滚动条截图（Windows 离屏 runner）。
//
// 种 12 张 Lapis 新卡 → 打开复习页 → 连续 10 张「空格翻面 → 3 评分」，量每次
// 「按键 → 卡面新内容首帧」：页内 MutationObserver 看到卡面文本变了，双 rAF 后经
// JS handler 回报 Dart（与实现无关：整页重载的旧实现靠 user script 在每个新文档里
// 重装探针，外壳实现只装一次）。结果打 `[srs-face-probe]` 行，截图落证据目录。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_card_face_swap_itest.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _probeHandler = 'onSrsDebugPaint';

/// 卡面文本一变就在双 rAF 后回报（≈ 新内容已合成上屏的那一帧）。
const String _probeScript =
    '''
(function(){
  if (window.__srsPaintProbe) return;
  window.__srsPaintProbe = true;
  var last = null;
  function text(){
    var r = document.getElementById('fushi-card-root') || document.body;
    return r ? r.textContent.replace(/\\s+/g, ' ').trim() : '';
  }
  function check(){
    var t = text();
    if (t === last) return;
    last = t;
    requestAnimationFrame(function(){ requestAnimationFrame(function(){
      if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('$_probeHandler', t.slice(0, 80));
    }); });
  }
  new MutationObserver(check).observe(document.documentElement, {subtree: true, childList: true, characterData: true});
  check();
})();
''';

/// 滚动容器与其滚动条占位宽度（offsetWidth − clientWidth − 左右边框）、
/// `::-webkit-scrollbar` 是否生效（伪元素宽度经 getComputedStyle 读不到，只能
/// 看占位：经典滚动条 ≈ 17 CSS px，本主题 8px，叠加滚动条 0）。
const String _scrollMetricsScript = '''
(function(){
  var out = {dpr: window.devicePixelRatio, innerWidth: window.innerWidth,
    rootGutter: window.innerWidth - document.documentElement.clientWidth,
    rootScrollable: document.scrollingElement.scrollHeight > document.scrollingElement.clientHeight,
    colorScheme: getComputedStyle(document.documentElement).colorScheme,
    scrollers: []};
  var all = document.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) {
    var el = all[i], cs = getComputedStyle(el);
    if ((cs.overflowY === 'auto' || cs.overflowY === 'scroll') && el.scrollHeight > el.clientHeight) {
      out.scrollers.push({tag: el.tagName, id: el.id, cls: el.className,
        gutter: el.offsetWidth - el.clientWidth - parseFloat(cs.borderLeftWidth) - parseFloat(cs.borderRightWidth)});
    }
  }
  return JSON.stringify(out);
})()
''';

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('复习卡面：连续翻面 + 评分 10 张的首帧耗时', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await _pumpFor(tester, const Duration(seconds: 1));

    final BuildContext rootContext = appModel.navigatorKey.currentContext!;
    final ProviderContainer container = ProviderScope.containerOf(rootContext);
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    expect(store.canSchedule, isTrue, reason: 'FSRS 内核应可用');
    await store.ensureBuiltins();
    final String uid = store.profileUid;
    final String longDefinition = List<String>.generate(
      40,
      (int i) => '定義の行 ${i + 1}：とても長い説明文がここに続きます。',
    ).join('<br>');
    for (int i = 0; i < 12; i++) {
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        createdAt: 1700000000000 + i,
        fieldsById: <String, String>{
          srsLapisFieldId(uid, 'Expression'): '単語$i',
          srsLapisFieldId(uid, 'ExpressionReading'): 'たんご$i',
          srsLapisFieldId(uid, 'MainDefinition'): '意味 $i<br>$longDefinition',
          srsLapisFieldId(uid, 'Sentence'): 'これは<b>単語$i</b>の例文です。',
        },
      );
    }
    container.read(srsRevisionProvider.notifier).state++;

    final List<String> painted = <String>[];
    final List<int> paintedAtUs = <int>[];
    final Stopwatch clock = Stopwatch()..start();

    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              SrsReviewPage(deckId: store.defaultDeckId, deckName: 'probe'),
        ),
      ),
    );

    // 等卡面 WebView 建好，装探针（user script：整页重载的实现每个新文档都重装）。
    final Stopwatch wait = Stopwatch()..start();
    while (SrsWebCardFace.debugController == null &&
        wait.elapsed < const Duration(seconds: 30)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final InAppWebViewController controller = SrsWebCardFace.debugController!;
    controller.addJavaScriptHandler(
      handlerName: _probeHandler,
      callback: (List<dynamic> args) {
        paintedAtUs.add(clock.elapsedMicroseconds);
        painted.add(args.isEmpty ? '' : '${args.first}');
        return null;
      },
    );
    await controller.addUserScript(
      userScript: UserScript(
        source: _probeScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
      ),
    );
    await controller.evaluateJavascript(source: _probeScript);
    await _pumpFor(tester, const Duration(seconds: 3));

    /// 发一个键，等到回报的卡面文本满足 [want]，返回毫秒。
    Future<double> step(
      LogicalKeyboardKey key,
      bool Function(String text) want,
      String label,
    ) async {
      final int from = painted.length;
      final int t0 = clock.elapsedMicroseconds;
      await tester.sendKeyEvent(key);
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 10)) {
        for (int i = from; i < painted.length; i++) {
          if (want(painted[i])) {
            final double ms = (paintedAtUs[i] - t0) / 1000;
            debugPrint(
              '[srs-face-probe] $label ${ms.toStringAsFixed(1)} ms '
              '(events ${painted.length - from}) "${painted[i].substring(0, painted[i].length.clamp(0, 30))}"',
            );
            return ms;
          }
        }
        await tester.pump(const Duration(milliseconds: 4));
      }
      fail('$label: 10 s 内没等到新内容首帧；收到 ${painted.sublist(from)}');
    }

    final List<double> flips = <double>[];
    final List<double> nexts = <double>[];
    for (int n = 0; n < 10; n++) {
      flips.add(
        await step(
          LogicalKeyboardKey.space,
          (String t) => t.contains('意味'),
          'flip#$n',
        ),
      );
      await _pumpFor(tester, const Duration(milliseconds: 400));
      if (n == 0) {
        final Uint8List? png = await controller.takeScreenshot();
        if (png != null) {
          final String path =
              '${observeScreenshotDir().path}/srs-face-answer-scrollbar.png';
          await File(path).writeAsBytes(png, flush: true);
          debugPrint('[srs-face-probe] screenshot $path');
        }
        // 抓图（CapturePreview）不含滚动条：滚动条实际占位宽度与样式直接量。
        final Object? metrics = await controller.evaluateJavascript(
          source: _scrollMetricsScript,
        );
        debugPrint('[srs-face-probe] scrollbar $metrics');
      }
      nexts.add(
        await step(
          LogicalKeyboardKey.digit3,
          (String t) => !t.contains('意味') && t.isNotEmpty,
          'next#$n',
        ),
      );
      await _pumpFor(tester, const Duration(milliseconds: 400));
    }

    String stats(List<double> v) {
      final List<double> s = List<double>.of(v)..sort();
      final double mean = v.reduce((double a, double b) => a + b) / v.length;
      return 'n=${v.length} mean=${mean.toStringAsFixed(1)} '
          'median=${s[s.length ~/ 2].toStringAsFixed(1)} '
          'min=${s.first.toStringAsFixed(1)} max=${s.last.toStringAsFixed(1)} ms';
    }

    debugPrint('[srs-face-probe] FLIP ${stats(flips)}');
    debugPrint('[srs-face-probe] NEXT ${stats(nexts)}');
    debugPrint('[srs-face-probe] RAW flips=$flips nexts=$nexts');
  });
}
