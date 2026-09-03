import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show
        buildSpreadPageHtml,
        kPagedWheelGestureHelperJs,
        readerFushiEngineSourceUncompacted;

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// PR#912 / BUG-1745 收口：分页滚轮手势桥必须只有**一份**实现。
///
/// 背景：BUG-1745 的修法（触摸板 vs 鼠标分流 + 主轴抖动余量）只改到了正文引擎
/// 那份 JS，spread 双页文档里**手抄的第二份**原样留着——旧的「轴」判据、只传
/// 2 个参数，落到 Dart 侧的兼容回落 `axis == 'horizontal' ? 'trackpad' : 'mouse'`
/// 把纵向恒判成 'mouse'、绕过 `ReaderWheelGestureGate`，于是双页模式下触摸板
/// 上下滑一次照样翻 3 页。**手抄本身就是漏改的直接原因**，所以这里守的不是
/// 「两份实现语义相同」，而是「源码里根本不存在第二份」。
///
/// 三层：
/// ① 同源：两个注入点的产物都**逐字包含** [kPagedWheelGestureHelperJs]；
/// ② 唯一：全语料里 `function _isTrackpadWheel(` / `function _handlePagedWheelTick(`
///    / `callHandler('onWheelPaginate'` 各只出现一次（再抄一遍立刻转红）；
/// ③ 行为：把 **生产 spread HTML 里的脚本**原样丢进 node 真跑，断言四条
///    `_isTrackpadWheel` 判据与主轴抖动余量都真的生效。第三层是本 PR 核心新逻辑
///    此前**零覆盖**的那块——`_isTrackpadWheel` 整个改成 `return false` 以前全套
///    测试照样绿。
void main() {
  group('BUG-1745 分页滚轮手势桥单一真值源', () {
    test('正文引擎与 spread 双页文档拼的是同一份常量（逐字包含）', () {
      expect(
          kPagedWheelGestureHelperJs, contains('function _isTrackpadWheel(e)'),
          reason: '常量本体就是那份 JS，空壳常量骗不过后两条断言但先在这里挡一道');

      // 正文引擎：取压缩**之前**那份（压缩器会删整行注释，逐字比对必须在压缩前做）。
      final String engine = readerFushiEngineSourceUncompacted();
      expect(engine, contains(kPagedWheelGestureHelperJs),
          reason: '正文引擎必须拼常量本体，而不是自己再写一份');

      final String spread = buildSpreadPageHtml(
        leftUrl: 'fushi.local/l.png',
        rightUrl: 'fushi.local/r.png',
        swipeDistThreshold: 44,
        swipeFastDistThreshold: 22,
      );
      expect(spread, contains(kPagedWheelGestureHelperJs),
          reason: 'spread 文档必须拼同一份常量；手抄第二遍正是 BUG-1745 漏改的根因');
    });

    test('全语料里没有第二份实现', () {
      // 语料 = 主壳 + 全部 part（常量声明与两个注入点都在里面）。掩码后注释里的
      // 同名文本不算数——本组要数的是**真代码**里的定义/调用次数。
      final String source = maskCommentsAndScriptLines(readReaderPageSource());
      int countOf(String needle) {
        int n = 0;
        int i = source.indexOf(needle);
        while (i >= 0) {
          n++;
          i = source.indexOf(needle, i + needle.length);
        }
        return n;
      }

      expect(countOf('function _isTrackpadWheel(e)'), 1,
          reason: '触摸板判据只能有一份定义（第二份 = BUG-1745 的复发形状）');
      expect(countOf('function _handlePagedWheelTick(e)'), 1,
          reason: '分页 wheel tick 只能有一份定义');
      expect(countOf("callHandler('onWheelPaginate'"), 1,
          reason: '滚轮桥的回传点只能有一处；spread 若再自己 callHandler 一次，'
              '参数漏传就又会落进 Dart 侧的 2 参兼容回落');
    });

    test('spread 生产 HTML 真跑：四条触摸板判据 + 主轴抖动余量（行为级）', () {
      final String html = buildSpreadPageHtml(
        leftUrl: 'fushi.local/l.png',
        rightUrl: 'fushi.local/r.png',
        swipeDistThreshold: 44,
        swipeFastDistThreshold: 22,
      );
      final Directory temp =
          Directory.systemTemp.createTempSync('hibiki-pr912-wheel-js-');
      final File payload = File('${temp.path}/payload.json')
        ..writeAsStringSync(jsonEncode(<String, String>{'html': html}));
      late final ProcessResult result;
      try {
        result = Process.runSync(
          'node',
          <String>['-e', _wheelKindRunner, payload.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
      expect(
        result.exitCode,
        0,
        reason: 'paged wheel kind runner failed:\n'
            'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout.toString().trim(), 'OK');
    });
  });
}

/// node 行为跑手：从生产 spread HTML 里抠出 `<script>` 原样执行，喂真实形状的
/// wheel 事件，断言桥回传的**第 4 个参数**（'trackpad' / 'mouse'）与主轴。
///
/// 断言依赖的字面量（写进注释供变异实测对照）：
/// - `'trackpad'` / `'mouse'`：`_isTrackpadWheel(e) ? 'trackpad' : 'mouse'`
/// - `PAGED_WHEEL_AXIS_MARGIN = 6`：`absX > absY + PAGED_WHEEL_AXIS_MARGIN`
/// - 120 的整数倍：`Math.abs(wd) % 120 !== 0`
/// - 分数增量：`dx % 1 !== 0 || dy % 1 !== 0`
/// - 两轴同时非零：`dx > 0 && dy > 0`
/// - line/page 模式：`e.deltaMode !== 0`
const String _wheelKindRunner = r'''
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}
const html = data.html;
const open = html.indexOf('<script>');
const close = html.indexOf('</script>', open);
assert(open >= 0 && close > open, 'spread script block missing');
const script = html.slice(open + '<script>'.length, close);

const docListeners = {};
const document = {
  querySelectorAll() { return []; },
  addEventListener(type, fn, options) {
    const capture = options === true || (options && options.capture === true);
    const key = type + (capture ? ':capture' : '');
    (docListeners[key] = docListeners[key] || []).push(fn);
  }
};
const calls = [];
const window = {
  flutter_inappwebview: {callHandler: (...args) => calls.push(args)}
};
new Function('window', 'document', script)(window, document);
calls.length = 0;

function wheel(e) {
  calls.length = 0;
  const evt = Object.assign({preventDefault() {}}, e);
  (docListeners['wheel'] || []).slice().forEach(fn => fn(evt));
  return calls[0];
}

// mouse notch: deltaMode=0, integer deltas, wheelDelta on the 120 grid.
let c = wheel({deltaMode: 0, deltaX: 0, deltaY: 120, wheelDeltaX: 0, wheelDeltaY: -120});
assert(c && c[0] === 'onWheelPaginate', 'wheel bridge missing');
assert(c[1] === 'forward' && c[2] === 'vertical' && c[3] === 'mouse',
  'a classic mouse notch must report mouse, got ' + JSON.stringify(c));

// deltaMode !== 0 (line / page) is produced by real wheels only.
c = wheel({deltaMode: 1, deltaX: 0, deltaY: 3, wheelDeltaX: 0, wheelDeltaY: -53});
assert(c[3] === 'mouse', 'deltaMode!==0 must classify as mouse, got ' + JSON.stringify(c));

// trackpad criterion 1: fractional pixel deltas.
c = wheel({deltaMode: 0, deltaX: 0, deltaY: 13.5, wheelDeltaX: 0, wheelDeltaY: -40.5});
assert(c[3] === 'trackpad',
  'fractional delta is trackpad-only, got ' + JSON.stringify(c));

// trackpad criterion 2: both axes non-zero = 2D gesture.
c = wheel({deltaMode: 0, deltaX: 3, deltaY: 7, wheelDeltaX: -360, wheelDeltaY: -840});
assert(c[3] === 'trackpad',
  'both axes non-zero is a 2D gesture, got ' + JSON.stringify(c));

// trackpad criterion 3: wheelDeltaY off the 120 grid.
c = wheel({deltaMode: 0, deltaX: 0, deltaY: 53, wheelDeltaX: 0, wheelDeltaY: -159});
assert(c[3] === 'trackpad',
  'wheelDeltaY off the 120 grid is trackpad, got ' + JSON.stringify(c));

// trackpad criterion 4: wheelDeltaX off the 120 grid.
c = wheel({deltaMode: 0, deltaX: 53, deltaY: 0, wheelDeltaX: -159, wheelDeltaY: 0});
assert(c[3] === 'trackpad',
  'wheelDeltaX off the 120 grid is trackpad, got ' + JSON.stringify(c));

// BUG-1745 axis jitter margin: a 2px lead stays on the vertical axis.
c = wheel({deltaMode: 0, deltaX: 10, deltaY: 8, wheelDeltaX: -300, wheelDeltaY: -240});
assert(c[2] === 'vertical',
  'a 2px lead over the other axis must stay inside the jitter margin, got ' +
  JSON.stringify(c));
// A 12px lead is beyond the margin = genuinely horizontal.
c = wheel({deltaMode: 0, deltaX: 20, deltaY: 8, wheelDeltaX: -600, wheelDeltaY: -240});
assert(c[2] === 'horizontal',
  'a lead beyond the jitter margin must report horizontal, got ' +
  JSON.stringify(c));

// The reported user symptom: vertical trackpad inertia turning 3 pages at once.
c = wheel({deltaMode: 0, deltaX: 0, deltaY: 4.2, wheelDeltaX: 0, wheelDeltaY: -12.6});
assert(c[2] === 'vertical' && c[3] === 'trackpad',
  'vertical trackpad inertia must be reported as trackpad, got ' +
  JSON.stringify(c));

process.stdout.write('OK');
''';
