import 'dart:convert';

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_cast_timing.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:test/test.dart';

TtsCastLine _line(
  String speaker, {
  CastLineKind? kind,
  int beat = 0,
  TtsCastSource source = TtsCastSource.llm,
}) => TtsCastLine(speaker: speaker, source: source, kind: kind, beatMs: beat);

TtsTimedSentence _s(
  TtsCastLine? line, {
  bool paragraph = false,
  bool scene = false,
}) => (endsParagraph: paragraph, sceneBreakAfter: scene, line: line);

void main() {
  group('TtsCastLine 演出字段 JSON', () {
    test('新字段往返，键名与漫画演出稿同名', () {
      const TtsCastLine line = TtsCastLine(
        speaker: 'スバル',
        source: TtsCastSource.llm,
        kind: CastLineKind.shout,
        beatMs: 400,
        emotion: CastEmotion.anger,
        intensity: 80,
        rateOffset: 0.2,
        pitchOffset: -2,
        volumeOffset: 3,
        seed: 42,
        confidence: 0.9,
      );
      final Map<String, Object?> json = line.toJson();
      expect(json['k'], 'shout');
      expect(json['beat'], 400);
      expect(json['e'], 'anger');
      expect(json['ei'], 80);
      expect(json['seed'], 42);
      final TtsCastLine back = TtsCastLine.fromJson(
        jsonDecode(jsonEncode(json)),
      )!;
      expect(back.kind, CastLineKind.shout);
      expect(back.beatMs, 400);
      expect(back.emotion, CastEmotion.anger);
      expect(back.intensity, 80);
      expect(back.rateOffset, 0.2);
      expect(back.pitchOffset, -2);
      expect(back.volumeOffset, 3);
      expect(back.seed, 42);
      expect(back.tone, isNull);

      // 同一份演出字段，漫画行的序列化结果与小说行一致（共用 CastLineDirection）。
      final MangaScriptLine manga = MangaScriptLine(
        page: 0,
        blocks: <int>[0],
        speaker: 'スバル',
        kind: CastLineKind.shout,
        beatMs: 400,
        emotion: CastEmotion.anger,
        intensity: 80,
        rateOffset: 0.2,
        pitchOffset: -2,
        volumeOffset: 3,
        seed: 42,
      );
      expect(manga.direction.toJson(), line.direction.toJson());
    });

    test('旧文件照读：没有新字段的行按说话人推断类型，自由文本语气转进 tone', () {
      final TtsCastLine dialogue = TtsCastLine.fromJson(<String, Object?>{
        's': 'レム',
        'src': 'llm',
        'e': '囁き',
        'c': 0.8,
      })!;
      expect(dialogue.kind, isNull);
      expect(dialogue.effectiveKind, CastLineKind.spoken);
      expect(dialogue.beatMs, 0);
      expect(dialogue.emotion, isNull);
      expect(dialogue.tone, '囁き');
      expect(dialogue.seed, isNull);
      // 再写回去不丢语气提示，也不把它冒充成情绪词。
      final Map<String, Object?> json = dialogue.toJson();
      expect(json['tone'], '囁き');
      expect(json.containsKey('e'), isFalse);

      final TtsCastLine narration = TtsCastLine.fromJson(<String, Object?>{
        's': kTtsNarrator,
        'src': 'llm',
      })!;
      expect(narration.effectiveKind, CastLineKind.narration);
    });

    test('数值夹到共用范围，不认识的类型 / 情绪当作没标', () {
      final TtsCastLine line = TtsCastLine.fromJson(<String, Object?>{
        's': 'A',
        'src': 'llm',
        'k': 'yodel',
        'beat': 999999,
        'e': 'joy',
        'ei': 500,
        'seed': -3,
        'rate': 9.0,
      })!;
      expect(line.kind, isNull);
      expect(line.beatMs, CastLineLimits.maxBeatMs);
      expect(line.emotion, CastEmotion.joy);
      expect(line.intensity, CastLineLimits.maxIntensity);
      expect(line.seed, 0);
      expect(line.rateOffset, CastLineLimits.maxRateOffset);
      // 漫画沿用同一份上限。
      expect(MangaScriptLimits.maxBeatMs, CastLineLimits.maxBeatMs);
    });
  });

  group('TtsCast 种子与重标', () {
    test('作品默认种子往返；单句种子优先；旧文件默认种子为 0', () {
      final TtsCast cast = TtsCast(defaultSeed: 7)..setLineSeed(1, 30, 1234);
      expect(cast.seedFor(1, 30), 1234);
      expect(cast.seedFor(1, 0), 7);
      final TtsCast back = TtsCast.fromJson(
        jsonDecode(jsonEncode(cast.toJson())),
      );
      expect(back.defaultSeed, 7);
      expect(back.seedFor(1, 30), 1234);
      // 只为挂种子建的行不算用户标注。
      expect(back.lines['1:30']!.source, TtsCastSource.llm);
      expect(back.speakerOf(1, 30), kTtsNarrator);

      expect(TtsCast.fromJson(<String, Object?>{'v': 1}).defaultSeed, 0);
      cast.setLineSeed(1, 30, null);
      expect(cast.seedFor(1, 30), 7);
    });

    test('重标：用户手改的行整行不被 AI 覆盖；AI 行上写下的种子跨重标保留', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': _line('A', kind: CastLineKind.spoken),
          '0:10': _line('B', kind: CastLineKind.spoken),
        },
      );
      cast.setLineSeed(0, 10, 99);
      cast.setUserSpeaker(0, 0, 'U');
      cast.mergeLlm(0, <String, TtsCastLine>{
        '0:0': _line('X', kind: CastLineKind.shout, beat: 500),
        '0:10': _line('Y', kind: CastLineKind.thought, beat: 200),
      });
      final TtsCastLine user = cast.lines['0:0']!;
      expect(user.speaker, 'U');
      expect(user.source, TtsCastSource.user);
      expect(user.kind, CastLineKind.spoken);
      expect(user.beatMs, 0);

      final TtsCastLine ai = cast.lines['0:10']!;
      expect(ai.speaker, 'Y');
      expect(ai.kind, CastLineKind.thought);
      expect(ai.beatMs, 200);
      expect(ai.seed, 99);
    });

    test('改成旁白时丢掉对不上的类型，演出字段留着', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': _line('A', kind: CastLineKind.shout, beat: 300),
        },
      )..setUserSpeaker(0, 0, kTtsNarrator);
      final TtsCastLine line = cast.lines['0:0']!;
      expect(line.kind, isNull);
      expect(line.effectiveKind, CastLineKind.narration);
      expect(line.beatMs, 300);
      cast.setUserSpeaker(0, 0, 'B');
      expect(cast.lines['0:0']!.effectiveKind, CastLineKind.spoken);
    });
  });

  group('转场基础值（漫画与小说共用）', () {
    test('内心 ↔ 说出口 > 换人 > 同人', () {
      expect(
        castTransitionBaseMs(
          speaker: 'A',
          kind: CastLineKind.spoken,
          nextSpeaker: 'A',
          nextKind: CastLineKind.shout,
        ),
        300,
      );
      expect(
        castTransitionBaseMs(
          speaker: 'A',
          kind: CastLineKind.spoken,
          nextSpeaker: 'B',
          nextKind: CastLineKind.spoken,
        ),
        450,
      );
      expect(
        castTransitionBaseMs(
          speaker: 'A',
          kind: CastLineKind.thought,
          nextSpeaker: 'B',
          nextKind: CastLineKind.spoken,
        ),
        900,
      );
    });

    test('漫画句后停顿走同一个函数（同页、不加翻页值）', () {
      const MangaTimedLine a = MangaTimedLine(
        page: 0,
        speaker: 'A',
        kind: CastLineKind.mutter,
        durationMs: 1000,
        beatMs: 120,
      );
      const MangaTimedLine b = MangaTimedLine(
        page: 0,
        speaker: 'A',
        kind: CastLineKind.spoken,
        durationMs: 1000,
      );
      expect(
        mangaGapAfter(a, b),
        castTransitionBaseMs(
              speaker: 'A',
              kind: CastLineKind.mutter,
              nextSpeaker: 'A',
              nextKind: CastLineKind.spoken,
            ) +
            120,
      );
    });
  });

  group('小说句间停顿', () {
    test('没按演出稿的章与预设一致', () {
      final List<TtsTimedSentence> s = <TtsTimedSentence>[
        _s(_line('A', beat: 500)),
        _s(null, paragraph: true),
        _s(null, scene: true),
        _s(null),
      ];
      const TtsPausePreset p = TtsPausePreset.standard;
      expect(
        ttsCastChapterGapsMs(sentences: s, preset: p, directed: false),
        <int>[
          p.chapterLeadMs,
          p.sentenceMs,
          p.paragraphMs,
          p.sceneMs,
          p.chapterTailMs,
        ],
      );
    });

    test('按演出稿：同段转场 + 一拍，段落 / 场景与转场取大，章尾加一拍', () {
      const TtsPausePreset p = TtsPausePreset.standard; // 段 600，场景 1500
      final List<TtsTimedSentence> s = <TtsTimedSentence>[
        // 旁白 → 旁白，同段：300
        _s(null),
        // 旁白 → A 说出口，段落结束：max(600, 450) = 600，再加一拍 0
        _s(null, paragraph: true),
        // A 说出口 → A 心声，段落结束：max(600, 900) = 900 + 一拍 250
        _s(_line('A', kind: CastLineKind.spoken, beat: 250), paragraph: true),
        // A 心声 → B 说出口，场景分隔：max(1500, 900) = 1500
        _s(_line('A', kind: CastLineKind.thought), scene: true),
        // B → 章尾：章尾 + 一拍 700
        _s(_line('B', kind: CastLineKind.spoken, beat: 700)),
      ];
      expect(
        ttsCastChapterGapsMs(sentences: s, preset: p, directed: true),
        <int>[p.chapterLeadMs, 300, 600, 1150, 1500, p.chapterTailMs + 700],
      );
    });

    test('预设「不额外停顿」时按演出稿只留一拍', () {
      final List<TtsTimedSentence> s = <TtsTimedSentence>[
        _s(_line('A', kind: CastLineKind.spoken, beat: 200)),
        _s(_line('B', kind: CastLineKind.thought)),
      ];
      expect(
        ttsCastChapterGapsMs(
          sentences: s,
          preset: TtsPausePreset.none,
          directed: true,
        ),
        <int>[0, 200, 0],
      );
    });

    test('空章只有章首章尾', () {
      expect(
        ttsCastChapterGapsMs(
          sentences: const <TtsTimedSentence>[],
          preset: TtsPausePreset.brisk,
          directed: true,
        ),
        <int>[
          TtsPausePreset.brisk.chapterLeadMs,
          TtsPausePreset.brisk.chapterTailMs,
        ],
      );
    });
  });
}
