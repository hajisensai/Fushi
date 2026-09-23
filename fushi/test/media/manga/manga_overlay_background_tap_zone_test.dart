import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

const MokuroImage _page = MokuroImage(
  url: 'p001.jpg',
  size: MokuroSize(1000, 1400),
  blocks: <MokuroBlock>[],
);

String _doc({
  MangaReadingMode mode = MangaReadingMode.spread,
  String spreadDirection = 'rtl',
  MangaTapZoneLayout tapZoneLayout = MangaTapZoneLayout.leftRight,
  bool tapZonePaging = true,
  String backgroundCss = '#000',
}) {
  return mangaWindowDocument(
    <MokuroImage>[_page],
    <String>['manga.local/0/p001.jpg'],
    mode: mode,
    spreadDirection: spreadDirection,
    inlineSelectionJs: ReaderSelectionScripts.source(),
    tapZoneLayout: tapZoneLayout,
    tapZonePaging: tapZonePaging,
    backgroundCss: backgroundCss,
  );
}

void main() {
  group('底色注入', () {
    test('默认仍是黑底（不改变旧行为）', () {
      expect(_doc().contains('background:#000'), isTrue);
    });

    test('白 / 灰 / 主题色都原样进 html,body', () {
      expect(_doc(backgroundCss: '#fff').contains('background:#fff'), isTrue);
      expect(
        _doc(backgroundCss: '#2b2b2b').contains('background:#2b2b2b'),
        isTrue,
      );
      expect(
        _doc(
          backgroundCss: 'rgb(18,18,18)',
        ).contains('background:rgb(18,18,18)'),
        isTrue,
      );
    });

    test('底色不再有第二处硬编码的 #000', () {
      // 旧实现把黑底写死在 html,body 里；换成白底后文档里不该再残留一处 #000
      // 背景声明，否则会在某个层级把页图周围重新刷黑。
      final String doc = _doc(backgroundCss: '#fff');
      expect(
        doc.contains('background:#000'),
        isFalse,
        reason: '白底档下不得残留任何 background:#000',
      );
    });
  });

  group('点击热区注入', () {
    test('热区表是 Dart 算好的字面量，JS 只遍历', () {
      final String doc = _doc();
      expect(doc.contains('var TAP_ZONES = ['), isTrue);
      // 遍历命中，而不是在 JS 里重算阈值/镜像。
      expect(
        doc.contains('for (var i = 0; i < TAP_ZONES.length; i++)'),
        isTrue,
      );
      expect(
        doc.contains('var TAP_ZONE = 0.25'),
        isFalse,
        reason: '旧的 JS 内硬编码阈值必须已被表驱动取代',
      );
    });

    test('RTL 的镜像已经烘进注入的表（JS 不再二次镜像）', () {
      // RTL leftRight：左竖条 forward=true。注入串里第一项即左竖条。
      final String rtl = _doc(spreadDirection: 'rtl');
      expect(
        rtl.contains('[0,0,0.25,1,true]'),
        isTrue,
        reason: 'RTL 下左竖条必须是前进',
      );
      final String ltr = _doc(spreadDirection: 'ltr');
      expect(
        ltr.contains('[0,0,0.25,1,false]'),
        isTrue,
        reason: 'LTR 下左竖条必须是后退',
      );
    });

    test('换布局真的换表：topBottom 注入上下半屏而非左右竖条', () {
      final String doc = _doc(tapZoneLayout: MangaTapZoneLayout.topBottom);
      expect(doc.contains('[0,0,1,0.5,'), isTrue);
      expect(doc.contains('[0,0.5,1,0.5,'), isTrue);
      expect(doc.contains('[0,0,0.25,1,'), isFalse);
    });

    test('lShaped 注入三块（两竖条 + 下横条），竖条在前', () {
      final String doc = _doc(tapZoneLayout: MangaTapZoneLayout.lShaped);
      final int left = doc.indexOf('[0,0,0.25,1,');
      final int bottom = doc.indexOf('[0.25,0.75,0.5,0.25,');
      expect(left, greaterThanOrEqualTo(0));
      expect(bottom, greaterThan(left), reason: '下横条必须排在竖条之后，否则左下角判成前进');
    });

    test('关掉点击翻页时 JS 直接短路（表仍在但不生效）', () {
      final String doc = _doc(tapZonePaging: false);
      expect(doc.contains('var TAP_ZONE_PAGING = false'), isTrue);
      expect(doc.contains('if (!TAP_ZONE_PAGING) return null;'), isTrue);
    });

    test('webtoon 的热区改为滚动，不发 onMangaTurn', () {
      final String doc = _doc(mode: MangaReadingMode.webtoon);
      expect(doc.contains('function _tapScroll(dir)'), isTrue);
      expect(
        doc.contains('if (IS_WEBTOON) { _tapScroll('),
        isTrue,
        reason: 'webtoon 命中热区必须滚动而不是翻页',
      );
      // 旧实现是 webtoon 直接 return null（点击完全没有翻页/滚动手段）。
      expect(
        doc.contains('if (!TAP_ZONE_PAGING || IS_WEBTOON) return null;'),
        isFalse,
      );
    });
  });

  group('双击缩放', () {
    test('注入双击判定，且不给查词/热区单击加延迟', () {
      final String doc = _doc();
      expect(doc.contains('function _consumeDoubleTap(x, y)'), isTrue);
      expect(doc.contains('var DBL_MS = 300'), isTrue);
      // 查词响应速度是用户明确抱怨过的一项：不得为了等第二击而 setTimeout 单击。
      expect(
        doc.contains('setTimeout(function(){ _onTap'),
        isFalse,
        reason: '单击不得被延迟去等双击',
      );
      // 查词与热区在双击判定之前就 return，不经过任何定时器。
      final int selectAt = doc.indexOf(
        'if (_selectOcrChar(x, y, false)) return;',
      );
      final int deferAt = doc.indexOf('_deferEmptyTap();');
      expect(selectAt, greaterThanOrEqualTo(0));
      expect(deferAt, greaterThan(selectAt));
    });

    test('空白单击的 onTapEmpty 延后发出，第二击到达即取消', () {
      // onTapEmpty 在 Dart 侧会切换悬浮栏；若第一击立刻上报，默认悬浮态下每次
      // 双击缩放都会连带闪一次顶栏/底栏。
      final String doc = _doc();
      expect(doc.contains('function _deferEmptyTap()'), isTrue);
      expect(doc.contains('function _cancelPendingEmptyTap()'), isTrue);
      expect(
        doc.contains("if (b) b.callHandler('onTapEmpty');"),
        isTrue,
        reason: 'onTapEmpty 只能从延后的定时器里发出',
      );
      expect(
        doc.contains('if (IS_WEBTOON && !true)'),
        isTrue,
        reason: '只有显式关闭长条漫双击后才同步上报空白点击，默认仍延后',
      );
      final int dblAt = doc.indexOf('if (_consumeDoubleTap(x, y)) {');
      final int cancelAt = doc.indexOf('_cancelPendingEmptyTap();', dblAt);
      final int zoomAt = doc.indexOf('_doubleTapZoom(x,y);', dblAt);
      expect(dblAt, greaterThanOrEqualTo(0));
      expect(cancelAt, greaterThan(dblAt));
      expect(zoomAt, greaterThan(cancelAt), reason: '第二击先取消挂起的 onTapEmpty 再缩放');
    });

    test('双击只在没命中 OCR 字、也没命中翻页热区时才缩放', () {
      final String doc = _doc();
      final int selectAt = doc.indexOf(
        'if (_selectOcrChar(x, y, false)) return;',
      );
      final int zoneAt = doc.indexOf('var zone = _tapZoneTurn(x, y);');
      final int dblAt = doc.indexOf('if (_consumeDoubleTap(x, y)) {');
      expect(selectAt, greaterThanOrEqualTo(0));
      expect(zoneAt, greaterThan(selectAt));
      expect(dblAt, greaterThan(zoneAt), reason: '双击判定必须排在选词与热区之后，否则会抢走查词/翻页');
    });

    test('在贴合与 2× 之间切换', () {
      expect(_doc().contains('var target=ZOOM>1.01 ? 1 : 2;'), isTrue);
    });
  });
}
