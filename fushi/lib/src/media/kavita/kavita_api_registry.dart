/// 每台 Kavita 服务器一个共享协议层实例（连接复用 + JWT 复用）。
///
/// 与 ABS 的注册表不同，这里没有令牌轮换的共享实例硬约束（JWT 过期用 API key
/// 重换即可），复用只是为了省 TLS 握手与重复鉴权。地址 / key 变了就换新实例。
///
/// 纯 Dart 容器，不依赖 Flutter / AppModel，方便单测与多处借用。
library;

import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';

class KavitaApiRegistry {
  KavitaApiRegistry();

  /// 进程内共享实例。设置页保存配置时调 [retainOnly] 收敛。
  static final KavitaApiRegistry instance = KavitaApiRegistry();

  final Map<String, ({KavitaServerConfig config, KavitaApi api})> _entries =
      <String, ({KavitaServerConfig config, KavitaApi api})>{};

  /// 取（或建）[config] 对应的协议层。连接参数变了会关掉旧实例换新。
  KavitaApi apiFor(KavitaServerConfig config) {
    final ({KavitaServerConfig config, KavitaApi api})? existing =
        _entries[config.id];
    if (existing != null && existing.config.sameConnectionAs(config)) {
      return existing.api;
    }
    existing?.api.close();
    final KavitaApi api = config.createApi();
    _entries[config.id] = (config: config, api: api);
    return api;
  }

  /// 只保留 [configs] 里仍存在的服务器的实例，其余关闭（用户删了服务器）。
  void retainOnly(Iterable<KavitaServerConfig> configs) {
    final Set<String> keep = <String>{
      for (final KavitaServerConfig c in configs) c.id,
    };
    final List<String> drop = <String>[
      for (final String id in _entries.keys)
        if (!keep.contains(id)) id,
    ];
    for (final String id in drop) {
      _entries.remove(id)?.api.close();
    }
  }

  void closeAll() {
    for (final ({KavitaServerConfig config, KavitaApi api}) e
        in _entries.values) {
      e.api.close();
    }
    _entries.clear();
  }

  int get length => _entries.length;
}
