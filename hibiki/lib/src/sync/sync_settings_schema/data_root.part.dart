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

  /// TODO-1182：目标是应用安装目录（含正在运行的 exe）或其祖先目录：拒绝（否则迁移失败
  /// 回滚会试图删掉含运行程序的整个安装目录，删不掉、留半状态）。
  containsExecutable,
}

/// 纯函数：在不触碰文件系统搬移的前提下判断 [newDataRoot] 是否可作为迁移目标。
/// [existsAndHasFiles] 注入目录是否存在且含文件的判定（生产传真实 FS 探测，测试传
/// 桩），保持本函数无 IO 依赖、可纯测。
DataRootTargetRejection? validateDataRootTarget({
  required String newDataRoot,
  required String oldDocumentsRoot,
  required String oldSupportRoot,
  required bool Function(String absolutePath) existsAndHasFiles,
  String? executablePath,
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
  // TODO-1182：拒绝安装目录（含正在运行的 exe）及其祖先目录。`isWithin(newRoot, exe)` 为真
  // 即 exe 落在 newRoot 内 → newRoot 是 exe 所在目录或其祖先。生产传 Platform.resolvedExecutable。
  if (executablePath != null && executablePath.trim().isNotEmpty) {
    if (p.isWithin(canonNew, p.canonicalize(executablePath))) {
      return DataRootTargetRejection.containsExecutable;
    }
  }
  final (Directory docs, Directory support) =
      AppPaths.rootsForDataRoot(newDataRoot);
  if (existsAndHasFiles(docs.path) || existsAndHasFiles(support.path)) {
    return DataRootTargetRejection.targetNotEmpty;
  }
  return null;
}

/// TODO-1182：迁移失败视图「重启」按钮触发的重启。桌面 `supportsRestart==true` → 拉新进程
/// 回到**未改变**的旧根重新初始化（pref 未写、数据已回滚）；不支持/失败则退出让用户手动重开
/// （数据安全，仅需重启）。抽成顶层函数供 `main.dart` 注入为失败视图 `onRestart`。
void dataRootMigrationRestart(AppModel appModel) {
  final PlatformLifecycleService lifecycle =
      appModel.platformServices.lifecycle;
  if (lifecycle.supportsRestart) {
    lifecycle.restartApp().catchError((Object e) {
      debugPrint('DataRoot migrate: 失败视图重启也失败: $e');
      _exitDataRootMigrationProcess();
    });
    return;
  }
  _exitDataRootMigrationProcess();
}

void _exitDataRootMigrationProcess() {
  if (Platform.isAndroid || Platform.isIOS) {
    FlutterExitApp.exitApp();
  } else {
    exit(0);
  }
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
      executablePath: Platform.resolvedExecutable,
    );
    if (rejection != null) {
      if (mounted) {
        _showSnackBar(context, _rejectionMessage(rejection));
      }
      return;
    }

    final bool confirmed = await _confirmMigrate();
    if (!confirmed || !mounted) return;

    final String? macOSBookmark;
    try {
      macOSBookmark = await MacOSDataRootAccess.createBookmarkForPath(picked);
    } catch (e, stack) {
      ErrorLogService.instance
          .logFatal('DataRootMigration.createBookmark', e, stack);
      if (mounted) {
        _showSnackBar(
          context,
          t.data_storage_migrate_failed(message: e.toString()),
        );
      }
      return;
    }

    setState(() => _migrating = true);
    // TODO-959: 先把全屏迁移遮罩顶上来，再让引擎 closeResources（含 closeDatabase 置
    // isInitialised=false）。这样 DB 关闭引发的根 widget rebuild 命中迁移遮罩分支，而不
    // 是裸 loading 近黑屏。顺序铁律：beginDataRootMigration（遮罩上屏）→ migrate（内部
    // 先 closeResources 关 DB 释放文件锁，再搬文件）。
    appModel.beginDataRootMigration();
    try {
      final DataRootMigrationRequest req = DataRootMigrationRequest(
        oldDocumentsRoot: Directory(oldDocs),
        oldSupportRoot: Directory(oldSupport),
        newDataRoot: picked,
        closeResources: () => _closeRuntimeResources(appModel),
        writeDataRootPref: (String newRoot) async {
          final SharedPreferences sp = await SharedPreferences.getInstance();
          final String? previousBookmark =
              sp.getString(MacOSDataRootAccess.dataRootBookmarkPrefKey);
          final bool bookmarkStored =
              await MacOSDataRootAccess.storeBookmark(sp, macOSBookmark);
          if (!bookmarkStored) {
            throw const DataRootMigrationException('写入 macOS 数据根授权失败');
          }
          try {
            final bool rootStored =
                await sp.setString(AppPaths.dataRootPrefKey, newRoot);
            if (!rootStored) {
              throw const DataRootMigrationException('写入新数据根设置失败');
            }
          } catch (e) {
            final bool bookmarkRestored =
                await MacOSDataRootAccess.restoreBookmark(sp, previousBookmark);
            if (!bookmarkRestored) {
              throw DataRootMigrationException(
                '写入新数据根设置失败，且恢复旧授权失败',
                cause: e,
              );
            }
            throw DataRootMigrationException('写入新数据根设置失败', cause: e);
          }
        },
        // 跨盘复制进度回灌到遮罩进度条（同盘 rename 不触发，遮罩显示不确定进度）。
        onProgress: (int copied, int total) =>
            appModel.updateDataRootMigrationProgress(copied, total),
        // TODO-1182：引擎据此二次拒绝安装目录/exe 目录，回滚也绝不删含运行 exe 的根。
        resolvedExecutablePath: Platform.resolvedExecutable,
      );
      await const DataRootMigrator().migrate(req);

      // 迁移成功，自动重启（仅桌面，supportsRestart=true）。重启会拉新进程并退出本
      // 进程，下面的代码通常不会执行到；restartApp 抛错（Process.start 失败）才落到
      // catch 的降级提示。
      if (mounted) {
        _showSnackBar(context, t.data_storage_migrate_success);
      }
      await _restartOrPromptManual(appModel);
    } on DataRootMigrationException catch (e, stack) {
      // 迁移失败：旧数据已由引擎完整回滚保留、未写 pref。但 closeResources 在搬移前就
      // 已关掉 DB（_isInitialised=false），本进程无法原地恢复 → 重启回到**未改变**的
      // 旧根（pref 没写，新进程仍解析到旧位置，干净重新初始化）。
      ErrorLogService.instance.logFatal('DataRootMigration.migrate', e, stack);
      await _recoverAfterFailedMigration(
        appModel,
        t.data_storage_migrate_failed(message: e.message),
      );
    } catch (e, stack) {
      ErrorLogService.instance.logFatal('DataRootMigration.migrate', e, stack);
      await _recoverAfterFailedMigration(
        appModel,
        t.data_storage_migrate_failed(message: e.toString()),
      );
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  /// TODO-1182：迁移失败 → 切到**失败态遮罩**（原因 + 建议 + 重启按钮），由根 widget 渲染。
  /// **不**在这里直接重启：旧实现桌面 supportsRestart=true 时立刻 `restartApp()`，用户永远
  /// 看不到失败原因（「换数据位置不生效且无提示」根因之一）。而且迁移期间根 widget 树已被
  /// 换成迁移遮罩，本设置页 State 已 unmount（`mounted==false`），旧的 `_showSnackBar` 也
  /// 从不触发。closeResources 已在搬移前关 DB，本进程无法原地恢复 → 保持遮罩激活（撤了会落
  /// 到裸 loading），由用户在失败视图点「重启」回到未改变的旧根重新初始化（数据已由引擎完整
  /// 回滚保留、pref 未写）。
  Future<void> _recoverAfterFailedMigration(
    AppModel appModel,
    String failureMessage,
  ) async {
    appModel.failDataRootMigration(failureMessage);
  }

  /// 注入给迁移引擎的真实资源关闭：停音频（含 media_kit/libmpv 对数据根内音频文件的
  /// 句柄）、清 Flutter 图片缓存、关词典 FFI、checkpoint+关 DB，确保 Windows 上数据根
  /// 子树里的文件句柄尽量释放、整目录可被 rename/搬移。顺序与 main.dart 退出闸门一致，
  /// 额外补上音频、图片缓存与 FFI（退出闸门没做这几步）。
  ///
  /// 关于 WebView2：常驻热 WebView2 的 user-data 目录在数据根**之外**（进程默认基于
  /// exe 名的目录 + 应用外查词覆盖窗的 `%LOCALAPPDATA%\Hibiki\GlobalLookupWebView2`，
  /// 见 `windows/runner/global_lookup_window.cpp`），不落在被迁移的 documents/support
  /// 子树里，故 dispose 它对释放数据根文件锁无意义、此处不做（避免无效的连带拆引擎）。
  /// 真正压在数据根子树上的句柄是：正在播放的音频/视频文件（media_kit/libmpv）、封面/
  /// 缩略图解码、词典索引/资源、DB 及 local_audio_*.db。
  static Future<void> _closeRuntimeResources(AppModel appModel) async {
    // 1) 停音频句柄（just_audio / AudiobookPlayerController；桌面经 just_audio_media_kit
    //    → libmpv 打开数据根内的音频文件，未停会锁住 rename/删源）。
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
    // 2) 清 Flutter 图片缓存：释放封面/缩略图解码持有的解码资源。FileImage 通常读完
    //    即关句柄，此处更多是防御性清理（活图连带 clearLiveImages），成本极低。
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    } catch (e) {
      debugPrint('DataRoot migrate: imageCache clear failed (best-effort): $e');
    }
    // 3) 释放词典 FFI 原生句柄（静态单例；打开数据根内的词典索引/资源文件）。
    HoshiDicts.disposeInstance();
    // 4) WAL checkpoint(TRUNCATE) 落盘 + 关 DB（释放文件锁）。
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
      case DataRootTargetRejection.containsExecutable:
        return t.data_storage_reject_install_dir;
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
