import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-5555（反馈 AmYIZcxlKr）：条漫用触控板两指滑动不跟手。Windows 宿主把触控板平移
/// 换算成一串碎的普通滚轮交给 WebView2，Chromium 对每一个都起平滑滚动动画、互相改目标。
/// 条漫页现在把像素模式下的细粒度滚轮流接过来 1:1 同步滚动，粗滚轮仍走原生平滑滚动。
///
/// 跑的是生成文档里**真实的**那段监听，不是复刻。
void main() {
  final String document = mangaWindowDocument(
    const <MokuroImage>[
      MokuroImage(
        url: 'page.png',
        size: MokuroSize(600, 1000),
        blocks: <MokuroBlock>[],
      ),
    ],
    const <String>['page.png'],
    mode: MangaReadingMode.webtoon,
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

  final String wheel = section(
    '  // ── webtoon 触控板 / 高精度滚轮',
    '  // ── 抑制原生拖拽残影',
  );

  String harness(String body) =>
      '''
const assert=require('node:assert/strict');
let ZOOM=1, IS_WEBTOON=true, now=0, scrolled=0, panned=[], flickStops=0;
const performance={now:()=>now};
const window={scrollBy:(x,y)=>{ assert.equal(x,0); scrolled+=y; }};
let wheelHandler=null;
const document={addEventListener:(t,f)=>{ if(t==='wheel') wheelHandler=f; }};
function _stopFlick(){ flickStops++; }
function _panBy(dx,dy){ panned.push([dx,dy]); }
function wheel(dy,opts){
  opts=opts||{};
  let prevented=false;
  wheelHandler({deltaY:dy,deltaX:opts.dx||0,deltaMode:opts.mode||0,
    ctrlKey:!!opts.ctrl,metaKey:false,preventDefault(){ prevented=true; }});
  now+=opts.gap===undefined?8:opts.gap;
  return prevented;
}
$wheel
$body
''';

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-webtoon-trackpad-',
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

  test('触控板碎 delta：接管原生滚动，同步 1:1，亚像素跨帧累计', () async {
    await runJs(
      harness('''
assert.equal(wheel(3.5),true,'细粒度滚轮必须 preventDefault，不交给原生动画');
assert.equal(scrolled,3,'整数部分当帧落地');
wheel(3.5);
assert.equal(scrolled,7,'余量 0.5 + 3.5 = 4，一像素不丢');
wheel(-2);
assert.equal(scrolled,5,'反向立即跟手');
assert.ok(flickStops>0,'页内触摸惯性让位');
'''),
    );
  });

  test('同一手势里后来的大帧（甩动）仍按细粒度同步', () async {
    await runJs(
      harness('''
wheel(4);
assert.equal(wheel(90),true);
assert.equal(scrolled,94);
'''),
    );
  });

  test('鼠标一格（大 delta / 行模式）交给原生平滑滚动', () async {
    await runJs(
      harness('''
assert.equal(wheel(100,{gap:500}),false,'像素模式一格 100');
assert.equal(wheel(3,{mode:1,gap:500}),false,'行模式');
assert.equal(scrolled,0);
'''),
    );
  });

  test('停顿超过空闲门限后重新判设备', () async {
    await runJs(
      harness('''
wheel(4,{gap:500});
assert.equal(wheel(100),false,'触控板手势结束后的鼠标一格不再被当成触控板');
'''),
    );
  });

  test('Ctrl+滚轮留给缩放监听；放大态横向走 _panBy', () async {
    await runJs(
      harness('''
assert.equal(wheel(4,{ctrl:true}),false);
assert.equal(scrolled,0);
ZOOM=2;
wheel(0,{dx:5});
assert.deepEqual(panned,[[-5,0]]);
'''),
    );
  });
}
