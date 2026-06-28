// TODO-935 E2/E3: 桌面端「数据存储位置」设置项 —— 显示当前数据根、选新目录、触发
// 已实现的 DataRootMigrator 整目录迁移、迁移成功后自动重启。仅桌面有效（移动端沙箱
// 固定，整个 section 在 sync_settings_schema.dart 里用 isDesktopPlatform 门控隐藏）。
part of '../sync_settings_schema.dart';

/// 迁移触发前的纯校验：用户挑的新目录是否是一个可接受的迁移目标。把判定从 UI 抽出
/// 来便于单测（真正的搬移/回滚仍由 [DataRootMigrator] 负责，它内部还会再做一次更严
/// 的校验 + 失败回滚）。返回 null 表示可接受；否则返回一个枚举原因，UI 据此选文案。
enum DataRootTargetRejection {
  /// 新目录等于（或位于）当前 documents/support 根：自我迁移，拒绝。
  insideCurrentRoot,

  /// 目标已派生出非空的 documents/support 子树：不覆盖已有数据。
  targetNotEmpty,
}

/// 纯函数：在不触碰文件系统搬移的前提下判断 [newDataRoot] 是否可作为迁移目标。
/// [existsAndHasFiles] 注入目录是否存在且含文件的判定（生产传真实 FS 探测，测试传
/// 桩），保持本函数无 IO 依赖、可纯测。
DataRootTargetRejection? validateDataRootTarget({
  required String newDataRoot,
  required String oldDocumentsRoot,
  required String oldSupportRoot,
  required bool Function(String absolutePath) existsAndHasFiles,
}) {
  final String canonNew = p.canonicalize(newDataRoot);
  final String canonDocs = p.canonicalize(oldDocumentsRoot);
  final String canonSupport = p.canonicalize(oldSupportRoot);
  if (canonNew == canonDocs ||
      canonNew == canonSupport ||
      p.isWithin(canonDocs, canonNew) ||
      p.isWithin(canonSupport, canonNew)) {
    return DataRootTargetRejection.insideCurrentRoot;
  }
  final (Directory docs, Directory support) =
      AppPaths.rootsForDataRoot(newDataRoot);
  if (existsAndHasFiles(docs.path) || existsAndHasFiles(support.path)) {
    return DataRootTargetRejection.targetNotEmpty;
  }
  return null;
}

/// 设置行：显示当前数据根 + 更改位置按钮。仅桌面构造（section 已门控）。
class _DataRootWidget extends StatefulWidget {
  const _DataRootWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_DataRootWidget> createState() => _DataRootWidgetState();
}

class _DataRootWidgetState extends State<_DataRootWidget> {
  bool _migrating = false;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((SharedPreferences sp) {
      if (mounted) setState(() => _prefs = sp);
    });
  }

  /// 当前数据根展示串：有自定义 data_root（存在）显示其绝对路径，否则显示默认位置 +
  /// 真实路径。data_root pref 是 DB 外通道，启动早期即可读，故优先用它判定；只有展示
  /// 默认位置的真实路径时才去读 appDirectory（late 字段），并对其未初始化兜底（早期
  /// 设置页 / 测试夹具里 AppModel 可能尚未跑完 _prepareRuntimeDirectories）。
  String _currentLocationLabel() {
    final String? custom = _prefs?.getString(AppPaths.dataRootPrefKey);
    if (custom != null && custom.trim().isNotEmpty) {
      return custom;
    }
    final AppModel appModel = widget.settingsContext.appModel;
    String? defaultRootPath;
    try {
      // appDirectory 是 documents 根；默认根时其父目录即平台数据目录，展示更直观。
      defaultRootPath = appModel.appDirectory.parent.path;
    } on Error {
      defaultRootPath = null; // late 未初始化 → 只显示「默认位置」不带路径。
    }
    return defaultRootPath == null
        ? t.data_storage_location_default
        : '${t.data_storage_location_default} - $defaultRootPath';
  }

  Future<void> _changeLocation() async {
    // 再入保护：行 Activate（A/Enter）和 trailing 按钮都进这里，迁移中忽略二次触发。
    if (_migrating) return;

    final String? picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t.data_storage_change_button,
    );
    if (picked == null || picked.isEmpty || !mounted) return;

    final AppModel appModel = widget.settingsContext.appModel;
    final String oldDocs = appModel.appDirectory.path;
    final String oldSupport = appModel.databaseDirectory.path;

    // 触发前纯校验：自我迁移 / 目标非空，直接报错，不进确认弹窗。
    final DataRootTargetRejection? rejection = validateDataRootTarget(
      newDataRoot: picked,
      oldDocumentsRoot: oldDocs,
      oldSupportRoot: oldSupport,
      existsAndHasFiles: _dirExistsAndHasFiles,
    );
    if (rejection != null) {
      if (mounted) {
        _showSnackBar(context, _rejectionMessage(rejection));
      }
      return;
    }

    final bool confirmed = await _confirmMigrate();
    if (!confirmed || !mounted) return;

    setState(() => _migrating = true);
    try {
      final DataRootMigrationRequest req = DataRootMigrationRequest(
        oldDocumentsRoot: Directory(oldDocs),
        oldSupportRoot: Directory(oldSupport),
        newDataRoot: picked,
        closeResources: () => _closeRuntimeResources(appModel),
        writeDataRootPref: (String newRoot) async {
          final SharedPreferences sp = await SharedPreferences.getInstance();
          await sp.setString(AppPaths.dataRootPrefKey, newRoot);
        },
      );
      await const DataRootMigrator().migrate(req);

      // 迁移成功，自动重启（仅桌面，supportsRestart=true）。重启会拉新进程并退出本
      // 进程，下面的代码通常不会执行到；restartApp 抛错（Process.start 失败）才落到
      // catch 的降级提示。
      if (mounted) {
        _showSnackBar(context, t.data_storage_migrate_success);
      }
      await _restartOrPromptManual(appModel);
    } on DataRootMigrationException catch (e) {
      // 迁移失败：旧数据已由引擎完整回滚保留、未写 pref、不重启。
      if (mounted) {
        _showSnackBar(
          context,
          t.data_storage_migrate_failed(message: e.message),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          context,
          t.data_storage_migrate_failed(message: e.toString()),
        );
      }
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  /// 注入给迁移引擎的真实资源关闭：停音频，关词典 FFI，checkpoint+关 DB，确保
  /// Windows 上文件锁释放、整目录可被 rename/搬移。顺序与 main.dart 退出闸门一致，
  /// 额外补上音频与 FFI（退出闸门没做这两步）。
  static Future<void> _closeRuntimeResources(AppModel appModel) async {
    // 1) 停音频句柄（just_audio / AudiobookPlayerController）。
    try {
      await appModel.audiobookSession.stop();
    } catch (e) {
      debugPrint(
          'DataRoot migrate: audiobookSession.stop failed (best-effort): $e');
    }
    try {
      await appModel.audioHandler?.stop();
    } catch (e) {
      debugPrint(
          'DataRoot migrate: audioHandler.stop failed (best-effort): $e');
    }
    // 2) 释放词典 FFI 原生句柄（静态单例）。
    HoshiDicts.disposeInstance();
    // 3) WAL checkpoint(TRUNCATE) 落盘 + 关 DB（释放文件锁）。
    try {
      await appModel.database
          .customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      // best-effort：checkpoint 失败不致命，下面的 closeDatabase 仍会落盘+关库。
      debugPrint('DataRoot migrate: wal_checkpoint failed (best-effort): $e');
    }
    await appModel.closeDatabase();
  }

  /// 迁移成功后自动重启；不支持或失败提示用户手动重开。
  static Future<void> _restartOrPromptManualImpl(
    AppModel appModel,
    void Function(String message) onRestartFailed,
  ) async {
    final PlatformLifecycleService lifecycle =
        appModel.platformServices.lifecycle;
    if (!lifecycle.supportsRestart) {
      onRestartFailed(t.data_storage_restart_failed);
      return;
    }
    try {
      await lifecycle.restartApp();
    } catch (e) {
      // 重启起新进程失败（Process.start 抛错）→ 降级提示用户手动重开。
      debugPrint('DataRoot migrate: restartApp failed: $e');
      onRestartFailed(t.data_storage_restart_failed);
    }
  }

  Future<void> _restartOrPromptManual(AppModel appModel) =>
      _restartOrPromptManualImpl(appModel, (String message) {
        if (mounted) _showSnackBar(context, message);
      });

  Future<bool> _confirmMigrate() async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 420,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.data_storage_change_confirm_title,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            body: Text(t.data_storage_change_confirm_body),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.dialog_ok),
                ),
              ],
            ),
          ),
        );
      },
    );
    return confirmed == true;
  }

  String _rejectionMessage(DataRootTargetRejection rejection) {
    // 两种拒绝都是目标不合法，复用迁移失败文案承载具体原因（引擎也会再拒一次）。
    switch (rejection) {
      case DataRootTargetRejection.insideCurrentRoot:
        return t.data_storage_migrate_failed(
            message: t.data_storage_change_confirm_title);
      case DataRootTargetRejection.targetNotEmpty:
        return t.data_storage_migrate_failed(
            message: t.data_storage_location_hint);
    }
  }

  static bool _dirExistsAndHasFiles(String absolutePath) {
    final Directory dir = Directory(absolutePath);
    if (!dir.existsSync()) return false;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: t.data_storage_location_title,
      subtitle: _migrating
          ? t.data_storage_migrating
          : '${t.data_storage_location_hint}${t.settings_experimental_suffix}\n${_currentLocationLabel()}',
      icon: Icons.folder_special_outlined,
      controlBelow: true,
      // 行 onTap 注册焦点目标（方向导航可达）；trailing 按钮是视觉入口。
      onTap: _changeLocation,
      trailing: _migrating
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 20,
                  height: 20,
                  child: adaptiveIndicator(context: context, strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(t.data_storage_migrating),
              ],
            )
          : FilledButton.tonal(
              onPressed: _changeLocation,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.drive_folder_upload_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(t.data_storage_change_button),
                ],
              ),
            ),
    );
  }
}
