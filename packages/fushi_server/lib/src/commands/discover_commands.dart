/// `fushi_server discover search <query>`：在线发现搜索（只读，不入库）。
///
/// 只有视频域：引擎里的 `VideoDiscoveryService`（TMDB / MAL / AniList 聚合，装配与
/// 服务端 AI 助手同一个 `productionServerDiscovery`）。书 / 漫画 / 游戏的发现源
/// （Nyaa / OPDS / AList / shinnku / mokuro.moe 等）住在 `fushi/` 的
/// `media_discovery_service.dart`，无头服务端装不了，所以 `--domain` 只接受 `video`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_server/src/assistant_host.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/server_runtime.dart';

const int _exitOk = 0;
const int _exitUsage = 64;
const int _exitUnavailable = 69;

/// 一次搜索：返回聚合结果（结束后由调用方释放）。
typedef DiscoverySearch = Future<ProviderBatchResult<VideoDiscoveryPage>> Function(VideoDiscoveryRequest request);

/// 测试注入点：按运行时造搜索端口。
typedef DiscoveryPortsFactory = ServerDiscoveryPorts Function(ServerRuntime rt);

/// 一条结果 → JSON。
Map<String, Object?> discoveryItemToJson(VideoDiscoveryItem item) {
  final VideoMediaReference r = item.reference;
  return <String, Object?>{
    'provider': r.providerId,
    'id': r.mediaId,
    'title': r.title,
    'originalTitle': r.originalTitle,
    'year': r.year,
    'category': r.discoveryCategory.name,
    'mediaKind': r.mediaKind.name,
    'score': item.score,
    'releaseDate': item.releaseDate,
    'genres': item.genres,
    'overview': item.overview,
    'cover': item.posterUrl,
    'ids': r.externalIds,
  };
}

/// 聚合结果 → 报告。
Map<String, Object?> buildDiscoveryReport(
  String query,
  VideoDiscoveryRequest request,
  ProviderBatchResult<VideoDiscoveryPage> result,
) {
  final List<VideoDiscoveryItem> items = <VideoDiscoveryItem>[
    for (final VideoDiscoveryPage page in result.items) ...page.items,
  ];
  return <String, Object?>{
    'query': query,
    'domain': 'video',
    'category': request.category?.name,
    'page': request.page,
    'hasMore': result.items.any((VideoDiscoveryPage p) => p.hasMore),
    'successfulProviders': result.successfulProviderCount,
    'failures': <Object?>[
      for (final ExternalProviderFailure f in result.failures)
        <String, Object?>{'provider': f.providerId, 'kind': f.kind.name, 'message': f.message},
    ],
    'items': <Object?>[for (final VideoDiscoveryItem i in items) discoveryItemToJson(i)],
  };
}

class DiscoverModule extends CliModule {
  const DiscoverModule({this.out, this.err, this.portsFactory});

  final StringSink? out;
  final StringSink? err;
  final DiscoveryPortsFactory? portsFactory;

  @override
  List<String> get commands => const <String>['discover'];

  @override
  void register(ArgParser parser) {
    parser.addCommand('discover').addCommand('search')
      ..addOption('domain', help: '发现域（服务端只有 video）', defaultsTo: 'video')
      ..addOption('category', help: 'movie | tv | anime（缺省不限）')
      ..addOption('year', help: '年份过滤')
      ..addOption('page', help: '页码（从 1 起）', defaultsTo: '1')
      ..addOption('size', help: '每页条数', defaultsTo: '20')
      ..addOption('locale', help: '资料语言（缺省读配置 metadata_locale / 偏好）')
      ..addFlag('json', negatable: false, help: '输出 JSON');
  }

  @override
  String get usage => '''
discover search <query> [--category movie|tv|anime] [--year Y] [--page N] [--size N] [--json]
    在线发现搜索（TMDB / MAL / AniList 聚合，只读）。只支持 --domain video：书 / 漫画 /
    游戏的发现源在桌面 app 里，服务端没有。TMDB 需要配置 tmdb_api_key。''';

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final ArgResults? sub = command.command;
    if (sub == null || sub.name != 'search' || sub.rest.isEmpty || sub.rest.join(' ').trim().isEmpty) {
      e.writeln('用法: discover search <query> [--category movie|tv|anime] [--json]');
      return _exitUsage;
    }
    final String domain = sub['domain'] as String;
    if (domain != 'video') {
      e.writeln('服务端只有视频发现（--domain video）；$domain 域的发现源在桌面 app 里');
      return domain == 'book' || domain == 'manga' || domain == 'game' ? _exitUnavailable : _exitUsage;
    }
    VideoDiscoveryCategory? category;
    final String? rawCategory = sub['category'] as String?;
    if (rawCategory != null) {
      category = VideoDiscoveryCategory.values.where((VideoDiscoveryCategory c) => c.name == rawCategory).firstOrNull;
      if (category == null) {
        e.writeln('--category 只接受 movie / tv / anime');
        return _exitUsage;
      }
    }
    final int? page = int.tryParse(sub['page'] as String);
    final int? size = int.tryParse(sub['size'] as String);
    final String? rawYear = sub['year'] as String?;
    final int? year = rawYear == null ? null : int.tryParse(rawYear);
    if (page == null || page < 1 || size == null || size < 1 || size > 100 || (rawYear != null && year == null)) {
      e.writeln('--page 需 ≥1、--size 需 1..100、--year 需整数');
      return _exitUsage;
    }
    final String query = sub.rest.join(' ').trim();
    final VideoDiscoveryRequest request = VideoDiscoveryRequest(
      query: query,
      category: category,
      page: page,
      pageSize: size,
      sort: VideoDiscoverySort.relevance,
      year: year,
    );
    final String? locale = sub['locale'] as String?;
    return ctx.withRuntime((ServerRuntime rt) async {
      final ServerDiscoveryPorts ports =
          (portsFactory ??
          (ServerRuntime r) => productionServerDiscovery(prefs: r.prefs, config: r.config, locale: locale ?? ''))(rt);
      try {
        final ProviderBatchResult<VideoDiscoveryPage> result = await ports.search(request);
        final Map<String, Object?> report = buildDiscoveryReport(query, request, result);
        for (final ExternalProviderFailure f in result.failures) {
          e.writeln('来源 ${f.providerId} 失败（${f.kind.name}）: ${f.message}');
        }
        if (sub['json'] as bool) {
          o.writeln(const JsonEncoder.withIndent('  ').convert(report));
        } else {
          final List<Object?> items = report['items']! as List<Object?>;
          if (items.isEmpty) o.writeln('（无结果）');
          for (final Object? row in items) {
            final Map<String, Object?> i = row! as Map<String, Object?>;
            final Object? year = i['year'];
            o.writeln('[${i['provider']}:${i['id']}] ${i['title']}${year == null ? '' : ' ($year)'}  ${i['category']}');
          }
        }
        // 所有来源都失败（断网 / 全被限流）才算依赖不可用；部分失败照常出结果。
        return result.isTotalFailure ? _exitUnavailable : _exitOk;
      } finally {
        ports.release();
      }
    });
  }
}
