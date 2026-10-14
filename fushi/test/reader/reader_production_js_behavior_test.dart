import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

void main() {
  test('production reader JS executes terminal and VN media behavior', () {
    final String payload = jsonEncode(<String, String>{
      'paged': ReaderPaginationScripts.paginatedShellSource(),
      'continuous': ReaderPaginationScripts.continuousShellSource(),
      'vn': ReaderVisualNovelScripts.vnShellScript(),
      'engine': readerFushiEngineSourceUncompacted(),
    });
    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi-reader-production-js-',
    );
    final File payloadFile = File('${temp.path}/payload.json')
      ..writeAsStringSync(payload);
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>['-e', _nodeBehaviorRunner, payloadFile.path],
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
          'production JS behavior runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

const String _nodeBehaviorRunner = r'''
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}
function objectLiteral(source) {
  const marker = 'window.fushiReader = {';
  const start = source.indexOf(marker);
  if (start < 0) throw new Error('fushiReader object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  if (end < 0) throw new Error('fushiReader object terminator missing');
  return source.slice(brace, end + 2);
}
function fragment() {
  return {
    children: [],
    appendChild(value) { this.children.push(value); return value; }
  };
}
function instantiate(source) {
  const window = {scrollX: 0, CSS: {}, Highlight: function() {}};
  const document = {
    documentElement: {},
    scrollingElement: null,
    createDocumentFragment: fragment
  };
  const C = {
    perfTraceEnabled: false,
    vnRevealSpeed: 0,
    vnScreenMode: 'sentence',
    vnSentencesPerScreen: 1,
    vnPreserveDialogue: false
  };
  const global = {};
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight',
    'window.fushiReader = ' + objectLiteral(source) + '; return window.fushiReader;'
  );
  const reader = factory(window, document, C, global, window.CSS, window.Highlight);
  return {reader, window, document};
}

const paged = instantiate(data.paged);
paged.reader.paginationMetrics = {maxScroll: 100};
paged.reader.getScrollContext = () => ({});
paged.reader.getPagePosition = () => 98;
assert(paged.reader.isAtEnd() === false, 'paged non-terminal misclassified');
paged.reader.getPagePosition = () => 99;
assert(paged.reader.isAtEnd() === true, 'paged terminal clamp not reached');

const continuous = instantiate(data.continuous);
const root = {
  scrollHeight: 1000, clientHeight: 500, scrollTop: 498,
  scrollWidth: 1200, clientWidth: 500, scrollLeft: 0
};
continuous.document.scrollingElement = root;
continuous.reader.isVertical = () => false;
assert(continuous.reader.isAtEnd() === false, 'continuous y non-terminal misclassified');
root.scrollTop = 499;
assert(continuous.reader.isAtEnd() === true, 'continuous y terminal not reached');
continuous.reader.isVertical = () => true;
continuous.window.scrollX = -699;
assert(continuous.reader.isAtEnd() === true, 'continuous vertical-rl terminal not reached');

const vn = instantiate(data.vn);
const restoreCalls = [];
vn.window.flutter_inappwebview = {
  callHandler: (...args) => restoreCalls.push(args)
};
vn.reader.notifyRestoreComplete();
assert(restoreCalls.length === 1 && restoreCalls[0][0] === 'onRestoreComplete',
  'VN restore notification did not reach the production bridge');
vn.reader.screens = [{}, {}, {}];
vn.reader.currentScreenIndex = 1;
assert(vn.reader.isAtEnd() === false, 'VN middle screen misclassified');
vn.reader.currentScreenIndex = 2;
assert(vn.reader.isAtEnd() === true, 'VN last screen not terminal');

function screen(label, start, end, mediaStop) {
  return {
    label, startCharCount: start, endCharCount: end,
    startRawCount: start, endRawCount: end,
    mediaStop, ids: new Set(), render: () => label
  };
}
const lead = screen('lead', 0, 0, true);
const first = screen('first', 0, 10, false);
const mixed = screen('mixed', 10, 20, true);
const middle = screen('middle', 20, 20, true);
const second = screen('second', 20, 30, false);
const tail = screen('tail', 30, 30, true);
let mergeInput = null;
vn.reader.screenMode = 'sentence';
vn.reader.buildSentenceScreens = () => [lead, first, mixed, middle, second, tail];
vn.reader.mergeSentenceAudioCrossScreenScreens = screens => {
  mergeInput = screens;
  return screens;
};
vn.reader.fitScreensToViewport = screens => screens;
vn.reader.assignScreenProgressAnchors = () => {};
vn.reader.buildScreens();
// BUG-3395：零宽纯图片屏独占一屏（并进相邻文字屏会让整屏插图把同屏句子挤出屏外）。
assert(mergeInput.length === 6, 'zero-width media must stay on screens of their own');
assert([lead, first, mixed, middle, second, tail].every((s, i) => mergeInput[i] === s),
  'screens must keep source order without rearranging media');

// 跟随跨过图片屏：开图片暂停先停在图上并通知 Dart，关图片暂停 / 向后跟随不停。
const rendered = [];
const detected = [];
vn.window.flutter_inappwebview = {
  callHandler: (name) => detected.push(name)
};
vn.reader.screens = [first, middle, second, tail];
vn.reader.renderScreen = (index) => {
  rendered.push(index);
  vn.reader.currentScreenIndex = index;
};
vn.reader.currentScreenIndex = 0;
assert(vn.reader.pauseAtCrossedMediaScreen(2, false, false) === false && !rendered.length,
  'image pause off must not stop on the image screen');
assert(vn.reader.pauseAtCrossedMediaScreen(2, true, false) === true &&
  rendered.join() === '1' && detected.join() === 'onImageDetected',
  'forward follow must stop on the crossed image screen and notify Dart');
assert(vn.reader.pauseAtCrossedMediaScreen(2, true, false) === false,
  'resuming from the image screen must go on to the sentence screen');
vn.reader.currentScreenIndex = 2;
assert(vn.reader.pauseAtCrossedMediaScreen(0, true, false) === false,
  'backward follow must not stop on images');
vn.reader.screens = [lead, first];
vn.reader.currentScreenIndex = 1;
rendered.length = 0;
assert(vn.reader.pauseAtCrossedMediaScreen(1, true, true) === true && rendered.join() === '0',
  'audio arriving from the previous chapter must stop on the chapter-start image');

const progressStart = data.engine.indexOf('window.fushiProgressDetails = function()');
const progressEnd = data.engine.indexOf('\n  };', progressStart);
assert(progressStart >= 0 && progressEnd > progressStart,
  'production progress assembly missing');
const progressSource = data.engine.slice(progressStart, progressEnd + 5);
const progressWindow = {};
new Function('window', progressSource)(progressWindow);
const progressReader = {
  calculateProgress: () => 0.9,
  paginationMetrics: {totalChars: 100},
  getFirstVisibleCharOffset: () => 7,
  isAtEnd: () => false
};
progressWindow.fushiReader = progressReader;
assert(progressWindow.fushiProgressDetails() === '90,100,7',
  'non-terminal progress must remain fractional');
progressReader.isAtEnd = () => true;
assert(progressWindow.fushiProgressDetails() === '100,100,7',
  'physical terminal must clamp to total');
progressReader.paginationMetrics = {totalChars: 0};
progressReader.isAtEnd = () => false;
assert(progressWindow.fushiProgressDetails() === '',
  'pure-image middle page must not complete');
progressReader.isAtEnd = () => true;
assert(progressWindow.fushiProgressDetails() === '1,1,-1',
  'pure-image terminal must emit the synthetic completion snapshot');

process.stdout.write('OK');
''';
