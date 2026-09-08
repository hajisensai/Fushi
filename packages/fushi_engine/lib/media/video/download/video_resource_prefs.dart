/// 视频资源索引器的两个设备本地偏好（Torznab indexer 清单、内置源停用清单）的
/// **读侧单一入口**：app 的 `PreferencesRepository` 与无头服务端的 `ServerPrefs` 都是
/// [PrefStore]，读同一张 `preferences` 表，解码规则只能有一份。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';

/// 多个 Torznab indexer 的配置（JSON 数组；API key 与 endpoint 分栏）。
const String kVideoResourceTorznabConfigPref = 'video_resource_torznab_config';

/// 停用的**内置**视频资源索引器 id，逗号分隔。
const String kVideoResourceDisabledSourcesPref =
    'video_resource_disabled_sources';

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

/// 停用清单 → id 集合（逗号分隔、去空白、丢空项）。
Set<String> readVideoResourceDisabledSourceIds(PrefStore prefs) {
  final String raw =
      (prefs.getPref(kVideoResourceDisabledSourcesPref, defaultValue: '') ?? '')
          .toString();
  return <String>{
    for (final String id in raw.split(','))
      if (id.trim().isNotEmpty) id.trim(),
  };
}
