// 曲库歌词搜索的语料文档构造：歌词的时间口径与指纹。
import 'package:test/test.dart';
import 'package:fushi/src/corpus/corpus_documents.dart';
import 'package:fushi/src/corpus/library_corpus_service.dart'
    show corpusNormalizerSignature;
import 'package:fushi_dictionary/fushi_dictionary_core.dart' show FushiDicts;
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_music/fushi_music.dart';

void main() {
  test('指纹：同样的输入同一个值，任一部分变了就变', () {
    expect(
      corpusFingerprint(<Object?>['a', 1]),
      corpusFingerprint(<Object?>['a', 1]),
    );
    expect(
      corpusFingerprint(<Object?>['a', 1]),
      isNot(corpusFingerprint(<Object?>['a', 2])),
    );
    // 分隔符：['ab', ''] 与 ['a', 'b'] 不能撞。
    expect(
      corpusFingerprint(<Object?>['ab', '']),
      isNot(corpusFingerprint(<Object?>['a', 'b'])),
    );
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

  test('归一签名：扫描窗口变了签名就变，出厂值时与旧签名逐字相同（反馈 ezCjUoU2QM）', () {
    const List<({String path, int modifiedMs})> dicts =
        <({String path, int modifiedMs})>[
          (path: '/d/jmdict', modifiedMs: 100),
          (path: '/d/daijirin', modifiedMs: 200),
        ];
    final String legacy = corpusFingerprint(<Object?>[
      '/d/jmdict',
      100,
      '/d/daijirin',
      200,
    ]);
    expect(
      corpusNormalizerSignature(
        dictionaries: dicts,
        scanLength: FushiDicts.defaultScanLength,
      ),
      legacy,
    );
    final String s24 = corpusNormalizerSignature(
      dictionaries: dicts,
      scanLength: 24,
    );
    expect(s24, isNot(legacy));
    expect(
      corpusNormalizerSignature(dictionaries: dicts, scanLength: 32),
      isNot(s24),
    );
  });
}
