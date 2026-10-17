/// `discover search` 契约：参数 → 发现请求、`--json` 形状、部分失败 / 全失败的退出码、
/// 非视频域与用法错误。搜索端口用假实现，不连网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/discover_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

VideoDiscoveryItem _item(String id, String title, {int? year}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'mal',
    mediaId: id,
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
    year: year,
    externalIds: <String, String>{'mal': id},
  ),
  score: 8.5,
  overview: 'ov',
);

void main() {
  late Directory tmp;
  late File configFile;
  late StringBuffer out;
  late StringBuffer err;
  late List<VideoDiscoveryRequest> requests;
  late ProviderBatchResult<VideoDiscoveryPage> next;
  late bool released;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_discover_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    await ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).save(configFile);
    out = StringBuffer();
    err = StringBuffer();
    requests = <VideoDiscoveryRequest>[];
    released = false;
    next = ProviderBatchResult<VideoDiscoveryPage>.success(<VideoDiscoveryPage>[
      VideoDiscoveryPage(items: <VideoDiscoveryItem>[_item('1', 'ぼっち・ざ・ろっく！', year: 2022)], page: 1, hasMore: true),
    ]);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<int> discover(List<String> args) {
    final DiscoverModule module = DiscoverModule(
      out: out,
      err: err,
      portsFactory: (ServerRuntime _) => (
        search: (VideoDiscoveryRequest r) async {
          requests.add(r);
          return next;
        },
        service: null,
        release: () => released = true,
      ),
    );
    final ArgParser parser = ArgParser();
    module.register(parser);
    return module.run(
      'discover',
      parser.parse(<String>['discover', ...args]).command!,
      CliContext(configFile: configFile, verbose: false),
    );
  }

  test('参数 → 请求，--json 形状，端口用完即释放', () async {
    expect(
      await discover(<String>[
        'search',
        'bocchi',
        'the',
        'rock',
        '--category',
        'anime',
        '--year',
        '2022',
        '--page',
        '2',
        '--size',
        '5',
        '--json',
      ]),
      0,
      reason: err.toString(),
    );
    final VideoDiscoveryRequest r = requests.single;
    expect(r.query, 'bocchi the rock');
    expect(r.category, VideoDiscoveryCategory.anime);
    expect(r.year, 2022);
    expect(r.page, 2);
    expect(r.pageSize, 5);
    expect(r.isSearch, isTrue);
    expect(released, isTrue);
    final Map<String, Object?> report = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(report['domain'], 'video');
    expect(report['hasMore'], true);
    final Map<String, Object?> item = (report['items']! as List<Object?>).single! as Map<String, Object?>;
    expect(item['provider'], 'mal');
    expect(item['id'], '1');
    expect(item['year'], 2022);
    expect(item['category'], 'anime');
    expect(item['ids'], <String, Object?>{'mal': '1'});
  });

  test('部分来源失败：照常 0，失败写 stderr', () async {
    next = ProviderBatchResult<VideoDiscoveryPage>(
      items: <VideoDiscoveryPage>[
        VideoDiscoveryPage(items: <VideoDiscoveryItem>[_item('2', 'x')], page: 1, hasMore: false),
      ],
      failures: const <ExternalProviderFailure>[
        ExternalProviderFailure(
          providerId: 'tmdb',
          operation: 'search',
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'no key',
        ),
      ],
      successfulProviderCount: 1,
    );
    expect(await discover(<String>['search', 'x']), 0);
    expect(err.toString(), contains('tmdb'));
    expect(out.toString(), contains('[mal:2] x'));
  });

  test('全部来源失败 = 69', () async {
    next = ProviderBatchResult<VideoDiscoveryPage>.failure(
      const ExternalProviderFailure(
        providerId: 'mal',
        operation: 'search',
        kind: ExternalProviderFailureKind.network,
        message: 'offline',
      ),
    );
    expect(await discover(<String>['search', 'x', '--json']), 69);
    expect(released, isTrue);
  });

  test('非视频域 = 69（发现源在 app 里）', () async {
    expect(await discover(<String>['search', 'x', '--domain', 'manga']), 69);
    expect(requests, isEmpty);
  });

  test('用法错误 = 64', () async {
    expect(await discover(<String>[]), 64);
    expect(await discover(<String>['search']), 64);
    expect(await discover(<String>['search', 'x', '--category', 'ova']), 64);
    expect(await discover(<String>['search', 'x', '--page', '0']), 64);
    expect(await discover(<String>['search', 'x', '--domain', 'music']), 64);
  });

  test('缺配置 = 66', () async {
    await configFile.delete();
    expect(await discover(<String>['search', 'x']), 66);
  });
}
