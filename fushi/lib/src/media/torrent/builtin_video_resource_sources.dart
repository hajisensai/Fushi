import 'package:http/http.dart' as http;

import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/torrent/public_video_index_client.dart';
import 'package:fushi/src/media/torrent/public_video_index_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/utils.dart';

/// 随应用内置、零配置的视频资源索引器。
///
/// 这张表是**唯一真相源**：`AppModel` 按它构造 provider，设置页按它渲染开关行。
/// 之前 provider 在 `AppModel` 里内联 new、设置页另手写一行只读的 Nyaa——加一个
/// 内置源要改两处，漏一处就出现「搜得到但设置里看不见」或反过来。
class BuiltinVideoResourceSource {
  const BuiltinVideoResourceSource({
    required this.id,
    required this.displayName,
    required this.hint,
    required this.create,
  });

  /// provider id：同时是停用清单（`video_resource_disabled_sources`）里的记录名
  /// 和开关行的 widget key，所以必须与 [VideoResourceProvider.id] 逐字相同。
  final String id;

  /// 品牌名，不进 i18n（同设置页 TMDB / Jimaku 的处理）。
  final String displayName;

  /// 覆盖范围说明。**惰性取值**：这张表是顶层 final，而 `t` 要等 i18n 初始化后
  /// 才有值——直接存字符串会在 app 启动前就读到未初始化的翻译。
  final String Function() hint;

  /// 用给定 http client 造出 provider。client 的所有权交给 provider
  /// （`closesClient: true`），与 registry 重建时的关闭时机一致。
  final VideoResourceProvider Function(http.Client client) create;
}

/// 内置视频资源索引器全表（构造序 = 设置页显示序）。
final List<BuiltinVideoResourceSource> kBuiltinVideoResourceSources =
    <BuiltinVideoResourceSource>[
  BuiltinVideoResourceSource(
    id: kNyaaResourceProviderId,
    displayName: 'Nyaa',
    hint: () => t.video_builtin_nyaa_hint,
    create: (http.Client client) => NyaaVideoResourceProvider(
      client: NyaaClient(client: client),
      closesClient: true,
    ),
  ),
  BuiltinVideoResourceSource(
    id: kApibayResourceProviderId,
    displayName: 'apibay',
    hint: () => t.video_builtin_apibay_hint,
    create: (http.Client client) => ApibayVideoResourceProvider(
      client: ApibayClient(client: client),
      closesClient: true,
    ),
  ),
  BuiltinVideoResourceSource(
    id: kKnabenResourceProviderId,
    displayName: 'Knaben',
    hint: () => t.video_builtin_knaben_hint,
    create: (http.Client client) => KnabenVideoResourceProvider(
      client: KnabenClient(client: client),
      closesClient: true,
    ),
  ),
];
