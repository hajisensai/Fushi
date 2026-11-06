/// 库页「发现」视图在没有内置发现源的平台（iOS）上是否仍然出现。
///
/// 2026-10-27 用户拍板：用户自己填地址的服务器（OPDS / AList 站点 /
/// Audiobookshelf）不属于 App Store 受限的「外部发现源」，iOS 上照常浏览与下载到
/// 本机（判据 `userConfiguredServersAvailable`，见 `store_compliance.dart`）。iOS 上
/// 发现源注册表只登记这些用户服务器源（`AppModel.mediaDiscoveryService`），所以
/// 「注册表里有能服务这些媒体域的源」就等价于「用户配了能用的服务器」——不另读
/// 一遍各服务器列表，免得两份判据漂移。
///
/// 只在 `StoreRestrictedCapability.externalDiscovery` 缺席时作为**第二条**入口判据
/// 使用；有内置源的平台仍按原样常显发现视图（空态里引导用户去加源）。
library;

import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

/// 是否为用户自配服务器出「发现」视图：判据可用且注册表里有服务 [kinds] 任一域的源。
bool userServerDiscoverViewAvailable(
  MediaDiscoveryService service,
  Iterable<DiscoveryMediaKind> kinds,
) =>
    userConfiguredServersAvailable &&
    kinds.any((DiscoveryMediaKind kind) => service.sourcesFor(kind).isNotEmpty);
