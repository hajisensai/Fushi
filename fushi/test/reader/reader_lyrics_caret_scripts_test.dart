import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_lyrics_caret_scripts.dart';

void main() {
  group('ReaderLyricsCaretScripts.source()', () {
    final String src = ReaderLyricsCaretScripts.source();

    test('defines the fushiLyricsCaret object and core API', () {
      expect(src, contains('window.fushiLyricsCaret'));
      for (final String fn in <String>[
        'enter:',
        'exit:',
        'move:',
        'lookup:',
        'activate:',
        'scrollPage:',
        'refresh:',
        'init:',
        'suspend:',
        'resume:',
      ]) {
        expect(src, contains(fn), reason: 'missing $fn');
      }
    });

    test('line moves go through cue index + __lyricsScrollToCue', () {
      expect(src, contains('__lyricsScrollToCue'));
      expect(src, contains('__lyricsGetCurrentIndex'));
      expect(src, contains('_lineMove'));
    });

    test('lookup reuses fushiSelection.selectFromPosition with cue context',
        () {
      expect(src, contains('window.fushiSelection'));
      expect(src, contains('selectFromPosition'));
      expect(src, contains('__lyricsCueContext'));
      expect(src, contains('data-text-fragment-id'));
    });
  });

  group('ReaderLyricsCaretScripts invocations target fushiLyricsCaret', () {
    test('enter/exit/move/scrollPage/lookup/activate/refresh', () {
      expect(ReaderLyricsCaretScripts.enterInvocation(),
          'JSON.stringify(window.fushiLyricsCaret.enter())');
      expect(ReaderLyricsCaretScripts.exitInvocation(),
          'window.fushiLyricsCaret.exit()');
      expect(ReaderLyricsCaretScripts.moveInvocation('up'),
          "JSON.stringify(window.fushiLyricsCaret.move('up'))");
      expect(ReaderLyricsCaretScripts.scrollPageInvocation(true),
          'JSON.stringify(window.fushiLyricsCaret.scrollPage(true))');
      expect(ReaderLyricsCaretScripts.lookupInvocation(),
          'window.fushiLyricsCaret.lookup()');
      expect(ReaderLyricsCaretScripts.activateInvocation(),
          'window.fushiLyricsCaret.activate()');
      expect(ReaderLyricsCaretScripts.refreshInvocation(),
          'JSON.stringify(window.fushiLyricsCaret.refresh())');
      expect(ReaderLyricsCaretScripts.suspendInvocation(),
          'window.fushiLyricsCaret.suspend()');
      expect(ReaderLyricsCaretScripts.resumeInvocation(),
          'JSON.stringify(window.fushiLyricsCaret.resume())');
      expect(ReaderLyricsCaretScripts.longPressInvocation(),
          'window.fushiLyricsCaret.longPress()');
    });

    test('initInvocation carries ring color', () {
      final String js = ReaderLyricsCaretScripts.initInvocation(
        color: 'rgba(1,2,3,0.98)',
        insetTop: 10,
        insetBottom: 0,
      );
      expect(js, contains('window.fushiLyricsCaret.init('));
      expect(js, contains('rgba(1,2,3,0.98)'));
    });

    // 竖排歌词：句子是右起左排的列、字自上而下，方向键转 90°（←/→ 换句、↑/↓
    // 句内逐字）；横排映射不变。在 node 里真执行 move() 验映射。无 node 时 skip。
    test('arrow keys rotate with vertical lyrics (executes move via node)',
        () async {
      final String? node = _resolveNode();
      if (node == null) {
        markTestSkipped('node not found on PATH');
        return;
      }
      final Directory dir =
          Directory.systemTemp.createTempSync('lyrics_caret_vertical');
      final File js = File('${dir.path}${Platform.pathSeparator}h.js')
        ..writeAsStringSync('var window = {}; var document = '
            '{ contains: function() { return true; } };\n'
            '${ReaderLyricsCaretScripts.source()}\n$_moveHarness');
      try {
        final ProcessResult r = await Process.run(node, <String>[js.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect('${r.stdout}', contains('MOVE_OK'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

const String _moveHarness = r'''
var c = window.fushiLyricsCaret;
var log = [];
c.active = true;
c.node = {};
c._lineMove = function(f) { log.push(f ? 'nextCue' : 'prevCue'); return {}; };
c._stepInCue = function(f) { log.push(f ? 'nextChar' : 'prevChar'); return null; };
function run(vertical) {
  window.__lyricsVertical = vertical;
  log = [];
  ['up', 'down', 'left', 'right'].forEach(function(d) { c.move(d); });
  return log.join(',');
}
var h = run(false), v = run(true);
if (h !== 'prevCue,nextCue,prevChar,nextChar') throw new Error('horizontal ' + h);
if (v !== 'prevChar,nextChar,nextCue,prevCue') throw new Error('vertical ' + v);
console.log('MOVE_OK');
''';

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final List<String> dirs = <String>[
    ...(Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ];
  for (final String d in dirs) {
    if (d.isEmpty) continue;
    final File f = File('$d${Platform.pathSeparator}$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}
