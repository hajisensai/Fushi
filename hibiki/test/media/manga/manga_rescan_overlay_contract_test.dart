/// P4 单框补扫：覆盖层生成器的 JS 协议契约（源码断言，照
/// manga_overlay_html_test.dart 风格）。
///
/// 锚定的协议：
/// - Dart→JS 挂点 `window.__mangaSetRescanMode(true/false)`；
/// - JS→Dart handler 名 `onMangaBoxSelected`（payload =
///   `{pageIndex, left, top, right, bottom}`，页图像素坐标）；
/// - 页 div 带 `data-page`（0-based 整卷页码）与 `data-pw`/`data-ph`
///   （页图原始像素尺寸）——视口矩形 → 页图像素的线性映射参数；
/// - 框太小（任一维 < 8 视口 px）忽略；
/// - 模式内查词 tap / swipe / 滚轮翻页旁路。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

MokuroImage _page({double w = 1000, double h = 1600}) {
  return MokuroImage(
    url: 'p001.jpg',
    size: Size(w, h),
    blocks: const <MokuroBlock>[],
  );
}

String _doc({List<int>? pageNumbers}) {
  return mangaWindowDocument(
    <MokuroImage>[_page(), _page(w: 900, h: 1200)],
    <String>[
      'https://manga.local/img/p001.jpg',
      'https://manga.local/img/p002.jpg'
    ],
    mode: MangaReadingMode.spread,
    spreadDirection: 'rtl',
    inlineSelectionJs: '/* selection */',
    pageNumbers: pageNumbers,
  );
}

void main() {
  group('补扫模式 JS 协议', () {
    test('窗口文档含 __mangaSetRescanMode 挂点与 onMangaBoxSelected handler 名', () {
      final String doc = _doc();
      expect(doc.contains('window.__mangaSetRescanMode'), isTrue,
          reason: 'Dart 进入/退出补扫模式的唯一 JS 挂点');
      expect(doc.contains("callHandler('onMangaBoxSelected'"), isTrue,
          reason: 'JS→Dart 框选回传的唯一 handler 名');
    });

    test('payload 字段契约：pageIndex + left/top/right/bottom（页图像素坐标）', () {
      final String doc = _doc();
      expect(doc.contains('pageIndex: pageIndex'), isTrue);
      for (final String field in <String>[
        'left:',
        'top:',
        'right:',
        'bottom:'
      ]) {
        expect(doc.contains(field), isTrue,
            reason: 'onMangaBoxSelected payload 必须带 $field');
      }
      // 换算参数来自页 div 的 data-pw/data-ph（线性映射到页图像素）。
      expect(doc.contains("getAttribute('data-pw')"), isTrue);
      expect(doc.contains("getAttribute('data-ph')"), isTrue);
      expect(doc.contains("getAttribute('data-page')"), isTrue);
    });

    test('页 div 携带 data-page（真实整卷页码）与 data-pw/data-ph（页图像素尺寸）', () {
      final String doc = _doc(pageNumbers: <int>[3, 4]);
      expect(doc.contains('data-page="3"'), isTrue,
          reason: '窗口化文档里 data-page 必须是整卷页码而非数组序');
      expect(doc.contains('data-page="4"'), isTrue);
      expect(doc.contains('data-pw="1000" data-ph="1600"'), isTrue);
      expect(doc.contains('data-pw="900" data-ph="1200"'), isTrue);
    });

    test('缺省 pageNumbers 时 data-page 退回数组序（webtoon 全量渲染两者一致）', () {
      final String doc = _doc();
      expect(doc.contains('data-page="0"'), isTrue);
      expect(doc.contains('data-page="1"'), isTrue);
    });

    test('太小的框（任一维 < 8 视口 px）忽略', () {
      final String doc = _doc();
      expect(doc.contains('< 8'), isTrue, reason: '框太小(<8px)忽略——协议规定的最小框尺寸');
    });

    test('模式内旁路：pointerdown/pointerup 先走 rescan 分支，滚轮翻页被 RESCAN 挡下', () {
      final String doc = _doc();
      // pointerup 的 rescan 分支必须在 _end（tap/swipe 消歧）之前 return。
      expect(
          doc.contains(
              'if (RESCAN) { _rescanFinish(e.clientX, e.clientY); return; }'),
          isTrue,
          reason: '模式内 pointerup 独占给框选，禁用查词 tap 与 swipe');
      expect(
          doc.contains(
              'if (RESCAN) { rescanStart = {x: e.clientX, y: e.clientY}; return; }'),
          isTrue);
      // 滚轮翻页在模式内被挡（框选中不许翻走当前页）。
      final int wheelIdx = doc.indexOf("addEventListener('wheel'");
      expect(wheelIdx, greaterThan(0));
      final String wheelBody = doc.substring(wheelIdx, wheelIdx + 400);
      expect(wheelBody.contains('if (RESCAN) return;'), isTrue,
          reason: '补扫模式内滚轮翻页必须旁路');
    });

    test('橡皮筋矩形视觉反馈存在（fixed 半透明框，pointer-events:none）', () {
      final String doc = _doc();
      expect(doc.contains('manga-rescan-rect'), isTrue);
      expect(doc.contains('pointer-events:none'), isTrue);
    });
  });
}
