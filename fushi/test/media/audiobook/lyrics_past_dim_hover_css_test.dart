import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';

/// 反馈 M8YDOqJ5Bm：歌词模式里鼠标悬停在**已播放**的句子上不高亮，未播放的高亮。
///
/// 根因是 CSS 优先级：已读淡化规则 `body.ly-past-dim:not(.ly-browsing) .cue…:not(.current ~ .cue)`
/// 整体 (0,6,1)（`:not(.current ~ .cue)` 按参数计 (0,2,0)），高过悬停规则
/// `body.ly-themed .cue:not(.current):hover` 的 (0,4,1)，已读行的透明度永远由淡化规则
/// 决定。修法是把悬停作为状态写进淡化判据（「已读且没被悬停」才淡化），不堆优先级、
/// 不加 !important。这里钉住生成器契约：凡在 `.cue` 上设透明度的已读淡化规则都必须
/// 排除 `:hover`。（WebView 里的真实 getComputedStyle 需 Windows itest，本层是可落地的
/// 最强契约。）
void main() {
  AudioCue cue(int i) => AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = ''
    ..text = 'cue $i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  test('every past-dim .cue opacity rule excludes :hover', () {
    final String html = LyricsModeHtml.generate(
      cues: <AudioCue>[cue(0), cue(1), cue(2), cue(3)],
      currentIndex: 2,
      backgroundColor: 'transparent',
      textColor: 'rgba(0,0,0,1.00)',
      accentColor: 'rgba(255,220,0,1.00)',
      fontSize: 20,
    );
    final Iterable<RegExpMatch> rules = RegExp(
      r'([^{}\n]*body\.ly-past-dim[^{}\n]*\.cue[^{}\n]*)\{([^}]*)\}',
    ).allMatches(html);
    final List<String> selectors = <String>[
      for (final RegExpMatch m in rules)
        if (m.group(2)!.contains('opacity')) m.group(1)!.trim(),
    ];
    expect(selectors, hasLength(4), reason: '基础 + near-1/2/3 四条已读淡化规则');
    for (final String selector in selectors) {
      expect(selector, contains(':not(:hover)'), reason: selector);
    }
    // 悬停规则本身仍在（它是已读行悬停时生效的那条）。
    expect(html, contains('body.ly-themed .cue:not(.current):hover'));
  });
}
