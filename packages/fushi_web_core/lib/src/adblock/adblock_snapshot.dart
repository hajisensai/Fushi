/// Rust 核心（`AdblockCore`）的状态快照：设置页与 WebView 接线只读它，不另存镜像状态。
///
/// 字段与 `native/fushi_web_core/src/adblock/mod.rs` 的 `snapshot_locked` 一一对应；
/// 每个改状态的命令都会返回新快照。
library;

/// 引擎所处阶段。
enum AdblockEngineStatus {
  /// 还没加载过（或没有订阅任何列表）。
  idle,

  /// 正在同步（下载列表 / 编译 / 恢复缓存）。
  loading,

  /// 引擎就绪。
  ready,

  /// 一份可用列表都没有（离线首装等），下次同步重试。
  failed;

  static AdblockEngineStatus parse(Object? wire) => switch (wire) {
    'loading' => AdblockEngineStatus.loading,
    'ready' => AdblockEngineStatus.ready,
    'failed' => AdblockEngineStatus.failed,
    _ => AdblockEngineStatus.idle,
  };
}

/// 一份列表最近一次是怎么拿到的。
enum AdblockListResult {
  cache,
  downloaded,
  notModified,
  staleCache,
  missing;

  static AdblockListResult? parse(Object? wire) => switch (wire) {
    'cache' => AdblockListResult.cache,
    'downloaded' => AdblockListResult.downloaded,
    'notModified' => AdblockListResult.notModified,
    'staleCache' => AdblockListResult.staleCache,
    'missing' => AdblockListResult.missing,
    _ => null,
  };
}

DateTime? _millis(Object? v) => v is num
    ? DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true)
    : null;

/// 内置目录里的一份过滤列表。
class AdblockCatalogEntry {
  const AdblockCatalogEntry({
    required this.id,
    required this.title,
    required this.url,
    required this.host,
    required this.defaultEnabled,
  });

  factory AdblockCatalogEntry.fromJson(Map<String, Object?> json) =>
      AdblockCatalogEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
        host: json['host'] as String? ?? '',
        defaultEnabled: json['defaultEnabled'] == true,
      );

  /// 稳定 id（落盘文件名、订阅集的键）。
  final String id;

  /// 列表官方名（不翻译）。
  final String title;
  final String url;
  final String host;
  final bool defaultEnabled;
}

/// 一份列表的状态。
class AdblockListState {
  const AdblockListState({
    required this.id,
    required this.title,
    required this.host,
    required this.enabled,
    required this.cached,
    required this.stale,
    required this.ruleCount,
    required this.byteLength,
    this.fetchedAt,
    this.checkedAt,
    this.lastResult,
    this.lastError,
  });

  factory AdblockListState.fromJson(Map<String, Object?> json) =>
      AdblockListState(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        host: json['host'] as String? ?? '',
        enabled: json['enabled'] == true,
        cached: json['cached'] == true,
        stale: json['stale'] == true,
        ruleCount: (json['ruleCount'] as num?)?.toInt() ?? 0,
        byteLength: (json['byteLength'] as num?)?.toInt() ?? 0,
        fetchedAt: _millis(json['fetchedAt']),
        checkedAt: _millis(json['checkedAt']),
        lastResult: AdblockListResult.parse(json['lastResult']),
        lastError: json['lastError'] as String?,
      );

  final String id;
  final String title;
  final String host;

  /// 是否订阅。
  final bool enabled;

  /// 本地有可用缓存。
  final bool cached;

  /// 缓存已过期（或没有缓存）。
  final bool stale;
  final int ruleCount;
  final int byteLength;

  /// 最近一次成功核对（200 / 304）的时刻（UTC）。
  final DateTime? fetchedAt;

  /// 最近一次尝试联网的时刻（UTC）。
  final DateTime? checkedAt;
  final AdblockListResult? lastResult;
  final String? lastError;
}

/// 整体快照。
class AdblockSnapshot {
  const AdblockSnapshot({
    required this.enabled,
    required this.allowlist,
    required this.allowlistHosts,
    required this.status,
    required this.syncing,
    required this.ruleCount,
    required this.fromCache,
    required this.lists,
    this.error,
    this.builtAt,
    this.lastUpdatedAt,
    this.lastSyncOk,
  });

  factory AdblockSnapshot.fromJson(Map<String, Object?> json) {
    final Object? lists = json['lists'];
    final Object? hosts = json['allowlistHosts'];
    return AdblockSnapshot(
      enabled: json['enabled'] == true,
      allowlist: json['allowlist'] as String? ?? '',
      allowlistHosts: hosts is List
          ? hosts.whereType<String>().toList(growable: false)
          : const <String>[],
      status: AdblockEngineStatus.parse(json['status']),
      syncing: json['syncing'] == true,
      ruleCount: (json['ruleCount'] as num?)?.toInt() ?? 0,
      fromCache: json['fromCache'] == true,
      lists: lists is List
          ? lists
                .whereType<Map<String, Object?>>()
                .map(AdblockListState.fromJson)
                .toList(growable: false)
          : const <AdblockListState>[],
      error: json['error'] as String?,
      builtAt: _millis(json['builtAt']),
      lastUpdatedAt: _millis(json['lastUpdatedAt']),
      lastSyncOk: json['lastSyncOk'] as bool?,
    );
  }

  /// 核心还没打开（宿主的数据目录未就绪）时的占位：什么都没开、没有列表。不是从磁盘读的状态。
  static const AdblockSnapshot notOpened = AdblockSnapshot(
    enabled: false,
    allowlist: '',
    allowlistHosts: <String>[],
    status: AdblockEngineStatus.idle,
    syncing: false,
    ruleCount: 0,
    fromCache: false,
    lists: <AdblockListState>[],
  );

  /// 总开关。
  final bool enabled;

  /// 白名单原文（用户输入）。
  final String allowlist;

  /// 白名单解析后的主机名。
  final List<String> allowlistHosts;
  final AdblockEngineStatus status;
  final bool syncing;

  /// 在用列表的规则行数之和（引擎没就绪时 0）。
  final int ruleCount;

  /// 引擎是从磁盘序列化缓存恢复的（没有重编）。
  final bool fromCache;

  /// 目录顺序的全部列表（含未订阅的）。
  final List<AdblockListState> lists;
  final String? error;
  final DateTime? builtAt;

  /// 在用列表里最近一次成功核对的时刻。
  final DateTime? lastUpdatedAt;

  /// 最近一次同步是否成功（「立即更新」= 至少一份列表新取到或确认未变）。
  final bool? lastSyncOk;

  /// 总开关开着且引擎就绪。
  bool get isActive => enabled && status == AdblockEngineStatus.ready;

  bool isListEnabled(String id) =>
      lists.any((AdblockListState l) => l.id == id && l.enabled);
}
