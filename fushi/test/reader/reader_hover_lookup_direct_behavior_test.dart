import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// 查词卡顿（P0-2）：阅读器正文的悬停查词在 JS 里直接 `fushiSelection.selectText`，不再
/// 经 `onShiftHover → Dart → evaluateJavascript` 绕一圈；一帧最多选一次，宿主回执
/// （onTextSelected 的 Promise）到达前只留最后一个指针位置。
///
/// 这里把 setup 脚本里那段 mousemove 腿原样切出来，在 node 里配上假的 document /
/// requestAnimationFrame / fushiSelection 跑，逐条验行为（不是源码扫描）。回执 Promise
/// 丢失时，宿主按序号显式调 `window.__fushiHoverLookupSettled(seq)` 释放；迟到的旧回执
/// 不得放掉新一次。
void main() {
  test(
    'hover lookup selects in JS, coalesces per frame and waits for the ack',
    () {
      final String source = File(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final int start = source.indexOf('  var _shiftHoverLastX = -1');
      const String endMarker = '  }, {passive: true});\n';
      final int end = source.indexOf(endMarker, start);
      expect(start, greaterThan(0), reason: 'hover block moved; update test');
      expect(end, greaterThan(start), reason: 'hover block moved; update test');
      final String block = source.substring(start, end + endMarker.length);
      expect(block, contains("addEventListener('mousemove'"));
      expect(block, isNot(contains(r'$')), reason: 'block must be plain JS');

      final Directory temp = Directory.systemTemp.createTempSync(
        'hover-direct-',
      );
      try {
        final File payload = File('${temp.path}/block.json')
          ..writeAsStringSync(jsonEncode(<String, String>{'block': block}));
        final ProcessResult result = Process.runSync(
          'node',
          <String>['-e', _runner, payload.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
        );
        expect(result.stdout.toString().trim(), 'OK 13');
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );

  test('宿主显式释放只认悬停查词与合法序号', () {
    expect(
      ReaderSelectionScripts.hoverLookupSettledInvocation(<String, dynamic>{
        'fromHover': true,
        'selectedSeq': 7,
      }),
      'window.__fushiHoverLookupSettled && window.__fushiHoverLookupSettled(7)',
    );
    // JSON 里的整数可能被解成 double。
    expect(
      ReaderSelectionScripts.hoverLookupSettledInvocation(<String, dynamic>{
        'fromHover': true,
        'selectedSeq': 7.0,
      }),
      endsWith('(7)'),
    );
    for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
      <String, dynamic>{'fromHover': false, 'selectedSeq': 7},
      <String, dynamic>{'selectedSeq': 7},
      <String, dynamic>{'fromHover': true},
      <String, dynamic>{'fromHover': true, 'selectedSeq': 0},
      <String, dynamic>{'fromHover': true, 'selectedSeq': 1.5},
      <String, dynamic>{'fromHover': true, 'selectedSeq': '7'},
      <String, dynamic>{'fromHover': true, 'selectedSeq': double.nan},
    ]) {
      expect(
        ReaderSelectionScripts.hoverLookupSettledInvocation(payload),
        isNull,
        reason: '$payload',
      );
    }
  });
}

const String _runner = r'''
const fs = require('fs');
const block = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).block;
let checks = 0;
function check(cond, msg) { if (!cond) throw new Error(msg); checks++; }

function setup(opts) {
  const listeners = {};
  const frames = [];
  const calls = { select: [], handler: [] };
  let resolveAck = null;
  const window = {
    __fushiHostHoverLookup: !!opts.hostLeg,
    __hoverAutoLookup: !!opts.auto,
    __fushiHoverKey: 'shiftKey',
    __fushiTapGate: { chrome: true, lookup: true, maxLen: 321 },
    flutter_inappwebview: { callHandler: (name, ...args) => { calls.handler.push([name, ...args]); } },
  };
  if (!opts.noSelection) {
    window.fushiSelection = {
      textSelectedSeq: 0,
      lastTextSelectedAck: null,
      selectText(x, y, maxLen, fromHover) {
        calls.select.push([x, y, maxLen, fromHover]);
        if (opts.sameWord && opts.sameWord(x, y)) return null;
        this.textSelectedSeq++;
        this.lastTextSelectedAck = new Promise((r) => { resolveAck = r; });
        return 'word';
      },
    };
  }
  const document = { addEventListener: (type, fn) => { listeners[type] = fn; } };
  const requestAnimationFrame = (fn) => { frames.push(fn); return frames.length; };
  new Function('window', 'document', 'requestAnimationFrame', block)(window, document, requestAnimationFrame);
  return {
    window, calls,
    move(x, y, shift) { listeners.mousemove({ clientX: x, clientY: y, shiftKey: shift !== false }); },
    frame() { const fs = frames.splice(0); fs.forEach((f) => f()); return fs.length; },
    ack() { const r = resolveAck; resolveAck = null; r(null); return Promise.resolve().then(() => {}); },
    // 拿走当前回执的 resolve 而不兑现：模拟平台把 callHandler 的 Promise 弄丢。
    dropAck() { const r = resolveAck; resolveAck = null; return r; },
    seq() { return window.fushiSelection.textSelectedSeq; },
  };
}

(async () => {
  // 1) Several moves inside one frame -> exactly one selectText with the last point.
  let h = setup({});
  h.move(10, 10); h.move(30, 10); h.move(50, 10);
  check(h.calls.select.length === 0, 'selection must wait for the frame');
  h.frame();
  check(JSON.stringify(h.calls.select) === JSON.stringify([[50, 10, 321, true]]),
    'one selectText per frame with the latest point, maxLen from the tap gate, fromHover=true: ' + JSON.stringify(h.calls.select));
  check(h.calls.handler.length === 0, 'no onShiftHover round trip when the selection script is ready');

  // 2) While the host has not acked, keep only the newest point; after the ack send it once.
  h.move(70, 10); h.move(90, 10);
  check(h.frame() === 0 && h.calls.select.length === 1, 'nothing is sent while a lookup is in flight');
  await h.ack();
  check(h.frame() === 1 && h.calls.select.length === 2 && h.calls.select[1][0] === 90,
    'after the ack the newest pending point is sent: ' + JSON.stringify(h.calls.select));

  // 3) A same-word hit fires nothing, so it never blocks the next frame.
  await h.ack();
  h = setup({ sameWord: (x) => x < 100 });
  h.move(10, 10); h.frame();
  h.move(200, 10); h.frame();
  check(h.calls.select.length === 2 && h.calls.select[1][0] === 200,
    'a deduplicated hover does not wait for an ack that never comes');

  // 5) The ack Promise never settles: the host's explicit settle(seq) releases the lock;
  //    a settle with a stale / unknown sequence number does not.
  h = setup({});
  h.move(10, 10); h.frame();
  const lostAck = h.dropAck();
  const firstSeq = h.seq();
  h.move(200, 10);
  check(h.frame() === 0, 'still waiting while the lost ack is outstanding');
  h.window.__fushiHoverLookupSettled(firstSeq + 5);
  check(h.frame() === 0 && h.calls.select.length === 1, 'a settle with the wrong sequence is ignored');
  h.window.__fushiHoverLookupSettled(firstSeq);
  check(h.frame() === 1 && h.calls.select.length === 2 && h.calls.select[1][0] === 200,
    'the explicit host settle releases a lookup whose ack was lost: ' + JSON.stringify(h.calls.select));

  // 6) The late ack of the first lookup must not release the second one.
  lostAck(null);
  await Promise.resolve(); await Promise.resolve();
  h.move(400, 10);
  check(h.frame() === 0 && h.calls.select.length === 2,
    'a late ack for an older sequence does not release the newer in-flight lookup');
  await h.ack();
  check(h.frame() === 1 && h.calls.select.length === 3 && h.calls.select[2][0] === 400,
    'the newer lookup is released by its own ack');

  // 4) Gates keep their old meaning: host leg, modifier / auto-lookup, missing selection script.
  h = setup({ hostLeg: true }); h.move(10, 10); h.frame();
  const hostQuiet = h.calls.select.length === 0 && h.calls.handler.length === 0;
  h = setup({}); h.move(10, 10, false); h.frame();
  const noKeyQuiet = h.calls.select.length === 0 && h.calls.handler.length === 0;
  h = setup({ auto: true }); h.move(10, 10, false); h.frame();
  check(hostQuiet && noKeyQuiet && h.calls.select.length === 1,
    'host leg / modifier / auto-lookup gates unchanged');
  h = setup({ noSelection: true }); h.move(10, 10); h.frame();
  check(h.calls.handler.length === 1 && h.calls.handler[0][0] === 'onShiftHover',
    'without fushiSelection the old onShiftHover bridge is used');
  console.log('OK ' + checks);
})().catch((e) => { console.error(e && e.stack || e); process.exit(1); });
''';
