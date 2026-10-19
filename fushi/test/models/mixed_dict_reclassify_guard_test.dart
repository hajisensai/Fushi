// TODO-622 source-scan guards for the mixed-dictionary classification fix.
//
// A mixed JA-JA dictionary (term entries + an embedded kanji appendix) used to
// be misclassified as 'kanji' by the native detect_type (it returned 'kanji'
// whenever a kanji_bank existed, regardless of term_bank). That sent the whole
// 80k+ entry dictionary into the kanji bucket only, so word lookup returned
// nothing. The fix has four layers; the Dart-side invariants this guard pins:
//
//   1. _migrateDictionaryTypes self-heals already-imported dictionaries:
//      a stored type=='kanji' dictionary whose on-disk blobs actually contain
//      term records (probed via the native single source of truth
//      FushiDicts.probeDictContent) is demoted back to 'term' and tagged
//      metadata['hasKanji']='true'.
//   2. _rebuildDictPathsCache / _rebuildDictPathsCacheAsync read
//      metadata['hasKanji'] into the DictPathEntry so the bucket router can
//      route a mixed dictionary into BOTH buckets.
//
// Layer rationale: the real reclassification calls a C++ FFI engine
// (probeDictContent) and the live Drift DB, neither of which flutter_test can
// link. The behavioural double-bucket routing is covered by
// bucket_dict_paths_test.dart; the reclassification control flow can only be
// pinned by a source scan (the real path needs the FFI lib recompiled with the
// TODO-622 probe export, which predates the current dev .dll/.so).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  late String appModel;

  /// fushi_dictionary 的分桶源文件（剥过注释）：DictPathEntry 与 dictPathEntryOf 住在这里。
  late String buckets;

  setUpAll(() {
    final File f = File('lib/src/models/app_model.dart');
    expect(f.existsSync(), isTrue,
        reason: 'app_model.dart not found at ${f.absolute.path}');
    appModel = f.readAsStringSync();
    final File b = File(
        '../packages/fushi_dictionary/lib/src/engine/dictionary_buckets.dart');
    expect(b.existsSync(), isTrue,
        reason: 'dictionary_buckets.dart not found at ${b.absolute.path}');
    buckets = maskComments(b.readAsStringSync());
  });

  // 先剥注释再取函数体：本文件的判据全是「函数体里必须出现某字面量」，而这些
  // 字面量在同一段代码的中文注释里逐字出现过好几次（本仓一天抓到过 6 起这种
  // 守卫假绿）。统一走 helpers/source_guard.dart 的 maskComments。
  String bodyOf(String rawSrc, String name) {
    final String src = maskComments(rawSrc);
    final int sig = src.indexOf(name);
    expect(sig, greaterThanOrEqualTo(0), reason: '$name not found');
    final int open = src.indexOf('{', sig);
    expect(open, greaterThanOrEqualTo(0), reason: 'no { after $name');
    int depth = 0;
    for (int i = open; i < src.length; i++) {
      final String c = src[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return src.substring(open, i + 1);
      }
    }
    fail('unbalanced braces scanning $name');
  }

  group('TODO-622 mixed dictionary reclassification', () {
    test('_migrateDictionaryTypes self-heals stored kanji dicts via probe', () {
      final String body = bodyOf(appModel, 'void _migrateDictionaryTypes(');
      expect(body.contains('d.type == DictionaryType.kanji'), isTrue,
          reason: 'must single out already-imported type==kanji dictionaries');
      expect(body.contains('FushiDicts.probeDictContent('), isTrue,
          reason: 'classification must come from the native single source of '
              'truth (probe blobs.bin), not a fragile Dart blob header read');
      // 锚到**降级表达式本身**，不是裸的 `DictionaryType.term`：后者会被同一
      // 函数体里无关的 `if (d.type != DictionaryType.term) continue;` 满足，于是
      // 把降级整个删成 `type: d.type` 这条断言仍然绿——恒真，零覆盖。
      expect(body.contains('mixed ? DictionaryType.term'), isTrue,
          reason: 'a kanji dict that actually contains term records must be '
              'demoted back to term so word lookup hits again');
      // 探测结果必须落库——包括「探过、结论是不用改」。少了这一步，「没探过」和
      // 「探过、无需改判」在数据上不可区分，纯 kanji 词典每次启动都要把整张 hash
      // 表重扫一遍（同步 FFI + 随机跳读 blobs.bin），词典一多启动直接卡死。
      expect(body.contains('kDictTypeProbeKey'), isTrue,
          reason: 'the probe result must be recorded so the scan runs once '
              'per dictionary, not once per launch');
      expect(body.contains("'hasKanji'"), isTrue,
          reason:
              'the demoted mixed dict must be tagged hasKanji so the bucket '
              'router also registers it as a kanji dict');
    });

    // DictPathEntry 与它的构造已搬进 fushi_dictionary（c93f413，与无头服务端共用）：
    // app_model 的两条重建路径把整份 metadata 交给 dictPathEntryOf，hasKanji 在那里读。
    test('path-cache rebuild reads metadata[hasKanji] into DictPathEntry', () {
      for (final m in <String>[
        'void _rebuildDictPathsCache(',
        'Future<void> _rebuildDictPathsCacheAsync(',
      ]) {
        final String body = bodyOf(appModel, m);
        expect(
            body.contains('dictPathEntryOf(') && body.contains('metadata:'),
            isTrue,
            reason: '$m must hand the dictionary metadata to dictPathEntryOf '
                'so a mixed dictionary is routed into the kanji bucket');
      }
      // 箭头函数：取签名到收尾的「\n);」（bodyOf 认的第一个「{」是命名参数表）。
      final int at = buckets.indexOf('DictPathEntry dictPathEntryOf(');
      expect(at, greaterThanOrEqualTo(0), reason: 'dictPathEntryOf not found');
      final String ctor = buckets.substring(at, buckets.indexOf('\n);', at));
      expect(ctor.contains('hasKanji: hasEmbeddedKanjiIn('), isTrue,
          reason: 'dictPathEntryOf must populate DictPathEntry.hasKanji');
      expect(buckets.contains("const String kDictHasKanjiKey = 'hasKanji';"),
          isTrue);
      expect(
          RegExp(r'bool hasEmbeddedKanjiIn\([^)]*\)\s*=>[^;]*metadata\[kDictHasKanjiKey\]')
              .hasMatch(buckets),
          isTrue,
          reason: 'hasEmbeddedKanjiIn must read metadata[hasKanji]');
    });

    test('DictPathEntry carries a hasKanji field', () {
      final int idx = buckets.indexOf('typedef DictPathEntry = ({');
      expect(idx, greaterThanOrEqualTo(0));
      final int close = buckets.indexOf('});', idx);
      final String decl = buckets.substring(idx, close);
      expect(decl.contains('bool hasKanji'), isTrue,
          reason:
              'DictPathEntry must declare hasKanji for double-bucket route');
    });
  });
}
