import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-2875：放大态（ZOOM>1）的左右滑。平移先吃掉位移，贴边后**没吃掉**的横向
/// 余量才判 swipe 翻页；捏合缩回「看起来贴合」时残留的 101%~105% 不再让左右滑
/// 永远翻不了页。
///
/// 跑的是生成文档里**真实的** `_clampPan` / `_panBy` / `_start` / `_end` 四段，
/// 不是复刻；指针事件按生产 pointermove 的方式逐步喂给 `_panBy`。
void main() {
  final String document = mangaWindowDocument(
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
  );

  String section(String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  final String pan = section('  function _clampPan(){', '  // 方向键平移');
  final String start = section(
    '  var sx = 0, sy = 0, st = 0, spx = 0, has = false;',
    '  // ── 触屏双指捏合缩放 ──',
  );
  final String end = section(
    '  function _end(x, y){',
    "  document.addEventListener('pointerdown', function(e){",
  );

  /// 视口 412×860（竖屏手机）、RTL。`drag(dx)` = 按下 → 分 10 步 pointermove（每步
  /// 喂 `_panBy`）→ 松手，历时 300ms。
  String harness(String body) =>
      '''
const assert=require('node:assert/strict');
let ZOOM=1, PAN_X=0, PAN_Y=0, PAN_WIDE=true, IS_WEBTOON=false, IS_RTL=true;
const window={innerWidth:412,innerHeight:860};
let turns=[], taps=0;
function _applyCanvas(){}
function _currentPageIsWide(){ return false; }
function _bridge(){ return {callHandler:(n,d)=>{ if(n==='onMangaTurn') turns.push(d); }}; }
function _onTap(){ taps++; }
let now=1000;
Date.now=()=>now;
$pan
$start
$end
function centerAt(zoom){ ZOOM=zoom; PAN_X=window.innerWidth*(1-ZOOM)/2; PAN_Y=window.innerHeight*(1-ZOOM)/2; }
function drag(dx){
  const x0=200, y=600;
  _start(x0,y);
  for(let i=1;i<=10;i++){ now+=30; _panBy(dx/10,0); }
  _end(x0+dx,y);
}
$body
''';

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-zoomed-swipe-',
    );
    try {
      final File script = File('${dir.path}/verify.js')
        ..writeAsStringSync(code);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('未放大：判据不变，RTL 右滑 = 下一页、左滑 = 上一页', () async {
    await runJs(
      harness('''
centerAt(1);
drag(120);
drag(-120);
assert.deepEqual(turns,['next','prev']);
assert.equal(PAN_X,0,'未放大时拖动不平移');
'''),
    );
  });

  test('捏合残留 103%（看起来就是贴合）：左右滑照样翻页', () async {
    await runJs(
      harness('''
centerAt(1.03);
drag(120);
assert.deepEqual(turns,['next'],'可平移余量只有几像素，贴边后的余量必须翻页');
assert.equal(PAN_X,0,'平移照样先贴到左边缘');
drag(-120);
assert.deepEqual(turns,['next','prev']);
'''),
    );
  });

  test('明显放大：平移吃得下就只平移，不翻页', () async {
    await runJs(
      harness('''
centerAt(2);
const before=PAN_X;
drag(120);
assert.deepEqual(turns,[],'平移区间内的拖动是看页面各处，不是翻页');
assert.ok(Math.abs(PAN_X-(before+120))<1e-9,'位移全部给了平移，got '+PAN_X);
'''),
    );
  });

  test('明显放大：拖到边缘后继续拖，余量过阈就翻页', () async {
    await runJs(
      harness('''
centerAt(2);
PAN_X=-40;
drag(120);
assert.equal(PAN_X,0,'先贴边');
assert.deepEqual(turns,['next'],'余量 80px 过 72px 阈值');
PAN_X=-100;
drag(120);
assert.deepEqual(turns,['next'],'余量只有 20px：不翻页');
'''),
    );
  });

  test('贴在左边缘往反方向拖：位移全被平移吃掉，不翻页', () async {
    await runJs(
      harness('''
centerAt(2);
PAN_X=0;
drag(-120);
assert.deepEqual(turns,[]);
assert.equal(PAN_X,-120);
'''),
    );
  });
}
