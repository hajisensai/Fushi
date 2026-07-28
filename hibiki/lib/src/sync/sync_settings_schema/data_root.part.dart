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

/// 纯函数：在不触碰文件系统搬移的前提下判断 [target] 是否可作为迁移目标。
/// [existsAndHasFiles] 注入目录是否存在且含文件的判定（生产传真实 FS 探测，测试传
/// 桩），保持本函数无 IO 依赖、可纯测。
///
/// BUG-1115：[sharedDocumentsRoot] 为真表示 [oldDocumentsRoot] 是**共享**的平台
/// `Documents`（老安装的扁平布局）。此时迁移是白名单选择性搬移，把新根设在它下面的一个
/// 非白名单子目录（典型：`Documents\Hibiki`，即用户把散落的 16 个目录收进自己的子目录）
/// 是安全的，不再按 [DataRootTargetRejection.insideCurrentRoot] 一刀切拒绝。
DataRootTargetRejection? validateDataRootTarget({
  required DataRootMigrationTarget target,
  required String oldDocumentsRoot,
  required String oldSupportRoot,
  required bool Function(String absolutePath) existsAndHasFiles,
  String? executablePath,
  bool sharedDocumentsRoot = false,
}) {
  final String canonNew = p.canonicalize(target.pickedPath);
  final String canonDocs = p.canonicalize(oldDocumentsRoot);
  final String canonSupport = p.canonicalize(oldSupportRoot);
  final bool nestedInSharedDocuments = sharedDocumentsRoot &&
      AppPaths.isSafeNestedTargetInSharedDocuments(
        sharedDocumentsRoot: oldDocumentsRoot,
        newDataRoot: target.pickedPath,
      );
  if (canonNew == canonDocs ||
      canonNew == canonSupport ||
      (p.isWithin(canonDocs, canonNew) && !nestedInSharedDocuments) ||
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
  if (existsAndHasFiles(target.documentsRoot.path)) {
    return DataRootTargetRejection.targetNotEmpty;
  }
  // BUG-1188：默认位置的 support 根就是平台固定落点——里面必然躺着
  // `shared_preferences.json`（它刻意不参与搬移），甚至就是当前 support 根本身。这里这个
  // 粗粒度预检不认识 prefs 文件族，一检必误报，故交给引擎的 prefs-aware 校验
  // （`DataRootMigrator._validateTarget`，会忽略顶层 prefs、但仍拒绝任何别的残留）。
  if (!target.isDefaultLocation && existsAndHasFiles(target.supportRoot.path)) {
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

  /// 当前数据根展示串：有自定义 data_root（存在）显示其绝对路径，否则直接显示默认根的
  /// 真实路径（不再加「默认位置」前缀）。data_root pref 是 DB 外通道，启动早期即可读，
  /// 故优先用它判定；只有展示默认根真实路径时才去读 appDirectory（late 字段），并对其未
  /// 初始化兜底（早期设置页 / 测试夹具里 AppModel 可能尚未跑完 _prepareRuntimeDirectories），
  /// 兜底时才回退到「默认位置」标签。
  String _currentLocationLabel() {
    final String? custom = _prefs?.getString(AppPaths.dataRootPrefKey);
    if (custom != null && custom.trim().isNotEmpty) {
      return custom;
    }
    final AppModel appModel = widget.settingsContext.appModel;
    String? defaultRootPath;
    try {
      // BUG-1115：显示 documents 根**本身**（内容真正落的地方）。旧实现显示它的父目录，
      // 那在扁平老布局下是用户主目录（`C:\Users\<name>`，根本不是数据位置），在
      // `<Documents>/Hibiki/data` 新布局下则是导出目录 `Hibiki` —— 两种都误导。
      defaultRootPath = appModel.appDirectory.path;
    } on Error {
      defaultRootPath = null; // late 未初始化 → 只显示「默认位置」不带路径。
    }
    // TODO-1211：直接显示实际路径，不再加「默认位置」前缀；仅 late 未初始化的
    // 罕见边界回退到标签。
    return defaultRootPath ?? t.data_storage_location_default;
  }

  Future<void> _changeLocation() async {
    // 再入保护：行 Activate（A/Enter）和 trailing 按钮都进这里，迁移中忽略二次触发。
    if (_migrating) return;

    // 数据根是整个 app 长期读写的落点，必须是真实文件系统路径（见
    // pickRealDirectoryPath）——content URI 串迁过去等于把库搬进一个读不回来的地方。
    final String? picked = await pickRealDirectoryPath(
      context: context,
      appModel: widget.settingsContext.appModel,
      dialogTitle: t.data_storage_change_button,
    );
    if (picked == null || picked.isEmpty || !mounted) return;

    final AppModel appModel = widget.settingsContext.appModel;
    final String oldDocs = appModel.appDirectory.path;
    final String oldSupport = appModel.databaseDirectory.path;

    // TODO-1226：判定旧 documents 根是否就是**共享的平台 Documents**（老安装的扁平布局）。
    // 不看 data_root pref（pref 存了失效路径时 AppPaths 仍回退默认根，此时按 pref 判
    // 会把共享 Documents 误当专属根整树搬走）——直接与平台 Documents 实路径比对。
    // 探测失败按共享处理：宁可少搬（白名单），绝不整搬/整删共享目录。
    //
    // BUG-1115：这个判定必须在**校验之前**拿到——共享根下的非白名单子目录
    // （`Documents\Hibiki`）是合法目标，校验要据此放行。
    bool sharedDocumentsRoot;
    try {
      final Directory platformDocuments =
          await getApplicationDocumentsDirectory();
      sharedDocumentsRoot = p.equals(oldDocs, platformDocuments.path);
    } catch (_) {
      sharedDocumentsRoot = true;
    }
    // BUG-1188：把用户挑的目录解析成迁移目标。挑中默认位置（`<Documents>\Hibiki` 或
    // `<Documents>\Hibiki\data`）时归一化成「与全新安装同形」：documents 根落
    // `<Documents>\Hibiki\data`、DB 留在平台固定落点。旧实现无条件按 `<picked>/documents`
    // + `<picked>/support` 派生，用户照文档指引整理完就得到第三种布局（DB 还被拖进文档目录）。
    final DataRootMigrationTarget target;
    try {
      final Directory defaultDocs =
          await AppPaths.defaultLocationDocumentsRoot();
      final Directory platformSupport = await getApplicationSupportDirectory();
      target = resolveDataRootMigrationTarget(
        pickedRoot: picked,
        defaultDocumentsRoot: defaultDocs.path,
        platformSupportRoot: platformSupport.path,
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .logFatal('DataRootMigration.resolveTarget', e, stack);
      if (mounted) {
        _showSnackBar(
          context,
          t.data_storage_migrate_failed(message: e.toString()),
        );
      }
      return;
    }
    if (!mounted) return;

    // 触发前纯校验：自我迁移 / 目标非空，直接报错，不进确认弹窗。
    final DataRootTargetRejection? rejection = validateDataRootTarget(
      target: target,
      oldDocumentsRoot: oldDocs,
      oldSupportRoot: oldSupport,
      existsAndHasFiles: _dirExistsAndHasFiles,
      executablePath: Platform.resolvedExecutable,
      sharedDocumentsRoot: sharedDocumentsRoot,
    );
    if (rejection != null) {
      if (mounted) {
        _showSnackBar(context, _rejectionMessage(rejection));
      }
      return;
    }

    final bool confirmed = await _confirmMigrate(target);
    if (!confirmed || !mounted) return;

    // 默认位置不需要 macOS 安全域书签（平台固定落点 + 应用自己的 Documents 容器，沙箱本就
    // 可访问）；提交时反而要把可能存在的旧书签清掉。
    final String? macOSBookmark;
    try {
      macOSBookmark = target.isDefaultLocation
          ? null
          : await MacOSDataRootAccess.createBookmarkForPath(picked);
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
        target: target,
        closeResources: () => _closeRuntimeResources(appModel),
        commitLocation: (DataRootMigrationTarget t) async {
          final SharedPreferences sp = await SharedPreferences.getInstance();
          if (t.isDefaultLocation) {
            await _commitDefaultLocation(sp);
            return;
          }
          await _commitCustomRoot(sp, t.dataRootPrefValue!, macOSBookmark);
        },
        // 跨盘复制进度回灌到遮罩进度条（同盘 rename 不触发，遮罩显示不确定进度）。
        onProgress: (int copied, int total) =>
            appModel.updateDataRootMigrationProgress(copied, total),
        // TODO-1182：引擎据此二次拒绝安装目录/exe 目录，回滚也绝不删含运行 exe 的根。
        resolvedExecutablePath: Platform.resolvedExecutable,
        // TODO-1226：默认根 = 共享用户 Documents → 只搬 Hibiki 自有顶层项白名单，
        // 且迁移引擎绝不删除 Documents 本体；自定义专属根（<root>/documents）→ 整树。
        documentsTopLevelIncludeNames:
            sharedDocumentsRoot ? AppPaths.hibikiOwnedDocumentsEntries : null,
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

  /// 自定义数据根的提交：存 macOS 安全域书签 + 写 `data_root`。任一步失败复原旧书签并抛错
  /// （引擎据此整次回滚）。行为与 BUG-1188 之前逐字节一致。
  static Future<void> _commitCustomRoot(
    SharedPreferences sp,
    String newRoot,
    String? macOSBookmark,
  ) async {
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
  }

  /// BUG-1188：归一化到**默认位置**的提交：把 `documents_layout` 锚成 nested、清掉
  /// `data_root` 与 macOS 书签。
  ///
  /// 两个键必须**同时**生效，否则下次启动必然解析到错误的根：
  ///  - 只锚 nested、`data_root` 还在 ⇒ 仍走自定义根分支，指向已经搬空的旧根。
  ///  - 只清 `data_root`、锚点还是 `flat` ⇒ documents 根解析回共享 `Documents`，而数据
  ///    已经在 `Hibiki/data` 里 = 书库/有声书/词典资源在 UI 上集体消失。
  /// 故任一步失败就把已改的键全部复原并抛错，由引擎回滚整次迁移。
  static Future<void> _commitDefaultLocation(SharedPreferences sp) async {
    final String? previousLayout =
        sp.getString(AppPaths.documentsLayoutPrefKey);
    final String? previousRoot = sp.getString(AppPaths.dataRootPrefKey);
    final String? previousBookmark =
        sp.getString(MacOSDataRootAccess.dataRootBookmarkPrefKey);
    if (!await sp.setString(
        AppPaths.documentsLayoutPrefKey, AppPaths.documentsLayoutNested)) {
      throw const DataRootMigrationException('写入数据位置布局设置失败');
    }
    try {
      if (!await sp.remove(AppPaths.dataRootPrefKey)) {
        throw const DataRootMigrationException('清除自定义数据根设置失败');
      }
      if (!await MacOSDataRootAccess.restoreBookmark(sp, null)) {
        throw const DataRootMigrationException('清除 macOS 数据根授权失败');
      }
    } catch (e) {
      await _restorePrefString(
          sp, AppPaths.documentsLayoutPrefKey, previousLayout);
      await _restorePrefString(sp, AppPaths.dataRootPrefKey, previousRoot);
      await MacOSDataRootAccess.restoreBookmark(sp, previousBookmark);
      if (e is DataRootMigrationException) rethrow;
      throw DataRootMigrationException('写入默认数据位置设置失败', cause: e);
    }
  }

  /// 把一个字符串 pref 复原到 [previous]（null 表示原本就没有这个键 → 删掉）。
  /// 提交失败回退用，尽力而为：复原本身失败只记日志（外层已在抛错回滚整次迁移）。
  static Future<void> _restorePrefString(
    SharedPreferences sp,
    String key,
    String? previous,
  ) async {
    try {
      if (previous == null) {
        await sp.remove(key);
      } else {
        await sp.setString(key, previous);
      }
    } catch (e) {
      debugPrint('DataRoot migrate: 复原 pref $key 失败: $e');
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
      await appModel.audiobookSession.stop().timeout(_closeResourceTimeout);
    } catch (e) {
      debugPrint(
          'DataRoot migrate: audiobookSession.stop failed/timeout (best-effort): $e');
    }
    try {
      final Future<void>? stopFuture = appModel.audioHandler?.stop();
      if (stopFuture != null) await stopFuture.timeout(_closeResourceTimeout);
    } catch (e) {
      debugPrint(
          'DataRoot migrate: audioHandler.stop failed/timeout (best-effort): $e');
    }
    // 1.5) TODO-1212：释放页面级媒体播放器的文件句柄（视频主播放器 / 离屏缩略图
    //    取帧 Player）。有声书会话上面 stop() 已直接 await disposeAndRelease 释放；
    //    这些视频侧 leaf 播放器是页面级、没有进程级持有者，迁移路径够不到——经
    //    全局 [MediaHandleRegistry] 触达并逐个 await，确保 rename 数据根前底层
    //    libmpv 视频/字幕文件句柄真放掉（收尾 TODO-935 的「无全局 registry 触达
    //    页面级播放器」残余）。best-effort：释放失败不阻止迁移（引擎有锁重试 +
    //    跨盘降级兜底）。
    try {
      await MediaHandleRegistry.instance.releaseAll();
    } catch (e) {
      debugPrint(
          'DataRoot migrate: media handle release failed (best-effort): $e');
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
          .customStatement('PRAGMA wal_checkpoint(TRUNCATE)')
          .timeout(_closeResourceTimeout);
    } catch (e) {
      // best-effort：checkpoint 失败/超时不致命，下面的 closeDatabase 仍会落盘+关库。
      debugPrint(
          'DataRoot migrate: wal_checkpoint failed/timeout (best-effort): $e');
    }
    // TODO-1324：closeDatabase 过去**无 try/catch 无超时**——若 Drift close 因某个未取消
    // 的 stream/挂起操作永不完成，整个迁移就永远卡在这里（遮罩转圈永不结束）。加超时 +
    // 兜底：超时则放行继续搬文件（真被占用会在 rename 阶段以「文件被占用」失败态醒目提示，
    // 而不是静默永久挂起）。
    try {
      await appModel.closeDatabase().timeout(_closeDatabaseTimeout);
    } catch (e) {
      debugPrint(
          'DataRoot migrate: closeDatabase failed/timeout (best-effort): $e');
    }
  }

  /// TODO-1324：迁移前关运行时句柄的单步硬上限。任一步（停音频 / checkpoint）卡住都不得
  /// 无限拖住迁移——超时即放行，把「永久挂起」降级为「可恢复的失败/继续」。
  static const Duration _closeResourceTimeout = Duration(seconds: 5);

  /// 关 DB 单独给更长上限（checkpoint 落盘可能较慢），但仍有界，绝不永久挂起。
  static const Duration _closeDatabaseTimeout = Duration(seconds: 10);

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
        // TODO-1324：迁移已成功，只是自动重启失败。**绝不**依赖 `if (mounted) _showSnackBar`
        // ——迁移一开始 beginDataRootMigration 就把根 widget 换成遮罩、本设置页 State 已
        // unmount（mounted==false），snackbar 静默丢失 → 遮罩永远停在转圈（用户报的「转圈
        // 永不完成」的根因之一）。改切到迁移遮罩的**终态**（消息 + 重启按钮，由 main.dart 注入
        // onRestart），用户永远能看到结果并手动重启；数据已安全落在新根。
        appModel.failDataRootMigration(message);
      });

  /// BUG-1188：确认弹窗里把**解析后的**两个根原样列出来。挑中默认位置时目标会被归一化
  /// （`<Documents>\Hibiki` → 内容落 `<Documents>\Hibiki\data`、DB 留在平台固定落点），
  /// 用户必须在按下确认前就看到数据到底会去哪，而不是重启后自己找。
  Future<bool> _confirmMigrate(DataRootMigrationTarget target) async {
    final String body = '${t.data_storage_change_confirm_body}\n\n'
        '${target.documentsRoot.path}\n${target.supportRoot.path}';
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
            body: Text(body),
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
    // followLinks: false —— 用户挑的目录可能含 shell junction（ACL 全拒），追进去
    // listSync 直接 errno 5 硬炸（TODO-1226）。
    for (final FileSystemEntity e
        in dir.listSync(recursive: true, followLinks: false)) {
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
