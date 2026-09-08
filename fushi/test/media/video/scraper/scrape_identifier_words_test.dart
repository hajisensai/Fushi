import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/scrape_identifier_words.dart';

/// 设计稿 C 二期第一项：识别词（对标 MoviePilot WordsMatcher）。
/// 四种语法、注释/空行、非法行收集、偏移越界与前导 0 保持，都锁在这里。
void main() {
  ScrapeIdentifierWords compile(String text) =>
      ScrapeIdentifierWords.parse(text).identifierWords;

  group('parse', () {
    test('comments and blank lines are skipped', () {
      final ScrapeIdentifierWordParseResult parsed =
          ScrapeIdentifierWords.parse(
        '# 这是注释\n\n   \nNekomoe\n',
      );
      expect(parsed.words, hasLength(1));
      expect(parsed.errors, isEmpty);
      expect(parsed.words.single.kind, ScrapeIdentifierWordKind.block);
      expect(parsed.words.single.raw, 'Nekomoe');
    });

    test('each syntax maps to its own kind', () {
      final ScrapeIdentifierWordParseResult parsed =
          ScrapeIdentifierWords.parse(
        <String>[
          'Nekomoe',
          'Kusuriya => Frieren',
          '- <> . >> EP+12',
          'Kusuriya => Frieren && - <> . >> EP-1',
        ].join('\n'),
      );
      expect(parsed.errors, isEmpty);
      expect(
        parsed.words.map((ScrapeIdentifierWord word) => word.kind).toList(),
        <ScrapeIdentifierWordKind>[
          ScrapeIdentifierWordKind.block,
          ScrapeIdentifierWordKind.replace,
          ScrapeIdentifierWordKind.offset,
          ScrapeIdentifierWordKind.replaceAndOffset,
        ],
      );
      expect(parsed.words[2].episodeOffset, 12);
      expect(parsed.words[3].episodeOffset, -1);
    });

    test('an invalid regex lands in errors and the other rules still work', () {
      final ScrapeIdentifierWordParseResult parsed =
          ScrapeIdentifierWords.parse(
        '[unclosed\nNekomoe',
      );
      expect(parsed.errors, hasLength(1));
      expect(parsed.errors.single, contains('第 1 行'));
      expect(parsed.words, hasLength(1));
      expect(
        parsed.identifierWords.apply('Nekomoe Frieren').title.trim(),
        'Frieren',
      );
    });

    test('a non EP offset expression is rejected instead of evaluated', () {
      for (final String line in <String>[
        'a <> b >> EP*2',
        'a <> b >> 1+1',
        'a <> b >> EP+1.5',
        'a >> EP+1',
        'a <> b EP+1',
      ]) {
        final ScrapeIdentifierWordParseResult parsed =
            ScrapeIdentifierWords.parse(line);
        expect(parsed.words, isEmpty, reason: line);
        expect(parsed.errors, hasLength(1), reason: line);
      }
    });

    test('parseEpisodeOffsetExpression only accepts decimal EP shifts', () {
      expect(parseEpisodeOffsetExpression('EP+12'), 12);
      expect(parseEpisodeOffsetExpression('EP-1'), -1);
      expect(parseEpisodeOffsetExpression(' EP + 12 '), 12);
      expect(parseEpisodeOffsetExpression('EP+0'), 0);
      expect(parseEpisodeOffsetExpression('EP'), isNull);
      expect(parseEpisodeOffsetExpression('EP+1e3'), isNull);
      expect(parseEpisodeOffsetExpression('EP+99999'), isNull);
    });
  });

  group('apply', () {
    test('a block word is deleted from the title', () {
      final ({String title, int episodeOffset}) result =
          compile(r'\[.*?\]').apply('[Nekomoe kissaten] Frieren - 01');
      expect(result.title.trim(), 'Frieren - 01');
      expect(result.episodeOffset, 0);
    });

    test('a replace word rewrites the title', () {
      final ({String title, int episodeOffset}) result =
          compile('Kusuriya => Frieren').apply('Kusuriya - 01');
      expect(result.title, 'Frieren - 01');
      expect(result.episodeOffset, 0);
    });

    test('an episode offset shifts the first number between the bounds', () {
      final ({String title, int episodeOffset}) result =
          compile('Frieren - <>  >> EP+12').apply('Frieren - 01');
      expect(result.title, 'Frieren - 13');
      expect(result.episodeOffset, 12);
    });

    test('leading zeros keep their width', () {
      expect(compile('- <>  >> EP+12').apply('Show - 01').title, 'Show - 13');
      expect(compile('- <>  >> EP+12').apply('Show - 001').title, 'Show - 013');
      expect(compile('- <>  >> EP+12').apply('Show - 1').title, 'Show - 13');
    });

    test('the back bound stops the number search', () {
      final ({String title, int episodeOffset}) result =
          compile(r'- <> \[ >> EP-12').apply('Show - 13 [1080p]');
      expect(result.title, 'Show - 01 [1080p]');
      expect(result.episodeOffset, -12);
    });

    test('an out-of-range shift leaves the title untouched', () {
      expect(compile('- <>  >> EP-12').apply('Show - 01'),
          (title: 'Show - 01', episodeOffset: 0));
      expect(compile('- <>  >> EP+9999').apply('Show - 12'),
          (title: 'Show - 12', episodeOffset: 0));
    });

    test('a missing bound makes the offset rule inapplicable', () {
      expect(compile('Other - <>  >> EP+1').apply('Show - 01'),
          (title: 'Show - 01', episodeOffset: 0));
      expect(compile(r'- <> \[ >> EP+1').apply('Show - 01'),
          (title: 'Show - 01', episodeOffset: 0));
      expect(compile('- <>  >> EP+1').apply('Show without a number'),
          (title: 'Show without a number', episodeOffset: 0));
    });

    test('replace-and-offset only shifts when the replacement matched', () {
      final ScrapeIdentifierWords words =
          compile('Kusuriya => Frieren && - <>  >> EP-12');
      expect(words.apply('Kusuriya - 13'),
          (title: 'Frieren - 01', episodeOffset: -12));
      // 替换没命中：整条规则跳过，集号一并不动。
      expect(
          words.apply('Other - 13'), (title: 'Other - 13', episodeOffset: 0));
    });

    test('rules are applied in the listed order', () {
      final ScrapeIdentifierWords words = compile(
        <String>['A => B', 'B => C'].join('\n'),
      );
      expect(words.apply('A show').title, 'C show');
      final ScrapeIdentifierWords reversed = compile(
        <String>['B => C', 'A => B'].join('\n'),
      );
      expect(reversed.apply('A show').title, 'B show');
    });

    test('each rule participates at most once per call', () {
      final ScrapeIdentifierWords words = compile('- <>  >> EP+1');
      final ({String title, int episodeOffset}) once = words.apply('Show - 01');
      expect(once, (title: 'Show - 02', episodeOffset: 1));
      // 同一条规则不会在一次调用里反复自我叠加。
      expect(words.apply(once.title), (title: 'Show - 03', episodeOffset: 1));
    });

    test('an empty word list is a no-op', () {
      expect(ScrapeIdentifierWords.empty.apply('Show - 01'),
          (title: 'Show - 01', episodeOffset: 0));
      expect(ScrapeIdentifierWords.empty.isEmpty, isTrue);
    });

    test('the source text is kept for configuration fingerprints', () {
      const String text = 'Nekomoe\n# comment';
      expect(ScrapeIdentifierWords.parse(text).identifierWords.source, text);
    });
  });
}
