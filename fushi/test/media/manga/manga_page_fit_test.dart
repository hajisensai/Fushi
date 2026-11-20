import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_page_fit.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-4704：4K 页图卷打开后内存暴涨闪退。页图按显示尺寸降采样后再交给 WebView：
/// 拦截器侧的尺寸规划 / 串行转码 / LRU（[MangaPageFitter]），文档侧按排版宽度挂
/// `fit=` 的 src（生成文档里**真实的** `_refitPage`，node 跑）。
void main() {
  group('mangaFitWidthOf', () {
    Uri u(String query) => Uri.parse('https://manga.local/img/a.jpg$query');

    test('reads a positive fit width and ignores garbage', () {
      expect(mangaFitWidthOf(u('?fit=1280')), 1280);
      expect(mangaFitWidthOf(u('?s=1&v=2&fit=640')), 640);
      expect(mangaFitWidthOf(u('')), isNull);
      expect(mangaFitWidthOf(u('?fit=0')), isNull);
      expect(mangaFitWidthOf(u('?fit=-3')), isNull);
      expect(mangaFitWidthOf(u('?fit=x')), isNull);
      expect(mangaFitWidthOf(u('?fit=70000')), isNull);
    });
  });

  group('mangaFitTarget', () {
    test('4K page shown at tablet width is downscaled keeping its aspect', () {
      // 926×650dp@2.63 横屏双页：每页约 1216 物理像素宽，取整到 1280 档。
      expect(
        mangaFitTarget(sourceWidth: 3840, sourceHeight: 5400, fitWidth: 1280),
        (width: 1280, height: 1800),
      );
    });

    test('keeps the original when not larger, or the saving is small', () {
      expect(
        mangaFitTarget(sourceWidth: 1200, sourceHeight: 1700, fitWidth: 1280),
        isNull,
      );
      expect(
        mangaFitTarget(sourceWidth: 1280, sourceHeight: 1800, fitWidth: 1280),
        isNull,
      );
      // 0.9² = 0.81 > 0.64：省下不到四成像素，转码不值。
      expect(
        mangaFitTarget(sourceWidth: 1000, sourceHeight: 1400, fitWidth: 900),
        isNull,
      );
      expect(
        mangaFitTarget(sourceWidth: 1000, sourceHeight: 1400, fitWidth: 768),
        (width: 768, height: 1075),
      );
      expect(
        mangaFitTarget(sourceWidth: 0, sourceHeight: 10, fitWidth: 5),
        isNull,
      );
    });
  });

  group('MangaPageFitter', () {
    test('one transcode at a time; same page and width deduped', () async {
      int running = 0;
      int maxRunning = 0;
      int transcodes = 0;
      final List<Completer<void>> gates = <Completer<void>>[];
      final MangaPageFitter fitter = MangaPageFitter(
        transcoder: (Uint8List bytes, int width) async {
          transcodes++;
          running++;
          if (running > maxRunning) maxRunning = running;
          final Completer<void> gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          running--;
          return Uint8List(width ~/ 100);
        },
      );
      int loads = 0;
      Future<Uint8List> load() async {
        loads++;
        return Uint8List(10);
      }

      Future<void> settle(int gateCount) async {
        for (int i = 0; i < 50 && gates.length < gateCount; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      final Future<Uint8List?> a1 = fitter.fit('a', 1280, load);
      final Future<Uint8List?> a2 = fitter.fit('a', 1280, load);
      final Future<Uint8List?> b = fitter.fit('b', 1280, load);
      await settle(1);
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(1), reason: '第二张必须排队，不能并发解两张原图');
      gates.first.complete();
      await settle(2);
      expect(gates, hasLength(2));
      gates[1].complete();
      final Uint8List? first = await a1;
      expect(first!.length, 12);
      expect(await a2, same(first));
      expect((await b)!.length, 12);
      expect(maxRunning, 1);
      expect(transcodes, 2);
      expect(loads, 2);
    });

    test(
      'caches results incl. "serve the original"; bounded by bytes',
      () async {
        int transcodes = 0;
        final MangaPageFitter fitter = MangaPageFitter(
          maxCacheBytes: 250,
          transcoder: (Uint8List bytes, int width) async {
            transcodes++;
            return width == 1 ? null : Uint8List(100);
          },
        );
        int loads = 0;
        Future<Uint8List> load() async {
          loads++;
          return Uint8List(4);
        }

        expect(await fitter.fit('orig', 1, load), isNull);
        expect(await fitter.fit('orig', 1, load), isNull);
        expect(loads, 1, reason: '「给原图」的结论也要缓存，命中时连原图都不读');

        await fitter.fit('p1', 640, load);
        await fitter.fit('p2', 640, load);
        expect(fitter.cachedBytes, 200);
        await fitter.fit('p1', 640, load); // 命中并刷新 p1。
        expect(transcodes, 3);
        await fitter.fit('p3', 640, load); // 超限：淘汰最久没用的 p2。
        expect(fitter.cachedBytes, lessThanOrEqualTo(250));
        await fitter.fit('p1', 640, load);
        expect(transcodes, 4, reason: 'p1 刚用过，不该被淘汰');
        await fitter.fit('p2', 640, load);
        expect(transcodes, 5, reason: 'p2 已被淘汰，要重转');
      },
    );

    test('a failing transcode surfaces the error and is not cached', () async {
      int calls = 0;
      final MangaPageFitter fitter = MangaPageFitter(
        transcoder: (Uint8List bytes, int width) async {
          calls++;
          if (calls == 1) throw StateError('native failure');
          return Uint8List(3);
        },
      );
      Future<Uint8List> load() async => Uint8List(4);
      await expectLater(fitter.fit('x', 640, load), throwsStateError);
      expect((await fitter.fit('x', 640, load))!.length, 3);
    });

    test(
      'pages that need no shrink skip the queue and never start a transcode',
      () async {
        // manga-6：原图已经够小的页（头里读得出来）不该排在别的页整张转码后面，
        // 更不该为了得出「给原图」再起一次 isolate。
        final List<Completer<void>> gates = <Completer<void>>[];
        final List<int> transcoded = <int>[];
        final MangaPageFitter fitter = MangaPageFitter(
          planner: (Uint8List bytes, int width) => bytes.first == 1,
          transcoder: (Uint8List bytes, int width) async {
            transcoded.add(bytes.first);
            final Completer<void> gate = Completer<void>();
            gates.add(gate);
            await gate.future;
            return Uint8List(7);
          },
        );
        int smallLoads = 0;
        final Future<Uint8List?> big = fitter.fit(
          'big',
          1280,
          () async => Uint8List.fromList(<int>[1]),
        );
        for (int i = 0; i < 20 && gates.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(gates, hasLength(1), reason: '大页正在转码，队列被占着');
        final Uint8List? small = await fitter
            .fit('small', 1280, () async {
              smallLoads++;
              return Uint8List.fromList(<int>[0]);
            })
            .timeout(const Duration(seconds: 2));
        expect(small, isNull, reason: '不需要缩的页当场给原图，不等大页转完');
        expect(transcoded, <int>[1], reason: '不需要缩的页不进转码段');
        expect(
          await fitter.fit('small', 1280, () async {
            smallLoads++;
            return Uint8List.fromList(<int>[0]);
          }),
          isNull,
        );
        expect(smallLoads, 1, reason: '「给原图」的结论照样缓存');
        gates.single.complete();
        expect((await big)!.length, 7);
      },
    );

    test(
      'the on-screen page jumps the transcode queue; nothing is dropped',
      () async {
        // manga-6：WebView 先请求的是 ±2 的预热邻页时，当前跨页不能排在它们后面
        // 等几张 4K 整张转码；但排着的邻页也不能丢（WebView 在等响应）。
        final List<String> order = <String>[];
        final List<Completer<void>> gates = <Completer<void>>[];
        final MangaPageFitter fitter = MangaPageFitter(
          planner: (Uint8List bytes, int width) => true,
          transcoder: (Uint8List bytes, int width) async {
            order.add(String.fromCharCode(bytes.first));
            final Completer<void> gate = Completer<void>();
            gates.add(gate);
            await gate.future;
            return Uint8List(5);
          },
        );
        Future<Uint8List> load(String name) async =>
            Uint8List.fromList(<int>[name.codeUnitAt(0)]);
        int onScreen = -1;
        Future<Uint8List?> request(String name, int pageIndex) => fitter.fit(
          name,
          1280,
          () => load(name),
          urgent: () => onScreen == pageIndex,
        );

        Future<void> settle(int gateCount) async {
          for (int i = 0; i < 50 && gates.length < gateCount; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        }

        final Future<Uint8List?> a = request('a', 0);
        final Future<Uint8List?> b = request('b', 1);
        final Future<Uint8List?> c = request('c', 2);
        final Future<Uint8List?> d = request('d', 3);
        await settle(1);
        for (int i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        // 排队期间读者翻到了 d：出队那一刻才判优先级。
        onScreen = 3;
        gates[0].complete();
        await settle(2);
        expect(order, <String>['a', 'd']);
        gates[1].complete();
        await settle(3);
        gates[2].complete();
        await settle(4);
        gates[3].complete();
        await Future.wait(<Future<Uint8List?>>[a, b, c, d]);
        expect(order, <String>['a', 'd', 'b', 'c']);
      },
    );

    test('dispose settles queued pages without transcoding them', () async {
      final List<Completer<void>> gates = <Completer<void>>[];
      int transcodes = 0;
      final MangaPageFitter fitter = MangaPageFitter(
        planner: (Uint8List bytes, int width) => true,
        transcoder: (Uint8List bytes, int width) async {
          transcodes++;
          final Completer<void> gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return Uint8List(5);
        },
      );
      Future<Uint8List> load() async => Uint8List(1);
      final Future<Uint8List?> running = fitter.fit('a', 1280, load);
      final Future<Uint8List?> queued = fitter.fit('b', 1280, load);
      for (int i = 0; i < 20 && gates.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      fitter.dispose();
      gates.single.complete();
      expect((await running)!.length, 5);
      expect(await queued, isNull);
      expect(transcodes, 1);
    });
  });

  group('document', () {
    String doc({required bool fit}) => mangaWindowDocument(
      const <MokuroImage>[
        MokuroImage(
          url: 'p0.jpg',
          size: MokuroSize(3840, 5400),
          blocks: <MokuroBlock>[],
        ),
      ],
      const <String>['https://manga.local/img/p0.jpg?s=ab&v=1'],
      mode: MangaReadingMode.spread,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
      fitImagesToDisplay: fit,
    );

    test('fit mode leaves src to the script: original never fetched first', () {
      final String fitted = doc(fit: true);
      expect(
        fitted,
        contains('<img data-src="https://manga.local/img/p0.jpg?s=ab&amp;v=1"'),
      );
      expect(fitted.contains('<img src='), isFalse);
      expect(fitted, contains('var FIT_IMAGES = true;'));
      final String plain = doc(fit: false);
      expect(
        plain,
        contains('<img src="https://manga.local/img/p0.jpg?s=ab&amp;v=1"'),
      );
      expect(plain, contains('var FIT_IMAGES = false;'));
    });

    test('_refitPage asks for layout width x dpr x zoom tier', () async {
      final String document = doc(fit: true);
      final int from = document.indexOf('  var FIT_IMAGES = ');
      final int to = document.indexOf('  function _layoutSource(page){');
      expect(from, greaterThan(0));
      expect(to, greaterThan(from));
      final String section = document.substring(from, to);
      final String script = _harness.replaceFirst('/*SECTION*/', section);
      final Directory dir = Directory.systemTemp.createTempSync('manga-fit-');
      try {
        final File file = File('${dir.path}/verify.js')
          ..writeAsStringSync(script);
        final ProcessResult result = await Process.run('node', <String>[
          file.path,
        ], runInShell: Platform.isWindows);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('dragging the window edge re-requests only the final tier', () async {
      // manga-22：resize 一秒几十次，每次都直接换 `fit=` 档的话，已加载的页每跨过
      // 一个 128 px 档就排一次整张转码；resize 路径只排版，换图走 200 ms 合并。
      final String document = doc(fit: true);
      final int from = document.indexOf('  var FIT_IMAGES = ');
      final int to = document.indexOf('  function _recenterPan(){');
      expect(from, greaterThan(0));
      expect(to, greaterThan(from));
      final String section = document.substring(from, to);
      final String script = _resizeHarness.replaceFirst(
        '/*SECTION*/',
        section,
      );
      final Directory dir = Directory.systemTemp.createTempSync('manga-fit-');
      try {
        final File file = File('${dir.path}/verify.js')
          ..writeAsStringSync(script);
        final ProcessResult result = await Process.run('node', <String>[
          file.path,
        ], runInShell: Platform.isWindows);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

const String _resizeHarness = r'''
const assert=require('node:assert/strict');
var ZOOM=1, CURRENT=0, IS_WEBTOON=false, IS_VERTICAL_PAGED=false;
var ROTATE_WIDE=false, SPREAD_GUTTER=false;
const listeners={};
const window={innerWidth:800,innerHeight:1200,devicePixelRatio:2,
  addEventListener(type,fn){ (listeners[type]=listeners[type]||[]).push(fn); }};
const timers=[];
function setTimeout(fn){ timers.push(fn); return timers.length; }
function clearTimeout(id){ if (id) timers[id-1]=null; }
function flushTimers(){ timers.splice(0).forEach(function(fn){ if (fn) fn(); }); }
function getComputedStyle(){ return {marginBottom:'0px'}; }
function _applyWidePolicy(){}
function _bridge(){ return null; }
const img={a:{'data-src':'https://manga.local/img/p0.jpg?s=ab&v=1'},sets:0,
  complete:false,naturalWidth:0,
  getAttribute(k){ return k in this.a ? this.a[k] : null; },
  setAttribute(k,v){ this.a[k]=String(v); this.sets++; }};
const source={style:{}};
const page={dataset:{pw:'3840',ph:'5400',spreadPages:'1'},style:{},
  previousElementSibling:null,
  getAttribute(k){ return k==='data-spread' ? '0' : null; },
  querySelector(sel){ return sel==='img' ? img : source; },
  getBoundingClientRect(){ return {top:0,bottom:10}; }};
const document={body:{style:{}},documentElement:{style:{}},
  querySelectorAll(){ return [page]; }, querySelector(){ return page; }};
/*SECTION*/
assert.equal(img.sets,1,'开卷首排版立即取图，不等合并');
const opened=img.a.src;
for (let w=800; w<=1400; w+=40) {
  window.innerWidth=w;
  listeners.resize.forEach(function(fn){ fn(); });
}
assert.equal(img.sets,1,'拖动过程中不换档取图');
flushTimers();
assert.equal(img.sets,2,'停手后只按最终尺寸取一次');
assert.notEqual(img.a.src,opened);
assert.match(img.a.src,/&fit=\d+$/);
''';

const String _harness = r'''
const assert=require('node:assert/strict');
var ZOOM=1, CURRENT=0, IS_WEBTOON=false;
const window={innerWidth:800,innerHeight:1200,devicePixelRatio:2.625};
function mkPage(spread, pw, scale, base, nofit){
  const attrs={'data-spread':String(spread)};
  if (nofit) attrs['data-nofit']='1';
  const img={a:{}, sets:0, getAttribute(k){ return k in this.a ? this.a[k] : null; },
    setAttribute(k,v){ this.a[k]=String(v); this.sets++; }};
  if (base) img.a['data-src']=base;
  return {dataset:{pw:String(pw)}, __fitScale:scale, img,
    getAttribute(k){ return k in attrs ? attrs[k] : null; },
    querySelector(){ return img; },
    getBoundingClientRect(){ return {top:0,bottom:10}; }};
}
const pages=[];
const document={querySelectorAll(){ return pages; }};
/*SECTION*/
const base='https://manga.local/img/p0.jpg?s=ab&v=1';
const cur=mkPage(0,3840,0.2,base);
const next=mkPage(1,3840,0.2,'https://manga.local/img/p1.jpg?s=ab&v=1');
const off=mkPage(2,3840,0.2,'https://manga.local/img/p2.jpg',true);
const plain=mkPage(0,3840,0.2,null);
pages.push(cur,next,off,plain);
pages.forEach(_refitPage);
// 3840 × 0.2 × 2.625 = 2016 → 向上取整到 128 档 = 2048。
assert.equal(cur.img.a.src, base+'&fit=2048');
assert.equal(next.img.a.src,'https://manga.local/img/p1.jpg?s=ab&v=1&fit=2048');
assert.equal(off.img.a.src,undefined,'放弃降采样的页不再改 src');
assert.equal(plain.img.a.src,undefined,'没有 data-src（未开降采样）不碰');
_refitPage(cur);
assert.equal(cur.img.sets,1,'同一档不重设 src（不重新取图）');
ZOOM=1.6;
pages.forEach(_refitPage);
assert.equal(cur.img.a.src, base+'&fit=4096','屏上页放大到 2 档');
assert.equal(next.img.a.src,'https://manga.local/img/p1.jpg?s=ab&v=1&fit=2048','屏外邻页不跟着放大');
ZOOM=2.2;
_refitPage(cur);
// 2016 × 4 = 8064，恰是 128 的整数倍。
assert.equal(cur.img.a.src, base+'&fit=8064','超过 2 倍取 4 档');
ZOOM=1; CURRENT=1;
pages.forEach(_refitPage);
assert.equal(cur.img.a.src, base+'&fit=2048','离开屏幕退回 1 档');
const unknown=mkPage(0,3840,0,'https://manga.local/img/p3.jpg');
_refitPage(unknown);
assert.equal(unknown.img.a.src,'https://manga.local/img/p3.jpg','还没排版（缩放未知）先取原图，不卡空白');
''';
