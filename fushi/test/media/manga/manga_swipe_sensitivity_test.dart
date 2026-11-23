import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_swipe_thresholds.dart';
import 'package:fushi/src/reader/page_curl/page_curl.dart';
import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 拍板 R721ZgWVSB（选 b）：漫画单独一个「滑动翻页灵敏度」，值越大越灵敏，缩放跟手
/// （0.25 屏宽 / ≥24px 且 >0.6px/ms）与不跟手（72px / 36px 且 900px/s）两组阈值。
///
/// 三层咬住：① 阈值公式（单一真相 [mangaSwipeThresholds]）；② 生成文档把阈值注入
/// 手势 JS、运行中经 `__mangaSetSwipeThresholds` 换值且拒收坏参数——跑的是生成文档里
/// **真实的** `_start` / `_end` / 阈值段；③ 卷页控制器的提交判据接受缩放后的阈值。
void main() {
  group('mangaSwipeThresholds', () {
    test('值域与语义照小说同名设置', () {
      expect(
        kMangaSwipePageTurnSensitivityMin,
        ReaderSettings.minSwipePageTurnSensitivity,
      );
      expect(
        kMangaSwipePageTurnSensitivityMax,
        ReaderSettings.maxSwipePageTurnSensitivity,
      );
      expect(kMangaSwipePageTurnSensitivityDefault, 1.0);
      expect(normalizeMangaSwipePageTurnSensitivity(null), 1.0);
      expect(normalizeMangaSwipePageTurnSensitivity(double.nan), 1.0);
      expect(normalizeMangaSwipePageTurnSensitivity(double.infinity), 1.0);
      expect(normalizeMangaSwipePageTurnSensitivity(0.1), 0.5);
      expect(normalizeMangaSwipePageTurnSensitivity(9), 3.0);
      expect(normalizeMangaSwipePageTurnSensitivity(1.7), 1.7);
    });

    test('默认 1.0 = 原先写死的阈值（不改默认手感）', () {
      final MangaSwipeThresholds t = mangaSwipeThresholds(1.0);
      expect(t.followCommitFraction, kPageTurnFollowCommitFraction);
      expect(t.followCommitFraction, 0.25);
      expect(t.followFlingVelocity, kPageTurnFollowFlingVelocity);
      expect(t.followFlingVelocity, 0.6);
      expect(t.followFlingMinPx, 24);
      expect(t.dist, 72);
      expect(t.fastDist, 36);
      expect(t.fastVelocity, 900);
    });

    test('越大越灵敏：阈值 = 基准 / 灵敏度', () {
      final MangaSwipeThresholds twice = mangaSwipeThresholds(2.0);
      expect(twice.followCommitFraction, closeTo(0.125, 1e-12));
      expect(twice.followFlingVelocity, closeTo(0.3, 1e-12));
      expect(twice.dist, 36);
      expect(twice.fastVelocity, 450);
      final MangaSwipeThresholds half = mangaSwipeThresholds(0.5);
      expect(half.followCommitFraction, closeTo(0.5, 1e-12));
      expect(half.followFlingVelocity, closeTo(1.2, 1e-12));
      expect(half.followFlingMinPx, 48);
      expect(half.dist, 144);
      expect(half.fastDist, 72);
      expect(half.fastVelocity, 1800);
      // 单调：灵敏度增大，任何一项阈值都不变大。
      MangaSwipeThresholds? prev;
      for (double s = 0.5; s <= 3.0; s += 0.1) {
        final MangaSwipeThresholds t = mangaSwipeThresholds(s);
        if (prev != null) {
          expect(
            t.followCommitFraction,
            lessThanOrEqualTo(prev.followCommitFraction),
          );
          expect(
            t.followFlingVelocity,
            lessThanOrEqualTo(prev.followFlingVelocity),
          );
          expect(t.followFlingMinPx, lessThanOrEqualTo(prev.followFlingMinPx));
          expect(t.dist, lessThanOrEqualTo(prev.dist));
          expect(t.fastDist, lessThanOrEqualTo(prev.fastDist));
          expect(t.fastVelocity, lessThanOrEqualTo(prev.fastVelocity));
        }
        prev = t;
      }
    });

    test('像素阈值下界 = 单击判定框，最灵敏也不吃掉单击', () {
      final MangaSwipeThresholds max = mangaSwipeThresholds(3.0);
      expect(max.dist, 24);
      expect(max.fastDist, kMangaSwipeTapBoxPx);
      expect(max.followFlingMinPx, kMangaSwipeTapBoxPx);
      expect(max.fastVelocity, 300);
      // 越界值先夹回值域。
      expect(mangaSwipeThresholds(99), mangaSwipeThresholds(3.0));
      expect(mangaSwipeThresholds(0), mangaSwipeThresholds(0.5));
    });
  });

  group('卷页提交判据', () {
    test('默认阈值与旧行为一致；缩放后的阈值生效；往回甩的取消门不随灵敏度变', () {
      expect(defaultPageCurlCommitThresholds(), (
        commitFraction: kPageTurnFollowCommitFraction,
        flingVelocity: kPageTurnFollowFlingVelocity,
      ));
      // 拖过 15% 屏宽、慢速：默认不提交，灵敏度 2.0（12.5%）提交。
      expect(
        pageCurlShouldCommit(progressPx: 60, velocity: 0.1, width: 400),
        isFalse,
      );
      final MangaSwipeThresholds t = mangaSwipeThresholds(2.0);
      expect(
        pageCurlShouldCommit(
          progressPx: 60,
          velocity: 0.1,
          width: 400,
          commitFraction: t.followCommitFraction,
          flingVelocity: t.followFlingVelocity,
        ),
        isTrue,
      );
      // 甩速 0.4px/ms：默认不够，2.0（0.3）够。
      expect(
        pageCurlShouldCommit(progressPx: 10, velocity: 0.4, width: 400),
        isFalse,
      );
      expect(
        pageCurlShouldCommit(
          progressPx: 10,
          velocity: 0.4,
          width: 400,
          commitFraction: t.followCommitFraction,
          flingVelocity: t.followFlingVelocity,
        ),
        isTrue,
      );
      // 往回甩 0.4px/ms 不到基准取消门（0.6）：拖得够远照样提交。
      expect(
        pageCurlShouldCommit(
          progressPx: 120,
          velocity: -0.4,
          width: 400,
          commitFraction: t.followCommitFraction,
          flingVelocity: t.followFlingVelocity,
        ),
        isTrue,
      );
    });
  });

  group('手势 JS', () {
    String documentFor(double sensitivity) => mangaWindowDocument(
      const <MokuroImage>[
        MokuroImage(
          url: 'page.png',
          size: MokuroSize(1000, 1414),
          blocks: <MokuroBlock>[],
        ),
      ],
      const <String>['page.png'],
      mode: MangaReadingMode.spread,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
      swipeSensitivity: sensitivity,
    );

    String section(String document, String start, String end) {
      final int from = document.indexOf(start);
      if (from < 0) throw StateError('生成文档里找不到 $start');
      final int to = document.indexOf(end, from);
      if (to < 0) throw StateError('生成文档里找不到 $end');
      return document.substring(from, to);
    }

    test('阈值由 Dart 单一真相注入，JS 里不再写死数字', () {
      final String doc = documentFor(2.0);
      expect(
        doc.contains(
          'window.__mangaSetSwipeThresholds('
          '${mangaSwipeThresholdsJs(mangaSwipeThresholds(2.0))});',
        ),
        isTrue,
      );
      final String end = section(
        doc,
        '  function _end(x, y){',
        '  // ── 滑动翻页提交阈值 ──',
      );
      expect(end.contains('aux >= 72'), isFalse);
      expect(end.contains('aux >= 24 &&'), isFalse);
      expect(end.contains('vel >= 900)'), isFalse);
      expect(end.contains('ax < 20'), isFalse);
    });

    /// 视口 412×860、RTL、未放大，走不跟手路径（不喂 `_swipeMove`）。
    /// `drag(dx)` = 按下 → 10 步 pointermove（每步喂 `_panBy`）→ 松手，历时 300ms。
    String harness(String document, String body) {
      final String pan = section(
        document,
        '  function _clampPan(){',
        '  // 方向键平移',
      );
      final String start = section(
        document,
        '  var sx = 0, sy = 0, st = 0, spx = 0, has = false;',
        '  // ── 触屏双指捏合缩放 ──',
      );
      final String end = section(
        document,
        '  function _end(x, y){',
        "  document.addEventListener('pointerdown', function(e){",
      );
      return '''
const assert=require('node:assert/strict');
let ZOOM=1, PAN_X=0, PAN_Y=0, PAN_WIDE=true, IS_WEBTOON=false, IS_RTL=true;
const window={innerWidth:412,innerHeight:860};
let turns=[], taps=0;
function _applyCanvas(){}
function _currentPageIsWide(){ return false; }
function _bridge(){ return {callHandler:(n,d)=>{ if(n==='onMangaTurn') turns.push(d); }}; }
function _onTap(){ taps++; }
let PAGE_ANIM='slide', FOLLOW_DRAG=true;
function _animMs(){ return 240; }
function _finishPageAnim(){}
function _dropDragHandoff(){}
let now=1000;
Date.now=()=>now;
$pan
$start
$end
function drag(dx){
  const x0=200, y=600;
  _start(x0,y);
  for(let i=1;i<=10;i++){ now+=30; _panBy(dx/10,0); }
  _end(x0+dx,y);
}
$body
''';
    }

    Future<void> runJs(String code) async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'manga-swipe-sensitivity-',
      );
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync(code);
        final ProcessResult result = await Process.run('node', <String>[
          script.path,
        ], runInShell: Platform.isWindows);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    test('默认灵敏度：慢拖 50px 不翻页；灵敏度 2.0：同一拖动翻页', () async {
      await runJs(
        harness(documentFor(1.0), '''
assert.equal(SWIPE_DIST,72); assert.equal(FOLLOW_COMMIT,0.25);
drag(50);
assert.deepEqual(turns,[],'50px < 72px 且均速 167px/s < 900');
assert.equal(taps,0,'超出单击框，也不是单击');
'''),
      );
      await runJs(
        harness(documentFor(2.0), '''
assert.equal(SWIPE_DIST,36); assert.equal(FOLLOW_COMMIT,0.125);
assert.equal(FOLLOW_FLING,0.3); assert.equal(SWIPE_FAST_VEL,450);
drag(50);
assert.deepEqual(turns,['next'],'50px ≥ 36px：翻页');
'''),
      );
    });

    test('运行中换值不重建文档；坏参数整包拒收', () async {
      final String backToDefault = mangaSwipeThresholdsJs(
        mangaSwipeThresholds(1.0),
      );
      await runJs(
        harness(documentFor(2.0), '''
window.__mangaSetSwipeThresholds($backToDefault);
assert.equal(SWIPE_DIST,72);
drag(50);
assert.deepEqual(turns,[],'换回默认后 50px 不再翻页');
// 坏参数：NaN / 低于单击框 / 缺字段 / null —— 一律不动现值。
window.__mangaSetSwipeThresholds({followCommit:0.1,followFling:0.3,followFlingMinPx:24,dist:NaN,fastDist:36,fastVel:900});
window.__mangaSetSwipeThresholds({followCommit:0.1,followFling:0.3,followFlingMinPx:24,dist:5,fastDist:36,fastVel:900});
window.__mangaSetSwipeThresholds({dist:30});
window.__mangaSetSwipeThresholds(null);
assert.equal(SWIPE_DIST,72); assert.equal(FOLLOW_COMMIT,0.25);
'''),
      );
    });

    test('最灵敏（3.0）：单击框内的抖动仍是单击、不翻页', () async {
      await runJs(
        harness(documentFor(3.0), '''
assert.equal(SWIPE_FAST_DIST,20); assert.equal(TAP_BOX,20);
drag(15);
assert.deepEqual(turns,[],'15px 抖动不翻页');
assert.equal(taps,1,'按单击处理');
drag(30);
assert.deepEqual(turns,['next'],'30px ≥ 24px：翻页');
'''),
      );
    });
  });
}
