import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// 推荐词典「学习语言」维度：非日语学习语言动态生成 wty 双语/单语条目，
/// 日语路径必须与旧 [DictionaryDownloader.catalogForLang] 完全一致（零破坏）。
void main() {
  group('catalogForLearningLang', () {
    test('日语学习语言 == 旧目录（行为零变化）', () {
      for (final String gloss in ['en', 'zh', 'ko', 'de', 'ja']) {
        final List<RecommendedDictionary> legacy =
            DictionaryDownloader.catalogForLang(gloss);
        final List<RecommendedDictionary> viaLearning =
            DictionaryDownloader.catalogForLearningLang(
                learningLang: 'ja', glossLang: gloss);
        expect(
          viaLearning.map((d) => d.matchPrefix).toList(),
          legacy.map((d) => d.matchPrefix).toList(),
          reason: 'gloss=$gloss 时日语目录必须与旧实现逐条一致',
        );
      }
    });

    test('学英语 + 中文释义 → 双语 en-zh + 英语兜底不重复 + 单语 en-en', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'en', glossLang: 'zh');
      expect(cat.map((d) => d.matchPrefix), ['wty-en-zh', 'wty-en-en']);
      expect(cat[0].category, DictionaryCategory.bilingual);
      expect(cat[0].url,
          'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/dict/en/zh/wty-en-zh.zip');
      expect(cat[1].category, DictionaryCategory.monolingual);
    });

    test('学中文 + 日语释义 → zh-ja、zh-en 兜底、zh-zh 单语', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'zh', glossLang: 'ja');
      expect(cat.map((d) => d.matchPrefix),
          ['wty-zh-ja', 'wty-zh-en', 'wty-zh-zh']);
    });

    test('释义语言 == 学习语言 → 只有英语兜底双语 + 单语', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'ko', glossLang: 'ko');
      expect(cat.map((d) => d.matchPrefix), ['wty-ko-en', 'wty-ko-ko']);
    });

    test('受限源语言（hu）缺 sv 目标与单语 → 只剩英语兜底', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'hu', glossLang: 'sv');
      expect(cat.map((d) => d.matchPrefix), ['wty-hu-en']);
    });

    test('id 源缺 mn 目标但保留单语', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'id', glossLang: 'mn');
      expect(cat.map((d) => d.matchPrefix), ['wty-id-en', 'wty-id-id']);
    });

    test('非日语目录不含日语专属条目（JPDB/KANJIDIC 等）', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'en', glossLang: 'zh');
      expect(
        cat.where((d) => !d.matchPrefix.startsWith('wty-')),
        isEmpty,
        reason: '非日语学习语言只应有 wty 动态条目',
      );
    });
  });

  group('defaultSelectionForLearningLang', () {
    test('日语委托旧默认勾选', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLang('zh');
      expect(
        DictionaryDownloader.defaultSelectionForLearningLang(
            learningLang: 'ja', glossLang: 'zh', workingCatalog: cat),
        DictionaryDownloader.defaultSelectionForLang('zh', cat),
      );
    });

    test('非日语默认勾第一个双语条目', () {
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'en', glossLang: 'zh');
      final Set<int> sel = DictionaryDownloader.defaultSelectionForLearningLang(
          learningLang: 'en', glossLang: 'zh', workingCatalog: cat);
      expect(sel, {0});
      expect(cat[0].matchPrefix, 'wty-en-zh');
    });

    test('无双语（受限对全灭时）回落单语；目录空则空选', () {
      // en 学 en 释义：无双语（同语言），应勾英英单语。
      final List<RecommendedDictionary> cat =
          DictionaryDownloader.catalogForLearningLang(
              learningLang: 'en', glossLang: 'en');
      expect(cat.map((d) => d.matchPrefix), ['wty-en-en']);
      expect(
        DictionaryDownloader.defaultSelectionForLearningLang(
            learningLang: 'en', glossLang: 'en', workingCatalog: cat),
        {0},
      );
      expect(
        DictionaryDownloader.defaultSelectionForLearningLang(
            learningLang: 'en',
            glossLang: 'en',
            workingCatalog: const <RecommendedDictionary>[]),
        isEmpty,
      );
    });
  });

  group('indexUrl 对任意 wty 语言对派生（在线更新能力保持）', () {
    test('wty-en-zh → 独立 index 端点', () {
      final RecommendedDictionary d =
          DictionaryDownloader.wtyPairDict(srcLang: 'en', tgtLang: 'zh')!;
      expect(
        d.indexUrl,
        'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-en-zh-index.json?download=true',
      );
      expect(d.isCatalogUpdatable, isTrue);
    });

    test('旧 ja 条目派生不变（wty-ja-en）', () {
      final RecommendedDictionary d = DictionaryDownloader.catalog
          .singleWhere((x) => x.matchPrefix == 'wty-ja-en');
      expect(
        d.indexUrl,
        'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-ja-en-index.json?download=true',
      );
    });
  });

  group('wtyPairAvailable 矩阵规则', () {
    test('主流语言对全可用', () {
      expect(DictionaryDownloader.wtyPairAvailable('en', 'zh'), isTrue);
      expect(DictionaryDownloader.wtyPairAvailable('zh', 'hu'), isTrue);
      expect(DictionaryDownloader.wtyPairAvailable('ja', 'mn'), isTrue);
    });

    test('受限源 × 缺失目标 不可用', () {
      expect(DictionaryDownloader.wtyPairAvailable('hu', 'hu'), isFalse);
      expect(DictionaryDownloader.wtyPairAvailable('sv', 'mn'), isFalse);
      expect(DictionaryDownloader.wtyPairAvailable('mn', 'sl'), isFalse);
      expect(DictionaryDownloader.wtyPairAvailable('id', 'id'), isTrue,
          reason: 'id 有单语，只缺 hu/sl/sv/mn 目标');
    });

    test('未知语言码不可用', () {
      expect(DictionaryDownloader.wtyPairAvailable('xx', 'en'), isFalse);
      expect(DictionaryDownloader.wtyPairAvailable('en', 'xx'), isFalse);
    });
  });
}
