import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:test/test.dart';

MangaAudiobookClip _clip(
  int startMs,
  int endMs, {
  String? book = 'novel',
  int file = 0,
}) => MangaAudiobookClip(
  bookKey: book,
  fileIndex: file,
  startMs: startMs,
  endMs: endMs,
);

MangaScriptLine _line(
  int page,
  int block, {
  MangaLineAudioSource audio = const MangaSynthesized(),
  String? voice,
  CastLineKind kind = CastLineKind.spoken,
}) => MangaScriptLine(
  page: page,
  blocks: <int>[block],
  speaker: 'A',
  kind: kind,
  audio: audio,
  voice: voice,
);

void main() {
  group('pickMangaNarratorRefs', () {
    test('只取时长在上下限之间的片段；按时长取最长的 3 段，结果按阅读顺序排', () {
      final List<MangaAudiobookClip> clips = <MangaAudiobookClip>[
        _clip(0, 1000), // 太短
        _clip(10000, 14000), // 4 s
        _clip(20000, 40000), // 太长
        _clip(50000, 56000), // 6 s
        _clip(60000, 63000), // 3 s
        _clip(70000, 78000), // 8 s
      ];
      expect(pickMangaNarratorRefs(clips), <MangaAudiobookClip>[
        _clip(10000, 14000),
        _clip(50000, 56000),
        _clip(70000, 78000),
      ]);
    });

    test('只取片段最多的那本书（并列取先出现的）', () {
      final List<MangaAudiobookClip> clips = <MangaAudiobookClip>[
        _clip(0, 9000, book: 'a'),
        _clip(0, 3000, book: 'b'),
        _clip(5000, 8000, book: 'b'),
      ];
      expect(
        pickMangaNarratorRefs(clips).map((MangaAudiobookClip c) => c.bookKey),
        everyElement('b'),
      );
      expect(
        pickMangaNarratorRefs(<MangaAudiobookClip>[
          _clip(0, 3000, book: 'a'),
          _clip(0, 4000, book: 'b'),
        ]).single.bookKey,
        'a',
      );
    });

    test('没有合格片段 → 空表', () {
      expect(
        pickMangaNarratorRefs(<MangaAudiobookClip>[_clip(0, 500)]),
        isEmpty,
      );
    });

    test('声音 id 只由参考片段决定：片段变了 id 跟着变', () {
      final String a = mangaNarratorVoiceId(<MangaAudiobookClip>[
        _clip(0, 4000),
      ]);
      expect(a, startsWith(kMangaNarratorVoicePrefix));
      expect(mangaNarratorVoiceId(<MangaAudiobookClip>[_clip(0, 4000)]), a);
      expect(
        mangaNarratorVoiceId(<MangaAudiobookClip>[_clip(0, 4001)]),
        isNot(a),
      );
    });
  });

  group('mangaNarratorFor', () {
    test('只从会剪的有声书片段里挑；旧行没有 bookKey 时落成第一本关联书', () {
      final MangaAudioScript script = MangaAudioScript(
        audiobookSources: <String>['novel'],
        lines: <MangaScriptLine>[
          _line(0, 0, audio: _clip(0, 4000, book: null)),
          _line(0, 1),
          // 「不读」的行与页码越界的行不当参考。
          _line(1, 0, audio: _clip(5000, 9000), kind: CastLineKind.skip),
          _line(9, 0, audio: _clip(10000, 15000)),
        ],
      );
      final MangaNarratorVoice? n = mangaNarratorFor(
        script: script,
        pageCount: 3,
      );
      expect(n!.refs, <MangaAudiobookClip>[_clip(0, 4000)]);
    });

    test('只合成策略下片段不会被剪 → 不克隆', () {
      final MangaAudioScript script = MangaAudioScript(
        sourcePolicy: MangaAudioSourcePolicy.synthOnly,
        audiobookSources: <String>['novel'],
        lines: <MangaScriptLine>[_line(0, 0, audio: _clip(0, 4000))],
      );
      expect(mangaNarratorFor(script: script, pageCount: 1), isNull);
    });
  });

  test('mangaSynthVoiceFor：克隆旁白时没单句指定声音的句子用旁白，单句指定的不改', () {
    final MangaAudioScript script = MangaAudioScript();
    final MangaNarratorVoice narrator = MangaNarratorVoice(<MangaAudiobookClip>[
      _clip(0, 4000),
    ]);
    expect(
      mangaSynthVoiceFor(script, _line(0, 0), 'reading', narrator),
      narrator.id,
    );
    expect(
      mangaSynthVoiceFor(
        script,
        _line(0, 0, voice: 'solo'),
        'reading',
        narrator,
      ),
      'solo',
    );
    expect(mangaSynthVoiceFor(script, _line(0, 0), 'reading', null), 'reading');
  });
}
