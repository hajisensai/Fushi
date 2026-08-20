import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

/// 漫画覆盖层里两条「同一件事只许有一个实现」的不变式（BUG-1750 复审）。
///
/// 1. 平移只有 _panBy 一个入口。右键拖动是桌面上的主力平移手势，此前它手抄了一份
///    PAN_X += dx / PAN_Y += dy / _applyCanvas()，于是同时绕过 _clampPan（右键能把
///    页面推出视口且回不来，左键会回弹）和 webtoon 的纵向分流（PAN_Y 被写成非 0 ->
///    onMangaScroll 与 __mangaScrollToSpread 都按 PAN_Y=0 用 scrollY/ZOOM 换算
///    offsetTop -> 进度落库与恢复错页；而 _clampPan 有意不碰 webtoon 的 PAN_Y，
///    于是永远拉不回来）。
/// 2. 首次定位必须无过渡落位。RTL 是默认阅读方向，倒序写入后 spread 0 的 offsetLeft
///    是 (n-1)x100vw，而 #manga-root 在 slide（默认动画）下带 transition:transform，
///    _initPosition 又挂在双 rAF 上（正是「保证过渡一定触发」的惯用法）—— 打开任何
///    RTL 书都会先看到整卷从最后一页扫回第一页。
MokuroImage _page(String url) => MokuroImage(
      url: url,
      size: const Size(1000, 1400),
      blocks: const <MokuroBlock>[],
    );

String _doc({
  MangaReadingMode mode = MangaReadingMode.spread,
  String direction = 'rtl',
  MangaPageAnimation animation = MangaPageAnimation.slide,
  int zoomPercent = 100,
}) =>
    mangaWindowDocument(
      <MokuroImage>[_page('p1.jpg'), _page('p2.jpg'), _page('p3.jpg')],
      <String>['p1.jpg', 'p2.jpg', 'p3.jpg'],
      mode: mode,
      spreadDirection: direction,
      inlineSelectionJs: '',
      pageAnimation: animation,
      zoomPercent: zoomPercent,
    );

/// 截出右键拖动那一支（起止锚点都是全文档唯一字面量）。
String _rightDragBranch(String doc) {
  const String head = 'if (rightDrag.moved && ZOOM > 1) {';
  const String tail = 'e.preventDefault();';
  final int start = doc.indexOf(head);
  expect(start, isNot(-1), reason: '右键拖动分支的锚点不在了，先确认它没被改名');
  final int end = doc.indexOf(tail, start);
  expect(end, isNot(-1));
  return doc.substring(start, end);
}

/// 截出 _initPosition 的函数体（结束锚点是缩进 2 的右花括号，函数内所有块都更深）。
String _initPositionBody(String doc) {
  const String head = 'function _initPosition(){';
  final int start = doc.indexOf(head);
  expect(start, isNot(-1));
  final int end = doc.indexOf('\n  }', start);
  expect(end, isNot(-1));
  return doc.substring(start, end);
}

void main() {
  group('平移只有 _panBy 一个入口', () {
    test('右键拖动走 _panBy，分支里不许自己写 PAN_X / PAN_Y / _applyCanvas', () {
      final String branch = _rightDragBranch(_doc());
      // 断言字面量：'_panBy(dx, dy);'
      expect(branch.contains('_panBy(dx, dy);'), isTrue,
          reason: '右键拖动必须复用 _panBy（含 _clampPan 与 webtoon 纵向分流），'
              '不能手抄一份平移公式');
      expect(branch.contains('PAN_X +='), isFalse,
          reason: '手抄 PAN_X += dx 就绕过了 _clampPan：右键能把页面推出视口且回不来');
      expect(branch.contains('PAN_Y +='), isFalse,
          reason: '手抄 PAN_Y += dy 会在 webtoon 下把 PAN_Y 写成非 0，'
              '进度落库与恢复按 PAN_Y=0 换算 offsetTop -> 错页');
      expect(branch.contains('_applyCanvas()'), isFalse,
          reason: '直接 _applyCanvas 等于跳过钳制后再提交，钳制形同虚设');
    });

    test('整份文档里 PAN_X / PAN_Y 的增量写入只出现在 _panBy 内', () {
      for (final MangaReadingMode mode in MangaReadingMode.values) {
        final String doc = _doc(mode: mode, zoomPercent: 150);
        // 断言字面量：'PAN_X += dx;' 恰好 2 次（_panBy 的 webtoon 支与 spread 支），
        // 'PAN_Y += dy;' 恰好 1 次（只有 _panBy 的 spread 支；webtoon 纵向归 scrollY）。
        expect('PAN_X += dx;'.allMatches(doc).length, 2,
            reason: '$mode：PAN_X 的增量写入只许在 _panBy 里出现两支');
        expect('PAN_Y += dy;'.allMatches(doc).length, 1,
            reason: '$mode：PAN_Y 的增量写入只许在 _panBy 的 spread 支里出现一次');
        expect(
            doc.contains('if (canvasMoved) { _clampPan(); _applyCanvas(); }'),
            isTrue,
            reason: '$mode：唯一的平移提交口必须带钳制');
      }
    });
  });

  group('首次定位无过渡落位', () {
    test('_initPosition 关过渡 -> 写 transform -> 强制 reflow -> 还原', () {
      final String body = _initPositionBody(_doc());
      // 断言字面量："root.style.transition = 'none';" / 'void root.offsetHeight;'
      // / 'root.style.transition = prevTransition;'
      final int off = body.indexOf("root.style.transition = 'none';");
      final int apply = body.indexOf('window.__mangaApplyTranslate(CURRENT);');
      final int reflow = body.indexOf('void root.offsetHeight;');
      final int restore =
          body.indexOf('root.style.transition = prevTransition;');
      expect(off, isNot(-1),
          reason: 'RTL 倒序后首帧要把 root 推过整卷长度，带着 transition 就是一次'
              '从最后一页扫回第一页的动画');
      expect(apply, isNot(-1));
      expect(reflow, isNot(-1),
          reason: '必须读一次布局属性强制同步 reflow，新 transform 才会成为后续过渡的起点');
      expect(restore, isNot(-1), reason: '还原原过渡值，不能把翻页动画永久关掉');
      expect(off < apply, isTrue, reason: '过渡必须在写 transform 之前关掉');
      expect(apply < reflow, isTrue);
      expect(reflow < restore, isTrue, reason: '还原必须发生在强制 reflow 之后');
    });

    test('翻页动画本身不受影响：slide 仍声明 transition:transform', () {
      expect(_doc().contains('transition:transform '), isTrue,
          reason: '只是首次定位不走过渡，翻页动画偏好照旧生效');
      expect(
          _doc(animation: MangaPageAnimation.none)
              .contains('transition:transform '),
          isFalse);
    });

    test('webtoon 分支直接返回，不碰 root 的过渡', () {
      final String body =
          _initPositionBody(_doc(mode: MangaReadingMode.webtoon));
      final int scroll = body
          .indexOf('window.__mangaScrollToSpread(CURRENT, RESTORE_FRACTION);');
      final int ret = body.indexOf('return;');
      expect(scroll, isNot(-1));
      expect(ret > scroll, isTrue,
          reason: 'webtoon 定位后必须直接返回，别再往下跑 spread 的 transform 逻辑');
    });
  });
}
