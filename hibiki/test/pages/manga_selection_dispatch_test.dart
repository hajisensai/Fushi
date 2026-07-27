import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/manga_hibiki_page.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';

void main() {
  group('dispatchMangaSelection', () {
    test('设置框内句子并用扫描词 + 其矩形发起查词', () async {
      String? capturedSentence;
      String? capturedTerm;
      Rect? capturedRect;

      final ReaderSelectionData data = ReaderSelectionData.fromJson(
        <String, dynamic>{
          'text': '世界',
          'sentence': 'この世界は美しい。',
          'rect': <String, dynamic>{
            'x': 30.0,
            'y': 40.0,
            'width': 12.0,
            'height': 16.0,
          },
        },
      );

      await dispatchMangaSelection(
        data,
        fallbackScreen: const Size(800, 600),
        setSentence: (String s) => capturedSentence = s,
        search: (String term, Rect rect) async {
          capturedTerm = term;
          capturedRect = rect;
        },
      );

      expect(capturedSentence, 'この世界は美しい。');
      expect(capturedTerm, '世界');
      expect(capturedRect, const Rect.fromLTWH(30.0, 40.0, 12.0, 16.0));
    });

    test('空 text payload 是 no-op（不设句、不查词）', () async {
      bool searched = false;
      bool sentenceSet = false;

      final ReaderSelectionData data = ReaderSelectionData.fromJson(
        <String, dynamic>{'text': '', 'sentence': ''},
      );

      await dispatchMangaSelection(
        data,
        fallbackScreen: const Size(400, 400),
        setSentence: (_) => sentenceSet = true,
        search: (_, __) async => searched = true,
      );

      expect(sentenceSet, isFalse);
      expect(searched, isFalse);
    });

    test('无 rect payload 锚到屏幕中心 1x1（块级兜底）', () async {
      Rect? capturedRect;
      final ReaderSelectionData data = ReaderSelectionData.fromJson(
        <String, dynamic>{'text': '词', 'sentence': '词のある句。'},
      );
      await dispatchMangaSelection(
        data,
        fallbackScreen: const Size(800, 600),
        setSentence: (_) {},
        search: (_, Rect rect) async => capturedRect = rect,
      );
      expect(capturedRect, isNotNull);
      expect(capturedRect!.center, const Offset(400, 300));
      expect(capturedRect!.width, 1);
      expect(capturedRect!.height, 1);
    });
  });

  // 收敛不变式守卫（ERRATA H2/C1）：选区 handler / pointerup 监听全工程唯一，
  // 防串框契约——漫画页与 EPUB 阅读器各自恰好一个 onTextSelected 注册点。
  group('选词路径收敛不变式（ERRATA H2/C1）', () {
    test('漫画页恰好注册一个 onTextSelected JS handler', () {
      final File page = File(
        'lib/src/media/manga/reader/manga_hibiki_page.dart',
      );
      expect(page.existsSync(), isTrue);
      final String src = page.readAsStringSync();
      final int handlerCount =
          "handlerName: 'onTextSelected'".allMatches(src).length;
      expect(handlerCount, 1,
          reason: '漫画页是其 onTextSelected handler 的唯一所有者；'
              '恰好一处注册（多注册会把同一 payload 双发查词）');
    });

    test('漫画页绝不再挂第二个 pointerup JS 监听', () {
      final File page = File(
        'lib/src/media/manga/reader/manga_hibiki_page.dart',
      );
      final String src = page.readAsStringSync();
      // 全工程唯一的 pointerup 选词监听内嵌在 manga_overlay_html（mangaWindowDocument）。
      expect(src.contains("addEventListener('pointerup'"), isFalse);
      expect(src.contains('addEventListener("pointerup"'), isFalse);
    });

    test('唯一 pointerup 监听只在 manga_overlay_html，且选词调用显式传 maxLength',
        () {
      final File overlay = File(
        'lib/src/media/manga/manga_overlay_html.dart',
      );
      expect(overlay.existsSync(), isTrue);
      final String src = overlay.readAsStringSync();
      final int pointerupCount =
          'addEventListener("pointerup"'.allMatches(src).length +
              "addEventListener('pointerup'".allMatches(src).length;
      expect(pointerupCount, 1,
          reason: 'manga_overlay_html.dart 必须持有唯一的 pointerup 监听');
      // 这条守卫防的是「选词调用漏传 maxLength → 扫描循环 gate `< undefined`
      // 恒假 → text 恒空 → onTextSelected 永不触发」。
      //
      // PR#474 把 OCR 命中层从「按坐标猜节点」的 `selectText(x, y, 40, false)`
      // 换成字级路径：命中层自己定位到字符节点，再直接调
      // `selectFromPosition(node, offset, maxLength, x, y)`
      // （`reader_selection_scripts.dart:1036`）。选词入口换了函数，但
      // **maxLength 仍是必传参数、漏传仍然会哑火**，危险一点没变，所以这里换靶
      // 不放宽：仍然要求全文件恰好一处选词调用，且 maxLength 显式写成 40。
      final RegExp selectRe = RegExp(
        r'selection\.selectFromPosition\(\s*node\s*,\s*0\s*,\s*40\s*,\s*x\s*,\s*y\s*\)',
      );
      expect(selectRe.allMatches(src).length, 1,
          reason: '选词必须是唯一调用点，且显式传 maxLength=40');
      expect(src.contains('hoshiSelection.selectText('), isFalse,
          reason: '旧的按坐标猜节点入口已下线，不得复活成第二条选词路径');
    });
  });
}
