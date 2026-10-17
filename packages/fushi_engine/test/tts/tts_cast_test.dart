import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

TtsCastLine _llm(String speaker, [String? emotion]) =>
    TtsCastLine(speaker: speaker, source: TtsCastSource.llm, emotion: emotion);

void main() {
  group('TtsCast', () {
    test('mergeLlm 替换本章旧 llm 行、保留用户手改行与别章行', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '1:0': _llm('A'),
          '1:5': _llm('B'),
          '2:0': _llm('C'),
          '12:0': _llm('D'),
        },
      )..setUserSpeaker(1, 9, 'U');
      cast.mergeLlm(1, <String, TtsCastLine>{
        '1:0': _llm('X'),
        '1:9': _llm('Y'),
      });
      expect(cast.speakerOf(1, 0), 'X');
      expect(cast.lines.containsKey('1:5'), isFalse);
      expect(cast.speakerOf(1, 5), kTtsNarrator);
      expect(cast.speakerOf(1, 9), 'U');
      expect(cast.lines['1:9']!.source, TtsCastSource.user);
      expect(cast.speakerOf(2, 0), 'C');
      expect(cast.speakerOf(12, 0), 'D');
      expect(cast.annotatedSections, <int>{1});
    });

    test('renameSpeaker 合并角色并迁移声音（目标已有声音时保留目标的）', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': _llm('スバル', '怒り'),
          '0:1': _llm('菜月昴'),
          '0:2': _llm('レム'),
        },
        voices: <String, String>{'菜月昴': 'v1', 'レム': 'v2'},
      );
      cast.renameSpeaker('菜月昴', 'スバル');
      expect(cast.speakerOf(0, 1), 'スバル');
      expect(cast.lines['0:0']!.emotion, '怒り');
      expect(cast.voices, <String, String>{'スバル': 'v1', 'レム': 'v2'});

      cast.renameSpeaker('レム', 'スバル');
      expect(cast.voices, <String, String>{'スバル': 'v1'});
      expect(cast.presetFor(0, 2), 'v1');
    });

    test('speakers() 不含旁白，按台词数降序', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': _llm('A'),
          '0:1': _llm('B'),
          '0:2': _llm('B'),
          '0:3': _llm(kTtsNarrator),
          '0:4': _llm(kTtsNarrator),
          '0:5': _llm(kTtsNarrator),
        },
      );
      expect(cast.speakers().map((s) => '${s.speaker}${s.count}'), <String>[
        'B2',
        'A1',
      ]);
    });

    test('presetFor：没配声音 / 旁白返回 null', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{'0:0': _llm('A'), '0:1': _llm('B')},
        voices: <String, String>{'A': 'va'},
      );
      expect(cast.presetFor(0, 0), 'va');
      expect(cast.presetFor(0, 1), isNull);
      expect(cast.presetFor(0, 99), isNull);
    });

    test('JSON 往返', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{'0:0': _llm('A', '笑い')},
        voices: <String, String>{'A': 'va', kTtsNarrator: 'vn'},
        annotatedSections: <int>{3, 0},
      )..setUserSpeaker(1, 4, 'B');
      final TtsCast back = TtsCast.fromJson(
        jsonDecode(jsonEncode(cast.toJson())),
      );
      expect(back.lines.length, 2);
      expect(back.lines['0:0']!.speaker, 'A');
      expect(back.lines['0:0']!.emotion, '笑い');
      expect(back.lines['0:0']!.source, TtsCastSource.llm);
      expect(back.lines['1:4']!.source, TtsCastSource.user);
      expect(back.lines['1:4']!.emotion, isNull);
      expect(back.voices, cast.voices);
      expect(back.annotatedSections, <int>{0, 3});
      expect(cast.toJson()['annotated'], <int>[0, 3]);
    });

    test('needsReview / reviewCount：不明、低把握、无提示推断的 llm 台词', () {
      TtsCastLine line(
        String speaker, {
        double? c,
        TtsCastEvidence? ev,
        TtsCastSource src = TtsCastSource.llm,
      }) => TtsCastLine(
        speaker: speaker,
        source: src,
        confidence: c,
        evidence: ev,
      );
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': line('A', c: 0.9, ev: TtsCastEvidence.explicit),
          '0:1': line(kTtsUnknown, c: 0.9),
          '0:2': line('A', c: 0.5, ev: TtsCastEvidence.explicit),
          '0:3': line('A', c: 0.95, ev: TtsCastEvidence.implicit),
          '0:4': line('A'),
          '0:5': line(kTtsNarrator, c: 0),
          '0:6': line(kTtsUnknown, src: TtsCastSource.user),
        },
      );
      expect(
        <String, bool>{
          for (final MapEntry<String, TtsCastLine> e in cast.lines.entries)
            e.key: e.value.needsReview,
        },
        <String, bool>{
          '0:0': false,
          '0:1': true,
          '0:2': true,
          '0:3': true,
          '0:4': false,
          '0:5': false,
          '0:6': false,
        },
      );
      expect(cast.reviewCount, 3);
    });

    test('mergeRoster：同名并别名、只补空特征', () {
      final TtsCast cast = TtsCast()
        ..mergeRoster(const <TtsCastCharacter>[
          TtsCastCharacter(name: 'A', aliases: <String>['a1'], gender: 'male'),
        ])
        ..mergeRoster(const <TtsCastCharacter>[
          TtsCastCharacter(
            name: 'A',
            aliases: <String>['a1', 'a2'],
            gender: 'female',
            age: 'teen',
          ),
          TtsCastCharacter(name: 'B'),
        ]);
      expect(cast.roster.keys, <String>['A', 'B']);
      expect(cast.roster['A']!.aliases, <String>['a1', 'a2']);
      expect(cast.roster['A']!.gender, 'male');
      expect(cast.roster['A']!.age, 'teen');
    });

    test('renameSpeaker：保留把握 / 依据，角色表旧名成为别名；并入不明不进角色表', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': const TtsCastLine(
            speaker: 'B',
            source: TtsCastSource.llm,
            confidence: 0.4,
            evidence: TtsCastEvidence.anaphoric,
          ),
        },
        roster: <String, TtsCastCharacter>{
          'A': const TtsCastCharacter(name: 'A'),
          'B': const TtsCastCharacter(
            name: 'B',
            aliases: <String>['b1'],
            gender: 'female',
          ),
          'C': const TtsCastCharacter(name: 'C'),
        },
      );
      cast.renameSpeaker('B', 'A');
      expect(cast.lines['0:0']!.speaker, 'A');
      expect(cast.lines['0:0']!.confidence, 0.4);
      expect(cast.lines['0:0']!.evidence, TtsCastEvidence.anaphoric);
      expect(cast.roster.keys, <String>['A', 'C']);
      expect(cast.roster['A']!.aliases, <String>['B', 'b1']);
      expect(cast.roster['A']!.gender, 'female');

      cast.renameSpeaker('C', kTtsUnknown);
      expect(cast.roster.keys, <String>['A']);
    });

    test('JSON 往返：角色表、把握、依据；把握越界夹到 0..1', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '0:0': const TtsCastLine(
            speaker: kTtsUnknown,
            source: TtsCastSource.llm,
            confidence: 0.25,
            evidence: TtsCastEvidence.implicit,
          ),
        },
        roster: <String, TtsCastCharacter>{
          'A': const TtsCastCharacter(
            name: 'A',
            aliases: <String>['a1'],
            gender: 'female',
            age: 'elderly',
            description: '老婆',
          ),
        },
      );
      final TtsCast back = TtsCast.fromJson(
        jsonDecode(jsonEncode(cast.toJson())),
      );
      expect(back.lines['0:0']!.confidence, 0.25);
      expect(back.lines['0:0']!.evidence, TtsCastEvidence.implicit);
      final TtsCastCharacter a = back.roster['A']!;
      expect(a.aliases, <String>['a1']);
      expect(
        (a.name, a.gender, a.age, a.description),
        ('A', 'female', 'elderly', '老婆'),
      );
      expect(
        TtsCastLine.fromJson(<String, Object?>{'s': 'A', 'c': 3})!.confidence,
        1.0,
      );
    });

    test('fromJson 容忍坏形状', () {
      expect(TtsCast.fromJson('nope').isEmpty, isTrue);
      final TtsCast cast = TtsCast.fromJson(<String, Object?>{
        'lines': <String, Object?>{
          '0:0': 5,
          '0:1': <String, Object?>{'s': 'A'},
        },
        'voices': <String, Object?>{'A': 1, 'B': 'vb'},
        'annotated': <Object?>[1, 'x'],
      });
      expect(cast.lines.keys, <String>['0:1']);
      expect(cast.voices, <String, String>{'B': 'vb'});
      expect(cast.annotatedSections, <int>{1});
    });
  });

  group('TtsCastStore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('tts_cast_test');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('没存过返回空表；存了能读回，不同书互不干扰', () async {
      final TtsCastStore store = TtsCastStore(Directory('${root.path}/cast'));
      expect((await store.load('book-a')).isEmpty, isTrue);
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{'0:0': _llm('A')},
        voices: <String, String>{'A': 'va'},
      )..mergeLlm(0, <String, TtsCastLine>{'0:0': _llm('A')});
      await store.save('book-a', cast);
      final TtsCast back = await store.load('book-a');
      expect(back.speakerOf(0, 0), 'A');
      expect(back.voices, <String, String>{'A': 'va'});
      expect(back.annotatedSections, <int>{0});
      expect((await store.load('book-b')).isEmpty, isTrue);
      expect(
        Directory('${root.path}/cast').listSync().whereType<File>().where(
          (File f) => f.path.endsWith('.tmp'),
        ),
        isEmpty,
      );
    });

    test('坏文件改名 .corrupt 并返回空表', () async {
      final TtsCastStore store = TtsCastStore(root);
      await store.save('book', TtsCast(voices: <String, String>{'A': 'v'}));
      final File file = root.listSync().whereType<File>().single;
      await file.writeAsString('{not json');
      expect((await store.load('book')).isEmpty, isTrue);
      expect(File('${file.path}.corrupt').existsSync(), isTrue);
      expect(file.existsSync(), isFalse);
    });
  });
}
