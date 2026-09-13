/// 随包内置、零配置的视频资源索引器**工厂表**（引擎侧真相源）。
///
/// app 的 `kBuiltinVideoResourceSources` 只是在这张表上再挂一层 i18n 的 `hint`
/// （设置页文案），provider id / 品牌名 / 构造方式都以这里为准——无头服务端跑订阅
/// 与代搜时按同一张表注册，客户端搜到的 `nyaa:default` 之类 provider id 在 host 上
/// 才对得上（订阅服务会校验 provider 在场，对不上直接 configuration error）。
library;

import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/public_video_index_client.dart';
import 'package:fushi_engine/media/torrent/public_video_index_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:http/http.dart' as http;

class BuiltinVideoResourceProviderSpec {
  const BuiltinVideoResourceProviderSpec({
    required this.id,
    required this.displayName,
    required this.create,
  });

  /// provider id：同时是停用清单（`video_resource_disabled_sources`）里的记录名，
  /// 必须与 [VideoResourceProvider.id] 逐字相同。
  final String id;

  /// 品牌名，不进 i18n。
  final String displayName;

  /// 用给定 http client 造出 provider；client 所有权交给 provider（`closesClient: true`）。
  final VideoResourceProvider Function(http.Client client) create;
}

/// 全表（构造序 = 设置页显示序）。
final List<BuiltinVideoResourceProviderSpec>
    kBuiltinVideoResourceProviderSpecs = <BuiltinVideoResourceProviderSpec>[
  BuiltinVideoResourceProviderSpec(
    id: kNyaaResourceProviderId,
    displayName: 'Nyaa',
    create: (http.Client client) => NyaaVideoResourceProvider(
      client: NyaaClient(client: client),
      closesClient: true,
    ),
  ),
  BuiltinVideoResourceProviderSpec(
    id: kApibayResourceProviderId,
    displayName: 'apibay',
    create: (http.Client client) => ApibayVideoResourceProvider(
      client: ApibayClient(client: client),
      closesClient: true,
    ),
  ),
  BuiltinVideoResourceProviderSpec(
    id: kKnabenResourceProviderId,
    displayName: 'Knaben',
    create: (http.Client client) => KnabenVideoResourceProvider(
      client: KnabenClient(client: client),
      closesClient: true,
    ),
  ),
];
