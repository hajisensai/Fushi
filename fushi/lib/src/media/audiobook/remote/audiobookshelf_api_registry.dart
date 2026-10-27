/// 每台 Audiobookshelf 服务器一个**共享**的协议层实例。
///
/// 为什么必须共享：ABS 的 refresh token 每次刷新都轮换，旧值只有 10 分钟宽限期。
/// 发现页的源、书库里的 ABS 标签页、流式播放、进度同步如果各自 new 一个
/// [AudiobookshelfApi]，它们手里的 refresh token 会互相作废——后刷新的那个拿到 401，
/// 用户被无故登出。所以全 app 对同一台服务器只留一个实例，所有调用方向这里借。
///
/// 借用方**不得** `close()` 借来的实例；生命周期归本注册表。
library;

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart'
    show audiobookshelfSourceIdFor;
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

/// 协议层刷新 / 登录换出新令牌后的落盘口（AppModel 接到偏好）。
typedef AudiobookshelfPersistTokens =
    Future<void> Function(String configId, AudiobookshelfTokens tokens);

class AudiobookshelfApiRegistry {
  AudiobookshelfApiRegistry({
    required AudiobookshelfPersistTokens persistTokens,
    http.Client Function()? clientFactory,
  }) : _persistTokens = persistTokens,
       _clientFactory = clientFactory;

  final AudiobookshelfPersistTokens _persistTokens;
  final http.Client Function()? _clientFactory;
  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// [config] 对应的共享实例；未登录返回 null（并丢弃旧实例）。
  ///
  /// 配置里的令牌与上次所见不同时分两种：是本实例自己刷新后写回偏好的回声 → 忽略
  /// （否则会把更新的令牌回滚成已被轮换掉的旧值）；否则是用户在别处重新登录 →
  /// 采用新令牌。服务器地址变了 = 另一台服务器，重建实例。
  AudiobookshelfApi? apiFor(AudiobookshelfServerConfig config) {
    final AudiobookshelfTokens? configTokens = config.tokens;
    if (!config.isSignedIn || configTokens == null) {
      _drop(config.id);
      return null;
    }
    final _Entry? existing = _entries[config.id];
    if (existing != null && existing.serverUrl == config.serverUrl) {
      if (configTokens != existing.configTokens) {
        existing.configTokens = configTokens;
        if (!existing.emitted.contains(configTokens)) {
          existing.api.adoptTokens(configTokens);
          existing.emitted.clear();
        }
      }
      return existing.api;
    }
    _drop(config.id);
    final _Entry entry = _Entry(
      serverUrl: config.serverUrl,
      configTokens: configTokens,
    );
    entry.api = AudiobookshelfApi(
      serverUrl: config.serverUrl,
      providerId: audiobookshelfSourceIdFor(config.id),
      tokens: configTokens,
      client: _clientFactory?.call(),
      onTokensChanged: (AudiobookshelfTokens tokens) {
        entry.emitted.add(tokens);
        return _persistTokens(config.id, tokens);
      },
    );
    _entries[config.id] = entry;
    return entry.api;
  }

  /// 配置清单变了（增删 / 停用 / 登出）：丢掉不再需要的实例。
  void retainOnly(Iterable<AudiobookshelfServerConfig> configs) {
    final Set<String> keep = <String>{
      for (final AudiobookshelfServerConfig config in configs)
        if (config.enabled && config.isSignedIn) config.id,
    };
    for (final String id in _entries.keys.toList(growable: false)) {
      if (!keep.contains(id)) _drop(id);
    }
  }

  void _drop(String configId) => _entries.remove(configId)?.api.close();

  void close() {
    for (final _Entry entry in _entries.values) {
      entry.api.close();
    }
    _entries.clear();
  }
}

class _Entry {
  _Entry({required this.serverUrl, required this.configTokens});

  final Uri serverUrl;

  /// 上次从配置里看到的令牌，用来判断配置有没有变。
  AudiobookshelfTokens configTokens;

  /// 本实例自己换出过的令牌（登录 / 刷新），用来认出写回偏好的回声。
  final Set<AudiobookshelfTokens> emitted = <AudiobookshelfTokens>{};

  late final AudiobookshelfApi api;
}
