import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/torrent/builtin_video_resource_providers.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/public_video_index_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi/utils.dart';

/// 随应用内置、零配置的视频资源索引器。
///
/// id / 品牌名 / 构造方式的真相源在引擎 `kBuiltinVideoResourceProviderSpecs`（无头
/// 服务端跑订阅与代搜按同一张表注册，客户端搜到的 provider id 在 host 上才对得上）；
/// 这里只再挂一层设置页的 i18n `hint`。`AppModel` 按本表构造 provider，设置页按本表
/// 渲染开关行——加一个内置源改引擎那一处 + 这里补一句 hint，漏 hint 会在启动时 assert。
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

/// 内置视频资源索引器全表（构造序 = 设置页显示序 = 引擎 spec 表序）。
final List<BuiltinVideoResourceSource> kBuiltinVideoResourceSources =
    <BuiltinVideoResourceSource>[
  for (final BuiltinVideoResourceProviderSpec spec
      in kBuiltinVideoResourceProviderSpecs)
    BuiltinVideoResourceSource(
      id: spec.id,
      displayName: spec.displayName,
      hint: _hintFor(spec.id),
      create: spec.create,
    ),
];

/// 覆盖范围说明（惰性取值：`t` 要等 i18n 初始化后才有值）。
String Function() _hintFor(String id) {
  switch (id) {
    case kNyaaResourceProviderId:
      return () => t.video_builtin_nyaa_hint;
    case kApibayResourceProviderId:
      return () => t.video_builtin_apibay_hint;
    case kKnabenResourceProviderId:
      return () => t.video_builtin_knaben_hint;
  }
  throw StateError('内置索引器 $id 缺设置页 hint：引擎 spec 表加了源，这里要补文案');
}
