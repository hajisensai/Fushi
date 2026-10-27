import 'package:flutter/widgets.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart' show FushiClientUrl;
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/download_save_root.dart';
import 'package:path/path.dart' as p;

/// 下载设置（`TorrentSettingsSection` 的 common / connection / trackers /
/// advanced 四个 scope，正文自绘 widget）在控制通道上的条目。
///
/// 读写全部走页面同一组顶层函数（`currentTorrentConfig` / `updateTorrentConfig` /
/// `probeTorrentConnection` / `refreshTorrentTrackerSubscription` /
/// `loadDownloadExecutionHostUrls`）与 `AppModel` 的下载目录方法；行的可见性与
/// 页面渲染同一套判据（后端是内置引擎还是外接 qB、上传 / 反吸血开关）。
///
/// id 前缀 [kCtlDownloadsIdPrefix]：页面里的 `downloads.*` 是设置搜索的 reveal
/// 目标，不能重复。
const String kCtlDownloadsIdPrefix = 'downloads.cli.';

String _id(String name) => '$kCtlDownloadsIdPrefix$name';

AppModel _app(SettingsContext c) => c.appModel;

QbConnectionConfig _cfg(SettingsContext c) => currentTorrentConfig(_app(c));

Future<void> _commit(
  SettingsContext c,
  QbConnectionConfig Function(QbConnectionConfig c) mutate,
) => updateTorrentConfig(_app(c), mutate);

String _backend(SettingsContext c) =>
    _cfg(c).resolveBackend(embeddedSupported: _app(c).supportsEmbeddedTorrent);

bool _embedded(SettingsContext c) =>
    _backend(c) == QbConnectionConfig.backendEmbedded;

bool _qb(SettingsContext c) =>
    _backend(c) == QbConnectionConfig.backendQbittorrent;

bool _pageVisible(SettingsContext c) => isSettingsDestinationVisible(
  SettingsDestinationId.downloads,
  c.appModel.moduleVisibility,
);

/// 全部下载设置条目，按页面 scope 分页。
List<CtlBodyPage> buildCtlDownloadsBodyPages() => <CtlBodyPage>[
  _commonPage(),
  _connectionPage(),
  _trackersPage(),
  _advancedPage(),
];

// ── 页面 ────────────────────────────────────────────────────────────────────

CtlBodyPage _commonPage() => CtlBodyPage(
  breadcrumb: t.nav_downloads,
  visible: _pageVisible,
  items: <SettingsItem>[
    SettingsCustomItem(
      id: _id('execution_host'),
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.download_execution_host_title,
      cliValue: SettingsCliValue(
        read: (SettingsContext c) =>
            _app(c).prefsRepo.downloadExecutionHostUrl.isEmpty
            ? 'local'
            : _app(c).prefsRepo.downloadExecutionHostUrl,
        write: _writeExecutionHost,
        help:
            'local = 本机；或已配对 host 的地址（候选见 `config run downloads.cli.execution_host_candidates`）',
      ),
    ),
    _action(
      id: 'execution_host_candidates',
      title: '${t.download_execution_host_title} · candidates',
      cli: const SettingsCliAction(run: _executionHostCandidates),
    ),
    SettingsSegmentedItem<String>(
      id: _id('backend'),
      title: t.download_settings,
      visible: (SettingsContext c) => _app(c).supportsEmbeddedTorrent,
      options: <SettingsSegmentOption<String>>[
        SettingsSegmentOption<String>(
          value: QbConnectionConfig.backendEmbedded,
          label: t.video_setting_torrent_backend_embedded,
        ),
        SettingsSegmentOption<String>(
          value: QbConnectionConfig.backendQbittorrent,
          label: t.video_setting_torrent_backend_qb,
        ),
      ],
      selected: _backend,
      onChanged: (SettingsContext c, String value) =>
          _commit(c, (QbConnectionConfig q) => q.copyWith(backend: value)),
    ),
    SettingsCustomItem(
      id: _id('save_root'),
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.download_save_root_title,
      visible: _embedded,
      cliValue: SettingsCliValue(
        read: (SettingsContext c) => _app(c).downloadSaveRoot,
        write: _writeSaveRoot,
        help:
            '下载目录绝对路径（只影响之后新增的任务）；恢复默认用 config run downloads.cli.save_root_reset',
      ),
    ),
    SettingsActionItem(
      id: _id('save_root_reset'),
      title: t.download_save_root_reset,
      visible: _embedded,
      onTap: (SettingsContext c) => _app(c).resetDownloadSaveRoot(),
      cli: const SettingsCliAction.tap(),
    ),
    SettingsStatusItem(
      id: _id('save_root_issue'),
      title: t.download_save_root_fallback_warning,
      visible: _embedded,
      subtitleBuilder: (SettingsContext c) {
        final DownloadSaveRootIssue? issue = _app(c).downloadSaveRootIssue;
        if (issue == null) return '';
        return '${_app(c).downloadSaveRootRejectedPath ?? ''} — '
            '${downloadSaveRootIssueMessage(issue)}';
      },
    ),
    _int(
      id: 'download_limit_kbps',
      title: t.video_setting_torrent_download_limit,
      subtitle: t.video_setting_torrent_limit_hint,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.downloadLimitKbps,
      write: (QbConnectionConfig q, int v) => q.copyWith(downloadLimitKbps: v),
      suffix: 'KiB/s',
    ),
    _switch(
      id: 'limit_lan',
      title: t.video_setting_torrent_limit_lan,
      subtitle: t.video_setting_torrent_limit_lan_hint,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.limitLocalPeers,
      write: (QbConnectionConfig q, bool v) => q.copyWith(limitLocalPeers: v),
    ),
    _switch(
      id: 'upload_enabled',
      title: t.video_setting_torrent_upload_enabled,
      subtitle: t.video_setting_torrent_upload_enabled_hint,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.uploadEnabled,
      write: (QbConnectionConfig q, bool v) => q.copyWith(uploadEnabled: v),
    ),
    _int(
      id: 'upload_limit_kbps',
      title: t.video_setting_torrent_upload_limit,
      subtitle: t.video_setting_torrent_limit_hint,
      visible: _uploadVisible,
      read: (QbConnectionConfig q) => q.uploadLimitKbps,
      write: (QbConnectionConfig q, int v) => q.copyWith(uploadLimitKbps: v),
      suffix: 'KiB/s',
    ),
    _int(
      id: 'seed_time_limit_minutes',
      title: t.video_setting_torrent_seed_time_limit,
      subtitle: t.video_setting_torrent_seed_time_hint,
      visible: _uploadVisible,
      read: (QbConnectionConfig q) => q.seedTimeLimitMinutes,
      write: (QbConnectionConfig q, int v) =>
          q.copyWith(seedTimeLimitMinutes: v),
    ),
    SettingsNumberItem(
      id: _id('seed_ratio_limit'),
      title: t.video_setting_torrent_seed_ratio_limit,
      subtitle: t.video_setting_torrent_seed_ratio_lifetime_hint,
      visible: _uploadVisible,
      min: 0,
      value: (SettingsContext c) => _cfg(c).seedRatioLimit,
      onChanged: (SettingsContext c, num v) => _commit(
        c,
        (QbConnectionConfig q) =>
            q.copyWith(seedRatioLimit: v.isFinite && v > 0 ? v.toDouble() : 0),
      ),
    ),
  ],
);

CtlBodyPage _connectionPage() => CtlBodyPage(
  breadcrumb: '${t.nav_downloads} › ${t.video_setting_torrent_backend_qb}',
  visible: _pageVisible,
  items: <SettingsItem>[
    _text(
      id: 'qb_url',
      title: t.video_setting_qb_url,
      subtitle: t.video_setting_qb_url_hint,
      read: (QbConnectionConfig q) => q.baseUrl,
      write: (QbConnectionConfig q, String v) => q.copyWith(baseUrl: v.trim()),
    ),
    _text(
      id: 'qb_username',
      title: t.video_setting_qb_username,
      read: (QbConnectionConfig q) => q.username,
      write: (QbConnectionConfig q, String v) => q.copyWith(username: v.trim()),
    ),
    _text(
      id: 'qb_password',
      title: t.video_setting_qb_password,
      secret: true,
      read: (QbConnectionConfig q) => q.password,
      write: (QbConnectionConfig q, String v) => q.copyWith(password: v),
    ),
    _action(
      id: 'test_connection',
      title: t.download_test_connection,
      visible: _qb,
      cli: const SettingsCliAction(run: _testConnection),
    ),
  ],
);

CtlBodyPage _trackersPage() => CtlBodyPage(
  breadcrumb: '${t.nav_downloads} › ${t.download_tracker_section}',
  visible: _pageVisible,
  items: <SettingsItem>[
    _switch(
      id: 'tracker_auto_add',
      title: t.download_tracker_auto_add,
      subtitle: t.download_tracker_auto_add_hint,
      read: (QbConnectionConfig q) => q.autoAddTrackerSubscription,
      write: (QbConnectionConfig q, bool v) =>
          q.copyWith(autoAddTrackerSubscription: v),
    ),
    SettingsTextItem(
      id: _id('tracker_url'),
      title: t.download_tracker_url,
      value: (SettingsContext c) => _cfg(c).trackerSubscriptionUrl,
      onChanged: (SettingsContext c, String v) => _commit(
        c,
        (QbConnectionConfig q) => q.copyWith(trackerSubscriptionUrl: v.trim()),
      ),
    ),
    _action(
      id: 'tracker_refresh',
      title: t.download_tracker_refresh,
      cli: const SettingsCliAction(
        run: _refreshTrackers,
        params: <SettingsCliParam>[
          SettingsCliParam(
            'url',
            help: 'tracker 订阅地址；省略 = 用当前配置的地址（给了会先写入配置）',
            required: false,
          ),
        ],
      ),
    ),
  ],
);

CtlBodyPage _advancedPage() => CtlBodyPage(
  breadcrumb: '${t.nav_downloads} › ${t.settings_downloads_advanced_title}',
  visible: _pageVisible,
  items: <SettingsItem>[
    SettingsTextItem(
      id: _id('category'),
      title: t.video_setting_qb_category,
      subtitle: t.video_setting_qb_category_hint,
      value: (SettingsContext c) => _cfg(c).category,
      // 与页面同一写法：清空时存储侧兜底 'fushi'。
      onChanged: (SettingsContext c, String v) => _commit(
        c,
        (QbConnectionConfig q) =>
            q.copyWith(category: v.trim().isEmpty ? 'fushi' : v.trim()),
      ),
    ),
    _int(
      id: 'max_connections',
      title: t.video_setting_torrent_max_connections,
      subtitle: t.video_setting_torrent_connections_hint,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.maxConnections,
      write: (QbConnectionConfig q, int v) => q.copyWith(maxConnections: v),
    ),
    _int(
      id: 'memory_limit_mb',
      title: t.video_setting_torrent_memory_limit,
      subtitle: t.video_setting_torrent_memory_hint,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.memoryLimitMb,
      write: (QbConnectionConfig q, int v) => q.copyWith(memoryLimitMb: v),
      suffix: 'MB',
    ),
    _int(
      id: 'listen_port',
      title: t.video_setting_torrent_listen_port,
      subtitle: t.video_setting_torrent_listen_port_hint,
      visible: _embedded,
      max: 65535,
      read: (QbConnectionConfig q) => q.listenPort,
      write: (QbConnectionConfig q, int v) => q.copyWith(listenPort: v),
    ),
    _switch(
      id: 'dht',
      title: t.video_setting_torrent_dht,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.enableDht,
      write: (QbConnectionConfig q, bool v) => q.copyWith(enableDht: v),
    ),
    _switch(
      id: 'lsd',
      title: t.video_setting_torrent_lsd,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.enableLsd,
      write: (QbConnectionConfig q, bool v) => q.copyWith(enableLsd: v),
    ),
    _switch(
      id: 'upnp',
      title: t.video_setting_torrent_upnp,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.enableUpnp,
      write: (QbConnectionConfig q, bool v) => q.copyWith(enableUpnp: v),
    ),
    _switch(
      id: 'natpmp',
      title: t.video_setting_torrent_natpmp,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.enableNatpmp,
      write: (QbConnectionConfig q, bool v) => q.copyWith(enableNatpmp: v),
    ),
    _switch(
      id: 'anonymous',
      title: t.video_setting_torrent_anonymous,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.anonymousMode,
      write: (QbConnectionConfig q, bool v) => q.copyWith(anonymousMode: v),
    ),
    SettingsSegmentedItem<String>(
      id: _id('encryption'),
      title: t.settings_downloads_encryption_title,
      visible: _embedded,
      options: <SettingsSegmentOption<String>>[
        for (final (String token, int _, String label) in _encryptionModes())
          SettingsSegmentOption<String>(value: token, label: label),
      ],
      selected: (SettingsContext c) {
        final int mode = _cfg(c).encryptionMode;
        return _encryptionModes()
            .firstWhere(
              ((String, int, String) m) => m.$2 == mode,
              orElse: () => _encryptionModes().first,
            )
            .$1;
      },
      onChanged: (SettingsContext c, String token) {
        final int mode = _encryptionModes()
            .firstWhere(((String, int, String) m) => m.$1 == token)
            .$2;
        return _commit(
          c,
          (QbConnectionConfig q) => q.copyWith(encryptionMode: mode),
        );
      },
    ),
    _int(
      id: 'max_active_downloads',
      title: t.video_setting_torrent_active_downloads,
      subtitle: t.video_setting_torrent_zero_default,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.maxActiveDownloads,
      write: (QbConnectionConfig q, int v) => q.copyWith(maxActiveDownloads: v),
    ),
    _int(
      id: 'max_active_seeds',
      title: t.video_setting_torrent_active_seeds,
      subtitle: t.video_setting_torrent_zero_default,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.maxActiveSeeds,
      write: (QbConnectionConfig q, int v) => q.copyWith(maxActiveSeeds: v),
    ),
    _int(
      id: 'max_upload_slots',
      title: t.video_setting_torrent_upload_slots,
      subtitle: t.video_setting_torrent_zero_default,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.maxUploadSlots,
      write: (QbConnectionConfig q, int v) => q.copyWith(maxUploadSlots: v),
    ),
    _switch(
      id: 'antileech',
      title: t.video_setting_torrent_antileech,
      visible: _embedded,
      read: (QbConnectionConfig q) => q.antiLeechEnabled,
      write: (QbConnectionConfig q, bool v) => q.copyWith(antiLeechEnabled: v),
    ),
    _switch(
      id: 'ban_progress_cheat',
      title: t.video_setting_torrent_ban_progress_cheat,
      visible: _antiLeechVisible,
      read: (QbConnectionConfig q) => q.banProgressCheat,
      write: (QbConnectionConfig q, bool v) => q.copyWith(banProgressCheat: v),
    ),
    _switch(
      id: 'ban_relative_cheat',
      title: t.video_setting_torrent_ban_relative_cheat,
      visible: _antiLeechVisible,
      read: (QbConnectionConfig q) => q.banRelativeProgressCheat,
      write: (QbConnectionConfig q, bool v) =>
          q.copyWith(banRelativeProgressCheat: v),
    ),
    _int(
      id: 'max_ip_ports',
      title: t.video_setting_torrent_max_ip_ports,
      subtitle: t.video_setting_torrent_zero_off,
      visible: _antiLeechVisible,
      read: (QbConnectionConfig q) => q.maxIpPortCount,
      write: (QbConnectionConfig q, int v) => q.copyWith(maxIpPortCount: v),
    ),
    _int(
      id: 'ban_time_minutes',
      title: t.video_setting_torrent_ban_time,
      subtitle: t.video_setting_torrent_ban_time_hint,
      visible: _antiLeechVisible,
      read: (QbConnectionConfig q) => q.banTimeMinutes,
      write: (QbConnectionConfig q, int v) => q.copyWith(banTimeMinutes: v),
    ),
  ],
);

bool _uploadVisible(SettingsContext c) => _embedded(c) && _cfg(c).uploadEnabled;

bool _antiLeechVisible(SettingsContext c) =>
    _embedded(c) && _cfg(c).antiLeechEnabled;

/// 加密模式：CLI token / 存储值 / 标签。
List<(String, int, String)> _encryptionModes() => <(String, int, String)>[
  (
    'prefer',
    QbConnectionConfig.encryptionPrefer,
    t.video_setting_torrent_encryption_prefer,
  ),
  (
    'forced',
    QbConnectionConfig.encryptionForced,
    t.video_setting_torrent_encryption_forced,
  ),
  (
    'disabled',
    QbConnectionConfig.encryptionDisabled,
    t.video_setting_torrent_encryption_disabled,
  ),
];

// ── 动作 / 写入体 ─────────────────────────────────────────────────────────────

/// 执行设备：`local` / 空串 = 本机；否则必须是已配对且启用的 host 的某条地址
/// （按所属 host 归一成它的代表地址存，与页面下拉同一判据）。
Future<void> _writeExecutionHost(SettingsContext c, String raw) async {
  final String value = raw.trim();
  if (value.isEmpty || value.toLowerCase() == 'local') {
    await _app(c).prefsRepo.setDownloadExecutionHostUrl('');
    return;
  }
  final List<FushiClientUrl> urls = await loadDownloadExecutionHostUrls(
    _app(c),
  );
  final FushiClientUrl? host = interconnectPeerRepresentativeOf(urls, value);
  if (host == null) {
    final List<String> known = <String>[
      for (final FushiClientUrl h in interconnectPeerRepresentatives(urls))
        h.url,
    ];
    throw ArgumentError(
      '「$value」不是已配对且启用的 host；可选：local'
      '${known.isEmpty ? '' : '、${known.join('、')}'}',
    );
  }
  await _app(c).prefsRepo.setDownloadExecutionHostUrl(host.url);
}

Future<Object?> _executionHostCandidates(
  SettingsContext c,
  Map<String, String> args,
) async {
  final List<FushiClientUrl> urls = await loadDownloadExecutionHostUrls(
    _app(c),
  );
  return <String, Object?>{
    'current': _app(c).prefsRepo.downloadExecutionHostUrl.isEmpty
        ? 'local'
        : _app(c).prefsRepo.downloadExecutionHostUrl,
    'candidates': <Map<String, Object?>>[
      <String, Object?>{'value': 'local', 'label': t.download_target_local},
      for (final FushiClientUrl host in interconnectPeerRepresentatives(urls))
        <String, Object?>{
          'value': host.url,
          'label': host.deviceName ?? host.url,
        },
    ],
  };
}

/// 下载目录：与页面同一条 `AppModel.setDownloadSaveRoot`，校验不过不写、报原因。
Future<void> _writeSaveRoot(SettingsContext c, String raw) async {
  final String path = raw.trim();
  if (path.isEmpty || !p.isAbsolute(path)) {
    throw ArgumentError(
      downloadSaveRootIssueMessage(DownloadSaveRootIssue.notAbsolute),
    );
  }
  final DownloadSaveRootIssue? issue = await _app(c).setDownloadSaveRoot(path);
  if (issue != null) {
    throw ArgumentError(downloadSaveRootIssueMessage(issue));
  }
}

Future<Object?> _testConnection(
  SettingsContext c,
  Map<String, String> args,
) async {
  final TorrentConnectionProbe probe = await probeTorrentConnection(
    _app(c),
    _cfg(c),
  );
  final String? version = probe.version;
  final String? failure = probe.failure;
  return <String, Object?>{
    'ok': version != null,
    if (version != null) 'version': version,
    if (version == null && failure != null && failure.isNotEmpty)
      'failure': failure,
    'message': version != null
        ? t.download_test_connection_ok(version: version)
        : failure != null && failure.isNotEmpty
        ? t.download_test_connection_failed_reason(message: failure)
        : t.download_test_connection_failed,
  };
}

/// 拉取 tracker 订阅（与页面同一条：先写地址再强制刷新）。拉取失败如实回报
/// 原因（`ok: false` + `error`），与页面状态句同一信息。
Future<Object?> _refreshTrackers(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String url = (args['url'] ?? _cfg(c).trackerSubscriptionUrl).trim();
  try {
    final List<String> trackers = await refreshTorrentTrackerSubscription(
      _app(c),
      url,
    );
    return <String, Object?>{
      'ok': true,
      'url': url,
      'count': trackers.length,
      'trackers': trackers,
    };
  } on Object catch (error) {
    return <String, Object?>{
      'ok': false,
      'url': url,
      'error': t.download_tracker_fetch_failed(message: '$error'),
    };
  }
}

// ── 构造辅助 ────────────────────────────────────────────────────────────────

SettingsActionItem _action({
  required String id,
  required String title,
  required SettingsCliAction cli,
  SettingsVisibility? visible,
}) {
  final SettingsCliRun? run = cli.run;
  return SettingsActionItem(
    id: _id(id),
    title: title,
    visible: visible,
    cli: cli,
    onTap: (SettingsContext c) async {
      if (run != null) await run(c, const <String, String>{});
    },
  );
}

SettingsSwitchItem _switch({
  required String id,
  required String title,
  required bool Function(QbConnectionConfig q) read,
  required QbConnectionConfig Function(QbConnectionConfig q, bool v) write,
  String? subtitle,
  SettingsVisibility? visible,
}) => SettingsSwitchItem(
  id: _id(id),
  title: title,
  subtitle: subtitle,
  visible: visible,
  value: (SettingsContext c) => read(_cfg(c)),
  onChanged: (SettingsContext c, bool v) =>
      _commit(c, (QbConnectionConfig q) => write(q, v)),
);

/// 非负整数行（0 = 不限 / 默认，与页面输入框同一语义）。
SettingsNumberItem _int({
  required String id,
  required String title,
  required int Function(QbConnectionConfig q) read,
  required QbConnectionConfig Function(QbConnectionConfig q, int v) write,
  String? subtitle,
  String? suffix,
  int? max,
  SettingsVisibility? visible,
}) => SettingsNumberItem(
  id: _id(id),
  title: title,
  subtitle: subtitle,
  visible: visible,
  integer: true,
  min: 0,
  max: max,
  suffixText: suffix,
  value: (SettingsContext c) => read(_cfg(c)),
  onChanged: (SettingsContext c, num v) =>
      _commit(c, (QbConnectionConfig q) => write(q, v < 0 ? 0 : v.toInt())),
);

SettingsTextItem _text({
  required String id,
  required String title,
  required String Function(QbConnectionConfig q) read,
  required QbConnectionConfig Function(QbConnectionConfig q, String v) write,
  String? subtitle,
  bool secret = false,
}) => SettingsTextItem(
  id: _id(id),
  title: title,
  subtitle: subtitle,
  secret: secret,
  visible: _qb,
  value: (SettingsContext c) => read(_cfg(c)),
  onChanged: (SettingsContext c, String v) =>
      _commit(c, (QbConnectionConfig q) => write(q, v)),
);
