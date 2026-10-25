import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('发现页统一封面卡走 ShelfCoverFrame + ShelfCardMeta，不再压角标', () {
    final String src = read(
      'lib/src/pages/implementations/discovery/discovery_layout.dart',
    );
    expect(
      src,
      contains('ShelfCoverFrame(child: cover)'),
      reason: 'DiscoveryCoverCard 的封面必须交给 ShelfCoverFrame 画材质',
    );
    expect(src, contains('ShelfCardMeta('), reason: '标题 / 副行与库页同款');
    expect(src, contains('shelfCoverCard('), reason: '卡壳透明、无状态层（库页同款）');
    expect(
      src,
      isNot(contains('List<Widget> badges')),
      reason: '封面上不压任何角标：评分 / 语言并进副行',
    );
    expect(
      src,
      contains('ShelfCardMeta.heightFor('),
      reason: '网格 / 横滑行行高与新卡文字块同一口径，否则溢出或留空',
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
      contains('ShelfCoverFrame('),
      reason: '在线源复用的 DiscoveryCoverCard 必须画材质',
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
