import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-3368：歌词页复用阅读器的选区脚本，查词高亮有三条绘制路径——
/// `::highlight(fushi-selection)`、旧引擎的 `.fushi-dict-highlight` 包裹、以及
/// `<ruby>` 内的字专用的 `ruby.fushi-selection-ruby-active`（BUG-110：ruby 不进
/// ::highlight，背景要页面自己画）。歌词页只写了前两条，带注音的词（烏滸がましい）
/// 查词时基字永远不亮、只亮后半截，Windows 与 macOS 都一样。
///
/// 类名从真实选区脚本里抽，脚本以后再加高亮类也会被这里咬住。
void main() {
  final String script = ReaderSelectionScripts.source();
  final int from = script.indexOf('highlightSelection: function');
  final int to = script.indexOf('getMatchableOffset: function', from);
  final String highlightBody = script.substring(from, to);

  final Set<String> classes = <String>{
    for (final RegExpMatch m in RegExp(
      r"classList\.add\('([\w-]+)'\)",
    ).allMatches(highlightBody))
      m.group(1)!,
    for (final RegExpMatch m in RegExp(
      r"className = '([\w-]+)'",
    ).allMatches(highlightBody))
      m.group(1)!,
  };

  AudioCue cue(int i, String text) => AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = ''
    ..text = text
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  String styleOf({required bool vertical}) {
    final String doc = LyricsModeHtml.generate(
      cues: <AudioCue>[cue(0, '烏滸がましくて申し訳ない')],
      currentIndex: 0,
      backgroundColor: '#000000',
      textColor: '#888888',
      accentColor: '#3366cc',
      fontSize: 24,
      vertical: vertical,
    );
    return doc.substring(doc.indexOf('<style>'), doc.indexOf('</style>'));
  }

  test('选区脚本挂的高亮类名能抽出来（含 ruby 专用类）', () {
    expect(classes, contains('fushi-selection-ruby-active'));
    expect(classes, contains('fushi-dict-highlight'));
  });

  for (final bool vertical in <bool>[false, true]) {
    test('歌词页给每个查词高亮类都画背景（vertical=$vertical）', () {
      final String style = styleOf(vertical: vertical);
      for (final String cls in classes) {
        final RegExp rule = RegExp(
          '(^|[\\s,}])[\\w.-]*\\.$cls\\s*\\{[^}]*background-color',
        );
        expect(
          rule.hasMatch(style),
          isTrue,
          reason: '歌词页 CSS 缺 .$cls 的背景规则：带注音的字查词时不高亮',
        );
      }
    });
  }

  test('当前行里 ruby 选区的文字色跟随选区文字色（与 ::highlight 一致）', () {
    final String style = styleOf(vertical: true);
    expect(
      style,
      contains(
        '.cue.current ruby.fushi-selection-ruby-active {\n'
        '  color: var(--ly-hl-text',
      ),
    );
  });
}
