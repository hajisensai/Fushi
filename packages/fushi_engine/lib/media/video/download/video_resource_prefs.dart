/// 视频资源索引器的设备本地偏好（Torznab indexer 清单）的**读侧单一入口**
/// （用户 BT 站清单见 `bt_site_config.dart`；旧的内置源停用清单
/// `video_resource_disabled_sources` 已冻结、不再写，只由 `bt_site_legacy_migration.dart`
/// 的一次性升级迁移读取——内置源已不存在）：
/// app 的 `PreferencesRepository` 与无头服务端的 `ServerPrefs` 都是 [PrefStore]，读同一张 `preferences` 表，解码规则只能有一份。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';

/// 多个 Torznab indexer 的配置（JSON 数组；API key 与 endpoint 分栏）。
const String kVideoResourceTorznabConfigPref = 'video_resource_torznab_config';

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
) =>
    prefs.setPref(
      kVideoResourceTorznabConfigPref,
      jsonEncode(encodeTorznabIndexerConfigs(configs)),
    );
