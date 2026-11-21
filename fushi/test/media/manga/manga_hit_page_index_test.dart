import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';

/// BUG-4717（反馈 NfaXdQeLyD）：漫画右键 / 长按 payload 的落点页号解析。右键菜单的
/// 图片动作与「设为封面」按这个页号取图；没落在页上返回 null（菜单不列图片项），
/// 不回落到当前跨页的主页——双页跨页里那会拿到另一页的图。
void main() {
  group('MangaFushiPage.mangaHitPageIndex', () {
    test('落在跨页左页（RTL 下是后一页）就返回那一页，不是当前跨页主页', () {
      // 跨页 [4, 5]，RTL 左边是 5：右键左页 payload 带 page 5。
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{
          'page': 5,
          'x': 120,
          'y': 300,
        }, 10),
        5,
      );
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{
          'page': 4,
          'group': 2,
        }, 10),
        4,
      );
    });

    test('JSON 解出的 double 页号按整数取', () {
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'page': 3.0}, 10),
        3,
      );
    });

    test('页外空白 / 加载失败页（page: null）或缺字段 → null', () {
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'page': null}, 10),
        isNull,
      );
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'x': 1, 'y': 2}, 10),
        isNull,
      );
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'page': '3'}, 10),
        isNull,
      );
    });

    test('越界页号 → null，不夹到首末页', () {
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'page': -1}, 10),
        isNull,
      );
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'page': 10}, 10),
        isNull,
      );
      expect(
        MangaFushiPage.mangaHitPageIndex(<String, Object?>{'page': 0}, 0),
        isNull,
      );
    });
  });
}
