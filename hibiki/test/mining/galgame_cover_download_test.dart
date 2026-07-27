import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_cover_download.dart';

/// 刮削封面落地的决策纯函数测试（是否下载 / 扩展名推导）。
///
/// 下载 IO 本体（HttpClient GET）不在单测射程内——决策与推导拆成纯函数的目的
/// 就是让「已有封面绝不覆盖」「扩展名归一」这些判定不用起网络就能钉死。
void main() {
  group('shouldAutoDownloadScrapedCover', () {
    test('无可用封面 + 有 URL → 下载', () {
      expect(
        shouldAutoDownloadScrapedCover(
          hasUsableCoverFile: false,
          coverUrl: 'https://example.com/cover.jpg',
        ),
        isTrue,
      );
    });

    test('已有可用封面文件（手选/自动/上次下载）→ 绝不覆盖', () {
      expect(
        shouldAutoDownloadScrapedCover(
          hasUsableCoverFile: true,
          coverUrl: 'https://example.com/cover.jpg',
        ),
        isFalse,
      );
    });

    test('无 URL / 空白 URL → 不下载', () {
      expect(
        shouldAutoDownloadScrapedCover(
          hasUsableCoverFile: false,
          coverUrl: null,
        ),
        isFalse,
      );
      expect(
        shouldAutoDownloadScrapedCover(
          hasUsableCoverFile: false,
          coverUrl: '   ',
        ),
        isFalse,
      );
    });
  });

  group('shouldDownloadExplicitScrapedCover', () {
    test('用户显式选中候选：有 URL 即下载（即使已有封面也覆盖）', () {
      // 显式路径的签名里根本没有 hasUsableCoverFile——「是否已有封面」不参与
      // 决策，这正是与隐式路径的分界：显式选择 = 用户点名要这条，封面一起换。
      expect(
        shouldDownloadExplicitScrapedCover(
          coverUrl: 'https://example.com/cover.jpg',
        ),
        isTrue,
      );
    });

    test('无 URL / 空白 URL → 不下载', () {
      expect(shouldDownloadExplicitScrapedCover(coverUrl: null), isFalse);
      expect(shouldDownloadExplicitScrapedCover(coverUrl: '   '), isFalse);
    });

    test('显式覆盖 vs 隐式不覆盖：同一「已有封面 + 有 URL」情形两函数分道', () {
      const String url = 'https://example.com/cover.jpg';
      // 隐式（自动刮削路径）：已有可用封面绝不覆盖。
      expect(
        shouldAutoDownloadScrapedCover(
          hasUsableCoverFile: true,
          coverUrl: url,
        ),
        isFalse,
      );
      // 显式（统一刮削弹窗「使用」）：照样下载覆盖。
      expect(shouldDownloadExplicitScrapedCover(coverUrl: url), isTrue);
    });
  });

  group('galgameCoverExtension', () {
    test('Content-Type 优先于 URL 后缀', () {
      expect(
        galgameCoverExtension(
          url: 'https://example.com/cover.png',
          contentType: 'image/jpeg',
        ),
        '.jpg',
      );
    });

    test('Content-Type 带 charset 参数也能识别', () {
      expect(
        galgameCoverExtension(
          url: 'https://example.com/x',
          contentType: 'image/png; charset=utf-8',
        ),
        '.png',
      );
    });

    test('无 Content-Type 时回落 URL 后缀（白名单内）', () {
      expect(
        galgameCoverExtension(url: 'https://example.com/a/b/cover.webp'),
        '.webp',
      );
      // .jpeg 归一成 .jpg（与 saveGameCoverFromFile 的归一化一致）。
      expect(
        galgameCoverExtension(url: 'https://example.com/cover.JPEG'),
        '.jpg',
      );
    });

    test('URL 带查询串不影响后缀推导', () {
      expect(
        galgameCoverExtension(url: 'https://example.com/cover.png?w=600&h=800'),
        '.png',
      );
    });

    test('两头都推不出 → 回退 .jpg', () {
      expect(galgameCoverExtension(url: 'https://example.com/cover'), '.jpg');
      expect(
        galgameCoverExtension(
          url: 'https://example.com/cover.php',
          contentType: 'application/octet-stream',
        ),
        '.jpg',
      );
    });
  });
}
