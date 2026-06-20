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
//      HoshiDicts.probeDictContent) is demoted back to 'term' and tagged
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

void main() {
  late String appModel;

  setUpAll(() {
    final File f = File('lib/src/models/app_model.dart');
    expect(f.existsSync(), isTrue,
        reason: 'app_model.dart not found at ${f.absolute.path}');
    appModel = f.readAsStringSync();
  });

  String bodyOf(String src, String name) {
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
      expect(body.contains('HoshiDicts.probeDictContent('), isTrue,
          reason: 'classification must come from the native single source of '
              'truth (probe blobs.bin), not a fragile Dart blob header read');
      expect(body.contains('type: DictionaryType.term'), isTrue,
          reason: 'a kanji dict that actually contains term records must be '
              'demoted back to term so word lookup hits again');
      expect(body.contains("'hasKanji'"), isTrue,
          reason:
              'the demoted mixed dict must be tagged hasKanji so the bucket '
              'router also registers it as a kanji dict');
    });

    test('path-cache rebuild reads metadata[hasKanji] into DictPathEntry', () {
      for (final m in <String>[
        'void _rebuildDictPathsCache(',
        'Future<void> _rebuildDictPathsCacheAsync(',
      ]) {
        final String body = bodyOf(appModel, m);
        expect(body.contains("metadata['hasKanji']"), isTrue,
            reason: '$m must read metadata[hasKanji] so a mixed dictionary is '
                'routed into the kanji bucket');
        expect(body.contains('hasKanji:'), isTrue,
            reason: '$m must populate the DictPathEntry.hasKanji field');
      }
    });

    test('DictPathEntry carries a hasKanji field', () {
      final int idx = appModel.indexOf('typedef DictPathEntry = ({');
      expect(idx, greaterThanOrEqualTo(0));
      final int close = appModel.indexOf('});', idx);
      final String decl = appModel.substring(idx, close);
      expect(decl.contains('bool hasKanji'), isTrue,
          reason:
              'DictPathEntry must declare hasKanji for double-bucket route');
    });
  });
}
