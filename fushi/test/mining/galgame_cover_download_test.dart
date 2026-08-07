import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_cover_download.dart';

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

  group('shouldDownloadExplicitScrapedCover（显式路径）', () {
    // 用户 2026-07-28 拍板：统一刮削弹窗里亲手点「使用」某候选 = 明确要绑到该
    // 条目，封面随元数据一起换（覆盖既有封面）——与视频「在线匹配封面」、书籍
    // 「在线刮削封面」的显式语义一致，三域手动刮削统一可覆盖。
    test('有 URL → 下载（不看是否已有封面：显式选择即覆盖）', () {
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
  });

  group('显式 vs 隐式对照（语义分界守卫）', () {
    // 同一输入（已有可用封面 + 有 URL）两条路径给出相反决策——这不是巧合而是
    // 契约：显式 = 用户点名要换（覆盖）；自动/隐式 = 后台补齐（绝不覆盖）。
    test('已有封面 + 有 URL：显式下载、隐式不下载', () {
      const String url = 'https://example.com/cover.jpg';
      expect(shouldDownloadExplicitScrapedCover(coverUrl: url), isTrue);
      expect(
        shouldAutoDownloadScrapedCover(hasUsableCoverFile: true, coverUrl: url),
        isFalse,
      );
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
