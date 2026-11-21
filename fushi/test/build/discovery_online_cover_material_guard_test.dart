import 'dart:io';

import 'package:test/test.dart';

/// 发现页 / 在线源浏览页的封面卡与库页同款（2026-10-25 定版：书 / 漫画光面书皮、
/// 视频光面海报，封面上不压角标，信息进副行）。
///
/// 用户 2026-10-26 反馈「发现页、在线源、媒体服务器，漫画视频没上新材质」：
/// 这些页的卡片是各自手写的 `AspectRatio + ClipRRect` 封面，读不到
/// `ShelfCoverMaterialScope`。材质靠 `ShelfCoverFrame` 读祖先 Scope 生效，
/// 两头缺一头都是静默失效（编译、单测全绿，画面仍是旧卡），所以按源码钉住：
/// 卡片组件用 `ShelfCoverFrame`、各页给 `ShelfCoverMaterialScope`。
void main() {
  String read(String path) => File(path).readAsStringSync();

  // 2026-11-16 拼贴改版二次定版：发现页媒体块与视频库「系列」同一个组件
  // （FushiCoverBlock：竖海报斜放 + 横版剧照 + logo 代替标题），封面材质由
  // 色块自己画，不再经 ShelfCoverFrame（用户「就该和视频媒体库的系列一样」）。
  test('发现页媒体块走视频库系列同款拼贴色块，不再压角标', () {
    final String src = read(
      'lib/src/pages/implementations/discovery/discovery_layout.dart',
    );
    expect(
      src,
      contains('FushiCoverBlock('),
      reason: 'DiscoveryCoverCard / 首块必须交给拼贴色块画（与库页系列块同款）',
    );
    expect(
      src,
      contains('backdrop: backdropImage == null'),
      reason: '有横版剧照时按系列块摆法铺在尾侧，竖海报完整斜放',
    );
    expect(src, contains('logo: logo,'), reason: '有 logo 时代替标题文字');
    expect(src, contains('shelfCoverCard('), reason: '卡壳透明、无状态层（库页同款）');
    expect(
      src,
      isNot(contains('List<Widget> badges')),
      reason: '封面上不压任何角标：评分 / 语言并进副行',
    );
    expect(
      src,
      contains('ShelfCoverMaterialScope('),
      reason: '「查看全部」是新路由，读不到发现页的 Scope，要自己给',
    );
  });

  test('在线源浏览页卡片走发现页同款封面卡，材质由 catalog 决定', () {
    final String src = read(
      'lib/src/media/online/online_source_browse_page.dart',
    );
    expect(src, contains('DiscoveryCoverCard('));
    expect(src, contains('DiscoverySkeletonCard('));
    expect(
      src,
      contains('ShelfCoverMaterialScope('),
      reason: '浏览页外层按 catalog.coverMaterial 给材质',
    );
    expect(src, contains('ShelfCoverMaterial get coverMaterial;'));
    expect(
      src,
      isNot(contains('childAspectRatio: 0.62')),
      reason: '旧的整张色卡比例；行高改按封面比例 + 文字块精确给',
    );
    final String layout = read(
      'lib/src/pages/implementations/discovery/discovery_layout.dart',
    );
    expect(
      layout,
      contains('FushiCoverBlock('),
      reason: '在线源复用的 DiscoveryCoverCard 必须是拼贴色块',
    );
  });

  test('各发现页 / 在线源 catalog 按域给材质', () {
    final Map<String, List<String>> expected = <String, List<String>>{
      'lib/src/pages/implementations/video_discovery_page.dart': <String>[
        'ShelfCoverMaterialScope(',
        'ShelfCoverMaterial.glossyPoster',
      ],
      'lib/src/pages/implementations/video_discovery_detail_page.dart':
          <String>[
            'ShelfCoverMaterialScope(',
            'ShelfCoverMaterial.glossyPoster',
          ],
      'lib/src/pages/implementations/discovery/airing_today_shelf.dart':
          <String>[
            'ShelfCoverMaterialScope(',
            'ShelfCoverMaterial.glossyPoster',
          ],
      'lib/src/media/manga/discovery/manga_discovery_page.dart': <String>[
        'ShelfCoverMaterialScope(',
        'ShelfCoverMaterial.glossyBook',
        'DiscoveryCoverShape.book',
      ],
      'lib/src/media/manga/mihon/mihon_source_browse_page.dart': <String>[
        'MihonMediaKind.manga => ShelfCoverMaterial.glossyBook',
        'MihonMediaKind.anime => ShelfCoverMaterial.glossyPoster',
      ],
      'lib/src/media/novel/online/lnreader_source_browse_page.dart': <String>[
        'ShelfCoverMaterial get coverMaterial => ShelfCoverMaterial.glossyBook',
      ],
    };
    for (final MapEntry<String, List<String>> entry in expected.entries) {
      final String src = read(entry.key);
      for (final String needle in entry.value) {
        expect(src, contains(needle), reason: '${entry.key} 缺 $needle');
      }
    }
  });
}
