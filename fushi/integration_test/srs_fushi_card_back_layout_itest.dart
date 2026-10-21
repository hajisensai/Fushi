// Fushi 卡片卡背排版的真像素截图 + 释义区实测宽度（Windows 离屏 runner）。
//
// 种一张内置 Fushi 卡片（样例字段 + 单词 / 例句音频）→ 打开复习页 → 翻面 →
// 抓原生卡面整帧（captureFlutterFrame）与释义 WebView（takeScreenshot），并打印
// 释义区各层盒子的实测宽度（`[srs-back-layout]` 行）。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_fushi_card_back_layout_itest.dart
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
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 释义区各层盒子的宽度（CSS px）与生效的 max-width。
const String _metricsScript = '''
(function(){
  function box(sel){
    var el = document.querySelector(sel);
    if (!el) return null;
    var cs = getComputedStyle(el);
    return {w: Math.round(el.getBoundingClientRect().width), maxW: cs.maxWidth,
      display: cs.display, margin: cs.marginLeft + ' ' + cs.marginRight};
  }
  function tree(el, depth){
    if (!el || depth > 6) return '';
    var cs = getComputedStyle(el);
    var line = new Array(depth + 1).join('  ') + el.tagName.toLowerCase() +
      (el.className ? '.' + String(el.className).trim().split(/\\s+/).join('.') : '') +
      ' w=' + Math.round(el.getBoundingClientRect().width) + ' d=' + cs.display +
      ' fd=' + cs.flexDirection + ' ai=' + cs.alignItems + ' as=' + cs.alignSelf +
      ' gtc=' + cs.gridTemplateColumns + ' maxW=' + cs.maxWidth + '\\n';
    for (var i = 0; i < el.children.length && i < 6; i++) {
      line += tree(el.children[i], depth + 1);
    }
    return line;
  }
  return JSON.stringify({tree: tree(document.getElementById('fushi-card-root'), 0),
    dpr: window.devicePixelRatio, inner: window.innerWidth,
    zoom: getComputedStyle(document.documentElement).zoom,
    body: box('body'), root: box('#fushi-card-root'), fc: box('.fc'),
    defs: box('.fc-defs'), first: box('.fc-defs > *'), more: box('.fc-more')});
})()
''';

/// 4 本其他词典（Fushi 制卡写进 Glossary 的形状：`li[data-dictionary]` + `<i>(标签, 词典名)</i>`）。
const String _multiDictGlossary =
    '<div class="yomitan-glossary" style="text-align: left;"><ol>'
    '<li data-dictionary="大辞林 第四版"><i>(動五, 大辞林 第四版)</i> '
    '<span>同じ所へ何度も行き来する。「病院に—・う」</span></li>'
    '<li data-dictionary="大辞林 第四版"><i>(動五)</i> '
    '<span>心が相手に伝わる。通じ合う。</span></li>'
    '<li data-dictionary="明鏡国語辞典"><i>(動五, 明鏡国語辞典)</i> '
    '<span>ある場所へ定期的に行き来する。</span></li>'
    '<li data-dictionary="新明解国語辞典"><i>(新明解国語辞典)</i> '
    '<span>決まった所へ繰り返し行く。</span></li>'
    '<li data-dictionary="JMdict"><i>(v5u, JMdict)</i> '
    '<span>to go to and from (a place); to commute</span></li>'
    '</ol></div>';

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Fushi 卡片卡背：原生区 + 释义区的真实排版', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    // 底部每段音频一颗重播键（放左侧），一起看。runner 是隔离库，不用还原。
    await appModel.setSrsReviewReplayButton(SrsReviewReplayButton.start);
    await _pumpFor(tester, const Duration(seconds: 1));

    final BuildContext rootContext = appModel.navigatorKey.currentContext!;
    final ProviderContainer container = ProviderScope.containerOf(rootContext);
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    await store.ensureBuiltins();
    final String uid = store.profileUid;
    final Map<String, String> fields = <String, String>{
      ...srsSampleCardFields(),
      'ExpressionAudio': '[sound:word.mp3]',
      'SentenceAudio': '[sound:sentence.mp3]',
      // 主词典之外再有 4 本：看分列网格与展开规则。
      'Glossary': _multiDictGlossary,
    };
    await store.createNote(
      noteTypeId: store.fushiCardNoteTypeId,
      createdAt: 1700000000000,
      fieldsById: <String, String>{
        for (final MapEntry<String, String> e in fields.entries)
          srsFushiCardFieldId(uid, e.key): e.value,
      },
    );
    container.read(srsRevisionProvider.notifier).state++;

    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              SrsReviewPage(deckId: store.defaultDeckId, deckName: 'layout'),
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 4));
    await captureFlutterFrame(tester, '01-front');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _pumpFor(tester, const Duration(seconds: 3));
    final ObserveShot back = await captureFlutterFrame(tester, '02-back');
    expect(back.saved, isTrue);
    final Size view = tester.view.physicalSize / tester.view.devicePixelRatio;
    debugPrint(
      '[srs-back-layout] view=$view dpr=${tester.view.devicePixelRatio}',
    );

    final InAppWebViewController? controller = SrsWebCardFace.debugController;
    expect(controller, isNotNull, reason: '释义 WebView 应已建');
    final Object? metrics = await controller!.evaluateJavascript(
      source: _metricsScript,
    );
    debugPrint('[srs-back-layout] defs $metrics');
    Future<void> shotDefs(String name) async {
      final Uint8List? png = await SrsWebCardFace.debugController!
          .takeScreenshot();
      if (png == null) return;
      final String path = '${observeScreenshotDir().path}/$name.png';
      await File(path).writeAsBytes(png, flush: true);
      debugPrint('[srs-back-layout] screenshot $path');
    }

    await shotDefs('03-back-defs-rows1');

    // 自动展开 2 行：主词典一行 + 其他词典一整行（按列数）展开。重开复习页让卡面重建。
    await appModel.setPopupAutoExpandDictionaries(2);
    appModel.navigatorKey.currentState!.pop();
    await _pumpFor(tester, const Duration(seconds: 1));
    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              SrsReviewPage(deckId: store.defaultDeckId, deckName: 'layout'),
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _pumpFor(tester, const Duration(seconds: 3));
    await captureFlutterFrame(tester, '04-back-rows2');
    final Object? metrics2 = await SrsWebCardFace.debugController!
        .evaluateJavascript(source: _metricsScript);
    debugPrint('[srs-back-layout] defs-rows2 $metrics2');
    await shotDefs('05-back-defs-rows2');
  });
}
