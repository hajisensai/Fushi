import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/models/dictionary_repository.dart';

/// 混合词典（term_bank + kanji_bank，例如附汉字表的「現代新国語辞典 第七版」）在
/// 词典管理里同时出现在「术语」与「汉字」两个分区（Hoshi Reader 同款）。用户反馈：
/// 汉字分区里看不到它，以为汉字条目没导入。
///
/// 钉死三件事：
/// 1. 「汉字」分区 = 纯 kanji 词典 + 混合词典的汉字部分，按分区自己的顺序；
/// 2. 在「汉字」分区重排 / 开关，不改混合词典在「术语」分区的 order / hidden；
/// 3. 重导时汉字部分的用户设置跟着继承。
Dictionary _dict(
  String name, {
  int order = 0,
  DictionaryType type = DictionaryType.term,
  Map<String, String> metadata = const <String, String>{},
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: type,
  metadata: metadata,
);

const Map<String, String> _mixed = <String, String>{kDictHasKanjiKey: 'true'};

void main() {
  group('kanjiSectionDictionariesOf', () {
    test('纯 kanji 词典 + 混合词典进分区,纯 term 词典不进', () {
      final List<Dictionary> section = kanjiSectionDictionariesOf(<Dictionary>[
        _dict('JMdict', order: 0),
        _dict('現代新国語辞典', order: 1, metadata: _mixed),
        _dict('KANJIDIC', order: 0, type: DictionaryType.kanji),
      ]);
      expect(section.map((Dictionary d) => d.name), <String>[
        'KANJIDIC',
        '現代新国語辞典',
      ]);
    });

    test('混合词典按 kanjiOrder 排,不看它在术语分区的 order', () {
      final List<Dictionary> section = kanjiSectionDictionariesOf(<Dictionary>[
        _dict('KANJIDIC', order: 0, type: DictionaryType.kanji),
        _dict(
          '現代新国語辞典',
          order: 5,
          metadata: <String, String>{..._mixed, kDictKanjiOrderKey: '0'},
        ),
      ]);
      // 同序 0：按输入先后，KANJIDIC 在前。
      expect(section.first.name, 'KANJIDIC');
      final List<Dictionary> moved = kanjiSectionDictionariesOf(<Dictionary>[
        _dict('KANJIDIC', order: 1, type: DictionaryType.kanji),
        _dict(
          '現代新国語辞典',
          order: 5,
          metadata: <String, String>{..._mixed, kDictKanjiOrderKey: '0'},
        ),
      ]);
      expect(moved.first.name, '現代新国語辞典');
    });

    test('标成 kanji 类型的词典带了 hasKanji 也只算纯 kanji 词典', () {
      final Dictionary d = _dict(
        'k',
        type: DictionaryType.kanji,
        metadata: _mixed,
      );
      expect(d.hasEmbeddedKanji, isFalse);
      expect(d.isInKanjiSection, isTrue);
    });
  });

  group('isKanjiSectionEnabled', () {
    test('混合词典:只看 kanjiHidden,与术语部分的 hidden 无关', () {
      final Dictionary termHidden = Dictionary(
        name: 'm',
        formatKey: 'yomichan',
        order: 0,
        metadata: _mixed,
        hiddenLanguages: <String>[JapaneseLanguage.instance.languageCode],
      );
      expect(
        termHidden.isKanjiSectionEnabled(JapaneseLanguage.instance),
        isTrue,
      );
      final Dictionary kanjiHidden = _dict(
        'm',
        metadata: <String, String>{..._mixed, kDictKanjiHiddenKey: 'true'},
      );
      expect(
        kanjiHidden.isKanjiSectionEnabled(JapaneseLanguage.instance),
        isFalse,
      );
      expect(kanjiHidden.isHidden(JapaneseLanguage.instance), isFalse);
    });

    test('纯 kanji 词典:仍是 hiddenLanguages', () {
      final Dictionary hidden = Dictionary(
        name: 'k',
        formatKey: 'yomichan',
        order: 0,
        type: DictionaryType.kanji,
        hiddenLanguages: <String>[JapaneseLanguage.instance.languageCode],
      );
      expect(hidden.isKanjiSectionEnabled(JapaneseLanguage.instance), isFalse);
    });
  });

  group('kanjiPartSettingsOf(重导继承)', () {
    test('只带汉字部分的两个键', () {
      final Map<String, String> carried = kanjiPartSettingsOf(
        _dict(
          'm',
          metadata: <String, String>{
            ..._mixed,
            kDictKanjiHiddenKey: 'true',
            kDictKanjiOrderKey: '2',
            'revision': 'old',
          },
        ),
      );
      expect(carried, <String, String>{
        kDictKanjiHiddenKey: 'true',
        kDictKanjiOrderKey: '2',
      });
    });

    test('没有旧记录 / 没设过 → 空', () {
      expect(kanjiPartSettingsOf(null), isEmpty);
      expect(kanjiPartSettingsOf(_dict('m', metadata: _mixed)), isEmpty);
    });
  });

  group('DictionaryRepository 汉字分区写入', () {
    late FushiDatabase db;
    late DictionaryRepository repo;
    int rebuilds = 0;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      rebuilds = 0;
      repo = DictionaryRepository(db, onCacheRebuild: () => rebuilds++);
      await repo.loadFromDb();
      await repo.persistDictionary(_dict('JMdict', order: 0));
      await repo.persistDictionary(
        _dict('現代新国語辞典', order: 1, metadata: _mixed),
      );
      await repo.persistDictionary(
        _dict('KANJIDIC', order: 0, type: DictionaryType.kanji),
      );
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('汉字分区列出混合词典', () {
      expect(
        repo.kanjiSectionDictionaries.map((Dictionary d) => d.name),
        containsAll(<String>['KANJIDIC', '現代新国語辞典']),
      );
      expect(repo.kanjiDictionaries.map((Dictionary d) => d.name), <String>[
        'KANJIDIC',
      ], reason: '按类型的列表语义不变(ctl 路由等仍按类型取)');
    });

    test('在汉字分区把混合词典挪到第一,不改它在术语分区的 order', () async {
      final List<Dictionary> section = repo.kanjiSectionDictionaries;
      final Dictionary mixed = section.firstWhere(
        (Dictionary d) => d.name == '現代新国語辞典',
      );
      final List<Dictionary> reordered = <Dictionary>[
        mixed,
        ...section.where((Dictionary d) => d.name != mixed.name),
      ];
      final int before = rebuilds;
      await repo.updateKanjiSectionOrder(reordered);

      expect(
        repo.kanjiSectionDictionaries.map((Dictionary d) => d.name),
        <String>['現代新国語辞典', 'KANJIDIC'],
      );
      final Dictionary afterMixed = repo.termDictionaries.firstWhere(
        (Dictionary d) => d.name == '現代新国語辞典',
      );
      expect(afterMixed.order, 1, reason: '术语分区里的位置不能被汉字分区的拖动带走');
      expect(repo.termDictionaries.map((Dictionary d) => d.name), <String>[
        'JMdict',
        '現代新国語辞典',
      ]);
      expect(rebuilds, greaterThan(before), reason: '重排要触发引擎重建');
    });

    test('关掉汉字部分:术语部分仍启用,且落库可重载', () async {
      final Dictionary mixed = repo.termDictionaries.firstWhere(
        (Dictionary d) => d.name == '現代新国語辞典',
      );
      await repo.setDictionaryKanjiPartHidden(mixed, true);

      Dictionary reloaded() => repo.termDictionaries.firstWhere(
        (Dictionary d) => d.name == '現代新国語辞典',
      );
      expect(reloaded().isKanjiPartHidden, isTrue);
      expect(reloaded().isHidden(JapaneseLanguage.instance), isFalse);

      await repo.loadFromDb();
      expect(reloaded().isKanjiPartHidden, isTrue, reason: '必须写穿 DB');
      expect(reloaded().metadata[kDictHasKanjiKey], 'true');

      await repo.setDictionaryKanjiPartHidden(reloaded(), false);
      expect(reloaded().isKanjiPartHidden, isFalse);
      expect(reloaded().metadata.containsKey(kDictKanjiHiddenKey), isFalse);
    });
  });
}
