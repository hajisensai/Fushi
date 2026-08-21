import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

/// 漫画覆盖层三条注入层不变式（Discord 反馈第二轮）。
///
/// 1. BUG-1758：布局全走视口单位（100vw/100vh），但 translateX / PAN / scrollY 是
///    加载或手势那一刻由旧视口换算出的 px 投影。resize 后必须把语义真值（CURRENT
///    跨页 + RESTORE_FRACTION 页内偏移 + ZOOM/PAN）重投影成新视口的 px，否则窗口
///    一变就停在「随机页」上，翻一页才被现场重测救回。
/// 2. BUG-1759：#manga-canvas / #manga-root 不得常驻 will-change:transform——
///    Chromium 会把带该提示的层的栅格化尺度钉成只升不降，缩到 <100% 时拿旧尺度
///    纹理做无 mipmap 缩小全是锯齿，放大跨过旧尺度才重栅格。提升必须是手势/动画
///    期间临时挂、静止后摘除。
/// 3. BUG-1760：spread 放大态（ZOOM>1）滚轮必须平移优先——动得了就消费事件，
///    动不了（贴边）才落入翻页累计；否则放大阅读时滚轮全是误翻页。
MokuroImage _page(String url) => MokuroImage(
      url: url,
      size: const Size(1000, 1400),
      blocks: const <MokuroBlock>[],
    );

String _doc({
  MangaReadingMode mode = MangaReadingMode.spread,
}) =>
    mangaWindowDocument(
      <MokuroImage>[_page('p1.jpg'), _page('p2.jpg'), _page('p3.jpg')],
      <String>['p1.jpg', 'p2.jpg', 'p3.jpg'],
      mode: mode,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
    );

void main() {
  group('BUG-1758 resize 重投影', () {
    test('两种模式都注册 resize 监听并走 _reanchor 重投影', () {
      for (final MangaReadingMode mode in MangaReadingMode.values) {
        final String doc = _doc(mode: mode);
        expect(doc.contains("window.addEventListener('resize'"), isTrue,
            reason: '$mode：没有 resize 监听，窗口一变就停在旧 px 投影的错误页上');
        expect(doc.contains('function _reanchor()'), isTrue,
            reason: '$mode：摆位与 resize 重投影必须统一在 _reanchor（无过渡落位）');
        expect(doc.contains('if (_reanchorRaf) return;'), isTrue,
            reason: '$mode：拖窗口边框是 resize 风暴，必须 rAF 合并、每帧至多一次');
      }
    });

    test('resize 与重投影之间的窗口期挡住 webtoon 滚动上报', () {
      final String doc = _doc(mode: MangaReadingMode.webtoon);
      expect(doc.contains('if (_resizePending) return;'), isTrue,
          reason: '窗口期几何已新、scrollY 还旧，视觉停在错误页；此刻上报会把错页'
              '记成语义真值，重投影反而钉死漂移');
      expect(doc.contains('_resizePending = true;'), isTrue);
      expect(doc.contains('_resizePending = false;'), isTrue);
    });

    test('语义真值由投影与滚动上报维护，重投影按真值回位', () {
      final String spread = _doc();
      // 翻页/摆位投影记录当前跨页；resize 重投影按它回位。
      expect(spread.contains('CURRENT = target;'), isTrue,
          reason: '投影函数必须维护 CURRENT，否则 resize 只能回到开书时的恢复位置');
      final String webtoon = _doc(mode: MangaReadingMode.webtoon);
      expect(webtoon.contains('CURRENT = topPage;'), isTrue,
          reason: 'webtoon 语义真值必须跟随用户滚动');
      expect(webtoon.contains('RESTORE_FRACTION = fraction;'), isTrue);
    });
  });

  group('BUG-1759 栅格化尺度', () {
    test('样式表不得常驻 will-change（钉 CSS 规则形态）', () {
      for (final MangaReadingMode mode in MangaReadingMode.values) {
        final String doc = _doc(mode: mode);
        expect(doc.contains('will-change:transform;}'), isFalse,
            reason: '$mode：常驻 will-change 让栅格化尺度只升不降，缩小态永远拿旧'
                '尺度纹理做无 mipmap 缩小——锯齿的根因');
      }
    });

    test('提升改为手势期临时挂、静止后摘除', () {
      final String doc = _doc();
      expect(doc.contains('function _hintWillChange(el, ms)'), isTrue);
      expect(doc.contains('_hintWillChange(canvas, 200);'), isTrue,
          reason: '缩放/平移的唯一提交口 _applyCanvas 必须走临时提升');
      expect(doc.contains("el.style.willChange = '';"), isTrue,
          reason: '静止后必须摘除提示，层降级才会按当前 ZOOM 重栅格');
    });
  });

  group('BUG-1760 放大态滚轮平移优先', () {
    test('ZOOM>1 时滚轮先 _panBy，动了就消费掉本事件', () {
      final String doc = _doc();
      expect(doc.contains('_panBy(-wdx, -wdy);'), isTrue,
          reason: '放大态滚轮必须复用 _panBy（含钳制），不能直接翻页');
      expect(doc.contains('if (PAN_X !== px || PAN_Y !== py)'), isTrue,
          reason: '「动得了就消费」的判据：平移生效则本事件不进翻页累计');
    });

    test('贴边翻页仍走累计阈值 + 反向清账，不是一格就跨页', () {
      final String doc = _doc();
      expect(doc.contains('_wheelAccum += Math.abs(d);'), isTrue);
      expect(doc.contains('if (_wheelAccum < 40) return;'), isTrue,
          reason: '贴边后惯性一冲就翻页会把平移的收尾变成误翻，必须重新攒满阈值');
    });
  });
}
