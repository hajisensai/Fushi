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
          splitDocument.indexOf('  _recenterPan();', halfStart),
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
      expect(document, contains('class="manga-source"'));
      expect(document, contains('source.insertAdjacentHTML'));
    },
  );
}

String _jsString(String source) =>
    '"${source.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\r', '\\r').replaceAll('\n', '\\n')}"';
