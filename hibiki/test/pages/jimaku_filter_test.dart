import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';

JimakuCandidate _cand(String fileName) => JimakuCandidate(
      entryName: 'Series',
      file: JimakuFile(name: fileName, url: 'https://x/$fileName'),
    );

void main() {
  test('empty keyword keeps all', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass'];
    expect(filterByKeyword(names, '', (String s) => s), names);
  });

  test('case-insensitive substring match', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass', 'c.srt'];
    final List<String> out = filterByKeyword(names, 'webrip', (String s) => s);
    expect(out, <String>['a.WEBRip.srt']);
  });

  test('whitespace-only keyword keeps all', () {
    final List<String> names = <String>['x', 'y'];
    expect(filterByKeyword(names, '   ', (String s) => s), names);
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
}
