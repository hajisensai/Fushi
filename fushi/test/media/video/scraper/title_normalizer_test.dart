import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/title_normalizer.dart';

void main() {
  group('TitleNormalizer.normalize', () {
    test('全角字母数字与全角冒号转半角，小写化', () {
      expect(TitleNormalizer.normalize('ＡＢＣ１２３：ｄｅｆ'), 'abc123 def');
    });

    test('全角空格折叠为单个半角空格', () {
      expect(TitleNormalizer.normalize('あ　　い'), 'あ い');
    });

    test('繁体/日文旧字体转简体', () {
      expect(TitleNormalizer.normalize('無職転生'), '无职转生');
      expect(TitleNormalizer.normalize('劇場版 紫羅蘭永恆花園'), '剧场版 紫罗兰永恒花园');
      expect(TitleNormalizer.normalize('戦闘'), '战斗');
    });

    test('装饰符号去除并折叠空白', () {
      expect(
        TitleNormalizer.normalize('無職転生～異世界行ったら本気だす～'),
        '无职转生 异世界行ったら本气だす',
      );
      expect(TitleNormalizer.normalize('「ぼっち・ざ・ろっく！」'), 'ぼっち ざ ろっく');
      expect(TitleNormalizer.normalize('SPY×FAMILY'), 'spy family');
    });

    test('空串与纯装饰串归一为空', () {
      expect(TitleNormalizer.normalize(''), '');
      expect(TitleNormalizer.normalize('～☆！？…'), '');
    });
  });

  group('TitleNormalizer.tokens', () {
    test('CJK 连续段按 bigram 切分', () {
      expect(
        TitleNormalizer.tokens(TitleNormalizer.normalize('无职转生 第三季')),
        <String>['无职', '职转', '转生', '第三', '三季'],
      );
    });

    test('单字 CJK 段保留原字', () {
      expect(
        TitleNormalizer.tokens(TitleNormalizer.normalize('a 之 b')),
        <String>['a', '之', 'b'],
      );
    });

    test('ASCII 词按空白切分，罗马数字保留为独立 token', () {
      expect(
        TitleNormalizer.tokens('mushoku tensei ii'),
        <String>['mushoku', 'tensei', 'ii'],
      );
      expect(
        TitleNormalizer.tokens(TitleNormalizer.normalize('無職転生Ⅱ')),
        contains('ⅱ'),
      );
    });
  });

  group('TitleNormalizer.similarity', () {
    test('繁简/大小写差异视为全同', () {
      expect(TitleNormalizer.similarity('無職転生', '无职转生'), 1.0);
      expect(
          TitleNormalizer.similarity('Mushoku Tensei', 'mushoku tensei'), 1.0);
    });

    test('真实季度对给出显著高于无关标题的分数', () {
      final double related = TitleNormalizer.similarity(
        '无职转生 第三季',
        '无职转生Ⅲ～到了异世界就拿出真本事～',
      );
      final double unrelated = TitleNormalizer.similarity(
        '无职转生 第三季',
        '孤独摇滚',
      );
      expect(related, greaterThan(0.25));
      expect(unrelated, lessThan(0.1));
      expect(related, greaterThan(unrelated + 0.15));
    });

    test('同系列不同季标题给出中高相似度', () {
      expect(
        TitleNormalizer.similarity('无职转生', '无职转生 第2季'),
        greaterThan(0.6),
      );
    });

    test('少量错字仍保持高相似度（Levenshtein 兜底）', () {
      expect(
        TitleNormalizer.similarity('violet evergarden', 'violet evergardan'),
        greaterThan(0.9),
      );
    });

    test('空串边界', () {
      expect(TitleNormalizer.similarity('', ''), 1.0);
      expect(TitleNormalizer.similarity('abc', ''), 0.0);
    });
  });
}
