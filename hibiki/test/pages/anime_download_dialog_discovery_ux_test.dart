import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';

import '../helpers/test_platform_services.dart';

/// 番剧下载「发现」流 UX 回归：
/// - Nyaa 搜索网络故障不再吞成「无结果」/统一文案：错误态展示真实异常串 +
///   代理提示 + 「去设置」（用户报告：站点被墙时切分类超时无从定位）。
/// - 选种结果排序（做种数/体积/发布时间，一律降序）。
/// - 手动字幕搜索词默认罗马字（与 Nyaa 查询词同口径），下拉可切日文原名。
/// - 集号输入框宽度 96（72 在界面缩放 >1 时 label 截成「集…」）。

const AniListMedia _kMedia = AniListMedia(
  id: 1,
  romaji: 'Test Anime',
  native: 'テスト・アニメ',
  english: 'The Test Anime',
  episodes: 12,
  seasonYear: 2026,
);

const NyaaTorrent _kTorrent = NyaaTorrent(
  title: '[Group] Test Anime - 01 [1080p]',
  torrentUrl: 'https://nyaa.si/download/1.torrent',
  pageUrl: 'https://nyaa.si/view/1',
  infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  seeders: 100,
  leechers: 1,
  downloads: 1000,
  sizeText: '1.4 GiB',
  sizeBytes: 1503238553,
  categoryId: '1_2',
  trusted: false,
  remake: false,
  pubDate: null,
);

String _rssItem({
  required String title,
  required String hash,
  required int seeders,
  required String size,
}) {
  return '''
  <item>
    <title>$title</title>
    <link>https://nyaa.si/download/$hash.torrent</link>
    <guid>https://nyaa.si/view/$hash</guid>
    <nyaa:infoHash>$hash</nyaa:infoHash>
    <nyaa:seeders>$seeders</nyaa:seeders>
    <nyaa:size>$size</nyaa:size>
  </item>''';
}

final String _kSortRss = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
  <channel>
${_rssItem(title: 'seeders-top', hash: 'a' * 40, seeders: 300, size: '1 GiB')}
${_rssItem(title: 'size-top', hash: 'b' * 40, seeders: 10, size: '10 GiB')}
${_rssItem(title: 'middle', hash: 'c' * 40, seeders: 100, size: '5 GiB')}
  </channel>
</rss>''';

/// 纯内存计划存储（widget 测试不碰真实文件）。
class _MemPlanStore extends AnimeDownloadPlanStore {
  _MemPlanStore() : super(baseDir: Directory('unused-mem-store'));

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async =>
      const <AnimeDownloadPlan>[];

  @override
  Future<void> save(AnimeDownloadPlan plan) async {}

  @override
  Future<void> delete(String id) async {}
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this._httpHandler) : super(testPlatformServices());

  final Future<http.Response> Function(http.Request request) _httpHandler;
  final _MemPlanStore store = _MemPlanStore();

  @override
  String get jimakuApiKey => 'key';

  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
        baseUrl: 'http://127.0.0.1:1',
      );

  @override
  bool get torrentUploadIntroShown => true;

  @override
  AnimeDownloadPlanStore? get animeDownloadPlanStore => store;

  @override
  Future<http.Client> createDownloadHttpClient() async =>
      MockClient(_httpHandler);
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<void> pumpDialog(
    WidgetTester tester,
    _FakeAppModel appModel, {
    NyaaTorrent? torrent,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: AnimeDownloadDialog(
              embedded: true,
              debugInitialMedia: _kMedia,
              debugInitialTorrent: torrent,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('纯函数', () {
    test('compareNyaaTorrents：三键降序，size/date 缺失沉底', () {
      final NyaaTorrent small = _torrentWith(seeders: 5, sizeBytes: 100);
      final NyaaTorrent big = _torrentWith(seeders: 1, sizeBytes: 900);
      final NyaaTorrent noSize = _torrentWith(seeders: 9, sizeBytes: null);
      expect(
          compareNyaaTorrents(TorrentSortKey.seeders, noSize, small) < 0, true);
      expect(compareNyaaTorrents(TorrentSortKey.size, big, small) < 0, true);
      expect(compareNyaaTorrents(TorrentSortKey.size, small, noSize) < 0, true);

      final NyaaTorrent newer =
          _torrentWith(seeders: 1, pubDate: DateTime.utc(2026, 7, 2));
      final NyaaTorrent older =
          _torrentWith(seeders: 1, pubDate: DateTime.utc(2026, 7, 1));
      final NyaaTorrent noDate = _torrentWith(seeders: 1);
      expect(compareNyaaTorrents(TorrentSortKey.date, newer, older) < 0, true);
      expect(compareNyaaTorrents(TorrentSortKey.date, older, noDate) < 0, true);
    });

    test('animeTitleOptions：罗马字优先、去空去重保序', () {
      expect(animeTitleOptions(_kMedia),
          <String>['Test Anime', 'テスト・アニメ', 'The Test Anime']);
      expect(
        animeTitleOptions(
            const AniListMedia(id: 2, romaji: 'Same', native: 'Same')),
        <String>['Same'],
      );
      expect(
        animeTitleOptions(const AniListMedia(id: 3, native: 'ネイティブ')),
        <String>['ネイティブ'],
      );
    });
  });

  testWidgets('Nyaa 搜索网络错误：展示真实异常串 + 代理提示 + 去设置', (WidgetTester tester) async {
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      throw http.ClientException('HandshakeException: 站点被墙', req.url);
    });
    await pumpDialog(tester, appModel);

    // Nyaa 查询词已预填罗马字，直接点搜索。
    await tester.tap(find.byTooltip(t.anime_download_search).first);
    await tester.pumpAndSettle();

    expect(find.text(t.anime_download_search_failed), findsOneWidget);
    expect(find.textContaining('HandshakeException'), findsOneWidget);
    expect(find.text(t.anime_download_search_error_proxy_hint), findsOneWidget);
    expect(find.text(t.download_open_settings), findsOneWidget);
  });

  testWidgets('选种结果排序：默认做种数降序，切「体积」就地重排', (WidgetTester tester) async {
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      return http.Response.bytes(_kSortRss.codeUnits, 200);
    });
    await pumpDialog(tester, appModel);

    await tester.tap(find.byTooltip(t.anime_download_search).first);
    await tester.pumpAndSettle();

    // 只收结果行（任务折叠区表头也是 ListTile，按已知标题过滤）。
    const Set<String> known = <String>{'seeders-top', 'middle', 'size-top'};
    List<String> titles() => tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((ListTile tile) => tile.title)
        .whereType<Text>()
        .map((Text text) => text.data)
        .whereType<String>()
        .where(known.contains)
        .toList();
    expect(titles(), <String>['seeders-top', 'middle', 'size-top']);

    // 打开排序菜单，切换到「体积」。
    await tester
        .tap(find.text('${t.sort_by}: ${t.anime_download_sort_seeders}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.anime_download_sort_size).last);
    await tester.pumpAndSettle();

    expect(titles(), <String>['size-top', 'middle', 'seeders-top']);
    expect(find.text('${t.sort_by}: ${t.anime_download_sort_size}'),
        findsOneWidget);
  });

  testWidgets('确认阶段：字幕搜索词默认罗马字、下拉可切日文原名、集号框宽 96', (WidgetTester tester) async {
    final _FakeAppModel appModel =
        _FakeAppModel((http.Request req) async => http.Response('', 404));
    await pumpDialog(tester, appModel, torrent: _kTorrent);

    final Finder queryField = find.byWidgetPredicate((Widget w) =>
        w is TextField && w.decoration?.labelText == t.video_jimaku_query);
    expect(queryField, findsOneWidget);
    expect(tester.widget<TextField>(queryField).controller!.text, 'Test Anime');

    // 标题候选下拉：切到日文原名。
    await tester.tap(find.byIcon(Icons.arrow_drop_down).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト・アニメ').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(queryField).controller!.text, 'テスト・アニメ');

    // 集号输入框宽度 96（回归：72 在界面缩放 >1 时 label 截成「集…」）。
    final Finder episodeField = find.byWidgetPredicate((Widget w) =>
        w is TextField && w.decoration?.labelText == t.video_jimaku_episode);
    expect(episodeField, findsOneWidget);
    expect(tester.getSize(episodeField).width, 96);
  });
}

NyaaTorrent _torrentWith({
  required int seeders,
  int? sizeBytes,
  DateTime? pubDate,
}) {
  return NyaaTorrent(
    title: 't',
    torrentUrl: '',
    pageUrl: '',
    infoHash: '',
    seeders: seeders,
    leechers: 0,
    downloads: 0,
    sizeText: '',
    sizeBytes: sizeBytes,
    categoryId: '1_0',
    trusted: false,
    remake: false,
    pubDate: pubDate,
  );
}
