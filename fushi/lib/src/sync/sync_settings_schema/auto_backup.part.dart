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

/// 落点：默认还原点目录；桌面端可选自定义文件夹 / 改回默认。默认目录在卸载时随 app 删除，提示一次。
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
    // 第三期接口位：Android SAF 树 / iOS「文件」里可见的文件夹在这里接（spec Phase 3）。
    // 第二期移动端只有默认目录，不出选择按钮。
    final String? folder = app.autoBackupSettings.effectiveFolder(
      supportsCustomFolder: supportsCustom,
    );
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
        if (folder == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FushiInlineNotice(
              key: const ValueKey<String>('auto-backup-uninstall-warning'),
              severity: FushiNoticeSeverity.warning,
              message: t.auto_backup_folder_uninstall_warning,
            ),
          ),
      ],
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
          ],
        );
      },
    );
  }
}
