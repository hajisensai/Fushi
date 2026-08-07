import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/tmdb_client.dart';

/// v68 守卫：TMDB `/images` 响应的 Jellyfin 式分类（parseTmdbImageSet 纯函数）。
///
/// 分类规则是本功能的语义核心，锁三条：
///  1. **带语言的横图不得混进无字 backdrop**——backdrop 槽是全屏背景/轮换，烧死
///     片名文字的图进去就是「背景上永远糊着一行字」（Jellyfin 把它降级为 Thumb，
///     本仓叫 titleCard）；
///  2. 无字 backdrop 封顶 [kTmdbMaxBackdrops] 张（响应序即 vote 降序）；
///  3. logo 跳过 SVG（Flutter Image 不解码矢量）+ 按 zh→ja→en 语言偏好挑选。
void main() {
  Map<String, Object?> image(String filePath, {String? lang}) =>
      <String, Object?>{'file_path': filePath, 'iso_639_1': lang};

  String body({
    List<Map<String, Object?>> backdrops = const <Map<String, Object?>>[],
    List<Map<String, Object?>> logos = const <Map<String, Object?>>[],
  }) =>
      jsonEncode(<String, Object?>{'backdrops': backdrops, 'logos': logos});

  test('带语言横图分流为 titleCard，不混进无字 backdrop', () {
    final TmdbImageSet set = parseTmdbImageSet(body(
      backdrops: <Map<String, Object?>>[
        image('/clean0.jpg'),
        image('/titled_en.jpg', lang: 'en'),
        image('/clean1.jpg'),
        image('/titled_zh.jpg', lang: 'zh'),
      ],
    ));

    expect(
      set.backdropUrls,
      <String>[
        '${TmdbClient.backdropBase}/clean0.jpg',
        '${TmdbClient.backdropBase}/clean1.jpg',
      ],
      reason: '带字横图混进背景槽 = 全屏背景永远糊着一行片名',
    );
    expect(
      set.titleCardUrl,
      '${TmdbClient.backdropBase}/titled_zh.jpg',
      reason: '带字横图按 zh→ja→en 偏好挑一张作 titleCard',
    );
  });

  test('无字 backdrop 封顶 kTmdbMaxBackdrops 张（响应序 = vote 降序）', () {
    final TmdbImageSet set = parseTmdbImageSet(body(
      backdrops: <Map<String, Object?>>[
        for (int i = 0; i < 10; i++) image('/b$i.jpg'),
      ],
    ));
    expect(set.backdropUrls, hasLength(kTmdbMaxBackdrops));
    expect(set.backdropUrls.first, '${TmdbClient.backdropBase}/b0.jpg',
        reason: '截断必须保头部（vote 最高的几张），不是随机取样');
  });

  test('logo：SVG 跳过 + 语言偏好 zh→ja→en → 首张兜底', () {
    final TmdbImageSet set = parseTmdbImageSet(body(
      logos: <Map<String, Object?>>[
        image('/vector.svg', lang: 'zh'),
        image('/logo_en.png', lang: 'en'),
        image('/logo_ja.png', lang: 'ja'),
      ],
    ));
    expect(
      set.logoUrl,
      '${TmdbClient.posterBase}/logo_ja.png',
      reason: 'zh 那张是 SVG（Flutter 解不了）须跳过，落到偏好序次位的 ja',
    );

    final TmdbImageSet noPref = parseTmdbImageSet(body(
      logos: <Map<String, Object?>>[image('/logo_fr.png', lang: 'fr')],
    ));
    expect(noPref.logoUrl, '${TmdbClient.posterBase}/logo_fr.png',
        reason: '偏好语言全缺时取首张，不是空手而归');
  });

  test('空响应 / 全空数组 → isEmpty，调用方回落候选单张背景', () {
    expect(parseTmdbImageSet('{}').isEmpty, isTrue);
    expect(parseTmdbImageSet(body()).isEmpty, isTrue);
  });
}
