import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

void main() {
  test('production reader JS executes terminal and VN media behavior', () {
    final String payload = jsonEncode(<String, String>{
      'paged': ReaderPaginationScripts.paginatedShellSource(),
      'continuous': ReaderPaginationScripts.continuousShellSource(),
      'vn': ReaderVisualNovelScripts.vnShellScript(),
      'engine': readerHibikiEngineSourceUncompacted(),
    });
    final Directory temp = Directory.systemTemp.createTempSync(
      'hibiki-reader-production-js-',
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
      reason: 'production JS behavior runner failed:\n'
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
assert(mergeInput.length === 3, 'zero-width media was not attached');
assert(mergeInput[1] === mixed, 'non-zero-width mixed media was rearranged');
assert(mergeInput[0].mediaStop === true && mergeInput[0].endCharCount === 10,
  'leading media did not attach to following text');
assert(mergeInput[2].mediaStop === true && mergeInput[2].endCharCount === 30,
  'middle/tail media did not remain visible with adjacent text');

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
