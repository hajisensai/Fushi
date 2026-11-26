part of '../sync_settings_schema.dart';

// 「自动备份」分组（docs/specs/2026-11-25-auto-backup-restore-points.md 第二层，D1 / D2 / D7）：
// 间隔、偏好时间、内容、落点、状态 + 立即备份、还原点入口。设置读写只经
// AppModel.autoBackupSettings / setAutoBackupSettings（设备本地偏好）。

/// 第二期只有桌面端能选自定义文件夹（与 AppModel 的自动备份宿主同一判据）。
bool get _autoBackupSupportsCustomFolder =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

bool _autoBackupOn(SettingsContext ctx) =>
    ctx.appModel.autoBackupSettings.enabled;

Future<void> _updateAutoBackupSettings(
  SettingsContext ctx,
  AutoBackupSettings Function(AutoBackupSettings current) update,
) async {
  final AppModel app = ctx.appModel;
  await app.setAutoBackupSettings(update(app.autoBackupSettings));
  ctx.refresh();
}

/// 间隔的界面文案。
String autoBackupIntervalLabel(AutoBackupInterval interval) =>
    switch (interval) {
      AutoBackupInterval.off => t.auto_backup_interval_off,
      AutoBackupInterval.daily => t.auto_backup_interval_daily,
      AutoBackupInterval.every3Days => t.auto_backup_interval_every_3_days,
      AutoBackupInterval.weekly => t.auto_backup_interval_weekly,
    };

/// 状态行文案（纯函数，测试用）：「上次备份：3 小时前 · 412 MB · 共保留 14 份」/「还没有备份」。
@visibleForTesting
String autoBackupStatusLine({
  required AutoBackupStatus status,
  required int keptCount,
  required DateTime now,
}) {
  final int? ms = status.lastSuccessMs;
  if (ms == null) return t.auto_backup_status_none;
  return t.auto_backup_status_last(
    time: formatActivityRelativeTime(ms, now),
    size: formatStorageBytes(status.lastSuccessBytes ?? 0),
    n: keptCount,
  );
}

SettingsSection _autoBackupSection() => SettingsSection(
  id: 'sync.auto_backup.section',
  presentation: SettingsSectionPresentation.alwaysExpanded,
  title: t.auto_backup_section,
  items: <SettingsItem>[
    SettingsSegmentedItem<AutoBackupInterval>(
      id: 'sync.auto_backup.interval',
      title: t.auto_backup_interval,
      subtitle: t.auto_backup_interval_hint,
      icon: FushiIcons.schedule,
      defaultValue: kAutoBackupDefaultInterval,
      options: <SettingsSegmentOption<AutoBackupInterval>>[
        for (final AutoBackupInterval v in AutoBackupInterval.values)
          SettingsSegmentOption<AutoBackupInterval>(
            value: v,
            label: autoBackupIntervalLabel(v),
          ),
      ],
      selected: (SettingsContext ctx) =>
          ctx.appModel.autoBackupSettings.interval,
      onChanged: (SettingsContext ctx, AutoBackupInterval value) =>
          _updateAutoBackupSettings(
            ctx,
            (AutoBackupSettings s) => s.copyWith(interval: value),
          ),
    ),
    SettingsCustomItem(
      id: 'sync.auto_backup.time',
      searchTitle: t.auto_backup_time,
      icon: FushiIcons.timer,
      visible: _autoBackupOn,
      builder: (SettingsContext ctx) =>
          _AutoBackupTimeRow(settingsContext: ctx),
    ),
    SettingsCustomItem.rows(
      id: 'sync.auto_backup.contents',
      searchTitle: t.auto_backup_contents_files,
      icon: FushiIcons.backup,
      visible: _autoBackupOn,
      rowsBuilder: _autoBackupContentRows,
    ),
    SettingsSwitchItem(
      id: 'sync.auto_backup.srs_media',
      title: t.auto_backup_srs_media,
      subtitle: t.auto_backup_srs_media_hint,
      icon: FushiIcons.image,
      defaultValue: false,
      // 复习笔记与记录恒在整库里；媒体（卡片图片 / 音频）是文件，单独一个开关（D2）。
      visible: _autoBackupOn,
      value: (SettingsContext ctx) =>
          ctx.appModel.autoBackupSettings.includeSrsMedia,
      onChanged: (SettingsContext ctx, bool value) => _updateAutoBackupSettings(
        ctx,
        (AutoBackupSettings s) => s.copyWith(includeSrsMedia: value),
      ),
    ),
    SettingsCustomItem(
      id: 'sync.auto_backup.folder',
      searchTitle: t.auto_backup_folder,
      icon: FushiIcons.folder,
      visible: _autoBackupOn,
      builder: (SettingsContext ctx) =>
          _AutoBackupFolderRow(settingsContext: ctx),
    ),
    SettingsCustomItem(
      id: 'sync.auto_backup.cloud',
      searchTitle: t.auto_backup_cloud,
      icon: FushiIcons.cloudUpload,
      visible: _autoBackupOn,
      builder: (SettingsContext ctx) => AutoBackupCloudRow(
        settings: ctx.appModel.autoBackupSettings,
        statusChanges: ctx.appModel.autoBackup.status,
        readStatus: () => ctx.appModel.autoBackup.status.value,
        meteredNetworks: _autoBackupMayBeMetered,
        backendLabel: ctx.appModel.autoBackup.host.cloudBackendLabel,
        onUpdate: (AutoBackupSettings Function(AutoBackupSettings) update) =>
            _updateAutoBackupSettings(ctx, update),
      ),
    ),
    SettingsCustomItem(
      id: 'sync.auto_backup.server',
      searchTitle: t.auto_backup_server,
      icon: FushiIcons.devices,
      visible: _autoBackupOn,
      builder: (SettingsContext ctx) => AutoBackupServerRow(
        settings: ctx.appModel.autoBackupSettings,
        statusChanges: ctx.appModel.autoBackup.status,
        readStatus: () => ctx.appModel.autoBackup.status.value,
        meteredNetworks: _autoBackupMayBeMetered,
        backendLabel: ctx.appModel.autoBackup.host.serverLabel,
        onUpdate: (AutoBackupSettings Function(AutoBackupSettings) update) =>
            _updateAutoBackupSettings(ctx, update),
      ),
    ),
    // 云端与服务器副本共用一个「也用移动数据上传」（D10 / D12）：只在移动端、至少开了一个时出现。
    SettingsSwitchItem(
      id: 'sync.auto_backup.metered',
      title: t.auto_backup_cloud_metered,
      subtitle: t.auto_backup_copies_metered_hint,
      icon: FushiIcons.dataUsage,
      defaultValue: false,
      visible: (SettingsContext ctx) =>
          _autoBackupMayBeMetered &&
          autoBackupMeteredRowVisible(ctx.appModel.autoBackupSettings),
      value: (SettingsContext ctx) =>
          ctx.appModel.autoBackupSettings.cloudAllowMetered,
      onChanged: (SettingsContext ctx, bool value) => _updateAutoBackupSettings(
        ctx,
        (AutoBackupSettings s) => s.copyWith(cloudAllowMetered: value),
      ),
    ),
    SettingsCustomItem(
      id: 'sync.auto_backup.status',
      searchTitle: t.auto_backup_now,
      icon: FushiIcons.backup,
      builder: (SettingsContext ctx) =>
          _AutoBackupStatusRow(settingsContext: ctx),
    ),
    SettingsActionItem(
      id: 'sync.auto_backup.restore_points',
      title: t.restore_points_title,
      subtitle: t.restore_points_entry_hint,
      icon: FushiIcons.restoreBackup,
      cli: const SettingsCliAction.unsupported(
        '还原点要逐条确认，只在界面里做：设置 › 同步与备份 › 还原点',
      ),
      onTap: (SettingsContext ctx) =>
          openRestorePointsPage(ctx.context, ctx.appModel),
    ),
  ],
);

/// 内容：每个定时还原点都是整库（一行说明），勾选只挑大块文件树（[kBackupFileCategories]，与手动
/// 导出同一套标签 / 说明 / 图标，不带计数）。一个都不勾也行——数据照样每次都在。
List<Widget> _autoBackupContentRows(SettingsContext ctx) {
  final AutoBackupSettings settings = ctx.appModel.autoBackupSettings;
  return <Widget>[
    AdaptiveSettingsRow(
      key: const ValueKey<String>('auto-backup-contents-caption'),
      title: t.auto_backup_contents_files,
      subtitle: t.auto_backup_contents_always,
      subtitleMaxLines: 3,
      icon: FushiIcons.backup,
      showIcon: true,
    ),
    for (final BackupCategory c in BackupCategory.values)
      if (kBackupFileCategories.contains(c))
        AdaptiveSettingsSwitchRow(
          key: ValueKey<String>('auto-backup-category-${c.name}'),
          title: backupCategoryLabel(c),
          subtitle: backupCategoryDescription(c),
          icon: backupCategoryIcon(c),
          showIcon: true,
          value: settings.categories.contains(c),
          onChanged: (bool on) => unawaited(
            _updateAutoBackupSettings(ctx, (AutoBackupSettings s) {
              final Set<BackupCategory> next = <BackupCategory>{
                ...s.categories,
              };
              on ? next.add(c) : next.remove(c);
              return s.copyWith(categories: next);
            }),
          ),
        ),
  ];
}

/// 偏好时间：选一个时刻，或「任意时间」。
class _AutoBackupTimeRow extends StatelessWidget {
  const _AutoBackupTimeRow({required this.settingsContext});

  final SettingsContext settingsContext;

  Future<void> _pick(BuildContext context, int? current) async {
    final TimeOfDay? picked = await showFushiTimePicker(
      context: context,
      initialTime: current == null
          ? const TimeOfDay(hour: 3, minute: 0)
          : TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: t.auto_backup_time,
    );
    if (picked == null) return;
    await _updateAutoBackupSettings(
      settingsContext,
      (AutoBackupSettings s) => s.copyWith(
        preferredMinuteOfDay: () => picked.hour * 60 + picked.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int? minute =
        settingsContext.appModel.autoBackupSettings.preferredMinuteOfDay;
    final String? time = minute == null
        ? null
        : MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    return AdaptiveSettingsRow(
      title: t.auto_backup_time,
      subtitle: time == null
          ? t.auto_backup_time_any_hint
          : t.auto_backup_time_value(time: time),
      icon: FushiIcons.timer,
      showIcon: true,
      subtitleMaxLines: 3,
      onTap: () => unawaited(_pick(context, minute)),
      trailing: Wrap(
        spacing: 4,
        children: <Widget>[
          if (minute != null)
            FushiPressScale(
              child: FushiTextButton(
                key: const ValueKey<String>('auto-backup-time-clear'),
                onPressed: () => unawaited(
                  _updateAutoBackupSettings(
                    settingsContext,
                    (AutoBackupSettings s) =>
                        s.copyWith(preferredMinuteOfDay: () => null),
                  ),
                ),
                child: Text(t.auto_backup_time_any),
              ),
            ),
          FushiPressScale(
            child: FushiTextButton(
              key: const ValueKey<String>('auto-backup-time-pick'),
              onPressed: () => unawaited(_pick(context, minute)),
              child: Text(t.auto_backup_time_pick),
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户文件夹的状态行（纯函数，测试用）：失败 → 告警原因；最新那份已复制 → 「最新备份已复制（3 小时前）」；
/// 还没复制 → 「下次检查时补上」；还没有任何备份 → null（不显示）。
@visibleForTesting
({String text, bool failed})? autoBackupMirrorStatusLine({
  required AutoBackupStatus status,
  required AutoBackupMirrorFolder folder,
  required DateTime now,
}) {
  final AutoBackupMirrorStatus mirror = status.mirror;
  if (mirror.failedFor(folder.key)) {
    return (
      text: t.auto_backup_mirror_failed(
        reason: autoBackupErrorText(mirror.error),
      ),
      failed: true,
    );
  }
  final String? latest = status.lastSuccessPointId;
  if (latest == null) return null;
  if (mirror.holds(folder.key, latest) && mirror.atMs != null) {
    return (
      text: t.auto_backup_mirror_status_done(
        time: formatActivityRelativeTime(mirror.atMs!, now),
      ),
      failed: false,
    );
  }
  return (text: t.auto_backup_mirror_status_pending, failed: false);
}

/// 落点：默认还原点目录；桌面端可选自定义文件夹 / 改回默认。默认目录在卸载时随 app 删除，提示一次。
/// 移动端（第三期）另有「复制到文件夹」：Android SAF 树 / iOS 书签文件夹，见 [_AutoBackupMirrorRow]。
class _AutoBackupFolderRow extends StatelessWidget {
  const _AutoBackupFolderRow({required this.settingsContext});

  final SettingsContext settingsContext;

  Future<void> _choose() async {
    final String? path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t.auto_backup_folder_choose,
    );
    if (path == null || path.trim().isEmpty) return;
    await _updateAutoBackupSettings(
      settingsContext,
      (AutoBackupSettings s) => s.copyWith(customFolder: () => path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppModel app = settingsContext.appModel;
    final bool supportsCustom = _autoBackupSupportsCustomFolder;
    // 移动端没有自定义存储根：还原点留在默认目录，另可复制到用户文件夹（[_AutoBackupMirrorRow]）。
    final String? folder = app.autoBackupSettings.effectiveFolder(
      supportsCustomFolder: supportsCustom,
    );
    final BackupFolderPlatform mirrorPlatform =
        app.autoBackup.host.mirrorPlatform;
    final AutoBackupMirrorFolder? mirror = app.autoBackup.mirrorFolder();
    final String defaultRoot = app.autoBackup.defaultStore.root;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.auto_backup_folder,
          subtitle: folder ?? t.auto_backup_folder_default(path: defaultRoot),
          icon: FushiIcons.folder,
          showIcon: true,
          subtitleMaxLines: 3,
          onTap: supportsCustom ? () => unawaited(_choose()) : null,
          trailing: supportsCustom
              ? Wrap(
                  spacing: 4,
                  children: <Widget>[
                    if (folder != null)
                      FushiPressScale(
                        child: FushiTextButton(
                          key: const ValueKey<String>(
                            'auto-backup-folder-reset',
                          ),
                          onPressed: () => unawaited(
                            _updateAutoBackupSettings(
                              settingsContext,
                              (AutoBackupSettings s) =>
                                  s.copyWith(customFolder: () => null),
                            ),
                          ),
                          child: Text(t.auto_backup_folder_reset),
                        ),
                      ),
                    FushiPressScale(
                      child: FushiTextButton(
                        key: const ValueKey<String>(
                          'auto-backup-folder-choose',
                        ),
                        onPressed: () => unawaited(_choose()),
                        child: Text(t.auto_backup_folder_choose),
                      ),
                    ),
                  ],
                )
              : null,
        ),
        if (folder == null && mirror == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FushiInlineNotice(
              key: const ValueKey<String>('auto-backup-uninstall-warning'),
              severity: FushiNoticeSeverity.warning,
              message: t.auto_backup_folder_uninstall_warning,
            ),
          ),
        if (mirrorPlatform.supported)
          _AutoBackupMirrorRow(
            settingsContext: settingsContext,
            platform: mirrorPlatform,
            folder: mirror,
          ),
      ],
    );
  }
}

/// 移动端「复制到文件夹」（第三期）：选 / 换 / 停止复制，加复制状态行。还原点照旧先写进本机存储，
/// 写好的每份再复制进这个文件夹（[AutoBackupController]）。
class _AutoBackupMirrorRow extends StatelessWidget {
  const _AutoBackupMirrorRow({
    required this.settingsContext,
    required this.platform,
    required this.folder,
  });

  final SettingsContext settingsContext;
  final BackupFolderPlatform platform;
  final AutoBackupMirrorFolder? folder;

  Future<void> _choose() async {
    final AutoBackupMirrorFolder? picked;
    try {
      picked = await platform.pick();
    } catch (e, st) {
      debugPrint('AutoBackup: picking the folder failed: $e\n$st');
      // 平台原文（PlatformException 之类）不上界面：归成错误码再给文案。
      FushiToast.show(
        msg: t.auto_backup_mirror_failed(reason: autoBackupErrorText(e)),
        severity: ToastSeverity.error,
      );
      return;
    }
    if (picked == null) return;
    final AutoBackupMirrorFolder? previous = folder;
    // 存设置会立刻查一次到期：没到期也会把最新那份补复制进新文件夹。
    await _updateAutoBackupSettings(
      settingsContext,
      (AutoBackupSettings s) => s.copyWith(mirrorFolder: () => picked),
    );
    if (previous != null && previous.handle != picked.handle) {
      await platform.forget(previous);
    }
  }

  Future<void> _stop() async {
    final AutoBackupMirrorFolder? previous = folder;
    await _updateAutoBackupSettings(
      settingsContext,
      (AutoBackupSettings s) => s.copyWith(mirrorFolder: () => null),
    );
    if (previous != null) await platform.forget(previous);
  }

  @override
  Widget build(BuildContext context) {
    final AppModel app = settingsContext.appModel;
    final AutoBackupMirrorFolder? current = folder;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('auto-backup-mirror'),
          title: t.auto_backup_mirror_folder,
          subtitle: current?.label ?? t.auto_backup_mirror_folder_none,
          icon: FushiIcons.folder,
          showIcon: true,
          subtitleMaxLines: 3,
          onTap: () => unawaited(_choose()),
          trailing: Wrap(
            spacing: 4,
            children: <Widget>[
              if (current != null)
                FushiPressScale(
                  child: FushiTextButton(
                    key: const ValueKey<String>('auto-backup-mirror-stop'),
                    onPressed: () => unawaited(_stop()),
                    child: Text(t.auto_backup_mirror_stop),
                  ),
                ),
              FushiPressScale(
                child: FushiTextButton(
                  key: const ValueKey<String>('auto-backup-mirror-choose'),
                  onPressed: () => unawaited(_choose()),
                  child: Text(t.auto_backup_folder_choose),
                ),
              ),
            ],
          ),
        ),
        if (current == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FushiInlineNotice(
              key: const ValueKey<String>('auto-backup-mirror-hint'),
              message: t.auto_backup_mirror_folder_hint,
            ),
          )
        else
          ValueListenableBuilder<AutoBackupStatus>(
            valueListenable: app.autoBackup.status,
            builder:
                (BuildContext context, AutoBackupStatus status, Widget? _) {
                  final ({String text, bool failed})? line =
                      autoBackupMirrorStatusLine(
                        status: status,
                        folder: current,
                        now: DateTime.now(),
                      );
                  final AutoBackupMirrorStatus mirror = status.mirror;
                  return _AutoBackupCopyStatusLines(
                    keyPrefix: 'auto-backup-mirror',
                    line: line,
                    pruneFailed:
                        mirror.target == current.key &&
                        mirror.pruneError != null,
                  );
                },
          ),
      ],
    );
  }
}

/// 云端 / 服务器副本可能走计费网络的平台（移动端）：只有这里才给「使用移动数据时也上传」；桌面端一律当不计流量
/// （与宿主 `networkUnmetered` 的判据一致）。
bool get _autoBackupMayBeMetered =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 「也用移动数据上传」那一行该不该出现（移动端之外的判据）：自动备份开着、云端或服务器副本至少开了一个。
@visibleForTesting
bool autoBackupMeteredRowVisible(AutoBackupSettings settings) =>
    settings.enabled && (settings.cloudCopies || settings.serverCopies);

/// 远端副本（云端 / 服务器）的状态行：失败 → 告警原因；最新那份已上传 → 「最新备份已上传（3 小时前）」；
/// 还没上传 → 「下次检查时补上」（[wifiOnly] 时说明要等 Wi-Fi）；还没有任何备份 → null（不显示）。
({String text, bool failed})? _remoteCopyStatusLine({
  required AutoBackupMirrorKind kind,
  required AutoBackupStatus status,
  required DateTime now,
  required bool wifiOnly,
}) {
  final bool server = kind == AutoBackupMirrorKind.server;
  final AutoBackupMirrorStatus copy = server ? status.server : status.cloud;
  final String? error = copy.error;
  if (error != null) {
    final String reason = autoBackupErrorText(error);
    return (
      text: server
          ? t.auto_backup_server_failed(reason: reason)
          : t.auto_backup_cloud_failed(reason: reason),
      failed: true,
    );
  }
  final String? latest = status.lastSuccessPointId;
  if (latest == null) return null;
  final int? atMs = copy.atMs;
  if (copy.target != null && copy.pointId == latest && atMs != null) {
    final String time = formatActivityRelativeTime(atMs, now);
    return (
      text: server
          ? t.auto_backup_server_status_done(time: time)
          : t.auto_backup_cloud_status_done(time: time),
      failed: false,
    );
  }
  return (
    text: switch ((server, wifiOnly)) {
      (false, true) => t.auto_backup_cloud_status_pending_wifi,
      (false, false) => t.auto_backup_cloud_status_pending,
      (true, true) => t.auto_backup_server_status_pending_wifi,
      (true, false) => t.auto_backup_server_status_pending,
    },
    failed: false,
  );
}

/// 云端副本的状态行（纯函数，测试用；规则见 [_remoteCopyStatusLine]）。
@visibleForTesting
({String text, bool failed})? autoBackupCloudStatusLine({
  required AutoBackupStatus status,
  required DateTime now,
  required bool wifiOnly,
}) => _remoteCopyStatusLine(
  kind: AutoBackupMirrorKind.cloud,
  status: status,
  now: now,
  wifiOnly: wifiOnly,
);

/// 服务器副本的状态行（纯函数，测试用；规则见 [_remoteCopyStatusLine]）。
@visibleForTesting
({String text, bool failed})? autoBackupServerStatusLine({
  required AutoBackupStatus status,
  required DateTime now,
  required bool wifiOnly,
}) => _remoteCopyStatusLine(
  kind: AutoBackupMirrorKind.server,
  status: status,
  now: now,
  wifiOnly: wifiOnly,
);

/// 副本目标（文件夹 / 云端 / 服务器）下方的状态行 + 「旧副本没删掉」提示行。
class _AutoBackupCopyStatusLines extends StatelessWidget {
  const _AutoBackupCopyStatusLines({
    required this.keyPrefix,
    required this.line,
    required this.pruneFailed,
  });

  /// 键前缀：`<前缀>-status` / `<前缀>-prune`。
  final String keyPrefix;
  final ({String text, bool failed})? line;
  final bool pruneFailed;

  @override
  Widget build(BuildContext context) {
    final ({String text, bool failed})? status = line;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FushiInlineNotice(
              key: ValueKey<String>('$keyPrefix-status'),
              severity: status.failed
                  ? FushiNoticeSeverity.warning
                  : FushiNoticeSeverity.info,
              message: status.text,
            ),
          ),
        if (pruneFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FushiInlineNotice(
              key: ValueKey<String>('$keyPrefix-prune'),
              message: t.auto_backup_copies_prune_failed,
            ),
          ),
      ],
    );
  }
}

/// 「复制到云端」（D8–D11）：开关 + 用哪个同步服务、没有支持的后端时的说明；开着时另有保留规则说明与上传
/// 状态行。依赖全部经构造参数注入（设置页从 AppModel 接，测试注入假的）。「也用移动数据上传」与服务器副本共用，
/// 是单独一行（`sync.auto_backup.metered`）。
class AutoBackupCloudRow extends StatelessWidget {
  const AutoBackupCloudRow({
    required this.settings,
    required this.statusChanges,
    required this.readStatus,
    required this.backendLabel,
    required this.onUpdate,
    required this.meteredNetworks,
    super.key,
  });

  final AutoBackupSettings settings;

  /// 状态文件变了（`AutoBackupController.status`）。
  final Listenable statusChanges;

  /// 状态文件的最新内容。
  final AutoBackupStatus Function() readStatus;

  /// 这台设备可能走计费网络（移动端）：「也用移动数据上传」没开时状态行说明要等 Wi-Fi。
  final bool meteredNetworks;

  /// 云端副本会用的同步服务名（`AutoBackupHost.cloudBackendLabel`，不联网）；null = 没有支持的后端。
  final Future<String?> Function() backendLabel;

  /// 改设置（设置页的 `_updateAutoBackupSettings`）。
  final Future<void> Function(
    AutoBackupSettings Function(AutoBackupSettings current) update,
  )
  onUpdate;

  @override
  Widget build(BuildContext context) => _AutoBackupRemoteCopyRow(
    kind: AutoBackupMirrorKind.cloud,
    settings: settings,
    statusChanges: statusChanges,
    readStatus: readStatus,
    meteredNetworks: meteredNetworks,
    label: backendLabel,
    onUpdate: onUpdate,
  );
}

/// 「复制到服务器」（第四期 D12–D13）：开关 + 同步用的互联服务器名、没有设置互联服务器时的说明；开着时另有
/// 保留规则说明与上传状态行。与云端副本互不相干（两个都开就各传一份）。
class AutoBackupServerRow extends StatelessWidget {
  const AutoBackupServerRow({
    required this.settings,
    required this.statusChanges,
    required this.readStatus,
    required this.backendLabel,
    required this.onUpdate,
    required this.meteredNetworks,
    super.key,
  });

  final AutoBackupSettings settings;
  final Listenable statusChanges;
  final AutoBackupStatus Function() readStatus;
  final bool meteredNetworks;

  /// 服务器名（`AutoBackupHost.serverLabel`，不联网）；null = 没有设置互联服务器。
  final Future<String?> Function() backendLabel;

  final Future<void> Function(
    AutoBackupSettings Function(AutoBackupSettings current) update,
  )
  onUpdate;

  @override
  Widget build(BuildContext context) => _AutoBackupRemoteCopyRow(
    kind: AutoBackupMirrorKind.server,
    settings: settings,
    statusChanges: statusChanges,
    readStatus: readStatus,
    meteredNetworks: meteredNetworks,
    label: backendLabel,
    onUpdate: onUpdate,
  );
}

/// 云端 / 服务器副本那一行的共同实现（文案按 [kind] 分）。
class _AutoBackupRemoteCopyRow extends StatefulWidget {
  const _AutoBackupRemoteCopyRow({
    required this.kind,
    required this.settings,
    required this.statusChanges,
    required this.readStatus,
    required this.meteredNetworks,
    required this.label,
    required this.onUpdate,
  });

  final AutoBackupMirrorKind kind;
  final AutoBackupSettings settings;
  final Listenable statusChanges;
  final AutoBackupStatus Function() readStatus;
  final bool meteredNetworks;
  final Future<String?> Function() label;
  final Future<void> Function(
    AutoBackupSettings Function(AutoBackupSettings current) update,
  )
  onUpdate;

  @override
  State<_AutoBackupRemoteCopyRow> createState() =>
      _AutoBackupRemoteCopyRowState();
}

class _AutoBackupRemoteCopyRowState extends State<_AutoBackupRemoteCopyRow> {
  late Future<String?> _label = widget.label();

  @override
  void didUpdateWidget(_AutoBackupRemoteCopyRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 设置页刷新（同一页上刚配好 / 关掉同步后端之后也会刷新）：重查一次名字。只读本机配置，不联网；
    // FutureBuilder 换 future 时保留上一次的结果，不会闪。
    _label = widget.label();
  }

  void _update(AutoBackupSettings Function(AutoBackupSettings s) update) =>
      unawaited(widget.onUpdate(update));

  @override
  Widget build(BuildContext context) {
    final AutoBackupSettings settings = widget.settings;
    final bool server = widget.kind == AutoBackupMirrorKind.server;
    final String k = server ? 'auto-backup-server' : 'auto-backup-cloud';
    return FutureBuilder<String?>(
      future: _label,
      builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
        final bool known =
            snapshot.connectionState == ConnectionState.done ||
            snapshot.hasData;
        final String? label = snapshot.data;
        final bool on = server ? settings.serverCopies : settings.cloudCopies;
        // 没有可用的目标时开关不可用；已经开着的仍可关掉（后端 / 服务器后来被移除了）。
        final bool canToggle = label != null || on;
        final bool wifiOnly =
            widget.meteredNetworks && !settings.cloudAllowMetered;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: ValueKey<String>(k),
              title: server ? t.auto_backup_server : t.auto_backup_cloud,
              subtitle: switch ((server, label)) {
                (false, null) => t.auto_backup_cloud_subtitle,
                (false, final String service) => t.auto_backup_cloud_service(
                  service: service,
                ),
                (true, null) => t.auto_backup_server_subtitle,
                (true, final String name) => t.auto_backup_server_service(
                  server: name,
                ),
              },
              subtitleMaxLines: 3,
              icon: server ? FushiIcons.devices : FushiIcons.cloudUpload,
              showIcon: true,
              value: on,
              onChanged: canToggle
                  ? (bool value) => _update(
                      (AutoBackupSettings s) => server
                          ? s.copyWith(serverCopies: value)
                          : s.copyWith(cloudCopies: value),
                    )
                  : null,
            ),
            if (known && label == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: FushiInlineNotice(
                  key: ValueKey<String>('$k-no-backend'),
                  message: server
                      ? t.auto_backup_server_no_server
                      : t.auto_backup_cloud_no_service,
                ),
              ),
            if (on) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: FushiInlineNotice(
                  key: ValueKey<String>('$k-retention'),
                  message: server
                      ? t.auto_backup_server_retention_hint
                      : t.auto_backup_cloud_retention_hint,
                ),
              ),
              ListenableBuilder(
                listenable: widget.statusChanges,
                builder: (BuildContext context, Widget? _) {
                  final AutoBackupStatus status = widget.readStatus();
                  return _AutoBackupCopyStatusLines(
                    keyPrefix: k,
                    line: _remoteCopyStatusLine(
                      kind: widget.kind,
                      status: status,
                      now: DateTime.now(),
                      wifiOnly: wifiOnly,
                    ),
                    pruneFailed:
                        (server ? status.server : status.cloud).pruneError !=
                        null,
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 状态行 + 告警 + 「立即备份」。备份态的真相源在 AppModel（与手动导出共用一把锁），
/// 状态文件的最新内容在 [AutoBackupController.status]，这里只订阅。
class _AutoBackupStatusRow extends StatelessWidget {
  const _AutoBackupStatusRow({required this.settingsContext});

  final SettingsContext settingsContext;

  static Future<void> _backUpNow(AppModel app) async {
    if (app.backupExportActive) return;
    final AutoBackupOutcome outcome = await app.autoBackup.backUpNow();
    switch (outcome) {
      case AutoBackupOutcome.created:
        FushiToast.show(
          msg: t.auto_backup_now_done,
          severity: ToastSeverity.success,
        );
      case AutoBackupOutcome.skippedNoChanges:
        FushiToast.show(msg: t.auto_backup_now_no_changes);
      case AutoBackupOutcome.busy:
        FushiToast.show(msg: t.auto_backup_now_busy);
      case AutoBackupOutcome.failed:
      // 失败已由控制器经宿主提示过一次（AutoBackupHost.notifyFailure），告警行常驻。
      case AutoBackupOutcome.notDue:
      case AutoBackupOutcome.disabled:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppModel app = settingsContext.appModel;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[app, app.autoBackup.status]),
      builder: (BuildContext context, Widget? _) {
        final AutoBackupStatus status = app.autoBackup.status.value;
        final AutoBackupSettings settings = app.autoBackupSettings;
        final bool busy = app.backupExportActive;
        final DateTime now = DateTime.now();
        final bool failed = status.lastRunFailed;
        final bool overdue = isAutoBackupOverdue(
          settings: settings,
          now: now,
          lastSatisfied: status.lastSatisfied,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.auto_backup_now,
              subtitle: autoBackupStatusLine(
                status: status,
                keptCount: app.autoBackup.scheduledPoints(settings).length,
                now: now,
              ),
              icon: FushiIcons.backup,
              showIcon: true,
              subtitleMaxLines: 2,
              onTap: busy ? null : () => unawaited(_backUpNow(app)),
              trailing: _BackupBusySwitcher(
                busy: busy,
                child: busy
                    ? ValueListenableBuilder<double?>(
                        valueListenable: app.backupExportProgress,
                        builder:
                            (
                              BuildContext context,
                              double? progress,
                              Widget? _,
                            ) => SizedBox.square(
                              dimension: 20,
                              child: adaptiveIndicator(
                                context: context,
                                strokeWidth: 2,
                                value: progress,
                              ),
                            ),
                      )
                    : FushiPressScale(
                        child: FushiFilledButton.tonalIcon(
                          key: const ValueKey<String>('auto-backup-now'),
                          onPressed: () => unawaited(_backUpNow(app)),
                          icon: const FushiIcon(FushiIcons.backup, size: 18),
                          label: Text(t.auto_backup_now),
                        ),
                      ),
              ),
            ),
            if (failed || overdue)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: FushiInlineNotice(
                  key: const ValueKey<String>('auto-backup-warning'),
                  severity: FushiNoticeSeverity.warning,
                  message: failed
                      ? t.auto_backup_failed_notice(
                          reason: autoBackupErrorText(status.lastError),
                        )
                      : t.auto_backup_overdue_warning,
                ),
              ),
            if (!failed && status.missingData.contains(BackupCategory.srs.name))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: FushiInlineNotice(
                  key: const ValueKey<String>('auto-backup-srs-missing'),
                  severity: FushiNoticeSeverity.info,
                  message: t.auto_backup_status_srs_missing,
                ),
              ),
          ],
        );
      },
    );
  }
}
