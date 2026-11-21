/// 逐格读 + 台词栏（方案 C）真 app 取证（Windows）：
///
/// 1. 台词栏开着：右侧按阅读顺序列出本页两个气泡，悬停一条 = 页上描边对应气泡；
/// 2. 在台词栏里点字 → 走现有 OCR 命中 → 查词面板弹出（测试词典收「猫」），
///    选区带句子上下文与页号（与在图上点字同一份 payload 来源）；
/// 3. Z → 逐格读：视图缩放到当前气泡；← 跳到下一个气泡；Esc 退出逐格读、不退书。
///
/// 鼠标输入经 DevTools 协议 `Input.dispatchMouseEvent` 投进正文 WebView（真 Chromium
/// 输入管线，页面收到真 pointer 事件）；Esc 走 Flutter 焦点链（`sendKeyEvent`）。
/// 证据：正文 WebView 的 CDP 截图（放大层是 DOM，只有它拍得到）+ 根帧截图。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

Map<String, Object?> _json(Object? raw) =>
    (jsonDecode(raw! as String) as Map).cast<String, Object?>();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('台词栏点字查词 → Z 逐格读 → ← 跳气泡 → Esc 退出', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    expect(await seedDictionary(tester), isTrue, reason: '测试词典要装上');

    final Directory bookDir = Directory.systemTemp.createTempSync(
      'manga_bubble_focus_',
    );
    const TestImageGenerator gen = TestImageGenerator();
    final Directory images = Directory(p.join(bookDir.path, 'images'))
      ..createSync();
    File(
      p.join(images.path, 'p001.png'),
    ).writeAsBytesSync(gen.pngBytes(width: 800, height: 1200, seed: 7));
    // 竖排气泡「猫が好き」：一列四字，字格由 lines_coords 切出。
    File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{
            'url': 'p001.png',
            'width': 800,
            'height': 1200,
            'blocks': <Object?>[
              <String, Object?>{
                'box': <double>[520, 160, 580, 400],
                'vertical': true,
                'font_size': 56,
                'lines': <String>['猫が好き'],
                'lines_coords': <Object?>[
                  <Object?>[
                    <double>[520, 160],
                    <double>[580, 160],
                    <double>[580, 400],
                    <double>[520, 400],
                  ],
                ],
              },
              <String, Object?>{
                'box': <double>[120, 760, 200, 1000],
                'vertical': true,
                'font_size': 56,
                'lines': <String>['猫だよ'],
                'lines_coords': <Object?>[
                  <Object?>[
                    <double>[120, 760],
                    <double>[200, 760],
                    <double>[200, 1000],
                    <double>[120, 1000],
                  ],
                ],
              },
            ],
          },
        ],
      }),
    );
    const String bookKey = 'bubble-focus-manga';
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'bubble zoom',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );

    final String spreadBefore = appModel.mangaSpreadPreference;
    final MangaReaderPreferences prefsBefore = appModel.mangaReaderPreferences;
    await appModel.setMangaReaderPreferences(
      prefsBefore.copyWithJson(<String, Object?>{'bubbleTextStrip': true}),
    );
    final NavigatorState nav = appModel.navigatorKey.currentState!;
    try {
      await appModel.setMangaSpreadPreference('single');
      final BuildContext navContext = nav.context;
      if (!navContext.mounted) fail('navigator context unmounted');
      unawaited(
        nav.push(
          adaptivePageRoute<void>(
            context: navContext,
            builder: (BuildContext context) => const FushiAppUiScaleNeutralizer(
              child: MangaFushiPage(item: null, bookKey: bookKey),
            ),
          ),
        ),
      );
      final dynamic reader = await _waitForReader(tester);

      Future<Uint8List?> capture() async =>
          await reader.debugCaptureWebView() as Uint8List?;
      Future<Map<String, Object?>> js(String body) async =>
          _json(await reader.debugEvaluateJavascript('JSON.stringify($body)'));
      Future<void> mouse(String type, double x, double y) async {
        await reader.debugCallDevToolsProtocolMethod(
          'Input.dispatchMouseEvent',
          <String, dynamic>{
            'type': type,
            'x': x,
            'y': y,
            'button': type == 'mouseMoved' ? 'none' : 'left',
            'buttons': type == 'mousePressed' ? 1 : 0,
            'clickCount': type == 'mouseMoved' ? 0 : 1,
            'pointerType': 'mouse',
          },
        );
      }

      // 1. 台词栏：两条，阅读顺序（RTL：右上「猫が好き」在前）。
      Map<String, Object?> panel = <String, Object?>{};
      for (int i = 0; i < 20; i++) {
        panel = await js(
          '(function(){var el=document.querySelector(".manga-text-strip.manga-ts-panel");'
          'if(!el)return {items:0};var it=el.querySelectorAll(".manga-ts-item");'
          'var r=el.getBoundingClientRect();'
          'var c=it.length?it[0].querySelector(".ocr-char").getBoundingClientRect():null;'
          'return {items:it.length,first:it.length?it[0].textContent:"",'
          'left:r.left,width:r.width,'
          'cx:c?c.left+c.width/2:0,cy:c?c.top+c.height/2:0};})()',
        );
        if ((panel['items']! as num) >= 2) break;
        await tester.pump(const Duration(milliseconds: 250));
      }
      debugPrint('[bubble-focus] panel=$panel');
      expect(panel['items'], 2, reason: '台词栏应列出本页两个气泡');
      expect('${panel['first']}', contains('猫が好き'));
      // 悬停第一条 → 原图上的气泡描边。
      final double px = (panel['cx']! as num).toDouble();
      final double py = (panel['cy']! as num).toDouble();
      await mouse('mouseMoved', px, py);
      await tester.pump(const Duration(milliseconds: 300));
      final Map<String, Object?> hovered = await js(
        '{outlined: document.querySelectorAll(".manga-page .ocr-box.manga-ts-hover").length,'
        ' zoomOpen: window.__mangaBubbleZoomOpen()}',
      );
      debugPrint('[bubble-focus] hovered=$hovered');
      expect(hovered['outlined'], 1, reason: '悬停台词 = 页上描边对应气泡');
      expect(hovered['zoomOpen'], isFalse, reason: '台词栏上不弹气泡放大');
      expect(
        (await captureWebViewWith('B01-text-panel-hover', capture)).saved,
        isTrue,
      );

      // 2. 台词栏里点「猫」→ 查词。
      await mouse('mousePressed', px, py);
      await mouse('mouseReleased', px, py);
      bool shown = false;
      for (int i = 0; i < 40 && !shown; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        shown = reader.isDictionaryShown as bool;
      }
      final Map<String, Object?> afterTap = await js(
        '(function(){var s=window.fushiSelection&&window.fushiSelection.selection;'
        'var n=s&&s.startNode;var el=n&&(n.nodeType===1?n:n.parentElement);'
        'var sent=el&&el.closest("[data-manga-sentence]");'
        'var pg=el&&el.closest(".manga-page, .manga-zoom-page");'
        'return {hit: window.__mangaLastOcrHit || null,'
        'inPanel: !!(el&&el.closest(".manga-text-strip")),'
        'sentence: sent?sent.getAttribute("data-manga-sentence"):null,'
        'page: pg?pg.getAttribute("data-page"):null};})()',
      );
      debugPrint('[bubble-focus] shown=$shown afterTap=$afterTap');
      expect(shown, isTrue, reason: '台词栏里点字应弹出查词面板');
      expect((afterTap['hit']! as Map)['text'], '猫');
      expect(afterTap['inPanel'], isTrue);
      expect('${afterTap['sentence']}', contains('猫が好き'));
      expect(afterTap['page'], '0');
      await tester.pump(const Duration(seconds: 1));
      expect(
        (await captureWebViewWith('B02-text-panel-lookup', capture)).saved,
        isTrue,
      );
      expect(
        (await captureFlutterFrame(
          tester,
          'B02-text-panel-lookup-frame',
        )).saved,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 600));
      expect(reader.isDictionaryShown as bool, isFalse);

      // 3. Z → 逐格读（第一个气泡），← 跳下一个（RTL），Esc 退出不退书。
      await mouse('mouseMoved', 5, 5);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pump(const Duration(milliseconds: 800));
      final Map<String, Object?> focused = await js(
        'window.__mangaFocusState()',
      );
      debugPrint('[bubble-focus] focused=$focused');
      expect(focused['on'], isTrue, reason: 'Z 进入逐格读');
      expect(focused['key'], '0:0');
      expect((focused['zoom']! as num).toDouble(), greaterThan(1.0));
      expect(
        (await captureWebViewWith('B03-focus-first', capture)).saved,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 800));
      final Map<String, Object?> stepped = await js(
        'window.__mangaFocusState()',
      );
      debugPrint('[bubble-focus] stepped=$stepped');
      expect(stepped['on'], isTrue);
      expect(stepped['key'], '0:1', reason: 'RTL 书 ← = 下一个气泡');
      expect(
        (await captureWebViewWith('B04-focus-next', capture)).saved,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 800));
      final Map<String, Object?> exited = await js(
        'window.__mangaFocusState()',
      );
      final bool readerStillUp = find
          .byType(MangaFushiPage)
          .evaluate()
          .isNotEmpty;
      debugPrint('[bubble-focus] exited=$exited readerStillUp=$readerStillUp');
      expect(exited['on'], isFalse, reason: 'Esc 退出逐格读');
      expect(readerStillUp, isTrue, reason: 'Esc 先退逐格读，不退书');
      expect(
        (await captureWebViewWith('B05-focus-exit', capture)).saved,
        isTrue,
      );
    } finally {
      await appModel.setMangaSpreadPreference(spreadBefore);
      await appModel.setMangaReaderPreferences(prefsBefore);
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    }
  });
}

Future<dynamic> _waitForReader(WidgetTester tester) async {
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find
        .byKey(const ValueKey<String>('manga_content_ready'))
        .evaluate()
        .isNotEmpty) {
      break;
    }
  }
  final dynamic reader = tester.state(find.byType(MangaFushiPage));
  // 等 WebView 文档与 OCR 层就绪。
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final Object? raw = await reader.debugEvaluateJavascript(
      "document.querySelectorAll('.manga-page .ocr-char').length",
    );
    final num? count = raw is num ? raw : num.tryParse('$raw');
    if (count != null && count > 0) break;
  }
  await tester.pump(const Duration(seconds: 1));
  return reader;
}
