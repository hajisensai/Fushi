import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/media_search_text.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';

JimakuCandidate _cand(String fileName) => JimakuCandidate(
      entryName: 'Series',
      file: JimakuFile(name: fileName, url: 'https://x/$fileName'),
    );

void main() {
  // G6：jimaku 关键词筛选并入库页同一归一化口径（filterByMediaSearch），
  // 原本地 filterByKeyword 已删除。
  test('empty keyword keeps all', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass'];
    expect(filterByMediaSearch(names, '', (String s) => <String>[s]), names);
  });

  test('case-insensitive substring match', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass', 'c.srt'];
    final List<String> out =
        filterByMediaSearch(names, 'webrip', (String s) => <String>[s]);
    expect(out, <String>['a.WEBRip.srt']);
  });

  test('whitespace-only keyword keeps all', () {
    final List<String> names = <String>['x', 'y'];
    expect(filterByMediaSearch(names, '   ', (String s) => <String>[s]), names);
  });

  test('G6: katakana/fullwidth folding matches like the library pages', () {
    final List<String> names = <String>['フェイト 01.srt', 'other.srt'];
    expect(
      filterByMediaSearch(names, 'ふぇいと', (String s) => <String>[s]),
      <String>['フェイト 01.srt'],
    );
  });

  group('language filter (TODO-674)', () {
    final List<JimakuCandidate> candidates = <JimakuCandidate>[
      _cand('ep01.ja.srt'),
      _cand('ep01.zh.srt'),
      _cand('ep02.ja.ass'),
      _cand('ep03.srt'), // 认不出语言
    ];

    test('null（全部）不过滤', () {
      expect(filterCandidatesByLanguage(candidates, null), candidates);
    });

    test('选 ja 只留 ja 候选', () {
      final List<JimakuCandidate> out =
          filterCandidatesByLanguage(candidates, 'ja');
      expect(out.map((JimakuCandidate c) => c.file.name),
          <String>['ep01.ja.srt', 'ep02.ja.ass']);
    });

    test('选具体语言会过滤掉认不出语言的候选；但「全部」仍能看到', () {
      // 选 zh：只剩 zh。认不出语言的 ep03.srt 被排除。
      final List<JimakuCandidate> zh =
          filterCandidatesByLanguage(candidates, 'zh');
      expect(
          zh.map((JimakuCandidate c) => c.file.name), <String>['ep01.zh.srt']);
      // 但「全部」永远列出全部，认不出语言的候选绝不彻底消失（保底）。
      expect(filterCandidatesByLanguage(candidates, null), hasLength(4));
    });

    test('availableLanguages 去重 + ja/zh/en/ko 稳定顺序', () {
      expect(availableLanguages(candidates), <String>['ja', 'zh']);
      expect(
        availableLanguages(<JimakuCandidate>[
          _cand('a.en.srt'),
          _cand('b.ja.srt'),
          _cand('c.ko.srt'),
          _cand('d.zh.srt'),
        ]),
        <String>['ja', 'zh', 'en', 'ko'],
      );
      // 全是认不出语言的候选 → 空（归到「全部」，不渲染语言 chip）。
      expect(availableLanguages(<JimakuCandidate>[_cand('x.srt')]), isEmpty);
    });
  });

  group('sortJimakuCandidates（消除集数乱序）', () {
    test('同语言按集号升序，认不出集号排末尾', () {
      final List<JimakuCandidate> sorted =
          sortJimakuCandidates(<JimakuCandidate>[
        _cand('Show - 12.ja.srt'),
        _cand('Show extras.ja.srt'), // 无集号
        _cand('Show - 02.ja.srt'),
        _cand('Show - 09.ja.srt'),
      ]);
      expect(
        sorted.map((JimakuCandidate c) => c.file.name),
        <String>[
          'Show - 02.ja.srt',
          'Show - 09.ja.srt',
          'Show - 12.ja.srt',
          'Show extras.ja.srt',
        ],
      );
    });

    test('语言权重优先：ja→zh→en→ko，同集号也按语言分组', () {
      final List<JimakuCandidate> sorted =
          sortJimakuCandidates(<JimakuCandidate>[
        _cand('Show - 01.en.srt'),
        _cand('Show - 01.zh.srt'),
        _cand('Show - 01.ja.srt'),
      ]);
      expect(
        sorted.map((JimakuCandidate c) => c.language),
        <String>['ja', 'zh', 'en'],
      );
    });

    test('preferred 语言置顶（用户按系列记忆的语言）', () {
      final List<JimakuCandidate> sorted = sortJimakuCandidates(
        <JimakuCandidate>[
          _cand('Show - 01.ja.srt'),
          _cand('Show - 01.zh.srt'),
        ],
        preferredLanguage: 'zh',
      );
      expect(sorted.first.language, 'zh');
    });

    test('jimakuLanguageRank 权重次序', () {
      expect(jimakuLanguageRank('ja'), lessThan(jimakuLanguageRank('zh')));
      expect(jimakuLanguageRank('zh'), lessThan(jimakuLanguageRank('en')));
      expect(jimakuLanguageRank('en'), lessThan(jimakuLanguageRank('ko')));
      expect(jimakuLanguageRank(null), greaterThan(jimakuLanguageRank('ko')));
      expect(jimakuLanguageRank('en', preferred: 'en'),
          lessThan(jimakuLanguageRank('ja')));
    });
  });
}
