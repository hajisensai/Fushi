// 「我库里的例句」各模块文档构造：书的阅读器锚点（学习单位）、字幕 / 歌词的时间口径、指纹。
// 真 fushi_corpus（切句）与 fushi_compute（学习单位前缀）原生库：找不到库直接红。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/corpus/corpus_documents.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_engine/stats/study_char_count.dart';
import 'package:fushi_music/fushi_music.dart';

AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'v'
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

void main() {
  test('书：句子定位 = 章内学习单位前缀（阅读器 charAnchor 同一把尺子）', () {
    const String text = '「行こう。」と彼は言った。 The dog ran home. 𠮷野家に行く';
    final List<CorpusSentence> sentences = bookChapterSentences(3, text);
    expect(sentences.map((CorpusSentence s) => s.text), <String>[
      '「行こう。」',
      'と彼は言った。',
      'The dog ran home.',
      '𠮷野家に行く',
    ]);
    for (final CorpusSentence s in sentences) {
      expect(s.section, 3);
      final int start = text.indexOf(s.text);
      expect(s.pos, countStudyChars(text.substring(0, start)), reason: s.text);
      expect(s.len, countStudyChars(s.text), reason: s.text);
    }
    expect(bookChapterSentences(0, ''), isEmpty);
  });

  test('视频：一条 cue 一句，换行压成空格，纯绘图 / 空行跳过；指纹随内容变', () {
    final CorpusDocument doc = videoCuesDocument(
      bookUid: 'uid',
      episodeIndex: 4,
      title: 'Show',
      cues: <AudioCue>[
        _cue('Hello\nthere', 1000, 2500),
        _cue('   ', 3000, 4000),
        _cue('Bye', 5000, 4000),
      ],
      normalizer: 'n',
      updatedAt: 1,
    );
    expect(doc.kind, CorpusSourceKind.video);
    expect(doc.part, 4);
    expect(doc.sentences.map((CorpusSentence s) => s.text), <String>[
      'Hello there',
      'Bye',
    ]);
    expect(doc.sentences.first.section, 4);
    expect(doc.sentences.first.pos, 1000);
    expect(doc.sentences.first.len, 1500);
    expect(doc.sentences.last.len, 0);
    final CorpusDocument same = videoCuesDocument(
      bookUid: 'uid',
      episodeIndex: 4,
      title: 'Renamed',
      cues: <AudioCue>[
        _cue('Hello\nthere', 1000, 2500),
        _cue('Bye', 5000, 4000),
      ],
      normalizer: 'other',
      updatedAt: 99,
    );
    expect(same.fingerprint, doc.fingerprint);
    final CorpusDocument changed = videoCuesDocument(
      bookUid: 'uid',
      episodeIndex: 4,
      title: 'Show',
      cues: <AudioCue>[_cue('Hello there!', 1000, 2500)],
      normalizer: 'n',
      updatedAt: 1,
    );
    expect(changed.fingerprint, isNot(doc.fingerprint));
  });

  test('歌词：偏移（正 = 歌词提前）折回音频时间，背景和声行跳过', () {
    LyricLine line(String text, int start, int end, {LyricRole? role}) =>
        LyricLine(
          startMs: start,
          endMs: end,
          syllables: <LyricSyllable>[
            LyricSyllable(text: text, startMs: start, endMs: end),
          ],
          role: role ?? LyricRole.main,
        );
    final LyricTimeline timeline = LyricTimeline(
      format: 'lrc',
      lines: <LyricLine>[
        line('夜明けの窓', 1000, 4000),
        line('(ooh)', 1500, 3000, role: LyricRole.background),
        line('開ける', 200, 900),
      ],
      offsetMs: 500,
      source: 'sidecar',
    );
    final CorpusDocument doc = lyricsDocument(
      trackUid: 't',
      title: 'Song',
      timeline: timeline,
      normalizer: 'n',
      updatedAt: 1,
    );
    expect(doc.kind, CorpusSourceKind.music);
    expect(doc.sentences.map((CorpusSentence s) => s.text), <String>[
      '夜明けの窓',
      '開ける',
    ]);
    expect(doc.sentences.first.pos, 500);
    expect(doc.sentences.first.len, 3000);
    expect(doc.sentences.last.pos, 0);
  });
}
