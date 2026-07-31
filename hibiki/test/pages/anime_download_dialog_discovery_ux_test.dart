import 'dart:convert';
import 'dart:async';
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
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';

import '../helpers/test_platform_services.dart';

/// 番剧下载「发现」流 UX 回归：
/// - Nyaa 搜索网络故障不再吞成「无结果」/统一文案：错误态展示真实异常串 +
///   代理提示 + 「去设置」（用户报告：站点被墙时切分类超时无从定位）。
/// - 选种结果排序（做种数/体积/发布时间，一律降序）。
/// - 手动字幕搜索词默认罗马字（与 Nyaa 查询词同口径），下拉可切日文原名。
/// - 集号输入框宽度必须放得下 label（BUG-1184：先后写死 72、96，都是在同一个错误
///   里换更大的数字；label 随语言/字号/界面缩放变长，写死多少都会被裁）。

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

/// 纯内存计划存储（widget 测试不碰真实文件）。字幕暂存目录落到临时目录，
/// 避免推送流程往仓库工作区写字幕文件。
class _MemPlanStore extends AnimeDownloadPlanStore {
  _MemPlanStore() : super(baseDir: Directory('unused-mem-store'));

  final Directory tempRoot = Directory.systemTemp.createTempSync(
    'hibiki-subs-test',
  );

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async =>
      const <AnimeDownloadPlan>[];

  /// 推送真正落盘的计划（断言「计划里记了什么」用）。
  final List<AnimeDownloadPlan> saved = <AnimeDownloadPlan>[];

  @override
  Future<bool> save(AnimeDownloadPlan plan) async {
    saved.add(plan);
    return true;
  }

  @override
  Future<void> delete(String id) async {}

  @override
  Directory subsDirFor(String planId) =>
      Directory('${tempRoot.path}${Platform.pathSeparator}$planId');
}

/// 推送必成功的假后端（真 qb 在 widget 测试里连不上，会在 snack 之前就早退）。
class _FakeTorrentBackend implements TorrentBackend {
  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    String? category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
    String? savePath,
  }) async =>
      true;

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => null;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async =>
      const TorrentStorageResult(ok: true);

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async =>
      const TorrentStorageResult(ok: true);

  @override
  void close() {}
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this._httpHandler) : super(testPlatformServices());

  final Future<http.Response> Function(http.Request request) _httpHandler;
  final _MemPlanStore store = _MemPlanStore();

  @override
  TorrentBackend createTorrentBackend(QbConnectionConfig config) =>
      _FakeTorrentBackend();

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
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
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
      ),
    );
    await tester.pumpAndSettle();
  }

  group('纯函数', () {
    test('compareNyaaTorrents：三键降序，size/date 缺失沉底', () {
      final NyaaTorrent small = _torrentWith(seeders: 5, sizeBytes: 100);
      final NyaaTorrent big = _torrentWith(seeders: 1, sizeBytes: 900);
      final NyaaTorrent noSize = _torrentWith(seeders: 9, sizeBytes: null);
      expect(
        compareNyaaTorrents(TorrentSortKey.seeders, noSize, small) < 0,
        true,
      );
      expect(compareNyaaTorrents(TorrentSortKey.size, big, small) < 0, true);
      expect(compareNyaaTorrents(TorrentSortKey.size, small, noSize) < 0, true);

      final NyaaTorrent newer = _torrentWith(
        seeders: 1,
        pubDate: DateTime.utc(2026, 7, 2),
      );
      final NyaaTorrent older = _torrentWith(
        seeders: 1,
        pubDate: DateTime.utc(2026, 7, 1),
      );
      final NyaaTorrent noDate = _torrentWith(seeders: 1);
      expect(compareNyaaTorrents(TorrentSortKey.date, newer, older) < 0, true);
      expect(compareNyaaTorrents(TorrentSortKey.date, older, noDate) < 0, true);
    });

    test('animeTitleOptions：罗马字优先、去空去重保序', () {
      expect(animeTitleOptions(_kMedia), <String>[
        'Test Anime',
        'テスト・アニメ',
        'The Test Anime',
      ]);
      expect(
        animeTitleOptions(
          const AniListMedia(id: 2, romaji: 'Same', native: 'Same'),
        ),
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

  testWidgets('Nyaa 真 0 条：展示实际查询词与筛选；损坏 feed 不伪装成无结果', (
    WidgetTester tester,
  ) async {
    const String emptyRss =
        '<rss><channel><title>valid empty</title></channel></rss>';
    final _FakeAppModel emptyModel = _FakeAppModel(
      (http.Request req) async => http.Response(emptyRss, 200),
    );
    await pumpDialog(tester, emptyModel);
    await tester.tap(find.byTooltip(t.anime_download_search).first);
    await tester.pumpAndSettle();

    expect(find.text(t.anime_download_no_results), findsOneWidget);
    expect(find.textContaining('Query: Test Anime;'), findsOneWidget);
    expect(
      find.textContaining(
        'filters: ${t.anime_download_category_all} · '
        '${t.anime_download_unfiltered}',
      ),
      findsOneWidget,
    );

    // 损坏 RSS 必须落错误态并带真实解析原因，不能再显示「无结果」。
    await tester.pumpWidget(const SizedBox.shrink());
    final _FakeAppModel brokenModel = _FakeAppModel(
      (http.Request req) async => http.Response('not xml <<<', 200),
    );
    await pumpDialog(tester, brokenModel);
    await tester.tap(find.byTooltip(t.anime_download_search).first);
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_search_failed), findsOneWidget);
    expect(find.textContaining('malformedXml'), findsOneWidget);
    expect(find.text(t.anime_download_no_results), findsNothing);
  });

  testWidgets('Nyaa 请求 generation + snapshot：旧请求晚回不覆盖，0条文案不读未提交控件', (
    WidgetTester tester,
  ) async {
    final Completer<http.Response> oldResponse = Completer<http.Response>();
    const String emptyRss =
        '<rss><channel><title>valid empty</title></channel></rss>';
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      if (req.url.queryParameters['q'] == 'old query') {
        return oldResponse.future;
      }
      return http.Response(emptyRss, 200);
    });
    await pumpDialog(tester, appModel);

    final Finder queryField = find.byWidgetPredicate(
      (Widget widget) =>
          widget is TextField &&
          widget.decoration?.labelText == t.anime_download_nyaa_query,
    );
    final Finder searchButton = find.descendant(
      of: queryField,
      matching: find.byTooltip(t.anime_download_search),
    );
    await tester.enterText(queryField, 'old query');
    await tester.tap(searchButton);
    await tester.pump();

    await tester.enterText(queryField, 'new query');
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_no_results), findsOneWidget);
    expect(find.textContaining('Query: new query;'), findsOneWidget);

    // 控件改了但没发请求：0 条说明仍必须绑定上一响应的 snapshot。
    await tester.enterText(queryField, 'unsent current text');
    await tester.pump();
    expect(find.textContaining('Query: new query;'), findsOneWidget);
    expect(find.textContaining('Query: unsent current text;'), findsNothing);

    oldResponse.complete(http.Response(_kSortRss, 200));
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_no_results), findsOneWidget);
    expect(
      find.text('seeders-top'),
      findsNothing,
      reason: '旧 generation 晚回不得覆盖新请求的有效 empty 结果',
    );
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
    await tester.tap(
      find.text('${t.sort_by}: ${t.anime_download_sort_seeders}'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.anime_download_sort_size).last);
    await tester.pumpAndSettle();

    expect(titles(), <String>['size-top', 'middle', 'seeders-top']);
    expect(
      find.text('${t.sort_by}: ${t.anime_download_sort_size}'),
      findsOneWidget,
    );
  });

  testWidgets('确认阶段：字幕搜索词默认罗马字、下拉可切日文原名、集号框放得下 label', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel appModel = _FakeAppModel(
      (http.Request req) async => http.Response('', 404),
    );
    await pumpDialog(tester, appModel, torrent: _kTorrent);

    final Finder queryField = find.byWidgetPredicate(
      (Widget w) =>
          w is TextField && w.decoration?.labelText == t.video_jimaku_query,
    );
    expect(queryField, findsOneWidget);
    expect(tester.widget<TextField>(queryField).controller!.text, 'Test Anime');

    // 标题候选下拉：切到日文原名。
    await tester.tap(find.byIcon(Icons.arrow_drop_down).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト・アニメ').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(queryField).controller!.text, 'テスト・アニメ');

    // BUG-1184：集号框宽度必须放得下 label，且**由 label 的实测宽度决定**。
    //
    // 这里原先断言的是「宽度恰好 96」——而 96 本身就是上一次补丁的产物（更早写死
    // 72，注释写着「72 在界面缩放 >1 时 label 截成『集…』」）。同一个错误换个更大
    // 的数字，label 一变长（中文「集数（可选）」、英文 `Episode (optional)`）照样
    // 被裁，用户在 1920 宽的窗口上截到了「集数···」——跟屏幕宽窄根本无关。
    // 现在断言的是「装得下」这个性质，而不是某个具体数字。
    final Finder episodeField = find.byWidgetPredicate(
      (Widget w) =>
          w is TextField && w.decoration?.labelText == t.video_jimaku_episode,
    );
    expect(episodeField, findsOneWidget);

    final TextPainter labelPainter = TextPainter(
      text: TextSpan(
        text: t.video_jimaku_episode,
        style: Theme.of(tester.element(episodeField)).textTheme.bodyLarge,
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(tester.element(episodeField)),
      maxLines: 1,
    )..layout();
    final double labelWidth = labelPainter.width;
    labelPainter.dispose();

    final double fieldWidth = tester.getSize(episodeField).width;
    expect(
      fieldWidth,
      greaterThan(96.0),
      reason: '不得退回写死的 96（更早是 72）——label 随语言/字号/界面缩放变长，'
          '写死多少都会被裁（BUG-1184）',
    );
    expect(
      fieldWidth,
      greaterThanOrEqualTo(labelWidth),
      reason: '框宽必须由 label 的实测宽度决定，至少放得下 label 本体',
    );
    // 注：本用例跑在对话框真实布局里，拿不到那一行的可用宽度，而宽度上限是行宽的
    // 四成；加之测试字体（Ahem）每字符整字宽、把 label 量成真实字体的两倍多，所以
    // 这里只能断言到「不是常数、装得下 label 本体」。「含内边距完整装下」这条性质
    // 由 test/widgets/narrow_screen_overflow_test.dart 覆盖——那里可以自己给定行宽。
  });

  // BUG-1190：下拉换标题只改输入框文本、不重搜，用户看到的是「番剧名换了、
  // 底下的字幕来源纹丝不动」，会当成功能坏了。选中即搜。
  testWidgets('确认阶段：下拉切标题立即重搜 Jimaku 并刷新字幕来源', (WidgetTester tester) async {
    int searchCalls = 0;
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      final String url = req.url.toString();
      if (url.contains('/entries/search')) {
        searchCalls++;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 7, 'name': 'テスト・アニメ 字幕'},
            ]),
          ),
          200,
        );
      }
      if (url.contains('/files')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{
                'name': 'Test Anime - 01.ja.srt',
                'url': 'https://jimaku.cc/f/1.srt',
              },
            ]),
          ),
          200,
        );
      }
      return http.Response('', 404);
    });
    await pumpDialog(tester, appModel, torrent: _kTorrent);
    // debug 直达确认阶段不自动联网搜；此时还没有任何字幕来源。
    expect(searchCalls, 0);
    expect(find.text(t.anime_download_no_subs), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_drop_down).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト・アニメ').last);
    await tester.pumpAndSettle();

    expect(searchCalls, 1, reason: '选中标题即触发重搜，不必再点放大镜');
    // 字幕来源 chip 换成新搜到的条目，字幕列表给出该单集种子对应的第 1 集。
    expect(find.text('テスト・アニメ 字幕'), findsOneWidget);
    expect(find.text('Test Anime - 01.ja.srt'), findsOneWidget);
    expect(find.text(t.anime_download_no_subs), findsNothing);
  });

  // 用户手选过字幕来源 = 他不认可自动选的首条。换番剧名重搜不得把手选静默冲掉。
  testWidgets('确认阶段：换番剧名重搜后仍保留用户手选的字幕来源条目', (WidgetTester tester) async {
    final List<int> filesForEntry = <int>[];
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      final String url = req.url.toString();
      if (url.contains('/entries/search')) {
        // 两次搜索都返回同样的两个条目（重搜后手选那条依然存在）。
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 11, 'name': 'Auto First Entry'},
              <String, Object>{'id': 22, 'name': 'User Picked Entry'},
            ]),
          ),
          200,
        );
      }
      final RegExpMatch? files = RegExp(
        r'/entries/(\d+)/files',
      ).firstMatch(url);
      if (files != null) {
        filesForEntry.add(int.parse(files.group(1)!));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{
                'name': 'Test Anime - 01.ja.srt',
                'url': 'https://jimaku.cc/f/1.srt',
              },
            ]),
          ),
          200,
        );
      }
      return http.Response('', 404);
    });
    await pumpDialog(tester, appModel, torrent: _kTorrent);

    bool selected(String name) => tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((ChoiceChip chip) => (chip.label as Text).data == name)
        .single
        .selected;

    // 首搜：自动选中首条。
    await tester.tap(find.byTooltip(t.anime_download_search).last);
    await tester.pumpAndSettle();
    expect(selected('Auto First Entry'), isTrue);
    expect(filesForEntry, <int>[11]);

    // 用户手选第二条。
    await tester.tap(find.text('User Picked Entry'));
    await tester.pumpAndSettle();
    expect(selected('User Picked Entry'), isTrue);
    expect(filesForEntry, <int>[11, 22]);

    // 换番剧名 → 触发重搜。手选那条仍在新结果里，必须继续选中它。
    await tester.tap(find.byIcon(Icons.arrow_drop_down).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト・アニメ').last);
    await tester.pumpAndSettle();

    expect(selected('User Picked Entry'), isTrue, reason: '重搜不得把用户手选的条目冲回首条');
    expect(selected('Auto First Entry'), isFalse);
    // 拉的必须是手选条目的文件，不是首条的。
    expect(filesForEntry, <int>[11, 22, 22]);
  });

  // 整季包的字幕集号来自 Jimaku 侧、未与包内视频核对，可能配上错季字幕
  // （S2 包视频 01-12 遇上按绝对集号编号的条目 13-24）。不得显示成确定态。
  testWidgets('确认阶段：整季包字幕标为「集号未核对」，徽标带 ~', (WidgetTester tester) async {
    const NyaaTorrent seasonPack = NyaaTorrent(
      title: '[Grp] Test Anime S1 [BDRip 1080p x265]',
      torrentUrl: '',
      pageUrl: '',
      infoHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      seeders: 10,
      leechers: 0,
      downloads: 0,
      sizeText: '10 GiB',
      sizeBytes: null,
      categoryId: '1_2',
      trusted: false,
      remake: false,
      pubDate: null,
    );
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      final String url = req.url.toString();
      if (url.contains('/entries/search')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 7, 'name': 'Season Entry'},
            ]),
          ),
          200,
        );
      }
      if (url.contains('/files')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              for (int ep = 1; ep <= 3; ep++)
                <String, Object>{
                  'name': 'Test Anime - 0$ep.ja.srt',
                  'url': 'https://jimaku.cc/f/$ep.srt',
                },
            ]),
          ),
          200,
        );
      }
      return http.Response('', 404);
    });
    await pumpDialog(tester, appModel, torrent: seasonPack);
    await tester.tap(find.byTooltip(t.anime_download_search).last);
    await tester.pumpAndSettle();

    expect(find.text('Test Anime - 01.ja.srt'), findsOneWidget);
    expect(
      find.text(t.anime_download_subs_episodes_unverified),
      findsOneWidget,
      reason: '整季包集号未核对，必须明说，不能画成「字幕已配好」',
    );
  });

  // BUG-1206：推送这一刻手上只有 Nyaa 标题，包里到底有哪些文件还不知道，照标题
  // 猜集号会静默配错季。所以字幕**不再在推送时下载**，计划只记「取哪个 Jimaku
  // 条目」，真正的反查放到下载完成后按包内真实文件名做。
  testWidgets('BUG-1206 推送：不预下字幕，计划落 pending 并说明时序', (
    WidgetTester tester,
  ) async {
    final List<String> requested = <String>[];
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      final String url = req.url.toString();
      requested.add(url);
      if (url.contains('/entries/search')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 7, 'name': 'Range Entry'},
            ]),
          ),
          200,
        );
      }
      if (url.contains('/files')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              for (int ep = 1; ep <= 3; ep++)
                <String, Object>{
                  'name': 'Test Anime - 0$ep.ja.srt',
                  'url': 'https://jimaku.cc/f/$ep.srt',
                },
            ]),
          ),
          200,
        );
      }
      if (url.contains('/f/')) return http.Response('sub body', 200);
      return http.Response('', 404);
    });
    // 区间包（01-03）：三集各取 1 条。
    const NyaaTorrent rangePack = NyaaTorrent(
      title: '[Grp] Test Anime 01-03 [1080p]',
      torrentUrl: '',
      pageUrl: '',
      infoHash: 'cccccccccccccccccccccccccccccccccccccccc',
      seeders: 10,
      leechers: 0,
      downloads: 0,
      sizeText: '3 GiB',
      sizeBytes: null,
      categoryId: '1_2',
      trusted: false,
      remake: false,
      pubDate: null,
    );
    await pumpDialog(tester, appModel, torrent: rangePack);
    await tester.tap(find.byTooltip(t.anime_download_search).last);
    await tester.pumpAndSettle();
    expect(find.text('Test Anime - 02.ja.srt'), findsOneWidget);

    // 推送会把字幕真写盘（计划暂存目录），真实 IO 只在 runAsync 里才会完成；
    // 推送期间按钮还是无限旋转的进度指示器，pumpAndSettle 也永远等不到静止。
    await tester.runAsync(() async {
      await tester.tap(find.text(t.anime_download_push));
      for (int i = 0; i < 200; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (find.byType(SnackBar).evaluate().isNotEmpty) break;
      }
    });
    await tester.pump();

    // ① 推送期间一条字幕都没下——这是「配对推迟到 add 之后」的直接证据。
    expect(
      requested.where((String u) => u.contains('/f/')),
      isEmpty,
      reason: '推送时不得再预下字幕：那时还不知道包里有哪些文件',
    );
    // ② 计划记的是**意图**（条目 id + pending），不是结论。
    final AnimeDownloadPlan plan = appModel.store.saved.single;
    expect(plan.jimakuEntryId, 7);
    expect(plan.subtitleStatus, AnimeDownloadPlan.subtitlePending);
    expect(plan.subtitles, isEmpty, reason: '结论要等包内真实文件名，推送时不该有任何已配字幕');
    // ③ 用户得知道字幕还在后头，不能以为字幕功能没了。
    expect(
      find.textContaining(t.anime_download_subs_deferred),
      findsOneWidget,
      reason: '推送成功必须说清字幕的时序',
    );
  });

  // PR#530 补的另一半：条目选择层的季号校验。落位层（按包内真实文件名反查）只能
  // 靠「集号严格相等」挡错配，可自动选中的条目本身就是 S1（编号 1-12）而包是 S2
  // 的 01-12 时集号照样相等 —— 必须在选条目这一层拦。
  testWidgets('季号校验：S1 条目遇上 S2 包不自动选，说明原因；用户手选照旧放行', (
    WidgetTester tester,
  ) async {
    const NyaaTorrent s2Pack = NyaaTorrent(
      title: '[Grp] Test Anime S2 01-03 [1080p]',
      torrentUrl: '',
      pageUrl: '',
      infoHash: 'dddddddddddddddddddddddddddddddddddddddd',
      seeders: 10,
      leechers: 0,
      downloads: 0,
      sizeText: '3 GiB',
      sizeBytes: null,
      categoryId: '1_2',
      trusted: false,
      remake: false,
      pubDate: null,
    );
    expect(s2Pack.season, 2, reason: '前提：种子标题能解析出季号');

    final List<String> requested = <String>[];
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      final String url = req.url.toString();
      requested.add(url);
      if (url.contains('/entries/search')) {
        // 条目名不写季号 = 第一季（Jimaku 的 S1 条目就是这个形状），且没挂
        // anilist_id（文本回退搜出来的条目，正是错季的产地）。
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 7, 'name': 'Wrong Season Entry'},
            ]),
          ),
          200,
        );
      }
      if (url.contains('/files')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              for (int ep = 1; ep <= 3; ep++)
                <String, Object>{
                  'name': 'Test Anime - 0$ep.ja.srt',
                  'url': 'https://jimaku.cc/f/$ep.srt',
                },
            ]),
          ),
          200,
        );
      }
      return http.Response('', 404);
    });
    await pumpDialog(tester, appModel, torrent: s2Pack);
    await tester.tap(find.byTooltip(t.anime_download_search).last);
    await tester.pumpAndSettle();

    // ① 没自动选中 → 一条字幕都没配上，连该条目的文件列表都不去拉。
    expect(
      find.text('Test Anime - 01.ja.srt'),
      findsNothing,
      reason: '错季条目的字幕不该被自动配上',
    );
    expect(
      requested.where((String u) => u.contains('/files')),
      isEmpty,
      reason: '没自动选中就不该拉它的文件',
    );
    // ② 不静默：说清「没有条目对得上第 2 季」。
    expect(
      find.text(t.anime_download_subs_season_mismatch(season: 2)),
      findsOneWidget,
      reason: '不自动选必须给理由，否则用户只看到「无字幕」',
    );
    // ③ 候选条目仍列在 picker 里，用户随时能手选。
    expect(find.text('Wrong Season Entry'), findsOneWidget);

    // ④ 用户手选 → 季号校验不拦：文件照拉，字幕照配，提示行消失。
    await tester.tap(find.text('Wrong Season Entry'));
    await tester.pumpAndSettle();
    expect(
      requested.where((String u) => u.contains('/files')),
      isNotEmpty,
      reason: '手选的条目必须照常加载',
    );
    expect(
      find.text('Test Anime - 01.ja.srt'),
      findsOneWidget,
      reason: '用户可能就是要另一季的字幕，不能拦',
    );
    expect(
      find.text(t.anime_download_subs_season_mismatch(season: 2)),
      findsNothing,
    );
  });

  // 反向：信息缺失不能把功能关掉。两边都拿不到季号时必须维持原有的「自动选首条」。
  testWidgets('季号校验：两边都拿不到 season 时仍照常自动选首条', (WidgetTester tester) async {
    expect(_kTorrent.season, isNull, reason: '前提：种子标题没有季号 token');
    final _FakeAppModel appModel = _FakeAppModel((http.Request req) async {
      final String url = req.url.toString();
      if (url.contains('/entries/search')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 7, 'name': 'No Season Entry'},
            ]),
          ),
          200,
        );
      }
      if (url.contains('/files')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Map<String, Object>>[
              <String, Object>{
                'name': 'Test Anime - 01.ja.srt',
                'url': 'https://jimaku.cc/f/1.srt',
              },
            ]),
          ),
          200,
        );
      }
      return http.Response('', 404);
    });
    await pumpDialog(tester, appModel, torrent: _kTorrent);
    await tester.tap(find.byTooltip(t.anime_download_search).last);
    await tester.pumpAndSettle();

    expect(
      find.text('Test Anime - 01.ja.srt'),
      findsOneWidget,
      reason: '拿不到季号就不校验，维持现状自动选，别因信息缺失把功能关掉',
    );
    expect(
      find.text(t.anime_download_subs_season_mismatch(season: 1)),
      findsNothing,
    );
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
