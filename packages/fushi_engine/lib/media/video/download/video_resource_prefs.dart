/// 资源索引器的两个设备本地偏好（Torznab indexer 清单、RSS 搜索站清单）的
/// **读写单一入口**：app 的 `PreferencesRepository` 与无头服务端的 `ServerPrefs` 都是
/// [PrefStore]，读同一张 `preferences` 表，编解码规则只能有一份。
///
/// 仓库不再内置 BT 搜索站，旧的内置源停用清单（`video_resource_disabled_sources`）
/// 随之退役：每条 RSS 站 / Torznab 配置自己带 `enabled`。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';

/// 多个 Torznab indexer 的配置（JSON 数组；API key 与 endpoint 分栏）。
const String kVideoResourceTorznabConfigPref = 'video_resource_torznab_config';

/// 用户自配的 RSS 搜索站（JSON 数组，元素是 `RssSearchSiteConfig.toJson()`）。
/// 视频资源搜索与发现页（书 / 有声书 / 漫画 / 游戏）共用这一份清单，每个站
/// 自己的 `domains` 决定参与哪些域。
const String kResourceRssSitesPref = 'resource_rss_sites';

/// 解码 Torznab indexer 清单；坏 JSON 交给 [onDecodeError]（app 记错误日志，
/// 服务端记诊断）并按空表处理——一条坏配置不该让整个资源搜索面消失。
List<TorznabIndexerConfig> readTorznabIndexerConfigs(
  PrefStore prefs, {
  void Function(Object error, StackTrace stack)? onDecodeError,
}) {
  final String raw =
      (prefs.getPref(kVideoResourceTorznabConfigPref, defaultValue: '') ?? '')
          .toString();
  if (raw.trim().isEmpty) return const <TorznabIndexerConfig>[];
  try {
    return decodeTorznabIndexerConfigs(jsonDecode(raw));
  } on Object catch (error, stack) {
    onDecodeError?.call(error, stack);
    return const <TorznabIndexerConfig>[];
  }
}

/// 写 Torznab indexer 清单：与 app `PreferencesRepository.setVideoResourceTorznabConfigs`
/// 同一编码（`encodeTorznabIndexerConfigs` 的 JSON 数组，API key 单独一栏）。
Future<void> writeTorznabIndexerConfigs(
  PrefStore prefs,
  Iterable<TorznabIndexerConfig> configs,
) => prefs.setPref(
  kVideoResourceTorznabConfigPref,
  jsonEncode(encodeTorznabIndexerConfigs(configs)),
);

/// 解码 RSS 搜索站清单；坏 JSON 交给 [onDecodeError] 并按空表处理，坏行跳过
/// （见 [decodeRssSearchSiteConfigs]）。
List<RssSearchSiteConfig> readRssSearchSiteConfigs(
  PrefStore prefs, {
  void Function(Object error, StackTrace stack)? onDecodeError,
}) {
  final String raw =
      (prefs.getPref(kResourceRssSitesPref, defaultValue: '') ?? '').toString();
  if (raw.trim().isEmpty) return const <RssSearchSiteConfig>[];
  try {
    return decodeRssSearchSiteConfigs(jsonDecode(raw));
  } on Object catch (error, stack) {
    onDecodeError?.call(error, stack);
    return const <RssSearchSiteConfig>[];
  }
}

/// 写 RSS 搜索站清单（[encodeRssSearchSiteConfigs] 的 JSON 数组）。
Future<void> writeRssSearchSiteConfigs(
  PrefStore prefs,
  Iterable<RssSearchSiteConfig> configs,
) => prefs.setPref(
  kResourceRssSitesPref,
  jsonEncode(encodeRssSearchSiteConfigs(configs)),
);
