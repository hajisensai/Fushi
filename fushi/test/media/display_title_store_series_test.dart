import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/display_title_store_series.dart';

/// BUG-4903（设计稿 H4）：首页「继续」把「Re：ゼロから始める異世界生活 1<Re：…」
/// 显示成两段标题粘在一起。根因是书店（Kindle / BookWalker）标题自带的
/// `<系列名> (文库名)` 注记原样进了显示名；显示出口去掉它，身份原名不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stripStoreSeriesAnnotation', () {
    test('用户库里的真实书名：去掉系列注记与文库名，保留卷号', () {
      expect(
        stripStoreSeriesAnnotation(
          'Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)',
        ),
        'Re：ゼロから始める異世界生活 1',
      );
    });

    test('没有文库名、全角括号同样处理', () {
      expect(
        stripStoreSeriesAnnotation('青春ブタ野郎はバニーガール先輩の夢を見ない<青春ブタ野郎>'),
        '青春ブタ野郎はバニーガール先輩の夢を見ない',
      );
      expect(
        stripStoreSeriesAnnotation('安達としまむら10＜安達としまむら＞（電撃文庫）'),
        '安達としまむら10',
      );
    });

    test('系列名按全角 / 空白归一化后比较前缀', () {
      expect(stripStoreSeriesAnnotation('ＳＡＯ 3<SAO>'), 'ＳＡＯ 3');
    });

    test('不是书店注记的写法原样返回', () {
      // 单字分卷标签。
      expect(stripStoreSeriesAnnotation('本の題名<上>'), '本の題名<上>');
      // 尖括号里不是正文前缀。
      expect(stripStoreSeriesAnnotation('タイトル<限定版>'), 'タイトル<限定版>');
      // 只有文库名、没有系列注记。
      expect(
        stripStoreSeriesAnnotation('安達としまむら13 (電撃文庫)'),
        '安達としまむら13 (電撃文庫)',
      );
      // 整个标题就是尖括号。
      expect(stripStoreSeriesAnnotation('<Re：ゼロ>'), '<Re：ゼロ>');
      expect(stripStoreSeriesAnnotation(''), '');
    });
  });

  group('cleanBookDisplayTitle', () {
    test('哈希后缀与系列注记一起去掉', () {
      expect(cleanBookDisplayTitle('志乃と恋 2<志乃と恋> [3574f94a]'), '志乃と恋 2');
    });

    test('书族显示出口走它（无 override 的原名回退）', () {
      expect(
        displayTitleForBook(
          rawTitle: 'Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)',
        ),
        'Re：ゼロから始める異世界生活 1',
      );
    });
  });
}
