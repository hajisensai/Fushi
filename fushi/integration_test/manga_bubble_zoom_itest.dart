/// 气泡原位放大（方案 A）真 app 取证（Windows）：
///
/// 1. 鼠标停在 OCR 气泡上 → 约 350ms 后原位弹出放大层；
/// 2. 在放大层里点字 → 走现有 OCR 命中 → 查词面板弹出（词典是生成的测试词典，
///    收「猫」）；
/// 3. Esc → 查词面板与放大层一起收起，不退出阅读器。
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

  testWidgets('悬停放大 → 放大层里点字查词 → Esc 收起', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    expect(await seedDictionary(tester), isTrue, reason: '测试词典要装上');

    final Directory bookDir = Directory.systemTemp.createTempSync(
      'manga_bubble_zoom_',
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
    const String bookKey = 'bubble-zoom-manga';
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

      // 1. 悬停：先停在空白，再移到第一个气泡中心，停 600ms。
      final Map<String, Object?> bubble = await js(
        '(function(){var r=document.querySelector(\'.manga-page .ocr-box[data-manga-block="0"]\').getBoundingClientRect();'
        'return {x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height};})()',
      );
      debugPrint('[bubble-zoom] bubble=$bubble');
      final double bx = (bubble['x']! as num).toDouble();
      final double by = (bubble['y']! as num).toDouble();
      await mouse('mouseMoved', 10, 10);
      await tester.pump(const Duration(milliseconds: 100));
      await mouse('mouseMoved', bx, by);
      // 只路过（200ms < 350ms）不弹。
      await tester.pump(const Duration(milliseconds: 200));
      final Map<String, Object?> early = await js(
        '{open: window.__mangaBubbleZoomOpen()}',
      );
      await tester.pump(const Duration(milliseconds: 600));
      final Map<String, Object?> opened = await js(
        '(function(){var l=document.querySelector(\'.manga-bubble-zoom\');'
        'if(!l)return {open:false};var r=l.getBoundingClientRect();'
        'var c=l.querySelector(\'.ocr-char\').getBoundingClientRect();'
        'return {open:window.__mangaBubbleZoomOpen(),w:r.width,h:r.height,'
        'cx:c.left+c.width/2,cy:c.top+c.height/2,cw:c.width,ch:c.height,'
        'chars:l.querySelectorAll(\'.ocr-char\').length};})()',
      );
      debugPrint('[bubble-zoom] early=$early opened=$opened');
      expect(early['open'], isFalse, reason: '停留不足 350ms 不应弹');
      expect(opened['open'], isTrue, reason: '停留 350ms 后应弹出放大层');
      final ObserveShot hoverShot = await captureWebViewWith(
        '01-bubble-zoom-hover',
        capture,
      );
      expect(hoverShot.saved, isTrue);

      // 2. 放大层里点「猫」。
      final double cx = (opened['cx']! as num).toDouble();
      final double cy = (opened['cy']! as num).toDouble();
      await mouse('mouseMoved', cx, cy);
      await mouse('mousePressed', cx, cy);
      await mouse('mouseReleased', cx, cy);
      bool shown = false;
      for (int i = 0; i < 40 && !shown; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        shown = reader.isDictionaryShown as bool;
      }
      final Map<String, Object?> afterTap = await js(
        '{open: window.__mangaBubbleZoomOpen(), hit: window.__mangaLastOcrHit || null}',
      );
      debugPrint('[bubble-zoom] shown=$shown afterTap=$afterTap');
      expect(shown, isTrue, reason: '放大层里点字应弹出查词面板');
      expect(afterTap['open'], isTrue, reason: '查词面板开着时放大层保持');
      expect((afterTap['hit']! as Map)['text'], '猫');
      await tester.pump(const Duration(seconds: 1));
      expect(
        (await captureWebViewWith('02-bubble-zoom-lookup-page', capture)).saved,
        isTrue,
      );
      expect(
        (await captureFlutterFrame(
          tester,
          '02-bubble-zoom-lookup-frame',
        )).saved,
        isTrue,
      );

      // 3. Esc：查词面板与放大层一起收起，不退出阅读器。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 600));
      final Map<String, Object?> afterEsc = await js(
        '{open: window.__mangaBubbleZoomOpen(), layers: document.querySelectorAll(\'.manga-bubble-zoom\').length}',
      );
      final bool readerStillUp = find
          .byType(MangaFushiPage)
          .evaluate()
          .isNotEmpty;
      debugPrint(
        '[bubble-zoom] afterEsc=$afterEsc dictShown=${reader.isDictionaryShown} '
        'readerStillUp=$readerStillUp',
      );
      expect(afterEsc['open'], isFalse, reason: 'Esc 应收起放大层');
      expect(reader.isDictionaryShown as bool, isFalse);
      expect(readerStillUp, isTrue, reason: 'Esc 先收放大层，不退出阅读器');
      expect(
        (await captureWebViewWith('03-bubble-zoom-esc', capture)).saved,
        isTrue,
      );
    } finally {
      await appModel.setMangaSpreadPreference(spreadBefore);
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
