import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

MangaScriptLine _line(
  int page,
  List<int> blocks, {
  String speaker = 'A',
  CastLineKind kind = CastLineKind.spoken,
  TtsCastSource source = TtsCastSource.llm,
}) => MangaScriptLine(
  page: page,
  blocks: blocks,
  speaker: speaker,
  kind: kind,
  source: source,
);

MangaAudioScript _fullScript() => MangaAudioScript(
  engineSignature: 'ocr-sig-1',
  defaultSeed: 42,
  sourcePolicy: MangaAudioSourcePolicy.synthOnly,
  voices: CastVoiceAssignment(
    defaultVoice: 'preset-default',
    narrationVoice: 'preset-narr',
    byCharacter: <String, String>{'A': 'pack-a'},
    byCharacterKind: <String, Map<CastLineKind, String>>{
      'A': <CastLineKind, String>{CastLineKind.thought: 'pack-a-inner'},
    },
  ),
  roster: <String, TtsCastCharacter>{
    'A': const TtsCastCharacter(
      name: 'A',
      aliases: <String>['a'],
      gender: 'female',
    ),
    'B': const TtsCastCharacter(name: 'B'),
  },
  lines: <MangaScriptLine>[
    MangaScriptLine(
      page: 0,
      blocks: <int>[2, 0],
      speaker: 'A',
      kind: CastLineKind.thought,
      beatMs: 250,
      emotion: CastEmotion.tension,
      intensity: 70,
      rateOffset: -0.1,
      pitchOffset: 2,
      volumeOffset: -3,
      seed: 7,
      textFixes: <int, String>{2: 'かきく'},
      source: TtsCastSource.user,
      confidence: 0.4,
      audio: const MangaAudiobookClip(fileIndex: 3, startMs: 1000, endMs: 2500),
    ),
    _line(0, <int>[1], speaker: kTtsNarrator, kind: CastLineKind.narration),
    _line(2, <int>[0], speaker: kTtsUnknown, kind: CastLineKind.skip),
  ],
  pages: <int, MangaPageDirective>{
    1: const MangaPageDirective(holdMs: 3000),
    2: const MangaPageDirective(leadMs: 1200, source: TtsCastSource.user),
  },
  annotatedPages: <int>{0, 1, 2},
);

Object? _roundTrip(Map<String, Object?> json) => jsonDecode(jsonEncode(json));

void main() {
  group('MangaAudioScript JSON', () {
    test('全字段往返后 JSON 不变', () {
      final MangaAudioScript script = _fullScript();
      final Object? decoded = _roundTrip(script.toJson());
      final MangaAudioScript back = MangaAudioScript.fromJson(decoded);
      expect(back.toJson(), equals(_roundTrip(script.toJson())));

      final MangaScriptLine l0 = back.lines.first;
      expect(l0.blocks, <int>[2, 0]);
      expect(l0.kind, CastLineKind.thought);
      expect(l0.emotion, CastEmotion.tension);
      expect(l0.intensity, 70);
      expect(l0.seed, 7);
      expect(l0.effectiveSeed(back.defaultSeed), 7);
      expect(back.lines[1].effectiveSeed(back.defaultSeed), 42);
      expect(l0.textFixes, <int, String>{2: 'かきく'});
      expect(l0.source, TtsCastSource.user);
      expect(
        l0.audio,
        const MangaAudiobookClip(fileIndex: 3, startMs: 1000, endMs: 2500),
      );
      expect(back.lines[1].audio, const MangaSynthesized());
      expect(back.engineSignature, 'ocr-sig-1');
      expect(back.sourcePolicy, MangaAudioSourcePolicy.synthOnly);
      expect(back.pages[1]!.holdMs, 3000);
      expect(back.pages[2]!.source, TtsCastSource.user);
      expect(back.roster['A']!.aliases, <String>['a']);
      expect(back.voices.resolve('A', CastLineKind.thought), 'pack-a-inner');
      expect(back.annotatedPages, <int>{0, 1, 2});
    });

    test('合成音源与默认值不落盘', () {
      final Map<String, Object?> json = _line(0, <int>[0]).toJson();
      expect(json.containsKey('audio'), isFalse);
      expect(json.containsKey('beat'), isFalse);
      expect(json.containsKey('seed'), isFalse);
    });

    test('宽松解析：坏行丢弃、数值夹取、越界修正与未知情绪忽略、跨页乱序拉回', () {
      final MangaAudioScript s = MangaAudioScript.fromJson(<String, Object?>{
        'seed': -5,
        'policy': 'nope',
        'lines': <Object?>[
          <String, Object?>{
            'p': 3,
            'b': <int>[0],
            's': 'A',
            'k': 'spoken',
          },
          <String, Object?>{
            'p': 1,
            'b': <int>[0],
            's': 'A',
            'k': 'sing',
          },
          <String, Object?>{
            'p': 1,
            'b': <Object?>[0, 'x'],
            's': 'A',
            'k': 'spoken',
          },
          <String, Object?>{'p': 1, 'b': <int>[], 's': 'A', 'k': 'spoken'},
          <String, Object?>{
            'p': 1,
            'b': <int>[4],
            's': 'B',
            'k': 'shout',
            'beat': 99999,
            'e': 'ecstatic',
            'ei': 500,
            'rate': 9,
            'pitch': -40,
            'vol': double.nan,
            'c': 3,
            'fix': <String, Object?>{'4': 'さしす', '9': 'たちつ', '5': ''},
            'audio': <String, Object?>{'t': 'book', 'f': 0, 's': 500, 'e': 100},
          },
        ],
      });
      expect(s.defaultSeed, 0);
      expect(s.sourcePolicy, MangaAudioSourcePolicy.audiobookFirst);
      expect(s.lines.map((MangaScriptLine l) => l.page), <int>[1, 3]);
      final MangaScriptLine l = s.lines.first;
      expect(l.beatMs, MangaScriptLimits.maxBeatMs);
      expect(l.emotion, isNull);
      expect(l.intensity, isNull);
      expect(l.rateOffset, MangaScriptLimits.maxRateOffset);
      expect(l.pitchOffset, -MangaScriptLimits.maxPitchSemitones);
      expect(l.volumeOffset, isNull);
      expect(l.confidence, 1.0);
      expect(l.textFixes, <int, String>{4: 'さしす'});
      expect(l.audio, const MangaSynthesized());
    });

    test('非对象输入得到空演出稿', () {
      expect(MangaAudioScript.fromJson('x').lines, isEmpty);
      expect(MangaAudioScript.fromJson(null).engineSignature, isNull);
    });
  });

  group('MangaAudioScriptStore', () {
    late Directory dir;
    setUp(
      () async => dir = await Directory.systemTemp.createTemp('manga_script_'),
    );
    tearDown(() async => dir.delete(recursive: true));

    test('原子写后可读回，不留临时文件', () async {
      final MangaAudioScriptStore store = MangaAudioScriptStore(dir);
      await store.save('book-1', _fullScript());
      final List<String> names = <String>[
        for (final FileSystemEntity e in dir.listSync())
          e.uri.pathSegments.last,
      ];
      expect(names, hasLength(1));
      expect(names.single, endsWith('.manga-script.json'));
      final MangaAudioScript back = await store.load('book-1');
      expect(back.toJson(), equals(_roundTrip(_fullScript().toJson())));
      expect((await store.load('other')).lines, isEmpty);
    });

    test('坏文件改名为 .corrupt 并返回空演出稿', () async {
      final MangaAudioScriptStore store = MangaAudioScriptStore(dir);
      await store.fileFor('b').writeAsString('{not json');
      expect((await store.load('b')).lines, isEmpty);
      expect(File('${store.fileFor('b').path}.corrupt').existsSync(), isTrue);
    });

    test('与小说选角表同目录共存，TtsCast 读写行为不变', () async {
      final TtsCastStore castStore = TtsCastStore(dir);
      final TtsCast cast = TtsCast(voices: <String, String>{'A': 'v1'})
        ..setUserSpeaker(1, 0, 'A');
      await castStore.save('book-1', cast);
      await MangaAudioScriptStore(dir).save('book-1', _fullScript());
      final TtsCast castBack = await castStore.load('book-1');
      expect(castBack.speakerOf(1, 0), 'A');
      expect(castBack.presetFor(1, 0), 'v1');
      expect(castBack.toJson(), equals(_roundTrip(cast.toJson())));
      expect(
        (await MangaAudioScriptStore(dir).load('book-1')).lines,
        hasLength(3),
      );
    });
  });

  group('mergeAiPage', () {
    test('替换该页 AI 行，保留用户行并丢弃与之共用块的 AI 行，别页不动', () {
      final MangaAudioScript s = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0, <int>[0]),
          _line(1, <int>[0]),
          _line(1, <int>[1, 2], speaker: 'U', source: TtsCastSource.user),
          _line(1, <int>[3]),
          _line(2, <int>[0]),
        ],
      );
      s.mergeAiPage(1, <MangaScriptLine>[
        _line(1, <int>[3], speaker: 'X'),
        _line(1, <int>[2], speaker: 'Y'),
        _line(1, <int>[0], speaker: 'Z'),
        _line(5, <int>[0], speaker: 'stray'),
      ]);
      expect(
        s.lines.map((MangaScriptLine l) => '${l.page}:${l.speaker}'),
        <String>['0:A', '1:X', '1:U', '1:Z', '2:A'],
      );
      expect(s.annotatedPages, <int>{1});
    });

    test('没被新行覆盖的用户行按原页内位置插回', () {
      final MangaAudioScript s = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0, <int>[0]),
          _line(0, <int>[5], speaker: 'U', source: TtsCastSource.user),
        ],
      );
      s.mergeAiPage(0, <MangaScriptLine>[
        _line(0, <int>[1], speaker: 'X'),
        _line(0, <int>[2], speaker: 'Y'),
      ]);
      expect(s.lines.map((MangaScriptLine l) => l.speaker), <String>[
        'X',
        'U',
        'Y',
      ]);
    });

    test('新页插在正确位置；用户改过的页指令保留，AI 指令被替换', () {
      final MangaAudioScript s = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0, <int>[0]),
          _line(4, <int>[0]),
        ],
        pages: <int, MangaPageDirective>{
          2: const MangaPageDirective(holdMs: 100, source: TtsCastSource.user),
          3: const MangaPageDirective(holdMs: 200),
        },
      );
      s.mergeAiPage(2, <MangaScriptLine>[
        _line(2, <int>[0], speaker: 'N'),
      ], directive: const MangaPageDirective(holdMs: 999));
      s.mergeAiPage(
        3,
        <MangaScriptLine>[],
        directive: const MangaPageDirective(leadMs: 300),
      );
      expect(s.lines.map((MangaScriptLine l) => l.page), <int>[0, 2, 4]);
      expect(s.pages[2]!.holdMs, 100);
      expect(s.pages[3]!.holdMs, isNull);
      expect(s.pages[3]!.leadMs, 300);
    });
  });

  group('过期判定', () {
    MangaAudioScript withLines(String? sig) => MangaAudioScript(
      engineSignature: sig,
      lines: <MangaScriptLine>[
        _line(0, <int>[0]),
      ],
    );

    test('签名一致为最新', () {
      expect(withLines('s1').freshness('s1'), MangaScriptFreshness.upToDate);
    });

    test('签名不一致需重新标注', () {
      expect(
        withLines('s1').freshness('s2'),
        MangaScriptFreshness.needsReannotation,
      );
    });

    test('任一侧缺签名需重新标注', () {
      expect(
        withLines(null).freshness('s1'),
        MangaScriptFreshness.needsReannotation,
      );
      expect(
        withLines('s1').freshness(null),
        MangaScriptFreshness.needsReannotation,
      );
    });

    test('还没有任何行时无从错位，算最新', () {
      expect(MangaAudioScript().freshness('s9'), MangaScriptFreshness.upToDate);
    });
  });

  group('声音解析', () {
    final CastVoiceAssignment v = CastVoiceAssignment(
      defaultVoice: 'def',
      narrationVoice: 'narr',
      byCharacter: <String, String>{'A': 'a', kTtsNarrator: 'nar-char'},
      byCharacterKind: <String, Map<CastLineKind, String>>{
        'A': <CastLineKind, String>{CastLineKind.monologue: 'a-inner'},
        'B': <CastLineKind, String>{CastLineKind.shout: 'b-shout'},
      },
    );

    test('角色 × 类型优先于角色', () {
      expect(v.resolve('A', CastLineKind.monologue), 'a-inner');
    });

    test('没有类型级指派回落到角色', () {
      expect(v.resolve('A', CastLineKind.spoken), 'a');
    });

    test('角色没有指派回落到作品默认', () {
      expect(v.resolve('B', CastLineKind.spoken), 'def');
      expect(v.resolve('B', CastLineKind.shout), 'b-shout');
      expect(v.resolve(kTtsUnknown, CastLineKind.spoken), 'def');
    });

    test('叙述类走单独一行，不受角色指派影响', () {
      expect(v.resolve('A', CastLineKind.narration), 'narr');
      expect(v.resolve(kTtsNarrator, CastLineKind.narration), 'narr');
      expect(v.resolve(kTtsNarrator, CastLineKind.spoken), 'nar-char');
    });

    test('叙述行未设时回落作品默认；全空返回 null（当前朗读声音）', () {
      expect(
        CastVoiceAssignment(
          defaultVoice: 'def',
        ).resolve('A', CastLineKind.narration),
        'def',
      );
      expect(CastVoiceAssignment().resolve('A', CastLineKind.spoken), isNull);
      expect(
        CastVoiceAssignment().resolve('A', CastLineKind.narration),
        isNull,
      );
    });

    test('voiceFor 按行的说话人与类型解析', () {
      final MangaAudioScript s = MangaAudioScript(voices: v);
      expect(
        s.voiceFor(_line(0, <int>[0], kind: CastLineKind.monologue)),
        'a-inner',
      );
    });
  });
}
