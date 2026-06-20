import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// [bucketDictPaths] 是 FFI 引擎词典分桶的单一真相（同步 _rebuildDictPathsCache 与
/// 异步 _rebuildDictPathsCacheAsync 共用）。此前分桶 switch 在两处逐字复制、无法单测
/// （依赖真词典 + 真目录 + FFI）。本测试钉死分桶规则：term 隐藏仍进桶（渲染期再过滤）；
/// freq/pitch/kanji 隐藏不进桶（BUG-177/TODO-094）；不存在的目录跳过。
void main() {
  DictPathEntry e(DictionaryType type, String path,
          {bool exists = true, bool hidden = false, bool hasKanji = false}) =>
      (
        type: type,
        path: path,
        exists: exists,
        hidden: hidden,
        hasKanji: hasKanji,
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

    test('term 隐藏仍进桶（渲染期再过滤）', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/t', hidden: true),
      ]);
      expect(b.term, <String>['/t'], reason: 'term 隐藏仍要进引擎,渲染期才过滤');
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
      expect(b.term, <String>['/mixed'],
          reason: '混合词典首先是词条词典,必须进 term 桶让划词查词命中');
      expect(b.kanji, <String>['/mixed'],
          reason: '混合词典内含 kanji,也要进 kanji 桶让单字查汉字命中');
    });

    test('纯 term 词典(hasKanji=false)不进 kanji 桶', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/pure'),
      ]);
      expect(b.term, <String>['/pure']);
      expect(b.kanji, isEmpty, reason: '纯词条词典无 kanji,不得污染 kanji 桶');
    });

    test('隐藏的混合词典不进 kanji 桶(kanji 桶无渲染期隐藏过滤,BUG-177)', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(DictionaryType.term, '/mixed', hidden: true, hasKanji: true),
      ]);
      expect(b.term, <String>['/mixed'], reason: 'term 隐藏仍进 term 桶,渲染期过滤');
      expect(b.kanji, isEmpty, reason: '隐藏的混合词典 kanji 部分不得冒出(kanji 桶无渲染期过滤)');
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
