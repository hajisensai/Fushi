import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_caret_scripts.dart';

void main() {
  test(
    'continuous caret viewport stays in client coordinates after scrolling',
    () {
      final Directory temp = Directory.systemTemp.createTempSync(
        'fushi-caret-viewport-',
      );
      final File payload = File('${temp.path}/caret.json')
        ..writeAsStringSync(
          jsonEncode(<String, String>{'caret': ReaderCaretScripts.source()}),
        );
      late final ProcessResult result;
      try {
        result = Process.runSync(
          'node',
          <String>['-e', _runner, payload.path],
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
            'caret viewport behavior failed:\n'
            'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout.toString().trim(), 'OK');
    },
  );
}

const String _runner = r'''
const fs = require('fs');
const source = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).caret;
function assert(value, message) { if (!value) throw new Error(message); }
const marker = 'window.fushiCaret = {';
const start = source.indexOf(marker);
const brace = source.indexOf('{', start);
const end = source.indexOf('\n};', brace);
assert(start >= 0 && end > brace, 'fushiCaret object missing');
const literal = source.slice(brace, end + 2);

function instantiate({paged, vertical, bodyLeft, bodyTop}) {
  const root = {};
  const body = {
    clientWidth: 375,
    clientHeight: 2400,
    getBoundingClientRect: () => ({
      left: bodyLeft, top: bodyTop,
      right: bodyLeft + 375, bottom: bodyTop + 2400,
      width: 375, height: 2400
    })
  };
  const document = {documentElement: root, body};
  const window = {
    innerWidth: 0,
    innerHeight: 0,
    fushiReader: paged ? {paginationMetrics: {}} : {},
  };
  const getComputedStyle = element => element === root
    ? {getPropertyValue: name => name === '--page-width' ? '375px' :
        (name === '--reader-viewport-height' ? '667px' : '')}
    : {writingMode: vertical ? 'vertical-rl' : 'horizontal-tb'};
  const factory = new Function(
    'window', 'document', 'getComputedStyle',
    'window.fushiCaret = ' + literal + '; return window.fushiCaret;'
  );
  return factory(window, document, getComputedStyle);
}

// Continuous mode scrolls documentElement; body is content and its border box
// moves to -scrollY. Character rects stay in client coordinates.
const continuous = instantiate({
  paged: false, vertical: false, bodyLeft: 0, bodyTop: -1600
});
const visible = {left: 20, top: 100, right: 40, bottom: 120, width: 20, height: 20};
assert(continuous._inViewport(visible),
  'continuous viewport was incorrectly anchored to scrolled body.top');

// Paged vertical-rl uses the body's negative horizontal page frame.
const pagedVertical = instantiate({
  paged: true, vertical: true, bodyLeft: -375, bodyTop: 0
});
const pageGlyph = {left: -350, top: 100, right: -330, bottom: 120, width: 20, height: 20};
assert(pagedVertical._inViewport(pageGlyph),
  'paged vertical body frame must keep its negative horizontal anchor');

process.stdout.write('OK');
''';
