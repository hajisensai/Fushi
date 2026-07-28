import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/metadata/bangumi_cover_url.dart';

void main() {
  group('bangumiOriginalImageUrl', () {
    test('原图地址保持不变（含查询参数）', () {
      expect(
        bangumiOriginalImageUrl(
          'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg?r=123',
        ),
        'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg?r=123',
      );
    });

    test('去掉当前 /r/尺寸/ 缩放层', () {
      expect(
        bangumiOriginalImageUrl(
          'https://lain.bgm.tv/r/800/pic/cover/l/aa/bb/42_cover.jpg',
        ),
        'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg',
      );
      expect(
        bangumiOriginalImageUrl(
          'https://lain.bgm.tv/r/200x200/pic/cover/l/aa/bb/42_cover.jpg',
        ),
        'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg',
      );
    });

    test('旧式 common/medium/small/grid 路径回到 large 原图路径', () {
      for (final String size in <String>['c', 'm', 's', 'g']) {
        expect(
          bangumiOriginalImageUrl(
            'https://lain.bgm.tv/pic/cover/$size/aa/bb/42_cover.jpg',
          ),
          'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg',
        );
      }
    });

    test('非 Bangumi 图床不猜路径，只去首尾空白', () {
      expect(
        bangumiOriginalImageUrl('  https://img.example/r/400/cover.jpg  '),
        'https://img.example/r/400/cover.jpg',
      );
      expect(bangumiOriginalImageUrl('  '), isNull);
      expect(bangumiOriginalImageUrl(null), isNull);
    });
  });

  group('bangumiOriginalCoverUrl', () {
    test('按字段优先级选择，并把退化尺寸还原为原图', () {
      expect(
        bangumiOriginalCoverUrl(<Object?, Object?>{
          'images': <String, Object?>{
            'large': '',
            'common':
                'https://lain.bgm.tv/r/400/pic/cover/l/aa/bb/42_cover.jpg',
            'medium': 'https://lain.bgm.tv/r/800/pic/cover/l/aa/bb/other.jpg',
          },
        }),
        'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg',
      );
    });

    test('兼容搜索响应的 image 字段', () {
      expect(
        bangumiOriginalCoverUrl(<Object?, Object?>{
          'image': 'https://lain.bgm.tv/pic/cover/s/aa/bb/42_cover.jpg',
        }),
        'https://lain.bgm.tv/pic/cover/l/aa/bb/42_cover.jpg',
      );
    });

    test('没有可用字段返回 null', () {
      expect(
        bangumiOriginalCoverUrl(<Object?, Object?>{
          'images': <String, Object?>{'large': '  '},
        }),
        isNull,
      );
    });
  });
}
