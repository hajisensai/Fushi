import 'package:test/test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_fusion.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';

SubtitleEvidenceCue _cue(
  int start,
  int end,
  String text, [
  SubtitleEvidenceRole role = SubtitleEvidenceRole.dialogue,
]) => SubtitleEvidenceCue(startMs: start, endMs: end, text: text, role: role);

SubtitleEvidenceTrack _track(
  String label,
  String? language,
  List<SubtitleEvidenceCue> cues, {
  SubtitleEvidenceKind kind = SubtitleEvidenceKind.text,
}) => SubtitleEvidenceTrack(
  label: label,
  kind: kind,
  language: language,
  cues: cues,
);

void main() {
  group('语言判定', () {
    test('假名够多判 ja；只有汉字判 zh；谚文 ko；拉丁 en；字太少 null', () {
      expect(detectSubtitleTextLanguage(<String>['今日はいい天気ですね、本当に']), 'ja');
      expect(detectSubtitleTextLanguage(<String>['今天天气很好我们去公园散步吧']), 'zh');
      expect(detectSubtitleTextLanguage(<String>['오늘은 날씨가 정말 좋네요']), 'ko');
      expect(
        detectSubtitleTextLanguage(<String>[
          'That song is really good, right?',
        ]),
        'en',
      );
      expect(detectSubtitleTextLanguage(<String>['はい']), isNull);
    });

    test('文字判得出就信文字；拉丁系只判出 en 时信标签', () {
      expect(
        resolveSubtitleEvidenceLanguage(tagged: 'en', detected: 'ja'),
        'ja',
      );
      expect(
        resolveSubtitleEvidenceLanguage(tagged: 'fr', detected: 'en'),
        'fr',
      );
      expect(
        resolveSubtitleEvidenceLanguage(tagged: 'ja', detected: 'en'),
        'en',
      );
      expect(
        resolveSubtitleEvidenceLanguage(tagged: 'de', detected: null),
        'de',
      );
      expect(sameSubtitleLanguage('zh-Hans', 'zh_Hant'), isTrue);
      expect(sameSubtitleLanguage('ja', null), isFalse);
    });

    test('纯文本角色：♪ 起头是歌，其余台词', () {
      expect(classifyPlainEvidenceText('♪ 君の声が'), SubtitleEvidenceRole.song);
      expect(classifyPlainEvidenceText('おはよう'), SubtitleEvidenceRole.dialogue);
    });
  });

  group('证据索引', () {
    final SubtitleEvidenceTrack jaText = _track(
      'ep08.ja.srt',
      'ja',
      <SubtitleEvidenceCue>[
        _cue(1000, 3000, 'あの曲。'),
        _cue(5000, 7000, '♪ ラララ', SubtitleEvidenceRole.song),
      ],
    );
    final SubtitleEvidenceTrack jaOcr = _track(
      'PGS #3',
      'ja',
      <SubtitleEvidenceCue>[_cue(1000, 3000, 'あの典。')],
      kind: SubtitleEvidenceKind.ocr,
    );
    final SubtitleEvidenceTrack en = _track(
      'ep08.en.ass',
      'en',
      <SubtitleEvidenceCue>[_cue(1100, 2900, 'That song.')],
    );
    final SubtitleEvidenceTrack fr = _track(
      'ep08.fr.srt',
      'fr',
      <SubtitleEvidenceCue>[_cue(1100, 2900, 'Cette chanson.')],
    );
    final SubtitleEvidenceTrack de = _track(
      'ep08.de.srt',
      'de',
      <SubtitleEvidenceCue>[_cue(1100, 2900, 'Das Lied.')],
    );

    test('同语言一条人工 + 一条 OCR；他言語英中优先、限条数', () {
      final SubtitleEvidenceIndex index = SubtitleEvidenceIndex(
        <SubtitleEvidenceTrack>[fr, de, jaOcr, en, jaText],
        targetLanguage: 'ja',
      );
      expect(index.same, <SubtitleEvidenceTrack>[jaText, jaOcr]);
      expect(index.others, hasLength(2));
      expect(index.others.first, en);
    });

    test('重叠不到较短一方 30% 的不算；歌词行不当台词证据', () {
      final SubtitleEvidenceIndex index = SubtitleEvidenceIndex(
        <SubtitleEvidenceTrack>[jaText, en],
        targetLanguage: 'ja',
      );
      final List<SubtitleEvidenceMatch> hit = index.matchesFor(1200, 2800);
      expect(
        <String>[for (final SubtitleEvidenceMatch m in hit) m.text],
        <String>['あの曲。', 'That song.'],
      );
      // 只擦到 2900~3000 的边。
      expect(index.matchesFor(2900, 6000), isEmpty);
      // 5000~7000 是歌词，不给校对当台词。
      expect(index.matchesFor(5000, 7000), isEmpty);
    });

    test('校对提示词：同语言标来源种类，他言語标语言', () {
      final SubtitleEvidenceIndex index = SubtitleEvidenceIndex(
        <SubtitleEvidenceTrack>[jaText, jaOcr, en],
        targetLanguage: 'ja',
      );
      expect(
        formatProofreadEvidenceLines(
          index,
          const SubtitleDraftCue(startMs: 1000, endMs: 3000, text: 'あの局'),
        ),
        <String>[
          '    同言語字幕[字幕]: あの曲。',
          '    同言語字幕[OCR]: あの典。',
          '    他言語字幕(en): That song.',
        ],
      );
    });

    test('无证据的集，校对稳定前缀与改版前逐字相同', () {
      expect(
        buildProofreadStablePrefix(title: 't', glossaryText: ''),
        isNot(contains('補足規則(既存字幕)')),
      );
      expect(
        buildProofreadStablePrefix(
          title: 't',
          glossaryText: '',
          withEvidence: true,
        ),
        contains(kSubtitleProofreadEvidenceRules),
      );
    });

    test('指纹：无轨为空串；内容变了指纹变；编解码往返', () {
      expect(subtitleEvidenceFingerprint(const <SubtitleEvidenceTrack>[]), '');
      final String a = subtitleEvidenceFingerprint(<SubtitleEvidenceTrack>[
        jaText,
      ]);
      final String b = subtitleEvidenceFingerprint(<SubtitleEvidenceTrack>[
        jaOcr,
      ]);
      expect(a, isNot(b));
      final List<SubtitleEvidenceTrack> back = decodeSubtitleEvidenceTracks(
        encodeSubtitleEvidenceTracks(<SubtitleEvidenceTrack>[jaText, jaOcr]),
      );
      expect(
        subtitleEvidenceFingerprint(back),
        subtitleEvidenceFingerprint(<SubtitleEvidenceTrack>[jaText, jaOcr]),
      );
    });
  });

  group('空缺补全', () {
    test('ASR 没覆盖的同语言台词补进来并标来源；已覆盖、太短、歌词不补', () {
      final SubtitleEvidenceIndex index = SubtitleEvidenceIndex(
        <SubtitleEvidenceTrack>[
          _track('ep08.ja.srt', 'ja', <SubtitleEvidenceCue>[
            _cue(1000, 3000, 'もう覆盖済み'),
            _cue(10000, 12000, 'ASR が\n拾えなかった'),
            _cue(15000, 15200, 'え'),
            _cue(20000, 23000, '♪ 歌', SubtitleEvidenceRole.song),
          ]),
          _track('ep08.en.srt', 'en', <SubtitleEvidenceCue>[
            _cue(30000, 32000, 'English only'),
          ]),
        ],
        targetLanguage: 'ja',
      );
      final List<SubtitleDraftCue> out = fillSubtitleGapsFromEvidence(
        const <SubtitleDraftCue>[
          SubtitleDraftCue(startMs: 1000, endMs: 3000, text: 'もう覆盖済み'),
        ],
        index,
      );
      expect(out, hasLength(2));
      expect(out[1].startMs, 10000);
      expect(out[1].text, 'ASR が　拾えなかった');
      expect(out[1].origin, 'ep08.ja.srt');
      expect(out[0].origin, isNull);
    });

    test('OCR 轨不重复补人工轨已补的时段', () {
      final SubtitleEvidenceIndex index = SubtitleEvidenceIndex(
        <SubtitleEvidenceTrack>[
          _track('ja.srt', 'ja', <SubtitleEvidenceCue>[
            _cue(10000, 12000, '人手の字幕です'),
          ]),
          _track('PGS', 'ja', <SubtitleEvidenceCue>[
            _cue(10000, 12000, '人手の宇幕です'),
          ], kind: SubtitleEvidenceKind.ocr),
        ],
        targetLanguage: 'ja',
      );
      final List<SubtitleDraftCue> out = fillSubtitleGapsFromEvidence(
        const <SubtitleDraftCue>[],
        index,
      );
      expect(out, hasLength(1));
      expect(out.single.origin, 'ja.srt');
    });
  });
}
