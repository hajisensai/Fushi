/// 复习的「备份」页（对标 Anki / AnkiMobile 的备份）：自动备份设置 + 按时间列出本机备份，
/// 每份显示笔记数 / 复习数 / 大小；可以恢复到某个时间点、另存 / 分享、删除，也可以从外部文件恢复。
///
/// 恢复的语义（回到过去的时间点在多设备同步下怎么成立）见 docs/specs/2026-10-17-srs-auto-backup-restore.md；
/// 本页只负责交互：确认 → 控制器先存一份「恢复前」备份 → 写恢复事件 → 刷新。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_storage.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/srs/srs_backup.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/utils.dart';

enum _BackupAction { restore, export, delete }

/// 自动备份间隔的可选值（分钟）。
const List<int> _kIntervalChoices = <int>[5, 15, 30, 60, 120, 240, 720, 1440];

/// 备份的显示时间：本地化日期 + 时刻。
String srsBackupTimeLabel(BuildContext context, DateTime t) {
  final MaterialLocalizations l = MaterialLocalizations.of(context);
  final bool h24 = MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false;
  return '${l.formatMediumDate(t)} '
      '${l.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: h24)}';
}

String srsBackupKindLabel(SrsBackupKind k) => switch (k) {
  SrsBackupKind.auto => t.srs_backup_kind_auto,
  SrsBackupKind.manual => t.srs_backup_kind_manual,
  SrsBackupKind.preRestore => t.srs_backup_kind_pre_restore,
};

/// 读备份失败的提示文案。
String srsBackupErrorText(Object e) => switch (e) {
  SrsBackupFormatException(reason: SrsBackupInvalidReason.notBackup) =>
    t.srs_backup_invalid,
  SrsBackupFormatException(reason: SrsBackupInvalidReason.corrupt) =>
    t.srs_backup_corrupt,
  SrsBackupFormatException(reason: SrsBackupInvalidReason.newerVersion) =>
    t.srs_backup_newer,
  _ => t.srs_backup_restore_failed,
};

class SrsBackupsPage extends ConsumerStatefulWidget {
  const SrsBackupsPage({super.key});

  @override
  ConsumerState<SrsBackupsPage> createState() => _SrsBackupsPageState();
}

class _SrsBackupsPageState extends ConsumerState<SrsBackupsPage> {
  late final SrsBackupController _controller;
  bool _loading = true;
  bool _busy = false;
  List<SrsBackupInfo> _backups = const <SrsBackupInfo>[];
  int _diskBytes = 0;

  /// 备份根（`<documents>/srs_backups`）。
  String? _rootPath;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(srsBackupControllerProvider);
    _controller.changes.addListener(_onChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _controller.changes.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => unawaited(_reload());

  Future<void> _reload() async {
    SrsBackupStore? store;
    try {
      store = await ref.read(srsBackupStoreProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBackupsPage.reload', e, stack);
    }
    final List<SrsBackupInfo> list = store == null
        ? const <SrsBackupInfo>[]
        : await store.list();
    final int disk = store == null ? 0 : await store.diskUsage();
    if (!mounted) return;
    setState(() {
      _backups = list;
      _diskBytes = disk;
      _rootPath = store?.root.path;
      _loading = false;
    });
  }

  /// 跑一个会改动备份 / 复习库的操作：期间禁用按钮，失败统一提示。
  Future<void> _run(
    String where,
    Future<void> Function() body, {
    String? failure,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBackupsPage.$where', e, stack);
      FushiToast.show(
        msg: failure ?? srsBackupErrorText(e),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupNow() => _run('backupNow', () async {
    final SrsBackupInfo? info = await _controller.backupNow();
    if (info != null) {
      FushiToast.show(msg: t.srs_backup_done, severity: ToastSeverity.success);
    }
  }, failure: t.srs_backup_failed);

  Future<void> _restore(SrsBackupInfo info) async {
    final String time = srsBackupTimeLabel(context, info.createdAt);
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_backup_restore_confirm_title,
      message: t.srs_backup_restore_confirm(time: time),
      confirmLabel: t.srs_backup_restore,
      cancelLabel: t.cancel,
      icon: FushiIcons.restoreBackup,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run('restore', () async {
      final SrsBackupRestoreOutcome? r = await _controller.restore(info);
      if (r == null) return;
      _afterRestore(time);
    });
  }

  void _afterRestore(String time) {
    if (mounted) bumpSrsRevision(ref);
    FushiToast.show(
      msg: t.srs_backup_restore_done(time: time),
      severity: ToastSeverity.success,
    );
  }

  Future<void> _restoreFromFile() async {
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: <String>{kSrsBackupExtension, 'zip'},
    );
    if (path == null || !mounted) return;
    final File file = File(path);
    SrsBackupManifest manifest;
    try {
      final SrsBackupArchive a = await SrsBackupStore.read(file);
      manifest = a.manifest;
      a.close();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBackupsPage.readFile', e, stack);
      FushiToast.show(
        msg: srsBackupErrorText(e),
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    final String time = srsBackupTimeLabel(
      context,
      DateTime.fromMillisecondsSinceEpoch(manifest.createdAt),
    );
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_backup_restore_confirm_title,
      message: t.srs_backup_restore_confirm(time: time),
      confirmLabel: t.srs_backup_restore,
      cancelLabel: t.cancel,
      icon: FushiIcons.restoreBackup,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final AppModel app = ref.read(appProvider);
    await _run('restoreFile', () async {
      final SrsStorage? srs = await ref.read(srsStorageProvider.future);
      if (srs == null) return;
      final SrsBackupRestoreOutcome? r;
      try {
        r = await _controller.restoreFile(
          file,
          db: app.database,
          srs: srs,
          activeProfileId: () async {
            final int id = ref.read(profileViewModelProvider).activeProfileId;
            return id > 0 ? id : app.database.resolveActiveProfileId();
          },
          reopenStore: () async {
            ref.invalidate(srsStoreProvider);
            await ref.read(srsStoreProvider.future);
          },
        );
      } on SrsRestoreOtherLocalProfile catch (e) {
        FushiToast.show(
          msg: t.srs_backup_switch_profile(name: e.profileName),
          severity: ToastSeverity.error,
        );
        return;
      } on SrsRestoreProfileMismatch {
        FushiToast.show(
          msg: t.srs_backup_other_profile(name: manifest.profileName),
          severity: ToastSeverity.error,
        );
        return;
      }
      if (r == null) return;
      _afterRestore(time);
      await _reload();
    });
  }

  Future<void> _export(SrsBackupInfo info) => _run('export', () async {
    final DateTime c = info.createdAt;
    String two(int v) => v.toString().padLeft(2, '0');
    final String name =
        'fushi-review-${c.year}${two(c.month)}${two(c.day)}-'
        '${two(c.hour)}${two(c.minute)}.$kSrsBackupExtension';
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.srs_backup_export,
        fileName: name,
      );
      if (savePath == null) return;
      await _controller.export(info, File(savePath));
      FushiToast.show(msg: t.srs_backup_saved, severity: ToastSeverity.success);
      return;
    }
    // 移动端走系统分享面板（iOS「存储到文件」/ iCloud 云盘、AirDrop；Android 各存储 app）。
    final Directory staging = await (await getTemporaryDirectory()).createTemp(
      'fushi_srs_backup_',
    );
    final File out = File('${staging.path}${Platform.pathSeparator}$name');
    await _controller.export(info, out);
    await FushiShare.shareFiles(<XFile>[
      XFile(out.path, mimeType: 'application/zip'),
    ], subject: name);
  }, failure: t.srs_backup_failed);

  Future<void> _delete(SrsBackupInfo info) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_backup_delete,
      message: t.srs_backup_delete_confirm(
        time: srsBackupTimeLabel(context, info.createdAt),
      ),
      confirmLabel: t.srs_backup_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok) return;
    await _run('delete', () => _controller.delete(info));
  }

  void _onAction(SrsBackupInfo info, _BackupAction action) {
    switch (action) {
      case _BackupAction.restore:
        srsRunLogged('SrsBackups.restore', () => _restore(info));
      case _BackupAction.export:
        srsRunLogged('SrsBackups.export', () => _export(info));
      case _BackupAction.delete:
        srsRunLogged('SrsBackups.delete', () => _delete(info));
    }
  }

  // ---------------------------------------------------------------- 设置

  Future<void> _setAuto(bool value) async {
    await ref.read(appProvider).setSrsBackupAuto(value);
    // 关掉 → 作废挂起的定时器；打开 → 按当前间隔重新排。
    await _controller.reschedule();
    if (mounted) setState(() {});
  }

  Future<void> _setLimits(SrsBackupLimits value) async {
    final int before = ref.read(appProvider).srsBackupLimits.intervalMinutes;
    await ref.read(appProvider).setSrsBackupLimits(value);
    // 间隔变了：挂起的定时器按旧间隔算的，按新间隔重排（只改保留份数不动定时器）。
    if (value.intervalMinutes != before) await _controller.reschedule();
    if (mounted) setState(() {});
  }

  SrsBackupLimits _with(
    SrsBackupLimits l, {
    int? daily,
    int? weekly,
    int? monthly,
    int? interval,
  }) => SrsBackupLimits(
    daily: daily ?? l.daily,
    weekly: weekly ?? l.weekly,
    monthly: monthly ?? l.monthly,
    intervalMinutes: interval ?? l.intervalMinutes,
  );

  Widget _buildSettings(BuildContext context) {
    final AppModel app = ref.watch(appProvider);
    final bool auto = app.srsBackupAuto;
    final SrsBackupLimits l = app.srsBackupLimits;
    final List<int> intervals = <int>{
      ..._kIntervalChoices,
      l.intervalMinutes,
    }.toList()..sort();
    Widget keep(
      Key key,
      String title,
      int value,
      SrsBackupLimits Function(int v) apply,
    ) => AdaptiveSettingsStepperRow(
      key: key,
      title: title,
      value: value.toDouble(),
      step: 1,
      min: 0,
      max: kSrsBackupKeepMax.toDouble(),
      format: (double v) => '${v.round()}',
      onChanged: (double v) =>
          srsRunLogged('SrsBackups.keep', () => _setLimits(apply(v.round()))),
    );
    return AdaptiveSettingsSection(
      title: t.srs_backup_auto,
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('srs_backup_auto'),
          title: t.srs_backup_auto,
          subtitle: t.srs_backup_auto_hint,
          icon: FushiIcons.backup,
          value: auto,
          onChanged: (bool v) =>
              srsRunLogged('SrsBackups.auto', () => _setAuto(v)),
        ),
        AdaptiveSettingsPickerRow<int>(
          key: const ValueKey<String>('srs_backup_interval'),
          title: t.srs_backup_interval,
          icon: FushiIcons.schedule,
          options: <AdaptiveSettingsPickerOption<int>>[
            for (final int m in intervals)
              AdaptiveSettingsPickerOption<int>(
                value: m,
                label: t.srs_backup_interval_minutes(n: m),
              ),
          ],
          selected: l.intervalMinutes,
          onChanged: (int v) => srsRunLogged(
            'SrsBackups.interval',
            () => _setLimits(_with(l, interval: v)),
          ),
        ),
        keep(
          const ValueKey<String>('srs_backup_keep_daily'),
          t.srs_backup_keep_daily,
          l.daily,
          (int v) => _with(l, daily: v),
        ),
        keep(
          const ValueKey<String>('srs_backup_keep_weekly'),
          t.srs_backup_keep_weekly,
          l.weekly,
          (int v) => _with(l, weekly: v),
        ),
        keep(
          const ValueKey<String>('srs_backup_keep_monthly'),
          t.srs_backup_keep_monthly,
          l.monthly,
          (int v) => _with(l, monthly: v),
        ),
        AdaptiveSettingsRow(
          title: t.srs_backup_keep_hint,
          subtitle: t.srs_backup_disk_usage(
            size: FushiByteFormat.bytes(_diskBytes),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 存放位置

  /// 存放位置：路径 + 各平台说明。桌面能直接打开文件夹，并跳到「数据存储位置」改位置（与书库一起迁移）；
  /// 移动端是应用私有存储（iOS 刻意不开「文件」App 共享，见 Info.plist 注释），带走靠每份备份的「另存为 / 分享」。
  Widget _buildLocation(BuildContext context) {
    final String? root = _rootPath;
    final bool desktop = isDesktopPlatform;
    final String hint = desktop
        ? t.srs_backup_location_desktop
        : t.srs_backup_location_mobile;
    return AdaptiveSettingsSection(
      title: t.srs_backup_location,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('srs_backup_location'),
          title: root ?? '',
          subtitle: hint,
          icon: FushiIcons.folder,
          showIcon: true,
          titleMaxLines: 4,
        ),
        if (desktop && root != null)
          AdaptiveSettingsNavigationRow(
            key: const ValueKey<String>('srs_backup_open_folder'),
            title: t.srs_backup_open_folder,
            icon: FushiIcons.folderOpen,
            onTap: () => srsRunLogged('SrsBackups.openFolder', () async {
              await Directory(root).create(recursive: true);
              await openDirectoryInFileManager(root);
            }),
          ),
        if (desktop)
          AdaptiveSettingsNavigationRow(
            key: const ValueKey<String>('srs_backup_change_location'),
            title: t.srs_backup_change_location,
            icon: FushiIcons.moveFile,
            onTap: () {
              SettingsSearchReveal.pendingItemId = 'sync.data_storage_location';
              unawaited(
                Navigator.of(context).push<void>(
                  adaptivePageRoute<void>(
                    context: context,
                    builder: (_) => SettingsDetailPage(
                      destination: buildStorageDestination(),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- 顶栏

  List<FushiToolbarItem> get _actions => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_backup_now'),
      icon: FushiIcons.backup,
      label: t.srs_backup_now,
      onPressed: _busy
          ? null
          : () => srsRunLogged('SrsBackups.now', _backupNow),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_backup_restore_file'),
      icon: FushiIcons.importFile,
      label: t.srs_backup_restore_from_file,
      onPressed: _busy
          ? null
          : () => srsRunLogged('SrsBackups.file', _restoreFromFile),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_backup_title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              for (final FushiToolbarItem a in _actions)
                FushiIconButton(
                  key: a.key,
                  icon: a.icon,
                  tooltip: a.label,
                  enabled: a.onPressed != null,
                  onTap: a.onPressed,
                ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.srs_backup_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_actions],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> items = <Widget>[
      // 本机备份不上云：用户找「云端备份」时在这里得到答案和去处。
      Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        child: SrsSyncSettingsNotice(
          modules: ref.watch(appProvider).moduleVisibility,
        ),
      ),
      _buildLocation(context),
      _buildSettings(context),
      Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.gap,
          tokens.spacing.section,
          tokens.spacing.gap,
          tokens.spacing.gap,
        ),
        child: Text(
          t.srs_backup_list,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      if (_backups.isEmpty)
        Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.backup,
            message: t.srs_backup_empty,
          ),
        ),
      for (int i = 0; i < _backups.length; i++)
        _BackupRow(
          key: ValueKey<String>('srs-backup-${_backups[i].id}'),
          info: _backups[i],
          index: i,
          count: _backups.length,
          enabled: !_busy,
          onRestore: () => _onAction(_backups[i], _BackupAction.restore),
          onAction: (_BackupAction a) => _onAction(_backups[i], a),
        ),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: items.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

class _BackupRow extends StatelessWidget {
  const _BackupRow({
    super.key,
    required this.info,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onRestore,
    required this.onAction,
  });

  final SrsBackupInfo info;
  final int index;
  final int count;
  final bool enabled;
  final VoidCallback onRestore;
  final void Function(_BackupAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final SrsBackupManifest m = info.manifest;
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        onTap: enabled ? onRestore : null,
        child: FushiListItem(
          density: srsListDensityOf(context),
          leading: FushiListLeadingIcon(
            switch (m.kind) {
              SrsBackupKind.auto => FushiIcons.backup,
              SrsBackupKind.manual => FushiIcons.save,
              SrsBackupKind.preRestore => FushiIcons.restoreBackup,
            },
            tone: m.kind == SrsBackupKind.preRestore
                ? FushiCardTone.primary
                : FushiCardTone.neutral,
          ),
          title: Text(srsBackupTimeLabel(context, info.createdAt)),
          subtitle: SrsMetaLine(<String>[
            srsBackupKindLabel(m.kind),
            ...SrsMetaLine.split(
              t.srs_backup_summary(
                notes: m.noteCount,
                reviews: m.reviewCount,
                size: FushiByteFormat.bytes(info.totalBytes),
              ),
            ),
          ]),
          trailing: FushiPopupMenuButton<_BackupAction>(
            key: ValueKey<String>('srs-backup-menu-${info.id}'),
            tooltip: t.srs_backup_menu,
            icon: const FushiIcon(FushiIcons.more),
            enabled: enabled,
            onSelected: onAction,
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<_BackupAction>>[
                  PopupMenuItem<_BackupAction>(
                    value: _BackupAction.restore,
                    child: Text(t.srs_backup_restore),
                  ),
                  PopupMenuItem<_BackupAction>(
                    value: _BackupAction.export,
                    child: Text(t.srs_backup_export),
                  ),
                  PopupMenuItem<_BackupAction>(
                    value: _BackupAction.delete,
                    child: Text(t.srs_backup_delete),
                  ),
                ],
          ),
        ),
      ),
    );
  }
}
