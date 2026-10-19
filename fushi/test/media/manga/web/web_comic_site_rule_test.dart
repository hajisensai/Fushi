import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';

void main() {
  final String bundled = File(
    'assets/web_comic/site_rules.json',
  ).readAsStringSync();

  group('随包站点规则', () {
    final WebComicRuleSet rules = WebComicRuleSet.parse(bundled);

    test('每一条都能解析（坏条目会被静默跳过，条数必须对得上）', () {
      final List<Object?> raw =
          (jsonDecode(bundled) as Map<String, Object?>)['rules']!
              as List<Object?>;
      expect(rules.rules.length, raw.length);
      expect(rules.rules.length, inInclusiveRange(3, 5));
    });

    test('没有真机验证过的规则一律标 verified:false', () {
      for (final WebComicSiteRule rule in rules.rules) {
        expect(rule.verified, isFalse, reason: rule.id);
      }
    });

    test('章节页命中对应规则，作品页 / 首页不命中', () {
      expect(
        rules
            .matchChapter(
              Uri.parse(
                'https://mangadex.org/chapter/4c419c16-ef49-4305-9c46-d3adbe1f60b7',
              ),
            )
            ?.id,
        'mangadex',
      );
      expect(
        rules.matchChapter(Uri.parse('https://mangadex.org/title/abc')),
        isNull,
      );
      expect(
        rules
            .matchChapter(
              Uri.parse(
                'https://komiic.com/comic/2299/chapter/66668/images/all',
              ),
            )
            ?.id,
        'komiic',
      );
      expect(
        rules
            .matchChapter(
              Uri.parse(
                'https://www.webtoons.com/en/fantasy/x/ep-1/viewer?title_no=95&episode_no=1',
              ),
            )
            ?.id,
        'webtoons',
      );
      expect(
        rules
            .matchChapter(
              Uri.parse(
                'https://www.mangacopy.com/comic/foo/chapter/33cde95c-c8ea-11ea',
              ),
            )
            ?.id,
        'copymanga',
      );
      expect(rules.matchChapter(Uri.parse('https://example.com/')), isNull);
    });

    test('作品身份按 seriesKeyPattern 推出并带 host；推不出返回 null', () {
      final WebComicSiteRule komiic = rules.byId('komiic')!;
      expect(
        komiic.seriesKeyOf(
          Uri.parse('https://komiic.com/comic/2299/chapter/66668/images/all'),
        ),
        'komiic.com/2299',
      );
      final WebComicSiteRule mangadex = rules.byId('mangadex')!;
      expect(
        mangadex.seriesKeyOf(Uri.parse('https://mangadex.org/chapter/x')),
        isNull,
      );
    });

    test('api 规则的 body 对象被编码成字符串，命名分组占位原样保留给脚本', () {
      final WebComicImageSource images = rules.byId('komiic')!.images;
      expect(images, isA<WebComicApiImageSource>());
      final WebComicApiImageSource api = images as WebComicApiImageSource;
      expect(api.method, 'POST');
      expect(api.body, contains('{chapterId}'));
      expect(jsonDecode(api.body!), isA<Map<String, Object?>>());
    });
  });

  group('规则解析的容错', () {
    test('缺字段 / 正则编译不过 / 重复 id 的条目被跳过，其余照常', () {
      final WebComicRuleSet set = WebComicRuleSet.parse(
        jsonEncode(<String, Object?>{
          'rules': <Object?>[
            <String, Object?>{
              'id': 'ok',
              'name': 'OK',
              'hosts': <String>['*.example.com'],
              'chapterUrlPattern': r'^/read/(?<id>\d+)',
              'images': <String, Object?>{'mode': 'dom', 'selector': 'img.p'},
            },
            <String, Object?>{
              'id': 'ok',
              'name': 'dup',
              'hosts': <String>['dup.com'],
              'chapterUrlPattern': '^/',
              'images': <String, Object?>{'mode': 'dom', 'selector': 'img'},
            },
            <String, Object?>{
              'id': 'bad-regex',
              'name': 'Bad',
              'hosts': <String>['bad.com'],
              'chapterUrlPattern': '(',
              'images': <String, Object?>{'mode': 'dom', 'selector': 'img'},
            },
            <String, Object?>{
              'id': 'no-images',
              'name': 'No',
              'hosts': <String>['no.com'],
              'chapterUrlPattern': '^/',
            },
            <String, Object?>{
              'id': 'fixed-without-url',
              'name': 'Fixed',
              'hosts': <String>['f.com'],
              'chapterUrlPattern': '^/',
              'referer': 'fixed',
              'images': <String, Object?>{'mode': 'dom', 'selector': 'img'},
            },
          ],
        }),
      );
      expect(set.rules.map((WebComicSiteRule r) => r.id), <String>['ok']);
      final WebComicSiteRule rule = set.rules.single;
      expect(rule.matchesHost('example.com'), isTrue);
      expect(rule.matchesHost('cdn.example.com'), isTrue);
      expect(rule.matchesHost('notexample.com'), isFalse);
      expect(
        rule
            .chapterMatch(Uri.parse('https://a.example.com/read/42'))
            ?.namedGroup('id'),
        '42',
      );
      final WebComicImageSource images = rule.images;
      expect(images, isA<WebComicDomImageSource>());
      expect((images as WebComicDomImageSource).attributes, <String>['src']);
    });

    test('整份不是 JSON 时返回空表（通用扫图照常可用）', () {
      expect(WebComicRuleSet.parse('not json').rules, isEmpty);
    });
  });

  group('扫图调用脚本', () {
    test('script 取图把函数体写进注入源码，不交给页面 eval', () {
      const WebComicSiteRule rule = WebComicSiteRule(
        id: 's',
        name: 'S',
        hosts: <String>['s.com'],
        chapterUrlPattern: '^/',
        images: WebComicScriptImageSource(code: 'return ["a.jpg"];'),
      );
      final String js = webComicScanInvocation(requestId: 'r1', rule: rule);
      expect(js, contains('async function (ctx) {\nreturn ["a.jpg"];\n}'));
      expect(js, contains('"requestId":"r1"'));
      expect(js, contains('"handler":"$kWebComicScanHandler"'));
      expect(js, isNot(contains('"code"')));
    });

    test('无规则时 rule 为 null、脚本函数为 null', () {
      final String js = webComicScanInvocation(requestId: 'r2', rule: null);
      expect(js, contains('"rule":null'));
      expect(js, contains(', null); true;'));
    });
  });
}
