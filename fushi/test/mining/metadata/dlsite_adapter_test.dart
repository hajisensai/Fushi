/// DLsite galgame 源：adapter 映射 / 搜索只留游戏 / merge 中的 nsfw 与开发商 /
/// 弹窗与批量刮削的「认编号直取」。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/galgame_scrape_dialog.dart';
import 'package:fushi/src/mining/metadata/adapters/dlsite_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一部成人向 ADV 的 product.json（字段形态同 2026-10 实测响应）。
final String _productJson = jsonEncode(<Object?>[
  <String, Object?>{
    'workno': 'RJ01234567',
    'work_name': '測試ゲーム',
    'title_name': '測試シリーズ',
    'maker_name': 'テストサークル',
    'work_type': 'ADV',
    'regist_date': '2024-05-03 00:00:00',
    'age_category': 3,
    'genres': <Object?>[
      <String, Object?>{'name': '純愛'},
      <String, Object?>{'name': 'ノベル'},
    ],
    'creaters': <String, Object?>{
      'voice_by': <Object?>[
        <String, Object?>{'name': '声優A'},
      ],
    },
    'intro_s': 'あらすじ',
    'image_main': <String, Object?>{
      'url':
          '//img.dlsite.jp/modpub/images2/work/doujin/RJ01235000/'
          'RJ01234567_img_main.jpg',
    },
  },
]);

final String _ratingJson = jsonEncode(<String, Object?>{
  'RJ01234567': <String, Object?>{
    'rate_average_2dp': 4.5,
    'rate_count': 10,
    'dl_count': 100,
  },
});

final String _suggestJson = jsonEncode(<String, Object?>{
  'work': <Object?>[
    <String, Object?>{
      'workno': 'RJ01234567',
      'work_name': '測試ゲーム',
      'maker_name': 'テストサークル',
      'work_type': 'ADV',
      'age_category': 3,
    },
    <String, Object?>{
      'workno': 'RJ299717',
      'work_name': '音声作品',
      'work_type': 'SOU',
      'age_category': 1,
    },
  ],
});

DlsiteMetadataAdapter _adapter() => DlsiteMetadataAdapter(
  client: DlsiteClient(
    minRequestInterval: Duration.zero,
    client: MockClient((http.Request req) async {
      final String body = switch (req.url.path) {
        '/suggest/' => _suggestJson,
        '/maniax/product/info/ajax' => _ratingJson,
        _ => _productJson,
      };
      return http.Response.bytes(utf8.encode(body), 200);
    }),
  ),
);

GalgameEntry _game({required String name, required String exePath}) =>
    GalgameEntry(
      id: '1',
      name: name,
      exePath: exePath,
      workdir: '',
      addedAt: DateTime(2026),
    );

void main() {
  group('DlsiteMetadataAdapter', () {
    test('validateId 只认作品编号，外链按分站拼', () {
      final DlsiteMetadataAdapter a = _adapter();
      expect(a.source, GalgameMetadataSource.dlsite);
      expect(a.validateId('RJ01234567'), isTrue);
      expect(a.validateId('vj123456'), isTrue);
      expect(a.validateId('4885'), isFalse, reason: '裸数字是 Bangumi 的');
      expect(a.validateId('v17'), isFalse, reason: 'v<数字> 是 VNDB 的');
      expect(
        a.externalUrl('RJ01234567'),
        'https://www.dlsite.com/maniax/work/=/product_id/RJ01234567.html',
      );
    });

    test('fetchById：社团→开发商、5 分制→10 分制、成人向→nsfw、带评分', () async {
      final GalgameMetadataDraft draft = (await _adapter().fetchById(
        'rj01234567',
      ))!;
      expect(draft.name, '測試ゲーム');
      expect(draft.allTitles, <String>['測試ゲーム', '測試シリーズ']);
      expect(draft.developer, 'テストサークル');
      expect(draft.releaseDate, '2024-05-03');
      expect(draft.tags, <String>['純愛', 'ノベル']);
      expect(draft.score, 9.0);
      expect(draft.nsfw, isTrue);
      expect(draft.summary, 'あらすじ');
      expect(draft.coverUrl, startsWith('https://img.dlsite.jp/'));
      expect(draft.externalId, 'RJ01234567');
    });

    test('fetchById 非法编号抛 GalgameMetadataException', () async {
      await expectLater(
        _adapter().fetchById('nope'),
        throwsA(isA<GalgameMetadataException>()),
      );
    });

    test('searchByName 只留游戏类作品，候选带推导出的主图', () async {
      final List<SourceCandidate> list = await _adapter().searchByName('測試');
      expect(list.map((SourceCandidate c) => c.externalId), <String>[
        'RJ01234567',
      ]);
      expect(list.single.source, GalgameMetadataSource.dlsite);
      expect(
        list.single.coverUrl,
        'https://img.dlsite.jp/modpub/images2/work/doujin/RJ01235000/'
        'RJ01234567_img_main.jpg',
      );
    });

    test('controller：输入编号只走 DLsite 直取（Bangumi / VNDB 不认这个 ID）', () async {
      final GalgameScrapeController controller = GalgameScrapeController(
        adapters: <GalgameMetadataAdapter>[_adapter()],
      );
      final GalgameScrapeSearchResult result = await controller.search(
        'RJ01234567',
      );
      expect(result.candidates.single.externalId, 'RJ01234567');
    });
  });

  test('全年龄作品 nsfw 为 false（分级明确，不是「源没给」的 null）', () {
    final GalgameMetadataDraft draft = dlsiteWorkToGalgameDraft(
      DlsiteWork(
        id: DlsiteWorkId.tryParse('RJ299717')!,
        title: 't',
        ageCategory: DlsiteAgeCategory.general,
      ),
    );
    expect(draft.nsfw, isFalse);
    expect(draft.score, isNull);
  });

  group('mergeDrafts 接 DLsite', () {
    test('任一源判成人向即 nsfw=true，即使 Bangumi 写的是 false', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: const GalgameMetadataDraft(nsfw: false),
          GalgameMetadataSource.dlsite: const GalgameMetadataDraft(nsfw: true),
        },
      );
      expect(merged.nsfw, isTrue);
    });

    test('都没判成人向时仍按源顺序取第一个非空', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.dlsite: const GalgameMetadataDraft(nsfw: false),
        },
      );
      expect(merged.nsfw, isFalse);
    });

    test('开发商：vndb → bgm → dlsite；只有 DLsite 时用社团名', () {
      expect(
        mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.dlsite: const GalgameMetadataDraft(
            developer: 'サークル',
          ),
        }).developer,
        'サークル',
      );
      expect(
        mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: const GalgameMetadataDraft(developer: 'b'),
          GalgameMetadataSource.dlsite: const GalgameMetadataDraft(
            developer: 'd',
          ),
        }).developer,
        'b',
      );
    });

    test('名称等字段 Bangumi 优先，DLsite 只做回退', () {
      final GalgameMetadataDraft merged =
          mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
            GalgameMetadataSource.bgm: const GalgameMetadataDraft(name: 'bgm'),
            GalgameMetadataSource.dlsite: const GalgameMetadataDraft(
              name: 'dl',
              summary: 'dl-summary',
            ),
          });
      expect(merged.name, 'bgm');
      expect(merged.summary, 'dl-summary');
    });
  });

  group('弹窗 / 批量的认编号', () {
    test('DLsite 作品页 URL 归一成编号（任意分站、尾随内容）', () {
      expect(
        normalizeGalgameScrapeQuery(
          'https://www.dlsite.com/maniax/work/=/product_id/RJ01234567.html',
        ),
        'RJ01234567',
      );
      expect(
        normalizeGalgameScrapeQuery(
          'dlsite.com/pro/work/=/product_id/VJ01000001.html/?locale=ja_JP',
        ),
        'VJ01000001',
      );
      expect(
        normalizeGalgameScrapeQuery('https://www.dlsite.com/maniax/'),
        'https://www.dlsite.com/maniax/',
        reason: '不是作品页原样透传',
      );
    });

    test('预填词：名字里有编号 → 编号；没给预填词时 exe 路径里有编号 → 编号；都没有 → 原词', () {
      expect(
        galgameScrapeInitialQuery(
          _game(name: '[RJ01234567] 測試', exePath: r'C:\g\game.exe'),
          null,
        ),
        'RJ01234567',
      );
      // 缺省预填（显示名）里没编号：回退到 exe 路径认编号。
      expect(
        galgameScrapeInitialQuery(
          _game(name: 'game', exePath: r'D:\Games\RJ299717\game.exe'),
          null,
        ),
        'RJ299717',
      );
      // 显式给的搜索词（详情页编辑框手填）没编号：原样保留，不被 exe 路径的编号覆盖。
      expect(
        galgameScrapeInitialQuery(
          _game(name: 'game', exePath: r'D:\Games\RJ299717\game.exe'),
          '測試ゲーム',
        ),
        '測試ゲーム',
      );
      // 显式词里自带编号：仍只取编号。
      expect(
        galgameScrapeInitialQuery(
          _game(name: 'game', exePath: r'D:\Games\RJ299717\game.exe'),
          '測試 RJ01234567',
        ),
        'RJ01234567',
      );
      expect(
        galgameScrapeInitialQuery(
          _game(name: 'game', exePath: r'C:\Games\Foo\game.exe'),
          '測試ゲーム',
        ),
        '測試ゲーム',
      );
    });

    test('dlsiteWorkIdOfGalgame 先看显示名再看 exe 路径', () {
      expect(
        dlsiteWorkIdOfGalgame(
          _game(name: 'x', exePath: r'D:\RJ299717\start.exe'),
        )?.value,
        'RJ299717',
      );
      expect(
        dlsiteWorkIdOfGalgame(_game(name: 'x', exePath: r'D:\a\start.exe')),
        isNull,
      );
    });
  });
}
