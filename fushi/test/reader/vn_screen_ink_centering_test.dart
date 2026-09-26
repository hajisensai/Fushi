import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/source_guard.dart';

/// BUG-2711：VN 拆屏判据认「字形墨迹落在内容盒内」，flex 居中却认段落 margin 盒。
/// 长段落拆开后那一截的 margin 盒比内容盒宽，内容被 `max-width: 100%` 钳成满宽，
/// 竖排从右侧贴着 1em 段距往左排——右边空出一大截、最左列压进左边距（用户截图：
/// 左右边距都设 5%，右侧空白明显更宽）。修法是 `renderScreen` 用同一把尺子
/// （墨迹）沿 block 轴把本屏摆正。
///
/// headless Chrome 实测（竖排 38px / 行高 1.65 / 左右 5%，526px 宽视口）：拆屏
/// 修前墨迹左右间距 22.9 / 64.3px，修后 42.8 / 44.4px；未拆的屏与横排修前修后
/// 一致（74.9 / 74.9、上下对称）。这里用伪 DOM 跑生产函数体钉住几何契约。
void main() {
  late String shell;
  late String centerBody;

  setUpAll(() {
    shell = ReaderVisualNovelScripts.vnShellScript();
    final String method = methodBody(
      shell,
      'centerScreenInk: function(content)',
      lexicon: SourceLexicon.js,
    );
    final int bodyStart = method.indexOf('{');
    expect(bodyStart, isNonNegative, reason: 'centerScreenInk body missing');
    centerBody = method.substring(bodyStart + 1, method.length - 1);
  });

  test(
    'BUG-2711: renderScreen centres the ink before the reveal splits text',
    () {
      final String render = methodBody(
        shell,
        'renderScreen: function(index, fullyRevealed)',
        lexicon: SourceLexicon.js,
      );
      final int append = render.indexOf('this.screen.appendChild(content);');
      final int center = render.indexOf('this.centerScreenInk(content);');
      final int reveal = render.indexOf('this.hideCurrentScreenForReveal();');
      expect(append, isNonNegative);
      expect(
        center,
        greaterThan(append),
        reason:
            'centring must measure the content once it is laid out on screen',
      );
      expect(
        reveal,
        greaterThan(center),
        reason:
            'the reveal wraps text in spans; measure the whole screen first',
      );
    },
  );

  test('BUG-2711: ink box is centred on the block axis of the content box', () {
    final Directory temp = Directory.systemTemp.createTempSync(
      'hibiki-vn-ink-center-',
    );
    final File payload = File('${temp.path}/payload.json')
      ..writeAsStringSync(jsonEncode(<String, String>{'body': centerBody}));
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>['-e', _inkCenterRunner, payload.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason:
          'VN ink centring runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

const String _inkCenterRunner = r'''
const fs = require('fs');
const body = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).body;
function assert(value, message) {
  if (!value) throw new Error(message);
}

// 竖排：屏 0..526，左右 padding 26.3 → 内容盒 26.3..499.7。
function run({vertical, inkRects, hasMedia = false}) {
  const props = {transform: 'stale'};
  const removed = [];
  const content = {
    style: {
      removeProperty(name) { removed.push(name); delete props[name]; },
      setProperty(name, value) { props[name] = value; },
    },
    querySelector() { return hasMedia ? {} : null; },
  };
  const screen = {
    getBoundingClientRect() {
      return {left: 0, right: 526, top: 0, bottom: 800};
    },
  };
  const nodes = inkRects.map((rects) => ({textContent: '字', rects}));
  const document = {
    createTreeWalker() {
      let i = 0;
      return {nextNode() { return nodes[i++] || null; }};
    },
    createRange() {
      let current = null;
      return {
        selectNodeContents(node) { current = node; },
        getClientRects() { return current.rects; },
      };
    },
  };
  const window = {
    getComputedStyle() {
      return {paddingLeft: '26.3px', paddingRight: '26.3px',
              paddingTop: '20px', paddingBottom: '40px'};
    },
  };
  const self = {screen, isVertical() { return vertical; }};
  const fn = new Function('document', 'window', 'NodeFilter', 'content', body);
  fn.call(self, document, window, {SHOW_TEXT: 4}, content);
  return {props, removed};
}

const col = (left, right) => ({left, right, top: 0, bottom: 700, width: right - left, height: 700});
const row = (top, bottom) => ({left: 30, right: 490, top, bottom, width: 460, height: bottom - top});

// 用户场景：拆屏那一截贴右排（右侧多了 1em 段距），最左列压进左边距。
let r = run({vertical: true, inkRects: [[col(423.7, 461.7)], [col(35.2, 73.2)]]});
const expected = ((26.3 + 499.7) - (35.2 + 461.7)) / 2;
assert(r.props.transform === 'translateX(' + expected + 'px)',
  'split vertical screen must shift its ink to the centre, got ' + r.props.transform);
assert(r.removed.includes('transform'), 'a stale offset from the previous screen must be cleared first');

// 已经居中（< 1px 偏差）的屏不动。
r = run({vertical: true, inkRects: [[col(74.9, 112.9)], [col(413.1, 451.1)]]});
assert(!('transform' in r.props), 'an already-centred screen must stay untouched');

// 横排走 block 轴 = 竖直方向，用 top/bottom padding。
r = run({vertical: false, inkRects: [[row(20, 60)], [row(600, 640)]]});
const expectedY = ((20 + 760) - (20 + 640)) / 2;
assert(r.props.transform === 'translateY(' + expectedY + 'px)',
  'horizontal screen must centre on the vertical axis, got ' + r.props.transform);

// 墨迹比内容盒还宽（不可拆的溢出屏）：保持屏首可见，不动。
r = run({vertical: true, inkRects: [[col(-80, -40)], [col(460, 499)]]});
assert(!('transform' in r.props), 'overflowing ink must not be pushed off both edges');

// 含图片/媒体的屏交回 flex 居中（图片晚加载会让偏移过期）。
r = run({vertical: true, hasMedia: true, inkRects: [[col(423.7, 461.7)], [col(35.2, 73.2)]]});
assert(!('transform' in r.props), 'screens with media keep the flex centring');

process.stdout.write('OK');
''';
