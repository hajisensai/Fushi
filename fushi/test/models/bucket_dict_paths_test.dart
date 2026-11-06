import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// [bucketDictPaths]（fushi_dictionary，app 与无头服务端共用）是 FFI 引擎词典分桶的单一真相（app 同步 _rebuildDictPathsCache 与
/// 异步 _rebuildDictPathsCacheAsync 共用）。此前分桶 switch 在两处逐字复制、无法单测
/// （依赖真词典 + 真目录 + FFI）。本测试钉死分桶规则：隐藏的词典四种类型一律不进桶
/// （BUG-177/TODO-094/BUG-3454）；不存在的目录跳过。
void main() {
  DictPathEntry e(
    DictionaryType type,
    String path, {
    bool exists = true,
    bool hidden = false,
    bool hasKanji = false,
    bool kanjiHidden = false,
    int kanjiOrder = 0,
  }) => (
    type: type,
    path: path,
    exists: exists,
    hidden: hidden,
    hasKanji: hasKanji,
    kanjiHidden: kanjiHidden,
    kanjiOrder: kanjiOrder,
  );

  group('bucketDictPaths 词典分桶单一真相', () {
    test('按类型分四桶', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/t1'),
        e(DictionaryType.frequency, '/f1'),
        e(DictionaryType.pitch, '/p1'),
        e(DictionaryType.kanji, '/k1'),
        e(DictionaryType.term, '/t2'),
      ]);
      expect(b.term, <String>['/t1', '/t2']);
      expect(b.freq, <String>['/f1']);
      expect(b.pitch, <String>['/p1']);
      expect(b.kanji, <String>['/k1']);
    });

    test('term 隐藏不进桶（BUG-3454）', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/hidden', hidden: true),
        e(DictionaryType.term, '/visible'),
      ]);
      expect(
        b.term,
        <String>['/visible'],
        reason:
            '引擎在 Dart 过滤之前就按最长匹配截断到 maxResults：关掉的词典的'
            '长匹配会把可见词典的结果挤出 top-N，高亮也按它的长度画',
      );
    });

    test('freq/pitch/kanji 隐藏不进桶（BUG-177/TODO-094）', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.frequency, '/f', hidden: true),
        e(DictionaryType.pitch, '/p', hidden: true),
        e(DictionaryType.kanji, '/k', hidden: true),
      ]);
      expect(b.freq, isEmpty, reason: '隐藏 freq 不得进引擎,否则弹窗仍冒出');
      expect(b.pitch, isEmpty);
      expect(b.kanji, isEmpty);
    });

    test('不存在的目录跳过（任意类型）', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/gone', exists: false),
        e(DictionaryType.frequency, '/gone2', exists: false),
        e(DictionaryType.term, '/here'),
      ]);
      expect(b.term, <String>['/here']);
      expect(b.freq, isEmpty);
    });

    test('全空输入返回四个空桶（支持 always-rebuild 清空引擎 BUG-171）', () {
      final b = bucketDictPaths(const <DictPathEntry>[]);
      expect(b.term, isEmpty);
      expect(b.freq, isEmpty);
      expect(b.pitch, isEmpty);
      expect(b.kanji, isEmpty);
    });

    // ── TODO-622: 混合词典(term + 内含 kanji)双桶路由 ──
    test('混合词典(term + hasKanji)同时进 term 桶和 kanji 桶', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/mixed', hasKanji: true),
      ]);
      expect(b.term, <String>[
        '/mixed',
      ], reason: '混合词典首先是词条词典,必须进 term 桶让划词查词命中');
      expect(b.kanji, <String>[
        '/mixed',
      ], reason: '混合词典内含 kanji,也要进 kanji 桶让单字查汉字命中');
    });

    test('纯 term 词典(hasKanji=false)不进 kanji 桶', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/pure'),
      ]);
      expect(b.term, <String>['/pure']);
      expect(b.kanji, isEmpty, reason: '纯词条词典无 kanji,不得污染 kanji 桶');
    });

    // 混合词典在词典管理里「术语」「汉字」两个分区各一行（Hoshi Reader 同款），
    // 两部分的开关各管各的：hidden 只管术语部分，kanjiHidden 只管汉字部分。
    test('关掉混合词典的汉字部分:不进 kanji 桶,术语部分照常', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/mixed', hasKanji: true, kanjiHidden: true),
      ]);
      expect(b.term, <String>['/mixed']);
      expect(b.kanji, isEmpty, reason: '关掉的汉字部分不得冒出(kanji 桶无渲染期过滤)');
    });

    test('关掉混合词典的术语部分:不进 term 桶,汉字部分照常', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/mixed', hidden: true, hasKanji: true),
      ]);
      expect(b.term, isEmpty, reason: '隐藏的 term 不进 term 桶(BUG-3454)');
      expect(b.kanji, <String>['/mixed'], reason: '汉字分区里那一行仍开着,汉字卡就该照常出来');
    });

    test('kanji 桶按「汉字」分区顺序输出,而不是全局 order 的交错顺序', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.kanji, '/kanjidic', kanjiOrder: 1),
        e(DictionaryType.term, '/mixed', hasKanji: true, kanjiOrder: 0),
        e(DictionaryType.kanji, '/other', kanjiOrder: 2),
      ]);
      expect(b.kanji, <String>['/mixed', '/kanjidic', '/other']);
    });

    test('分区顺序相同时按输入先后(与 kanjiSectionDictionariesOf 同一规则)', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.kanji, '/a', kanjiOrder: 3),
        e(DictionaryType.term, '/b', hasKanji: true, kanjiOrder: 3),
      ]);
      expect(b.kanji, <String>['/a', '/b']);
    });

    test('不存在目录的混合词典任何桶都跳过', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/gone', exists: false, hasKanji: true),
      ]);
      expect(b.term, isEmpty);
      expect(b.kanji, isEmpty);
    });
  });
}
