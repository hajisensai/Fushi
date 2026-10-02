import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_download_counts.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';

import 'fake_lnreader_runtime.dart';

/// 小说插件下载量（jsDelivr 文件统计）：地址映射、解析、翻页与「缺席算 0 /
/// 拉不全记无数据」的口径，以及 manager 刷新后回填目录。
void main() {
  group('jsDelivrFileForPluginUrl', () {
    test('官方仓库的 raw.githubusercontent 地址（方括号解码成字面量）', () {
      final LnReaderCdnFile? file = jsDelivrFileForPluginUrl(
        'https://raw.githubusercontent.com/lnreader/lnreader-plugins/plugins/'
        'v3.0.0/.js/src/plugins/english/AllNovelFull%5Breadnovelfull%5D.js',
      );
      expect(file, isNotNull);
      expect(file!.packageKey, 'lnreader/lnreader-plugins@plugins');
      expect(
        file.path,
        '/v3.0.0/.js/src/plugins/english/AllNovelFull[readnovelfull].js',
      );
      expect(
        file.statsUri(page: 2).toString(),
        'https://data.jsdelivr.com/v1/stats/packages/gh/lnreader/'
        'lnreader-plugins@plugins/files?period=quarter&limit=100&page=2',
      );
    });

    test('owner / repo 大小写不同的地址归到同一个包', () {
      expect(
        jsDelivrFileForPluginUrl(
          'https://raw.githubusercontent.com/LNReader/LNReader-Plugins/plugins/a.js',
        )!.packageKey,
        jsDelivrFileForPluginUrl(
          'https://raw.githubusercontent.com/lnreader/lnreader-plugins/plugins/b.js',
        )!.packageKey,
      );
    });

    test('refs/heads 写法、github.com/raw、jsDelivr 直链都认', () {
      final LnReaderCdnFile heads = jsDelivrFileForPluginUrl(
        'https://raw.githubusercontent.com/o/r/refs/heads/main/src/a.js',
      )!;
      expect(heads.ref, 'main');
      expect(heads.path, '/src/a.js');
      final LnReaderCdnFile raw = jsDelivrFileForPluginUrl(
        'https://github.com/o/r/raw/dev/x/b.js',
      )!;
      expect(raw.ref, 'dev');
      expect(raw.path, '/x/b.js');
      final LnReaderCdnFile cdn = jsDelivrFileForPluginUrl(
        'https://cdn.jsdelivr.net/gh/o/r@v2/c.js',
      )!;
      expect(cdn.repo, 'r');
      expect(cdn.ref, 'v2');
      expect(cdn.path, '/c.js');
    });

    test('自建托管 / 残缺地址 / 没有 ref 的 jsDelivr 地址判无数据', () {
      expect(jsDelivrFileForPluginUrl('https://my.site/plugins/a.js'), isNull);
      expect(
        jsDelivrFileForPluginUrl('https://raw.githubusercontent.com/o/r/a.js'),
        isNull,
      );
      expect(
        jsDelivrFileForPluginUrl('https://cdn.jsdelivr.net/gh/o/r/a.js'),
        isNull,
      );
      expect(jsDelivrFileForPluginUrl('not a url'), isNull);
    });
  });

  test('parseJsDelivrFileHits：跳过坏条目但原始条数照实计；非数组抛', () {
    final JsDelivrStatsPage page = parseJsDelivrFileHits(
      jsonEncode(<Object?>[
        <String, Object?>{
          'name': '/a.js',
          'hits': <String, Object?>{'total': 12},
        },
        <String, Object?>{'name': '/b.js'},
        'junk',
      ]),
    );
    expect(page.hits, <String, int>{'/a.js': 12});
    expect(page.entries, 3);
    expect(() => parseJsDelivrFileHits('{}'), throwsFormatException);
  });

  group('LnReaderDownloadCountsClient', () {
    late HttpServer server;
    late String base;

    /// 包名（owner）→ 页号 → 该页条目。没登记的包回 500。
    late Map<String, Map<int, List<Map<String, Object?>>>> pages;
    late List<String> requested;

    setUp(() async {
      pages = <String, Map<int, List<Map<String, Object?>>>>{};
      requested = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((HttpRequest request) async {
        final String owner = request.uri.pathSegments.first;
        final int page = int.parse(request.uri.queryParameters['page']!);
        requested.add('$owner#$page');
        final List<Map<String, Object?>>? body = pages[owner]?[page];
        if (body == null && pages.containsKey(owner)) {
          request.response.write('[]');
        } else if (body == null) {
          request.response.statusCode = HttpStatus.internalServerError;
        } else {
          request.response.write(jsonEncode(body));
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    LnReaderDownloadCountsClient client() => LnReaderDownloadCountsClient(
      httpClientFactory: HttpClient.new,
      statsUri: (LnReaderCdnFile package, int page) =>
          Uri.parse('$base/${package.owner}/files?page=$page'),
    );

    Map<String, Object?> hit(String path, int total) => <String, Object?>{
      'name': path,
      'hits': <String, Object?>{'total': total},
    };

    String url(String owner, String file) =>
        'https://raw.githubusercontent.com/$owner/repo/main/$file';

    test('整包翻页拉完：命中的给次数，统计里缺席的算 0', () async {
      pages['good'] = <int, List<Map<String, Object?>>>{
        // 满页（100 条）才翻下一页。
        1: <Map<String, Object?>>[
          hit('/hot.js', 300),
          for (int i = 0; i < 99; i++) hit('/filler$i.js', 1),
        ],
        2: <Map<String, Object?>>[hit('/warm.js', 7)],
      };
      final Map<String, int> counts = await client().fetch(<String>[
        url('good', 'hot.js'),
        url('good', 'warm.js'),
        url('good', 'cold.js'),
        'https://self.hosted/plugin.js',
      ]);
      expect(counts, <String, int>{
        url('good', 'hot.js'): 300,
        url('good', 'warm.js'): 7,
        url('good', 'cold.js'): 0,
      });
      expect(requested, <String>['good#1', 'good#2']);
    });

    test('某个包拉失败：整组无数据（不拿半份名单冒充 0），不影响别的包', () async {
      pages['good'] = <int, List<Map<String, Object?>>>{
        1: <Map<String, Object?>>[hit('/a.js', 5)],
      };
      final Map<String, int> counts = await client().fetch(<String>[
        url('down', 'x.js'),
        url('good', 'a.js'),
      ]);
      expect(counts, <String, int>{url('good', 'a.js'): 5});
    });

    test('翻到页数上限仍是满页：名单不完整，整组无数据', () async {
      pages['big'] = <int, List<Map<String, Object?>>>{
        for (int p = 1; p <= 2; p++)
          p: <Map<String, Object?>>[
            for (int i = 0; i < 100; i++) hit('/p$p-$i.js', 1),
          ],
      };
      final LnReaderDownloadCountsClient capped = LnReaderDownloadCountsClient(
        httpClientFactory: HttpClient.new,
        maxPagesPerPackage: 2,
        statsUri: (LnReaderCdnFile package, int page) =>
            Uri.parse('$base/${package.owner}/files?page=$page'),
      );
      expect(await capped.fetch(<String>[url('big', 'p1-0.js')]), isEmpty);
    });
  });

  test('manager：目录刷新后回填下载量；不开开关就不拉', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'lnreader_counts_manager',
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() async {
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final String base = 'http://127.0.0.1:${server.port}';
    const String pluginUrl =
        'https://raw.githubusercontent.com/lnreader/lnreader-plugins/plugins/a.js';
    int statsRequests = 0;
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/index.json') {
        request.response.write(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'a',
              'name': 'A',
              'site': 'https://a.example/',
              'lang': 'English',
              'version': '1.0.0',
              'url': pluginUrl,
              'iconUrl': '',
            },
          ]),
        );
      } else {
        statsRequests++;
        request.response.write(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'name': '/a.js',
              'hits': <String, Object?>{'total': 42},
            },
          ]),
        );
      }
      await request.response.close();
    });
    LnReaderManager build({required bool fetch}) => LnReaderManager(
      rootDirectory: root,
      runtime: FakeLnReaderRuntime(),
      httpClientFactory: HttpClient.new,
      builtinStoreUrl: '$base/index.json',
      fetchDownloadCounts: fetch,
      downloadCountsClient: LnReaderDownloadCountsClient(
        httpClientFactory: HttpClient.new,
        statsUri: (LnReaderCdnFile package, int page) =>
            Uri.parse('$base/stats?page=$page'),
      ),
    );

    final LnReaderManager off = build(fetch: false);
    addTearDown(off.dispose);
    await off.initialise();
    await off.refreshStores();
    expect(off.available.single.downloadCount, isNull);
    expect(statsRequests, 0, reason: '单测 / 未开开关的 manager 不碰统计接口');

    final LnReaderManager on = build(fetch: true);
    addTearDown(on.dispose);
    await on.initialise();
    await on.refreshStores();
    await on.refreshDownloadCounts();
    final LnReaderRepoPlugin plugin = on.available.single;
    expect(plugin.downloadCount, 42);
    // 已有数据的地址再刷新不重拉。
    await on.refreshStores();
    await on.refreshDownloadCounts();
    expect(statsRequests, 1);
    expect(on.available.single.downloadCount, 42);
  });
}
