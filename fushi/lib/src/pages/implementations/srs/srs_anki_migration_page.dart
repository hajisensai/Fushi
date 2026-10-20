/// 「从 Anki 迁移」页：发现 → 确认 → 导入 → 结果，一页走完。
///
/// - 桌面（Windows / macOS / Linux）：自动找本机 Anki 用户数据目录里的各 profile，点一下即迁移
///   （读的是集合的只读快照，见 fushi_engine 的 anki_collection_snapshot.dart）；
/// - Android：自动找 AnkiDroid 旧默认目录（需要「所有文件访问」）；AnkiDroid 2.17+ 新装的集合在
///   它的私有目录里，别的 app 读不到，页面写明并引导「在 AnkiDroid 导出 .colpkg → 这里选文件」；
/// - iOS：AnkiMobile 的数据在它自己的沙盒里，只有「选导出的文件」一条路。
///
/// 导入本身只经 [runSrsAnkiMigration]（逻辑层 srs_anki_migration.dart）。
library;

import 'dart:async';
import 'dart:io';

import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_backups_page.dart'
    show srsBackupTimeLabel;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_anki_migration.dart';
import 'package:fushi/src/srs/srs_import_entry.dart' show srsImportReportLines;
import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 快照失败 → 给人看的一句话。
String srsAnkiSnapshotErrorText(AnkiSnapshotFailure reason) => switch (reason) {
  AnkiSnapshotFailure.missing => t.srs_anki_migrate_error_missing,
  AnkiSnapshotFailure.locked => t.srs_anki_migrate_error_locked,
  AnkiSnapshotFailure.changedDuringCopy => t.srs_anki_migrate_error_changed,
  AnkiSnapshotFailure.corrupt => t.srs_anki_migrate_error_corrupt,
};

/// 当前平台的引导文案。
String srsAnkiMigrationPlatformHint() {
  if (Platform.isAndroid) return t.srs_anki_migrate_android_hint;
  if (Platform.isIOS) return t.srs_anki_migrate_ios_hint;
  return t.srs_anki_migrate_desktop_hint;
}

/// 迁移成功、结果对话框关掉之后的后续步骤（见 [SrsAnkiMigrationPage.onMigrated]）。
typedef SrsAnkiMigrationFollowUp =
    Future<void> Function(BuildContext context, SrsImportReport report);

class SrsAnkiMigrationPage extends ConsumerStatefulWidget {
  const SrsAnkiMigrationPage({super.key, this.onMigrated});

  /// 钩子：每次迁移成功、结果对话框关闭后调用（页面仍在栈上）。留给「检测到旧 Lapis
  /// 笔记类型 → 提示迁移到新 Fushi 卡片模板」这类后续流程接入；本页不实现那套迁移。
  final SrsAnkiMigrationFollowUp? onMigrated;

  @override
  ConsumerState<SrsAnkiMigrationPage> createState() =>
      _SrsAnkiMigrationPageState();
}

class _SrsAnkiMigrationPageState extends ConsumerState<SrsAnkiMigrationPage>
    with WidgetsBindingObserver {
  final bool _canScan = srsAnkiMigrationCanScan(Platform.operatingSystem);
  bool _scanning = true;
  bool _busy = false;

  /// Android 没给「所有文件访问」：AnkiDroid 目录读不了。
  bool _needsAccess = false;
  List<AnkiProfileCandidate> _profiles = const <AnkiProfileCandidate>[];
  List<AnkiDataRoot> _unreadable = const <AnkiDataRoot>[];

  /// 「选文件夹」选过、含多个 profile 的根：重扫时一起扫，不被平台根的结果冲掉。
  final List<AnkiDataRoot> _customRoots = <AnkiDataRoot>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_scan());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 用户常是看到「Anki 正开着」后切出去关 Anki 再回来：回到前台时静默重扫，
  /// 列表里的状态（WAL / 大小 / 修改时刻）跟上磁盘现状。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _scanning || _busy) return;
    srsRunLogged('SrsAnkiMigration.resumeRescan', () => _scan(quiet: true));
  }

  // ---------------------------------------------------------------- 发现

  /// [quiet]：不切到加载态（列表原地刷新，不闪）。
  Future<void> _scan({bool quiet = false}) async {
    if (!_canScan) {
      setState(() => _scanning = false);
      return;
    }
    if (!quiet) setState(() => _scanning = true);
    bool needsAccess = false;
    if (Platform.isAndroid) {
      needsAccess = !await ref
          .read(appProvider)
          .platformServices
          .permission
          .hasExternalStoragePermission();
    }
    AnkiDiscovery found = const AnkiDiscovery(
      profiles: <AnkiProfileCandidate>[],
      unreadableRoots: <AnkiDataRoot>[],
    );
    if (!needsAccess) {
      try {
        found = await discoverAnkiProfiles(<AnkiDataRoot>[
          ...srsAnkiPlatformRoots(),
          ..._customRoots,
        ]);
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsAnkiMigration.scan', e, stack);
      }
    }
    if (!mounted) return;
    setState(() {
      _needsAccess = needsAccess;
      _profiles = found.profiles;
      _unreadable = found.unreadableRoots;
      _scanning = false;
    });
  }

  Future<void> _grantAccess() async {
    await ref.read(appProvider).requestExternalStoragePermissions();
    await _scan();
  }

  Future<void> _pickFolder() async {
    final String? path = await pickRealDirectoryPath(
      context: context,
      appModel: ref.read(appProvider),
      dialogTitle: t.srs_anki_migrate_pick_folder,
    );
    if (path == null || !mounted) return;
    final AnkiDataRoot root = AnkiDataRoot(path, AnkiDataRootKind.custom);
    final AnkiDiscovery found = await discoverAnkiProfiles(<AnkiDataRoot>[
      root,
    ]);
    if (!mounted) return;
    if (found.profiles.isEmpty) {
      FushiToast.show(
        msg: t.srs_anki_migrate_no_collection_in_folder,
        severity: ToastSeverity.warning,
      );
      return;
    }
    if (found.profiles.length == 1) {
      await _migrateCollection(found.profiles.single);
      return;
    }
    // 选的是桌面 Anki 的数据根（多个 profile）：并进列表让用户挑。
    if (!_customRoots.contains(root)) _customRoots.add(root);
    setState(() {
      _profiles = <AnkiProfileCandidate>[
        ...found.profiles,
        for (final AnkiProfileCandidate c in _profiles)
          if (!found.profiles.any(
            (AnkiProfileCandidate f) => f.directory.path == c.directory.path,
          ))
            c,
      ];
    });
  }

  Future<void> _openAnkiDroid() async {
    await LaunchApp.openApp(
      androidPackageName: 'com.ichi2.anki',
      openStore: true,
    );
  }

  // ---------------------------------------------------------------- 迁移

  Future<void> _migrateCollection(AnkiProfileCandidate profile) async {
    if (_busy) return;
    setState(() => _busy = true);
    AnkiCollectionSnapshot? snapshot;
    try {
      try {
        snapshot = await snapshotAnkiCollection(
          collection: profile.collection,
          mediaDir: profile.mediaDir,
          tempParent: await getTemporaryDirectory(),
        );
      } on AnkiSnapshotException catch (e, stack) {
        ErrorLogService.instance.log('SrsAnkiMigration.snapshot', e, stack);
        FushiToast.show(
          msg: srsAnkiSnapshotErrorText(e.reason),
          severity: ToastSeverity.error,
        );
        return;
      }
      if (!mounted) return;
      final AnkiCollectionStats s = snapshot.stats;
      final bool go = await showFushiConfirmDialog(
        context: context,
        title: t.srs_anki_migrate_confirm_title(name: profile.name),
        message: <String>[
          t.srs_anki_migrate_confirm_body(
            notes: s.notes,
            cards: s.cards,
            reviews: s.reviews,
          ),
          if (snapshot.sourceProbablyOpen) t.srs_anki_migrate_open_warning,
        ].join('\n\n'),
        icon: FushiIcons.importFile,
        confirmLabel: t.srs_anki_migrate_start,
        cancelLabel: t.cancel,
      );
      if (!go || !mounted) return;
      // 快照归后台任务所有：任务结束（成功或失败）时由它丢弃，用户中途离开本页也一样。
      final AnkiCollectionSnapshot owned = snapshot;
      snapshot = null;
      await _run(
        SrsAnkiMigrationFromCollection(owned),
        displayName: profile.name,
        cleanup: owned.discard,
      );
    } finally {
      await snapshot?.discard();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: const <String>{'colpkg', 'apkg'},
    );
    if (path == null || !mounted) return;
    final bool go = await showFushiConfirmDialog(
      context: context,
      title: t.srs_anki_migrate,
      message: t.srs_anki_migrate_confirm_file(
        name: File(path).uri.pathSegments.last,
      ),
      icon: FushiIcons.importFile,
      confirmLabel: t.srs_anki_migrate_start,
      cancelLabel: t.cancel,
    );
    if (!go || !mounted) return;
    setState(() => _busy = true);
    try {
      await _run(
        SrsAnkiMigrationFromPackage(File(path)),
        displayName: File(path).uri.pathSegments.last,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 排进后台导入队列（[srsImportControllerProvider]）→ [runSrsAnkiMigration]。
  ///
  /// 用户可以立刻离开本页继续用 app：牌组列表的任务条显示进度，结束时控制器弹全局提示并
  /// 让列表重读。本页还开着时才在结束后补上报告对话框与 [SrsAnkiMigrationPage.onMigrated]。
  /// [cleanup] 由任务在结束后执行（本机集合快照的临时目录）；没排上队时这里直接执行。
  Future<void> _run(
    SrsAnkiMigrationSource source, {
    required String displayName,
    Future<void> Function()? cleanup,
  }) async {
    final SrsDbStore? store = await readSrsStore(ref);
    SrsMediaStore? media;
    try {
      media = await ref.read(srsMediaStoreProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsAnkiMigration.media', e, stack);
    }
    if (store == null || media == null || !mounted) {
      await cleanup?.call();
      if (mounted) {
        FushiToast.show(
          msg: t.srs_action_failed,
          severity: ToastSeverity.error,
        );
      }
      return;
    }
    final SrsMediaStore lockedMedia = media;
    final SrsImportTask task = ref
        .read(srsImportControllerProvider)
        .enqueueJob(
          displayName: displayName,
          job:
              (
                void Function(double progress) onProgress,
                bool Function() shouldStop,
              ) => runSrsAnkiMigration(
                store: store,
                media: lockedMedia,
                source: source,
                onProgress: onProgress,
                shouldStop: shouldStop,
              ),
          cleanup: cleanup,
        );
    FushiToast.show(msg: t.srs_import_background_started);
    SrsImportReport? report;
    Object? failure;
    try {
      report = await task.result;
    } catch (e) {
      // 控制器已记日志并弹过全局失败提示；这里只补详细原因。
      failure = e;
    }
    // 排队时被用户在任务条上取消：没写过库，也不是失败，不弹原因框。
    if (!mounted || failure is SrsImportCancelledException) return;
    if (failure != null) {
      await showFushiConfirmDialog(
        context: context,
        title: t.srs_anki_migrate,
        message:
            failure is SrsImportException &&
                failure.code == SrsImportException.needsKernel
            ? t.srs_import_needs_kernel
            : t.srs_import_failed(
                error: failure is SrsImportException
                    ? failure.message
                    : '$failure',
              ),
        icon: FushiIcons.error,
        confirmLabel: t.dialog_ok,
        cancelLabel: t.cancel,
      );
      return;
    }
    final SrsImportReport done = report!;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => FushiAlertDialog(
        icon: const FushiDialogHeroIcon(icon: FushiIcons.success),
        title: Text(t.srs_import_report_title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String line in srsImportReportLines(done))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          FushiDialogAction(
            label: t.dialog_ok,
            kind: FushiDialogActionKind.primary,
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
    final SrsAnkiMigrationFollowUp? followUp = widget.onMigrated;
    if (followUp != null && mounted) await followUp(context, done);
  }

  // ---------------------------------------------------------------- 界面

  List<FushiToolbarItem> get _actions => <FushiToolbarItem>[
    if (_canScan)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_anki_migrate_rescan'),
        icon: FushiIcons.refresh,
        label: t.srs_anki_migrate_rescan,
        onPressed: _busy || _scanning
            ? null
            : () => srsRunLogged('SrsAnkiMigration.rescan', _scan),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_anki_migrate,
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
        title: t.srs_anki_migrate,
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

  Widget _gap(FushiDesignTokens tokens) => SizedBox(height: tokens.spacing.gap);

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<Widget> items = <Widget>[
      Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
        child: Text(t.srs_anki_migrate_intro, style: text.bodyLarge),
      ),
      _gap(tokens),
      FushiInlineNotice(
        key: const ValueKey<String>('srs-anki-migrate-hint'),
        message: srsAnkiMigrationPlatformHint(),
      ),
      _gap(tokens),
      FushiInlineNotice(
        key: const ValueKey<String>('srs-anki-migrate-scope'),
        icon: FushiIcons.checklist,
        message: t.srs_anki_migrate_scope,
      ),
      if (_busy)
        Padding(
          padding: EdgeInsets.only(top: tokens.spacing.gap),
          child: const FushiLinearProgressIndicator(),
        ),
      if (_canScan) ..._buildFound(context, tokens, text),
      Padding(
        padding: EdgeInsets.only(top: tokens.spacing.section),
        child: _buildOtherWays(),
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

  List<Widget> _buildFound(
    BuildContext context,
    FushiDesignTokens tokens,
    TextTheme text,
  ) => <Widget>[
    Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap,
        tokens.spacing.section,
        tokens.spacing.gap,
        tokens.spacing.gap,
      ),
      child: Text(t.srs_anki_migrate_found, style: text.titleSmall),
    ),
    if (_scanning)
      FushiLoadingView(compact: true, message: t.srs_anki_migrate_scanning)
    else if (_needsAccess)
      FushiInlineNotice(
        key: const ValueKey<String>('srs-anki-migrate-access'),
        severity: FushiNoticeSeverity.warning,
        icon: FushiIcons.lock,
        message: t.srs_anki_migrate_grant_access,
        actions: <Widget>[
          FushiTextButton(
            key: const ValueKey<String>('srs-anki-migrate-grant'),
            onPressed: _busy
                ? null
                : () => srsRunLogged('SrsAnkiMigration.grant', _grantAccess),
            child: Text(t.srs_anki_migrate_grant_access),
          ),
        ],
      )
    else if (_profiles.isEmpty)
      Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          message: t.srs_anki_migrate_none_found,
        ),
      )
    else
      for (int i = 0; i < _profiles.length; i++)
        _ProfileRow(
          key: ValueKey<String>(
            'srs-anki-profile-${_profiles[i].directory.path}',
          ),
          profile: _profiles[i],
          index: i,
          count: _profiles.length,
          enabled: !_busy,
          onTap: () => srsRunLogged(
            'SrsAnkiMigration.collection',
            () => _migrateCollection(_profiles[i]),
          ),
        ),
    if (_unreadable.isNotEmpty)
      Padding(
        padding: EdgeInsets.only(top: tokens.spacing.gap),
        child: FushiInlineNotice(
          severity: FushiNoticeSeverity.warning,
          message: t.srs_anki_migrate_unreadable(
            paths: _unreadable.map((AnkiDataRoot r) => r.path).join(', '),
          ),
        ),
      ),
  ];

  Widget _buildOtherWays() => AdaptiveSettingsSection(
    title: t.srs_anki_migrate_other_ways,
    children: <Widget>[
      AdaptiveSettingsNavigationRow(
        key: const ValueKey<String>('srs_anki_migrate_pick_file'),
        title: t.srs_anki_migrate_pick_file,
        icon: FushiIcons.importFile,
        showIcon: true,
        onTap: () {
          if (_busy) return;
          srsRunLogged('SrsAnkiMigration.file', _pickFile);
        },
      ),
      if (_canScan)
        AdaptiveSettingsNavigationRow(
          key: const ValueKey<String>('srs_anki_migrate_pick_folder'),
          title: t.srs_anki_migrate_pick_folder,
          icon: FushiIcons.folderOpen,
          showIcon: true,
          onTap: () {
            if (_busy) return;
            srsRunLogged('SrsAnkiMigration.folder', _pickFolder);
          },
        ),
      if (Platform.isAndroid)
        AdaptiveSettingsNavigationRow(
          key: const ValueKey<String>('srs_anki_migrate_open_ankidroid'),
          title: t.srs_anki_migrate_open_ankidroid,
          icon: FushiIcons.openInNew,
          showIcon: true,
          onTap: () =>
              srsRunLogged('SrsAnkiMigration.openAnkiDroid', _openAnkiDroid),
        ),
    ],
  );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    super.key,
    required this.profile,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onTap,
  });

  final AnkiProfileCandidate profile;
  final int index;
  final int count;
  final bool enabled;
  final VoidCallback onTap;

  String get _kindLabel => switch (profile.kind) {
    AnkiDataRootKind.desktop => 'Anki',
    AnkiDataRootKind.ankiDroid => 'AnkiDroid',
    AnkiDataRootKind.custom => t.srs_anki_migrate_kind_folder,
  };

  @override
  Widget build(BuildContext context) => FushiPressScale(
    child: FushiGroupedListItem(
      index: index,
      count: count,
      onTap: enabled ? onTap : null,
      child: FushiListItem(
        density: srsListDensityOf(context),
        leading: FushiListLeadingIcon(switch (profile.kind) {
          AnkiDataRootKind.desktop => FushiIcons.laptop,
          AnkiDataRootKind.ankiDroid => FushiIcons.phone,
          AnkiDataRootKind.custom => FushiIcons.folder,
        }, tone: FushiCardTone.primary),
        title: Text(profile.name),
        subtitle: SrsMetaLine(<String>[
          _kindLabel,
          ...SrsMetaLine.split(
            t.srs_anki_migrate_profile_meta(
              size: FushiByteFormat.bytes(
                profile.collectionBytes + profile.walBytes,
              ),
              time: srsBackupTimeLabel(context, profile.modified),
            ),
          ),
        ]),
        trailing: profile.probablyOpen
            ? FushiTooltip(
                message: t.srs_anki_migrate_open_warning,
                child: const FushiIcon(FushiIcons.warning),
              )
            : const FushiIcon(FushiIcons.chevronRight),
      ),
    ),
  );
}
