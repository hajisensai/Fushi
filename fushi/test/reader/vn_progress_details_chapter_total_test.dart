import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

/// BUG-2556：VN 模式下宿主 `fushiProgressDetails` 的分母必须是**章级**字数。
///
/// VN 把整章正文 detach 进游离的 sourceRoot，document 里只剩当前一屏的克隆；它不带
/// 分页 shell 的 `paginationMetrics`，宿主退到 `createWalker()` 兜底时 VN 的 walker
/// 默认根是当前屏，数出来的「章总字数」其实是本屏字数。于是 `round(p × 本屏字数)`
/// 恒为 0、progress 恒 0.0，Dart `_debouncedSaveReaderPosition` 的「与上次相差
/// < 0.001 不落库」把每一次翻屏都当没动，charOffset 一次也进不了库；渐显未完成时
/// walker 还会剔掉未揭示节点让 total 归 0、整段返空串。
///
/// 与 `reader_production_js_behavior_test.dart` 同一范式：从生产引擎源码切出
/// `window.fushiProgressDetails` 原文，node 真跑，喂一个 VN 形态的替身 reader。
void main() {
  test('VN 形态 reader（无 paginationMetrics、有 totalChapterChars）分母取章级字数', () {
    final String payload = jsonEncode(<String, String>{
      'engine': readerFushiEngineSourceUncompacted(vnMode: true),
    });
    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi-vn-progress-total-',
    );
    final File payloadFile = File('${temp.path}/payload.json')
      ..writeAsStringSync(payload);
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>['-e', _nodeRunner, payloadFile.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason: 'VN progress-details runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

const String _nodeRunner = r'''
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}
const start = data.engine.indexOf('window.fushiProgressDetails = function()');
const end = data.engine.indexOf('\n  };', start);
assert(start >= 0 && end > start, 'production progress assembly missing');
const source = data.engine.slice(start, end + 5);
const win = {};
new Function('window', source)(win);

// 当前屏 54 字的 walker（VN createWalker() 不传根时只走 this.screen）。
function screenWalker(chars) {
  let done = false;
  return {
    nextNode() {
      if (done) return null;
      done = true;
      return {textContent: 'x'.repeat(chars)};
    }
  };
}
const vn = {
  totalChapterChars: 648,
  calculateProgress: () => 0.25,
  createWalker: () => screenWalker(54),
  countChars: (text) => text.length,
  getFirstVisibleCharOffset: () => 162,
  getLastVisibleCharOffset: () => 216,
  isAtEnd: () => false
};
win.fushiReader = vn;
assert(win.fushiProgressDetails() === '162,648,162,216',
  'VN must report the chapter-level total, not the current screen: got '
    + win.fushiProgressDetails());

// 渐显未完成：walker 剔掉未揭示节点 → 本屏 0 字。修前整段返空串（被当纯图片章）。
vn.createWalker = () => screenWalker(0);
assert(win.fushiProgressDetails() === '162,648,162,216',
  'unrevealed screen must not collapse the snapshot to empty: got '
    + win.fushiProgressDetails());

// 末屏：钳到章级 total。
vn.isAtEnd = () => true;
vn.calculateProgress = () => 1;
vn.getFirstVisibleCharOffset = () => 600;
vn.getLastVisibleCharOffset = () => 648;
assert(win.fushiProgressDetails() === '648,648,600,648',
  'VN terminal screen must clamp to the chapter total: got '
    + win.fushiProgressDetails());

// 分页 shell 契约不变：paginationMetrics.totalChars 仍优先于 totalChapterChars。
win.fushiReader = {
  paginationMetrics: {totalChars: 100},
  totalChapterChars: 999,
  calculateProgress: () => 0.9,
  getFirstVisibleCharOffset: () => 7,
  isAtEnd: () => false
};
assert(win.fushiProgressDetails() === '90,100,7',
  'paginationMetrics must keep precedence: got ' + win.fushiProgressDetails());

// 真没有章级计数的 shell（纯图片章）：仍走 walker → 空串 / 合成终态。
win.fushiReader = {
  calculateProgress: () => 0.5,
  createWalker: () => screenWalker(0),
  countChars: (text) => text.length,
  getFirstVisibleCharOffset: () => -1,
  isAtEnd: () => false
};
assert(win.fushiProgressDetails() === '',
  'pure-image middle page must stay empty: got ' + win.fushiProgressDetails());

process.stdout.write('OK');
''';
