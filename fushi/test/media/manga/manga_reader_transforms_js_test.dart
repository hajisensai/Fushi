import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

void main() {
  final String document = mangaWindowDocument(
    const <MokuroImage>[
      MokuroImage(
        url: 'page.png',
        size: MokuroSize(1000, 600),
        blocks: <MokuroBlock>[],
      ),
    ],
    const <String>['page.png'],
    mode: MangaReadingMode.spread,
    spreadDirection: 'rtl',
    inlineSelectionJs: '',
    readerPreferences: const MangaReaderPreferences(
      cropBorders: true,
      rotateWidePages: true,
      automaticBackground: true,
    ),
  );

  Future<void> runJs(String code) async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'manga-transforms-',
    );
    try {
      final File script = File('${directory.path}/verify.js')
        ..writeAsStringSync(code);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      directory.deleteSync(recursive: true);
    }
  }

  String section(String start, String end) => document.substring(
    document.indexOf(start),
    document.indexOf(end, document.indexOf(start)),
  );

  test('generated gesture script parses as executable JavaScript', () async {
    final String script = section('(function(){', '</script>');
    await runJs('new Function(${_jsString(script)});');
  });

  test(
    'crop and rotation share bitmap and OCR coordinates and invert for capture',
    () async {
      final String layout = section(
        '  function _layoutSource(page){',
        '  function _inspectSource(page){',
      );
      final String inverse = section(
        '  window.__mangaViewportToPageRect = function',
        '  _applyCanvas();\n  // ── spread',
      );
      await runJs('''
const assert=require('node:assert/strict');
const source={style:{}};
const page={dataset:{pw:'1000',ph:'600',spreadPages:'1'},style:{},
  __crop:{x:100,y:50,width:800,height:500},
  querySelector:()=>source,
  getBoundingClientRect:()=>({left:20,top:30,width:500,height:800})};
const window={innerWidth:1000,innerHeight:800};
const document={querySelector:()=>page};
const ROTATE_WIDE=true,IS_WEBTOON=false;
$layout
$inverse
_layoutSource(page);
assert.equal(page.style.width,'500px');
assert.equal(page.style.height,'800px');
assert.equal(source.style.width,'1000px');
assert.equal(source.style.height,'600px');
assert.equal(source.style.transform,'matrix(0,1,-1,0,550,-100)');
assert.deepEqual(window.__mangaViewportToPageRect(0,20,30,500,800),
  {x:100,y:50,width:800,height:500});
assert.deepEqual(window.__mangaViewportToPageRect(0,145,230,125,200),
  {x:300,y:300,width:200,height:125});
page.__rotated=false;
assert.deepEqual(window.__mangaViewportToPageRect(0,20,30,500,800),
  {x:100,y:50,width:800,height:500});
''');
    },
  );

  test(
    'pixel crop ignores uniform margins and preserves blank pages',
    () async {
      final String inspect = section(
        '  function _layoutSource(page){',
        "  document.querySelectorAll('.manga-page').forEach(function(page){",
      );
      await runJs('''
const assert=require('node:assert/strict');
let pixels=new Uint8ClampedArray(10*10*4).fill(255);
for(let y=2;y<8;y++)for(let x=2;x<8;x++){
  const i=(y*10+x)*4;pixels[i]=pixels[i+1]=pixels[i+2]=0;
}
const image={complete:true,naturalWidth:10,naturalHeight:10};
const source={style:{}};
const page={dataset:{pw:'1000',ph:'600',spreadPages:'1'},style:{},
  querySelector:(selector)=>selector==='img'?image:source};
const window={innerWidth:1000,innerHeight:800};
const document={body:{style:{}},documentElement:{style:{}},querySelector:()=>page,
  createElement:()=>({getContext:()=>({drawImage:()=>{},getImageData:()=>({data:pixels})})})};
const ROTATE_WIDE=true,IS_WEBTOON=false,CURRENT=0;
function _bridge(){return null;}
$inspect
_inspectSource(page);
assert.deepEqual(page.__crop,{x:100,y:60,width:800,height:480});
assert.equal(document.body.style.background,'#fff');
assert.equal(source.style.transform,'matrix(0,1,-1,0,540,-100)');
delete page.__crop;pixels.fill(255);
_inspectSource(page);
assert.equal(page.__crop,undefined);
assert.equal(source.style.width,'1000px');
''');
    },
  );

  test(
    'long strip pages snap to device pixels and overlap one device pixel',
    () async {
      final String webtoon = mangaWindowDocument(
        const <MokuroImage>[
          MokuroImage(
            url: 'a.png',
            size: MokuroSize(720, 3001),
            blocks: <MokuroBlock>[],
          ),
        ],
        const <String>['a.png'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
        readerPreferences: const MangaReaderPreferences(),
      );
      final int start = webtoon.indexOf('  function _layoutSource(page){');
      final String layout = webtoon.substring(
        start,
        webtoon.indexOf('  function _inspectSource(page){', start),
      );
      await runJs('''
const assert=require('node:assert/strict');
function mk(prev, gap){
  const source={style:{}};
  return {dataset:{pw:'720',ph:'3001',spreadPages:'1'},style:{},
    previousElementSibling:prev,__gap:gap,querySelector:()=>source,source};
}
const window={innerWidth:393,innerHeight:852,devicePixelRatio:2.75};
function getComputedStyle(el){return {marginBottom:el.__gap?'12px':'0px'};}
const ROTATE_WIDE=false,IS_WEBTOON=true,IS_VERTICAL_PAGED=false;
$layout
const first=mk(null,false), second=mk(first,false), afterGap=mk(mk(null,true),false);
[first,second,afterGap].forEach(_layoutSource);
// 393/720*3001 = 1638.07… CSS px → 4504.7 device px; must land on a whole one.
const devicePx=parseFloat(first.style.height)*2.75;
assert.ok(Math.abs(devicePx-Math.round(devicePx))<1e-6, first.style.height);
assert.equal(first.style.marginTop,'');
assert.equal(second.style.marginTop,(-1/2.75)+'px');
// 有间距（webtoonGaps）时页缝是有意的，不能被压掉。
assert.equal(afterGap.style.marginTop,'');
// 图像的纵向缩放必须跟着对齐后的页高走，否则图和页框之间又留一条缝。
const sy=Number(first.source.style.transform.split(',')[3]);
assert.ok(Math.abs(sy*3001-parseFloat(first.style.height))<1e-6);
''');
    },
  );

  test('long strip gaps follow the reading mode, not showPageGaps', () {
    String rule(MangaReadingMode mode, {required bool showPageGaps}) {
      final String doc = mangaWindowDocument(
        const <MokuroImage>[
          MokuroImage(
            url: 'a.png',
            size: MokuroSize(720, 2000),
            blocks: <MokuroBlock>[],
          ),
        ],
        const <String>['a.png'],
        mode: mode,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
        readerPreferences: MangaReaderPreferences(
          mode: mode,
          showPageGaps: showPageGaps,
        ),
      );
      final int start = doc.indexOf('.manga-page{width:');
      return doc.substring(start, doc.indexOf('}', start));
    }

    // 「条漫」：showPageGaps 默认开也不能留缝（BUG-3749 的满屏黑线）。
    expect(
      rule(MangaReadingMode.webtoon, showPageGaps: true),
      isNot(contains('margin-bottom')),
    );
    expect(
      rule(MangaReadingMode.webtoonGaps, showPageGaps: false),
      contains('margin-bottom:12px'),
    );
  });

  test(
    'fling velocity averages the recent window, not the last event',
    () async {
      final String webtoon = mangaWindowDocument(
        const <MokuroImage>[
          MokuroImage(
            url: 'a.png',
            size: MokuroSize(720, 3000),
            blocks: <MokuroBlock>[],
          ),
        ],
        const <String>['a.png'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
      );
      final int start = webtoon.indexOf(
        '  function _releaseVelocity(drag, upT){',
      );
      final String velocity = webtoon.substring(
        start,
        webtoon.indexOf('  function _startFlick(vy){', start),
      );
      await runJs('''
const assert=require('node:assert/strict');
$velocity
// 最后一次事件间隔 1ms、只挪 0.2px：旧实现得到 200px/s，几乎不滑。
const drag={vy:200,samples:[{t:0,y:0},{t:50,y:-100},{t:99,y:-199.8},{t:100,y:-200}]};
assert.equal(_releaseVelocity(drag,104),-2000);
// 手指停住 80ms 后才抬：不带惯性。
assert.equal(_releaseVelocity(drag,180),0);
''');
    },
  );

  test(
    'split wide page consumes exactly two halves in reading direction',
    () async {
      for (final String direction in <String>['rtl', 'ltr']) {
        final String splitDocument = mangaWindowDocument(
          const <MokuroImage>[
            MokuroImage(
              url: 'wide.png',
              size: MokuroSize(1000, 500),
              blocks: <MokuroBlock>[],
            ),
          ],
          const <String>['wide.png'],
          mode: MangaReadingMode.spread,
          spreadDirection: direction,
          inlineSelectionJs: '',
          splitWidePages: true,
        );
        final int halfStart = splitDocument.indexOf(
          '  function _applyPageHalf(){',
        );
        final String half = splitDocument.substring(
          halfStart,
          splitDocument.indexOf('  function _applyStartPan(){', halfStart),
        );
        final int turnStart = splitDocument.indexOf(
          '  window.__mangaTurnWithinPage = function',
        );
        final String turn = splitDocument.substring(
          turnStart,
          splitDocument.indexOf('  // Bridge helper', turnStart),
        );
        await runJs('''
const assert=require('node:assert/strict');
const page={style:{},offsetWidth:1000,offsetHeight:500,offsetLeft:0,offsetTop:0,
  closest:()=>({offsetLeft:0}),getAttribute:(key)=>key==='data-pw'?'1000':'500'};
const document={querySelector:()=>page};
const window={innerWidth:1000,innerHeight:1000};
const SPLIT_WIDE=true,ROTATE_WIDE=false,IS_WEBTOON=false,CURRENT=0;
let PAGE_HALF=0,ZOOM=1,PAN_X=0,PAN_Y=0,SPLIT_ACTIVE=false;
function _clampZoom(value){return value;}
function _applyCanvas(){}
$half
$turn
_applyPageHalf();
assert.equal(ZOOM,2);assert.equal(PAN_X,${direction == 'rtl' ? -1000 : 0});
assert.equal(window.__mangaTurnWithinPage(true),true);
assert.equal(PAN_X,${direction == 'rtl' ? 0 : -1000});
assert.equal(window.__mangaTurnWithinPage(true),false);
assert.equal(window.__mangaTurnWithinPage(false),true);
assert.equal(PAN_X,${direction == 'rtl' ? -1000 : 0});
// Landscape fit is height-limited: the other half would otherwise be visible
// in the 350px gutter. Clip only painting/hit-testing, preserving source size.
page.offsetWidth=1600;page.offsetHeight=800;
window.innerWidth=1600;window.innerHeight=900;
_applyPageHalf();
assert.equal(ZOOM,1.125);
assert.equal(PAN_X,${direction == 'rtl' ? -550 : 350});
assert.equal(page.style.clipPath,'${direction == 'rtl' ? 'inset(0 0 0 50%)' : 'inset(0 50% 0 0)'}');
assert.equal(page.offsetWidth,1600);assert.equal(page.offsetHeight,800);
assert.equal(window.__mangaTurnWithinPage(true),true);
assert.equal(PAN_X,${direction == 'rtl' ? 350 : -550});
assert.equal(page.style.clipPath,'${direction == 'rtl' ? 'inset(0 50% 0 0)' : 'inset(0 0 0 50%)'}');
''');
      }
    },
  );

  test('取页失败的页可以重取：换带 retry 参数的新 URL，只认失败页', () async {
    expect(
      document,
      contains("image.addEventListener('error'"),
      reason: '失败要打标记，否则整章不重开这页就一直白着',
    );
    final String retry = section('  var RETRY_SERIAL = 0;', '  // 摆位是「重投影」');
    await runJs('''
function el(attrs){
  return {
    attrs: attrs,
    getAttribute: function(k){ return k in this.attrs ? this.attrs[k] : null; },
    setAttribute: function(k, v){ this.attrs[k] = String(v); },
    removeAttribute: function(k){ delete this.attrs[k]; },
  };
}
var img = el({src: 'https://fushi.local/img/a.png?v=3', loading: 'lazy'});
Object.defineProperty(img, 'src', {
  get: function(){ return this.attrs.src; },
  set: function(v){ this.attrs.src = v; },
});
var page = el({'data-page': '0', 'data-spread': '0', 'data-load-failed': '1'});
page.querySelector = function(){ return img; };
page.getBoundingClientRect = function(){ return {left: 0, top: 0, right: 100, bottom: 100}; };
var document = {
  querySelectorAll: function(){
    return page.getAttribute('data-load-failed') === '1' ? [page] : [];
  },
};
$retry
function check(cond, msg){ if (!cond) { console.error(msg); process.exit(1); } }
check(!_retryFailedPageAt(200, 200), 'tap outside the failed page must not retry');
check(!_retryFailedPageAt(5, 50), 'tap on the failed page away from the retry icon must not retry');
check(_retryFailedPageAt(50, 50), 'tap on the retry icon retries it');
check(img.src === 'https://fushi.local/img/a.png?v=3&retry=1', 'retry url: ' + img.src);
check(img.attrs.loading === 'eager', 'retry is requested now, not lazily');
check(page.getAttribute('data-load-failed') === null, 'failure mark cleared');
check(!_retryPageImage(page), 'a page that did not fail is never re-requested');
page.setAttribute('data-load-failed', '1');
_retryFailedPagesWhere(function(p){ return Number(p.getAttribute('data-spread')) === 0; });
check(img.src === 'https://fushi.local/img/a.png?v=3&retry=2', 'second retry keeps base url: ' + img.src);
''');
  });

  test('失败页上左右翻页热区照常翻页，只有中央重试符号触发重取', () async {
    final String retry = section('  var RETRY_SERIAL = 0;', '  // 摆位是「重投影」');
    final String tap = section(
      '  var TAP_ZONE_PAGING = ',
      '  function _end(x, y){',
    );
    await runJs('''
function el(attrs){
  return {
    attrs: attrs,
    getAttribute: function(k){ return k in this.attrs ? this.attrs[k] : null; },
    setAttribute: function(k, v){ this.attrs[k] = String(v); },
    removeAttribute: function(k){ delete this.attrs[k]; },
    appendChild: function(){},
    remove: function(){},
    style: {},
  };
}
var img = el({src: 'https://fushi.local/img/a.png', loading: 'lazy'});
Object.defineProperty(img, 'src', {
  get: function(){ return this.attrs.src; },
  set: function(v){ this.attrs.src = v; },
});
// 单页模式：失败页铺满 1000x1000 视口。
var page = el({'data-page': '0', 'data-spread': '0', 'data-load-failed': '1'});
page.querySelector = function(){ return img; };
page.getBoundingClientRect = function(){ return {left: 0, top: 0, right: 1000, bottom: 1000}; };
var document = {
  querySelectorAll: function(){
    return page.getAttribute('data-load-failed') === '1' ? [page] : [];
  },
  createElement: function(){ return el({}); },
  getElementById: function(){ return null; },
  addEventListener: function(){},
  body: {appendChild: function(){}},
};
// 未放大（BUG-3634 的放大态判据住在 canvas zoom 段，本 harness 不截那段）。
function _userZoomedIn(){ return false; }
var calls = [];
var window = {
  innerWidth: 1000, innerHeight: 1000,
  flutter_inappwebview: {callHandler: function(name, arg){ calls.push([name, arg]); }},
};
var timers = [];
var setTimeout = function(fn){ timers.push(fn); return timers.length; };
var clearTimeout = function(){};
var IS_WEBTOON = false;
function _bridge(){ return window.flutter_inappwebview; }
function _selectOcrChar(){ return false; }
function _doubleTapZoom(){}
$retry
$tap
function check(cond, msg){ if (!cond) { console.error(msg); process.exit(1); } }
function failAgain(){ page.setAttribute('data-load-failed', '1'); }
// 左右热区：失败页上照常翻页，且不重取。
_onTap(20, 500);
check(calls.length === 1 && calls[0][0] === 'onMangaTurn', 'left zone must turn on a failed page: ' + JSON.stringify(calls));
check(page.getAttribute('data-load-failed') === '1', 'left zone tap must not retry');
_onTap(980, 500);
check(calls.length === 2 && calls[1][0] === 'onMangaTurn' && calls[1][1] !== calls[0][1], 'right zone must turn the other way: ' + JSON.stringify(calls));
check(page.getAttribute('data-load-failed') === '1', 'right zone tap must not retry');
// 重取后源仍挂、马上又失败：热区依旧能翻走（不会卡在失败页上）。
_onTap(500, 500);
check(page.getAttribute('data-load-failed') === null, 'tap on the centre retry icon retries');
check(calls.length === 2, 'retry tap does nothing else: ' + JSON.stringify(calls));
failAgain();
_onTap(20, 500);
check(calls.length === 3 && calls[2][0] === 'onMangaTurn', 'still turns after a failed retry');
// 命中区 ≥48dp：图标外缘 ±30px 内仍算重试。
_onTap(530, 470);
check(page.getAttribute('data-load-failed') === null, 'retry hit area is at least 48dp');
failAgain();
// 中央空白但不在图标上：不重取，走空白单击。
_onTap(500, 200);
check(page.getAttribute('data-load-failed') === '1', 'blank centre away from the icon must not retry');
''');
  });

  test(
    'filter values preserve zero adjustment and isolate bitmap color effects',
    () {
      expect(
        mangaImageFilterCss(const MangaReaderPreferences()),
        'invert(0) grayscale(0) brightness(1.0) contrast(1.0) saturate(1.0)',
      );
      expect(
        mangaImageFilterCss(
          const MangaReaderPreferences(
            invertColors: true,
            grayscale: true,
            brightness: 25,
            contrast: 150,
            saturation: 50,
          ),
        ),
        'invert(1) grayscale(1) brightness(1.25) contrast(1.5) saturate(0.5)',
      );
      // 恒等滤镜不下发：超高长条页图上的滤镜离屏面会越过纹理上限画成空白。
      expect(
        mangaImageFilterIsIdentity(const MangaReaderPreferences()),
        isTrue,
      );
      expect(
        mangaImageFilterIsIdentity(const MangaReaderPreferences(brightness: 5)),
        isFalse,
      );
      expect(document, contains('.manga-source img{filter:none;}'));
      expect(document, contains('class="manga-source"'));
      expect(document, contains('source.insertAdjacentHTML'));
    },
  );
}

String _jsString(String source) =>
    '"${source.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\r', '\\r').replaceAll('\n', '\\n')}"';
