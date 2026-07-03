import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';

/// TODO-1125 B：deriveSeriesDefaultName 纯函数守卫（widget/DB-free）。
///  - 剥各类卷号 / 集数 / 上下 / 罗马数字 / #N 尾标记后取最长公共前缀。
///  - 无公共前缀 / 推导为空 → 兜底 fallback。
///  - 单成员 → 剥卷号后的该标题。
///  - 与视频侧 parseVideoFilename 复用（视频批量组合路径）。
void main() {
  const String fb = '新系列';

  group('deriveSeriesDefaultName', () {
    test('空列表 → fallback', () {
      expect(deriveSeriesDefaultName(const <String>[], fallback: fb), fb);
    });

    test('单成员剥卷号 → 主干', () {
      expect(
        deriveSeriesDefaultName(const <String>['转生史莱姆 第3巻'], fallback: fb),
        '转生史莱姆',
      );
    });

    test('CJK 第N巻 尾标记 → 公共前缀', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['転生したらスライムだった件 第1巻', '転生したらスライムだった件 第2巻'],
          fallback: fb,
        ),
        '転生したらスライムだった件',
      );
    });

    test('第N話 / 第N集 尾标记', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['鬼滅の刃 第1話', '鬼滅の刃 第10話'],
          fallback: fb,
        ),
        '鬼滅の刃',
      );
    });

    test('vol.N 尾标记', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['One Piece Vol.1', 'One Piece Vol.2'],
          fallback: fb,
        ),
        'One Piece',
      );
    });

    test('上 / 下 尾标记', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['ノルウェイの森 (上)', 'ノルウェイの森 (下)'],
          fallback: fb,
        ),
        'ノルウェイの森',
      );
    });

    test('罗马数字尾标记', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['Final Fantasy I', 'Final Fantasy II'],
          fallback: fb,
        ),
        'Final Fantasy',
      );
    });

    test('#N 尾标记', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['Chainsaw Man #1', 'Chainsaw Man #12'],
          fallback: fb,
        ),
        'Chainsaw Man',
      );
    });

    test('结尾裸数字尾标记', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['進撃の巨人 1', '進撃の巨人 2'],
          fallback: fb,
        ),
        '進撃の巨人',
      );
    });

    test('无公共前缀 → fallback', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['苹果之书', '香蕉物语'],
          fallback: fb,
        ),
        fb,
      );
    });

    test('公共前缀剥后只剩「第」等悬挂标记 → 不残留半截', () {
      // 两标题剥卷号后公共前缀含悬挂「第」时应清掉，落到 fallback 或干净主干。
      final String r = deriveSeriesDefaultName(
        const <String>['第1巻', '第2巻'],
        fallback: fb,
      );
      expect(r, fb);
    });

    test('叠加标记「名 第1巻 上」也剥净', () {
      expect(
        deriveSeriesDefaultName(
          const <String>['ある本 第1巻 上', 'ある本 第2巻 下'],
          fallback: fb,
        ),
        'ある本',
      );
    });

    test('视频侧复用 parseVideoFilename 得系列名后再取公共前缀', () {
      final List<String> series = <String>[
        for (final String f in const <String>[
          'SPYxFAMILY S01E01',
          'SPYxFAMILY S01E02'
        ])
          parseVideoFilename(f).series,
      ];
      expect(
        deriveSeriesDefaultName(series, fallback: fb),
        'SPYxFAMILY',
      );
    });
  });
}
