import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 反馈 a6XkWp0Ot4：歌词模式横排「左边距」调的是右边、「右边距」调的是左边。CSS
/// `padding` 四值简写的顺序是「上 右 下 左」，首屏生成与 JS 热更新两条路径都把
/// marginLeft 填进了第 2 位（右）、marginRight 填进了第 4 位（左）。这里按 CSS 语义
/// 解析四值简写，断言左边距落在 padding-left、右边距落在 padding-right，横竖排、
/// 首屏 CSS 与热更新 JS 同一口径。
AudioCue _cue(int i) => AudioCue()
  ..id = i + 1
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = '行$i'
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

String _doc({required bool vertical}) => LyricsModeHtml.generate(
  cues: <AudioCue>[_cue(0), _cue(1)],
  currentIndex: 0,
  backgroundColor: 'transparent',
  textColor: '#888888',
  accentColor: '#3366cc',
  fontSize: 24,
  vertical: vertical,
  marginTop: 3,
  marginBottom: 7,
  marginLeft: 19,
  marginRight: 11,
);

/// 把 `padding:` 四值简写按顶层空格切开（`calc(...)` 内的空格不切）。
List<String> _paddingSides(String value) {
  final List<String> out = <String>[];
  final StringBuffer cur = StringBuffer();
  int depth = 0;
  for (final int unit in value.trim().codeUnits) {
    final String ch = String.fromCharCode(unit);
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ' ' && depth == 0) {
      if (cur.isNotEmpty) out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty) out.add(cur.toString());
  return out;
}

/// 生成文档里 `.lyrics-container { ... }` 规则的 padding 值。
String _containerPadding(String doc) {
  final int rule = doc.indexOf('.lyrics-container {');
  expect(rule, isNonNegative, reason: '找不到 .lyrics-container 规则');
  final int end = doc.indexOf('}', rule);
  final String body = doc.substring(rule, end);
  final RegExpMatch? m = RegExp(r'padding:\s*([^;]+);').firstMatch(body);
  expect(m, isNotNull, reason: '.lyrics-container 规则里没有 padding');
  return m!.group(1)!;
}

String _applyPaddingFn(String doc) {
  const String start = 'function __lyricsApplyContainerPadding(';
  final int from = doc.indexOf(start);
  expect(from, isNonNegative, reason: '找不到 __lyricsApplyContainerPadding');
  final int to = doc.indexOf('\n}\n', from);
  return doc.substring(from, to + 2);
}

Future<String> _runApplyPadding(String doc, {required bool vertical}) async {
  final Directory dir = Directory.systemTemp.createTempSync('lyrics-margin-');
  try {
    final File script = File('${dir.path}/verify.js')
      ..writeAsStringSync('''
var __lyricsVertical = $vertical;
${_applyPaddingFn(doc)}
var r = {style: {}};
__lyricsApplyContainerPadding(r, 3, 7, 19, 11);
process.stdout.write('PADDING=' + r.style.padding);
''');
    final ProcessResult result = await Process.run('node', <String>[
      script.path,
    ], runInShell: Platform.isWindows);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final String out = '${result.stdout}';
    expect(out, startsWith('PADDING='));
    return out.substring('PADDING='.length);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  group('歌词模式左右边距落在对应的物理边（反馈 a6XkWp0Ot4）', () {
    test('横排首屏 CSS：第 2 位（右）= 右边距，第 4 位（左）= 左边距', () {
      final List<String> sides = _paddingSides(
        _containerPadding(_doc(vertical: false)),
      );
      expect(sides, hasLength(4));
      expect(sides[1], '11.0vw', reason: 'padding-right 应是右边距 11');
      expect(sides[3], '19.0vw', reason: 'padding-left 应是左边距 19');
      expect(sides[0], contains('3.0vh'));
      expect(sides[2], contains('7.0vh'));
    });

    test('竖排首屏 CSS：右侧居中余量叠右边距，左侧叠左边距', () {
      final List<String> sides = _paddingSides(
        _containerPadding(_doc(vertical: true)),
      );
      expect(sides, hasLength(4));
      expect(sides[1], '56.0vw');
      expect(sides[3], '64.0vw');
    });

    test('横排 JS 热更新与首屏同序：第 2 位右边距、第 4 位左边距', () async {
      final List<String> sides = _paddingSides(
        await _runApplyPadding(_doc(vertical: false), vertical: false),
      );
      expect(sides, hasLength(4));
      expect(sides[1], '11vw', reason: 'padding-right 应是右边距 11');
      expect(sides[3], '19vw', reason: 'padding-left 应是左边距 19');
    });

    test('竖排 JS 热更新：右侧叠右边距，左侧叠左边距', () async {
      final List<String> sides = _paddingSides(
        await _runApplyPadding(_doc(vertical: true), vertical: true),
      );
      expect(sides, hasLength(4));
      expect(sides[1], 'calc(45vw + 11vw)');
      expect(sides[3], 'calc(45vw + 19vw)');
    });
  });
}
