/// 框选识别的 JS 契约：窗口文档必须暴露 `__mangaSetRescanMode` 门控、
/// `onMangaBoxSelected` 回传、页图像素坐标换算所需的 data 属性，以及模式内对
/// 查词 tap / swipe 翻页 / 滚轮翻页的旁路。
///
/// 这些是 Dart 侧唯一能验证的 JS 行为面：坐标换算错一位就回写到别的页，手势旁路
/// 漏一处就框选途中被翻页/查词抢走。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

const List<MokuroImage> _pages = <MokuroImage>[
  MokuroImage(
    url: 'p001.jpg',
    size: Size(1000, 1600),
    blocks: <MokuroBlock>[],
  ),
  MokuroImage(
    url: 'p002.jpg',
    size: Size(1000, 1600),
    blocks: <MokuroBlock>[],
  ),
];

String _document({
  MangaReadingMode mode = MangaReadingMode.spread,
  List<int>? pageNumbers,
}) {
  return mangaWindowDocument(
    _pages,
    const <String>[
      'https://manga.local/img/p001.jpg',
      'https://manga.local/img/p002.jpg',
    ],
    mode: mode,
    spreadDirection: 'rtl',
    inlineSelectionJs: '/* selection */',
    pageNumbers: pageNumbers,
  );
}

void main() {
  test('窗口文档暴露 __mangaSetRescanMode 门控与 onMangaBoxSelected 回传', () {
    final String document = _document();
    expect(document, contains('window.__mangaSetRescanMode'));
    expect(document, contains("callHandler('onMangaBoxSelected'"));
  });

  test('回传 payload 字段契约：pageIndex + left/top/right/bottom', () {
    final String document = _document();
    for (final String field in <String>[
      'pageIndex:',
      'left:',
      'top:',
      'right:',
      'bottom:',
    ]) {
      expect(document, contains(field));
    }
    // 换算读的是页 div 上的三个 data 属性；缺一个就只能拿到视口坐标。
    expect(document, contains("getAttribute('data-pw')"));
    expect(document, contains("getAttribute('data-ph')"));
    expect(document, contains("getAttribute('data-page')"));
  });

  test('页 div 携带真实整卷页码与页图像素尺寸（换算的两个自变量）', () {
    final String document = _document(pageNumbers: <int>[3, 4]);
    expect(document, contains('data-page="3"'));
    expect(document, contains('data-page="4"'));
    expect(document, contains('data-pw="1000"'));
    expect(document, contains('data-ph="1600"'));
  });

  test('缺省 pageNumbers 时 data-page 退回数组序', () {
    final String document = _document();
    expect(document, contains('data-page="0"'));
    expect(document, contains('data-page="1"'));
  });

  test('太小的框（任一维 < 8 视口 px）被忽略', () {
    final String document = _document();
    expect(
      document,
      contains(
        'if (Math.abs(x - start.x) < 8 || Math.abs(y - start.y) < 8) return;',
      ),
    );
  });

  test('模式内旁路：pointerdown/pointerup 先走框选分支', () {
    final String document = _document();
    expect(
      document,
      contains('if (RESCAN) { rescanStart = {x: e.clientX, y: e.clientY}; '
          'return; }'),
    );
    expect(
      document,
      contains('if (RESCAN) { _rescanFinish(e.clientX, e.clientY); return; }'),
      reason: '必须排在 _end 的 tap/swipe 消歧之前，否则松手被判成查词或翻页',
    );
  });

  test('模式内旁路：滚轮翻页被 RESCAN 挡下', () {
    final String document = _document();
    final int wheelAt = document.indexOf("addEventListener('wheel'");
    expect(wheelAt, greaterThan(0));
    // 两个 wheel 监听器（Ctrl 缩放 / spread 翻页）都必须在模式内早退。
    expect(
      RegExp(r'if \(RESCAN\) return;').allMatches(document).length,
      greaterThanOrEqualTo(3),
      reason: '两个 wheel + 一个 Shift 悬停查词，模式内都必须旁路',
    );
  });

  test('橡皮筋矩形存在且不吃指针事件（纯视觉反馈）', () {
    final String document = _document();
    expect(document, contains('manga-rescan-rect'));
    expect(document, contains('position:fixed;z-index:2147483647;'));
    expect(document, contains('pointer-events:none;'));
  });

  test('橡皮筋挂在 body 上，后台 OCR 热替换该页 OCR 层不会把它一起抹掉', () {
    final String document = _document();
    expect(
      document,
      contains('document.body.appendChild(rescanEl);'),
      reason: '挂进 .manga-page 的话，__mangaReplaceOcr 逐页热替换会连橡皮筋一起清掉',
    );
    // 反向：热替换只删该页的 .ocr-box，不删任何 rescan 节点。
    expect(document, contains("page.querySelectorAll('.ocr-box')"));
    expect(document, isNot(contains("querySelectorAll('#manga-rescan-rect')")));
  });

  test('指针被夺走（pointercancel）时清掉橡皮筋，不残留到下次拖拽', () {
    final String document = _document();
    expect(document, contains("addEventListener('pointercancel'"));
    expect(document, contains('if (RESCAN) _rescanClear();'));
  });

  test('webtoon 同样可用（原生触摸滚动全程关闭，竖滚抢不走拖框手势）', () {
    final String document = _document(mode: MangaReadingMode.webtoon);
    expect(document, contains('window.__mangaSetRescanMode'));
    // BUG-1701 起原生手势由 CSS 全程归 JS：浏览器在第一个 touchstart 就按当时的
    // touch-action 锁定手势，模式内再切换对已开始的手势无效。框选因此不再需要
    // 自己开关 touch-action，那个特例必须保持消除。
    expect(document, contains('touch-action:none;'));
    expect(document, isNot(contains('document.body.style.touchAction')));
  });
}
