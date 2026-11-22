import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_match_measure.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 手柄查词模式在查词交给副屏查词页时（页内不弹窗、副屏不回报命中长度）由本机量命中
/// 长度：四页（阅读器、视频、漫画、歌词）共用 [measureLookupMatchGraphemes]，右摇杆
/// −1 在先按 +1 之前就有长度可减。
class _MeasureAppModel extends AppModel {
  _MeasureAppModel(this.matched) : super(testPlatformServices());

  /// term → 引擎命中前缀长度（UTF-16）；不在表里 = 查不到。
  final Map<String, int> matched;
  final List<({String term, int rubyCount, int? max})> queries =
      <({String term, int rubyCount, int? max})>[];

  @override
  int get maximumTerms => 7;

  @override
  Future<DictionarySearchResult> searchDictionaryWithRuby({
    required String searchTerm,
    required List<FushiRubySpan> rubySpans,
    bool searchWithWildcards = false,
    int? overrideMaximumTerms,
  }) async {
    queries.add((
      term: searchTerm,
      rubyCount: rubySpans.length,
      max: overrideMaximumTerms,
    ));
    final int? len = matched[searchTerm];
    return DictionarySearchResult(
      searchTerm: searchTerm,
      bestLength: len ?? 0,
      entries: len == null
          ? const <DictionaryEntry>[]
          : <DictionaryEntry>[
              DictionaryEntry(
                dictionaryName: 'd',
                word: searchTerm.substring(0, len),
                reading: '',
                meaning: 'm',
              ),
            ],
    );
  }
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('lookupMatchedGraphemes', () {
    test('UTF-16 命中前缀换算成字素，查不到 = 0', () {
      expect(lookupMatchedGraphemes('駆ける', 2), 2);
      expect(lookupMatchedGraphemes('駆ける', 9), 3);
      expect(lookupMatchedGraphemes('駆ける', 0), 0);
      expect(lookupMatchedGraphemes('', 3), 0);
      expect(lookupMatchedGraphemes('👨‍👩‍👧b', 8), 1);
      // 代理对（U+20B9F 𠮟）占两个码元：命中 3 码元 = 2 字素。
      expect(lookupMatchedGraphemes('𠮟る', 3), 2);
    });
  });

  group('measureLookupMatchGraphemes', () {
    test('同一查询（同上限、带注音），返回字素数', () async {
      final _MeasureAppModel model = _MeasureAppModel(<String, int>{
        '𠮟られる': 3,
      });
      final int n = await measureLookupMatchGraphemes(
        model,
        '𠮟られる',
        rubySpans: const <FushiRubySpan>[
          FushiRubySpan(start: 0, end: 2, reading: 'しか'),
        ],
      );
      expect(n, 2);
      expect(model.queries.single.term, '𠮟られる');
      expect(model.queries.single.rubyCount, 1);
      expect(model.queries.single.max, 7);
    });

    test('查不到 / 空词 = 0（空词不查）', () async {
      final _MeasureAppModel model = _MeasureAppModel(<String, int>{});
      expect(await measureLookupMatchGraphemes(model, 'xyz'), 0);
      expect(await measureLookupMatchGraphemes(model, ''), 0);
      expect(model.queries.map((q) => q.term), <String>['xyz']);
    });
  });

  group('四页查词交给副屏时都用同一个 helper 量命中长度', () {
    test('阅读器：副屏分支给手柄查词量长度，页内分支换算成字素', () {
      final String src = _read(
        'lib/src/pages/implementations/reader_fushi/lookup.part.dart',
      );
      final int route = src.indexOf('await _routeLookupToCompanion(data');
      expect(route, greaterThan(0));
      final String branch = src.substring(route, src.indexOf('return;', route));
      expect(branch, contains('controller != null'));
      expect(branch, contains('measureLookupMatchGraphemes('));
      expect(
        'lookupMatchedGraphemes(\n'.allMatches(src).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('视频：控制器查词带 measureMatch，副屏分支量长度', () {
      final String target = _read(
        'lib/src/pages/implementations/video_fushi/controller_lookup.part.dart',
      );
      expect(target, contains('measureMatch: true'));
      final String src = _read(
        'lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart',
      );
      final int route = src.indexOf('await routeCompanionLookup(');
      expect(route, greaterThan(0));
      final String branch = src.substring(
        route,
        src.indexOf('_lastLookupPositionMs', route),
      );
      expect(branch, contains('measureLookupMatchGraphemes(appModel, term)'));
      expect(branch, isNot(contains('return 0;\n    }')));
    });

    test('漫画：认领到手柄请求时副屏分支量长度', () {
      final String src = _read(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      );
      expect(src, contains('measureMatch: request != null'));
      final int route = src.indexOf(
        'await routeCompanionLookup(text: term, sentence: _lastSentence)',
      );
      expect(route, greaterThan(0));
      final String branch = src.substring(route, src.indexOf('return;', route));
      expect(branch, contains('measureLookupMatchGraphemes(appModel, term)'));
      expect(src, contains('lookupMatchedGraphemes(term, highlightCount)'));
    });

    test('歌词：用共享 helper，不再自带一份换算', () {
      final String src = _read(
        'lib/src/pages/implementations/music/music_lyrics_page.dart',
      );
      expect(src, contains('measureLookupMatchGraphemes('));
      expect(src, contains('lookupMatchedGraphemes(term, highlight)'));
      expect(src, isNot(contains('musicLyricsMatchedGraphemes')));
    });
  });
}
