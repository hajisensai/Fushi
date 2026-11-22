// 字数目标的语言维度：单位（字 / 词）、按语言的预设、「只算目标语言」过滤，
// 以及媒体语言表的读取（键与 StatFact.mediaKey 同一身份）。
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_goal_language.dart';
import 'package:test/test.dart';

StatFact _fact(String mediaKey, int chars, {String dateKey = '2026-11-19'}) =>
    StatFact(
      mediaKind: 'book',
      mediaKey: mediaKey,
      title: mediaKey,
      format: 'epub',
      dateKey: dateKey,
      hour: -1,
      ms: 0,
      chars: chars,
      pages: 0,
      lastActiveMs: 0,
    );

void main() {
  group('studyGoalUnitFor', () {
    test('per-character scripts count characters', () {
      for (final String tag in <String>[
        'ja',
        'ja-JP',
        'zh-Hans',
        'zh-Hant-TW',
        'ko',
        'th',
      ]) {
        expect(studyGoalUnitFor(tag), StudyGoalUnit.chars, reason: tag);
      }
    });

    test('space-delimited languages count words', () {
      for (final String tag in <String>['en', 'en-US', 'fr', 'ru', 'es_MX']) {
        expect(studyGoalUnitFor(tag), StudyGoalUnit.words, reason: tag);
      }
    });

    test('unknown language keeps the existing character unit', () {
      expect(studyGoalUnitFor(null), StudyGoalUnit.chars);
      expect(studyGoalUnitFor(''), StudyGoalUnit.chars);
      expect(studyGoalUnitFor('und'), StudyGoalUnit.chars);
    });
  });

  group('presets', () {
    test('Japanese and unknown keep the existing presets', () {
      const List<int> daily = <int>[3000, 5000, 10000, 20000];
      const List<int> weekly = <int>[20000, 35000, 70000, 140000];
      expect(studyGoalDailyPresetsFor(null), daily);
      expect(studyGoalDailyPresetsFor('ja'), daily);
      expect(studyGoalWeeklyPresetsFor(null), weekly);
      expect(studyGoalWeeklyPresetsFor('ja-JP'), weekly);
    });

    test('Chinese, Korean and word languages get their own scale', () {
      expect(studyGoalDailyPresetsFor('zh-Hant'), <int>[
        2000,
        4000,
        7000,
        14000,
      ]);
      expect(studyGoalDailyPresetsFor('ko'), <int>[2000, 4000, 8000, 15000]);
      expect(studyGoalDailyPresetsFor('en'), <int>[1500, 3000, 6000, 12000]);
      expect(studyGoalWeeklyPresetsFor('en'), <int>[
        10500,
        21000,
        42000,
        84000,
      ]);
    });
  });

  group('resolveStudyGoalLanguage', () {
    test('primary, explicit script, region-derived script', () {
      expect(resolveStudyGoalLanguage('ja-JP'), const StudyGoalLanguage('ja'));
      expect(
        resolveStudyGoalLanguage('zh-hans'),
        const StudyGoalLanguage('zh', 'Hans'),
      );
      expect(
        resolveStudyGoalLanguage('zh-TW'),
        const StudyGoalLanguage('zh', 'Hant'),
      );
      expect(
        resolveStudyGoalLanguage('zh_HK'),
        const StudyGoalLanguage('zh', 'Hant'),
      );
      expect(
        resolveStudyGoalLanguage('zh-SG'),
        const StudyGoalLanguage('zh', 'Hans'),
      );
      expect(resolveStudyGoalLanguage('zh'), const StudyGoalLanguage('zh'));
      // 显式文字子标签对任何语言都认（数据驱动，不是中文特例）。
      expect(
        resolveStudyGoalLanguage('sr-Latn-RS'),
        const StudyGoalLanguage('sr', 'Latn'),
      );
      // 只有表里的语言按地区推文字。
      expect(resolveStudyGoalLanguage('pt-BR'), const StudyGoalLanguage('pt'));
      expect(resolveStudyGoalLanguage(''), isNull);
      expect(resolveStudyGoalLanguage('und'), isNull);
      expect(resolveStudyGoalLanguage(null), isNull);
    });

    test('tags, combined form and goal matching', () {
      expect(resolveStudyGoalLanguage('zh-TW')!.tag, 'zh-Hant');
      expect(studyGoalCombinedLanguageTag('zh-Hant'), 'zh');
      expect(studyGoalCombinedLanguageTag('ja-JP'), 'ja');
      expect(studyGoalCombinedLanguageTag(''), isNull);
      expect(studyGoalLanguageIncludes('zh', 'zh-Hant'), isTrue);
      expect(studyGoalLanguageIncludes('zh', 'zh'), isTrue);
      expect(studyGoalLanguageIncludes('zh-Hans', 'zh-CN'), isTrue);
      expect(studyGoalLanguageIncludes('zh-Hans', 'zh-TW'), isFalse);
      expect(studyGoalLanguageIncludes('zh-Hans', 'zh'), isFalse);
      expect(studyGoalLanguageIncludes('zh', 'ja'), isFalse);
      expect(studyGoalLanguageIncludes('zh', null), isFalse);
      expect(kStudyGoalScriptVariants['zh'], <String>['Hans', 'Hant']);
    });
  });

  group('StudyGoalLanguageScope', () {
    final List<StatFact> rows = <StatFact>[
      _fact('jp-book', 1000),
      _fact('en-book', 300),
      _fact('zh-book', 50),
      _fact('untagged', 7),
      _fact('', 2),
    ];
    const Map<String, String> languages = <String, String>{
      'jp-book': 'ja-JP',
      'en-book': 'en',
      'zh-book': 'zh-Hant',
    };

    test('default scope counts everything', () {
      expect(studyGoalCharsForDay(rows, '2026-11-19'), 1359);
    });

    test('only-language counts only content known to be the goal language', () {
      const StudyGoalLanguageScope scope = StudyGoalLanguageScope(
        language: 'ja',
        onlyLanguage: true,
        mediaLanguages: languages,
      );
      expect(studyGoalCharsForDay(rows, '2026-11-19', scope: scope), 1000);
    });

    test('content without a language falls back to the default language', () {
      const StudyGoalLanguageScope ja = StudyGoalLanguageScope(
        language: 'ja',
        onlyLanguage: true,
        mediaLanguages: languages,
        fallbackLanguage: 'ja-JP',
      );
      const StudyGoalLanguageScope ko = StudyGoalLanguageScope(
        language: 'ko',
        onlyLanguage: true,
        mediaLanguages: languages,
        fallbackLanguage: 'ja',
      );
      expect(studyGoalCharsForDay(rows, '2026-11-19', scope: ja), 1000 + 7 + 2);
      // 用户实测场景：目标韩语、库里没有韩语内容 → 0。
      expect(studyGoalCharsForDay(rows, '2026-11-19', scope: ko), 0);
    });

    test(
      'combined Chinese counts every script; a script goal only its own',
      () {
        final List<StatFact> zh = <StatFact>[
          _fact('hans', 1),
          _fact('hant', 10),
          _fact('cn', 100),
          _fact('tw', 1000),
          _fact('plain', 10000),
        ];
        const Map<String, String> tags = <String, String>{
          'hans': 'zh-Hans',
          'hant': 'zh-Hant-TW',
          'cn': 'zh-CN',
          'tw': 'zh_TW',
          'plain': 'zh',
        };
        int count(String goal) => studyGoalCharsForDay(
          zh,
          '2026-11-19',
          scope: StudyGoalLanguageScope(
            language: goal,
            onlyLanguage: true,
            mediaLanguages: tags,
          ),
        );
        expect(count('zh'), 11111);
        // 只标了 zh 的媒体看不出文字：只计入整门中文。
        expect(count('zh-Hans'), 101);
        expect(count('zh-Hant'), 1010);
        expect(
          studyGoalCharsForDay(
            rows,
            '2026-11-19',
            scope: const StudyGoalLanguageScope(
              language: 'zh',
              onlyLanguage: true,
              mediaLanguages: languages,
            ),
          ),
          50,
        );
      },
    );

    test('switch off, or no goal language, does not filter', () {
      const StudyGoalLanguageScope off = StudyGoalLanguageScope(
        language: 'ja',
        onlyLanguage: false,
        mediaLanguages: languages,
      );
      const StudyGoalLanguageScope unknown = StudyGoalLanguageScope(
        language: null,
        onlyLanguage: true,
        mediaLanguages: languages,
      );
      expect(off.filters, isFalse);
      expect(unknown.filters, isFalse);
      expect(studyGoalCharsForDay(rows, '2026-11-19', scope: off), 1359);
      expect(studyGoalCharsForDay(rows, '2026-11-19', scope: unknown), 1359);
    });
  });

  group('loadStudyGoalMediaLanguages', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    test('maps video bookUid and galgame id to their language', () async {
      await db.customStatement(
        "INSERT INTO galgames (id, name, exe_path, workdir, added_at, language) "
        "VALUES ('g-ja', 'a', 'a.exe', '.', 0, 'ja'), "
        "('g-none', 'b', 'b.exe', '.', 0, NULL)",
      );
      final Map<String, String> map = await loadStudyGoalMediaLanguages(db);
      expect(map['g-ja'], 'ja');
      expect(map.containsKey('g-none'), isFalse);
    });
  });
}
