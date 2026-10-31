part of 'update_checker.dart';

/// 一次更新下载在本机上的界面状态：进度 / 状态文案 / 诊断 / 来源降级通告 / 浮层可见性，
/// 外加取消令牌与下载浮层本身。
///
/// 本机「发现新版本 → 下载」（[UpdateChecker._runDownloadAndInstall]）与互联远程触发
/// （[HeadlessUpdateFlow.downloadAndApply]，反馈 Pp8XPyve0N）共用这一份：两条流在本机
/// 上看到的是同一个下载浮层、同一个「取消」按钮——远程触发不另写一套界面，host 上正在
/// 阅读 / 播放的人也能看见并中止一次别的设备发起的更新。
class _UpdateDownloadSession {
  /// [cancellation] 由调用方给时与调用方共享同一个取消令牌（控制通道
  /// `fushi_cli update cancel` 与浮层「取消」按的是同一个）。
  _UpdateDownloadSession({UpdateDownloadCancellation? cancellation})
    // 体感快修（TODO-683）：进下载前显「正在连接更新源…」，首个进度/诊断信号到达再翻
    // 「正在下载更新…」。GFW 下坏候选累积超时期间不再让用户盯着「下载中 0%」误以为卡死。
    : status = ValueNotifier<String>(t.update_connecting),
      cancellation = cancellation ?? UpdateDownloadCancellation() {
    _statusController = UpdateDownloadStatusController(status);
  }

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String> status;
  late final UpdateDownloadStatusController _statusController;
  final ValueNotifier<UpdateDownloadDiagnostics?> diagnostics =
      ValueNotifier<UpdateDownloadDiagnostics?>(null);

  /// 「本次没用上你选的下载来源」通告：所选来源对某些资产解析不出候选（旧仓库直链 /
  /// 第三方 host / 镜像前缀已下线）时行为上照常回退，但降级必须看得见，否则用户会以为
  /// 自己锁定了 Cloudflare（见 [UpdateDownloadPlan.preferenceUnavailable]）。
  final ValueNotifier<String?> sourceNotice = ValueNotifier<String?>(null);
  final ValueNotifier<bool> overlayVisible = ValueNotifier<bool>(true);

  /// 取消令牌（TODO-738）：浮层「取消」按下后置位，下载引擎在候选边界看到即中断。
  final UpdateDownloadCancellation cancellation;
  OverlayEntry? _entry;

  /// 把下载浮层插进 [overlay]（一个会话只插一次）。
  void showIn(OverlayState overlay) {
    if (_entry != null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext _) => ValueListenableBuilder<bool>(
        valueListenable: overlayVisible,
        builder: (BuildContext _, bool visible, Widget? __) {
          if (!visible) return const SizedBox.shrink();
          return _DownloadOverlay(
            progress: progress,
            status: status,
            notice: sourceNotice,
            diagnostics: diagnostics,
            onHide: () => overlayVisible.value = false,
            onCancel: requestCancel,
          );
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 立即给反馈：置「正在取消…」并请求取消；引擎在下一个候选边界中断。
  void requestCancel() {
    cancellation.cancel();
    status.value = t.update_cancelling;
  }

  /// 首个真实进度（>0 = 已有字节落盘）才翻「下载中」；onProgress(0) 是请求前的初始
  /// 占位，不能据它过早翻、否则 connecting 几乎不可见（失去体感意义）。
  void onProgress(double value) {
    if (value > 0) _statusController.onFirstByte();
    progress.value = value;
  }

  /// 诊断里 receivedBytes>0 同样表示已有字节到达，作为翻「下载中」的等价信号
  /// （某些路径 diagnostics 比 onProgress 先携带非零字节，如续传起点）。
  void onDiagnostics(UpdateDownloadDiagnostics value) {
    if (value.receivedBytes > 0) _statusController.onFirstByte();
    diagnostics.value = value;
  }

  void onSourceNotice(String? notice) => sourceNotice.value = notice;

  void dispose() {
    _entry?.remove();
    _entry = null;
    progress.dispose();
    status.dispose();
    diagnostics.dispose();
    sourceNotice.dispose();
    overlayVisible.dispose();
  }
}

/// 测试缝：在 [overlay] 里开一个真实的下载会话浮层（与生产同一个
/// [_UpdateDownloadSession]），返回它的取消令牌与收尾函数。
@visibleForTesting
({UpdateDownloadCancellation cancellation, void Function() dispose})
showUpdateDownloadSessionForTest(OverlayState overlay) {
  final _UpdateDownloadSession session = _UpdateDownloadSession()
    ..showIn(overlay);
  return (cancellation: session.cancellation, dispose: session.dispose);
}

/// 一次「查新版本」的结果（[HeadlessUpdateFlow.checkAvailableUpdate]）。
class HeadlessUpdateCheck {
  const HeadlessUpdateCheck({
    required this.version,
    required this.asset,
    required this.releaseNotes,
    required this.htmlUrl,
  });

  /// 本平台可装的版本（per-平台 effective 版本，与「发现新版本」对话框同源）。
  final String version;

  /// null = 有新版但本平台没有可应用内安装的包。
  final UpdateAsset? asset;

  /// 更新说明（release body，Markdown）。
  final String releaseNotes;

  /// 发布页 URL。
  final String? htmlUrl;
}

/// 不经「发现新版本」对话框的更新入口（互联 host 远程更新，反馈 Pp8XPyve0N）。
///
/// 与本机 UI 流同一条拉取 / 选包 / 比较链路、同一把版本级互斥锁、同一条下载引擎与
/// 同一个下载浮层（[_UpdateDownloadSession]），只是由别的设备发起、没有调用方 context。
abstract final class HeadlessUpdateFlow {
  /// 查一次本平台可装的新版本（不弹任何对话框）。
  ///
  /// 与 [UpdateChecker.scheduleCheck] 同一条链路（`_fetchReleasesForChannel` →
  /// [selectUpdateReleaseForCurrentPlatform] → [isUpdateVersionNewer]）。返回 null =
  /// 已是最新 / 没有匹配 release；asset 为 null = 有新版但本平台没有可应用内安装的包。
  /// 网络失败照常抛出。
  static Future<({String version, UpdateAsset? asset})?>
  resolveAvailableUpdate({
    required String currentVersion,
    String? currentBuildNumber,
    required UpdateChannel channel,
    String customProxy = '',
    PlatformUpdater? updater,
  }) async {
    final HeadlessUpdateCheck? check = await checkAvailableUpdate(
      currentVersion: currentVersion,
      currentBuildNumber: currentBuildNumber,
      channel: channel,
      customProxy: customProxy,
      updater: updater,
    );
    if (check == null) return null;
    return (version: check.version, asset: check.asset);
  }

  /// 同 [resolveAvailableUpdate]，另带更新说明与发布页（控制通道 `update check`）。
  /// [cacheWriter] 非 null 时与 [UpdateChecker.scheduleCheck] 一样把结果写回检查缓存
  /// （设置页「立即检查更新」下次的乐观提示读它）。
  static Future<HeadlessUpdateCheck?> checkAvailableUpdate({
    required String currentVersion,
    String? currentBuildNumber,
    required UpdateChannel channel,
    String customProxy = '',
    PlatformUpdater? updater,
    UpdateCheckCacheWriter? cacheWriter,
  }) async {
    final PlatformUpdater platformUpdater =
        updater ?? updaterForCurrentPlatform();
    final int? localSeq = currentReleaseSequence(
      version: currentVersion,
      buildNumber: currentBuildNumber,
    );
    final HttpClient client = UpdateChecker._newUpdateHttpClient();
    try {
      await applyAppProxy(client, userProxy: customProxy);
      final List<Map<String, dynamic>> releases =
          await UpdateChecker._fetchReleasesForChannel(client, channel);
      final UpdateReleaseSelection? selection =
          await selectUpdateReleaseForCurrentPlatform(
            releases,
            currentVersion: currentVersion,
            currentReleaseSeq: localSeq,
            channel: channel,
            updater: platformUpdater,
          );
      if (selection == null || selection.version.isEmpty) return null;
      if (cacheWriter != null) {
        await cacheWriter(
          UpdateCheckCacheEntry(
            lastCheckEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
            latestTag: selection.version,
            htmlUrl: selection.htmlUrl ?? '',
            channel: channel,
          ),
        );
      }
      if (!isUpdateVersionNewer(
        selection.version,
        currentVersion,
        channel,
        remoteSeq: selection.release['releaseSequence'] as int?,
        localSeq: localSeq,
      )) {
        return null;
      }
      return HeadlessUpdateCheck(
        version: selection.version,
        asset: selection.asset,
        releaseNotes: selection.releaseNotes,
        htmlUrl: selection.htmlUrl,
      );
    } finally {
      client.close();
    }
  }

  /// [version] 这一版是否已有更新流在途（对话框开着 / 正在下载安装）。
  static bool isActive(String version) => UpdateChecker._activeUpdateFlows
      .containsKey(UpdateChecker._updateFlowKey(version));

  /// 下载并安装 [asset]。
  ///
  /// [overlay] 非 null 时在本机显示与 UI 流同一个下载浮层：本机的人看得见进度，也能点
  /// 「取消」中止（取消以 [UpdateDownloadCancelledException] 抛给调用方）。桌面 apply
  /// 会退出本进程由安装器接班重启；Android apply 拉起系统安装确认（缺「安装未知应用」
  /// 权限时抛 `INSTALL_PERMISSION_REQUIRED`，原样抛给调用方）。已有同版本流在途时抛
  /// [StateError]。
  static Future<void> downloadAndApply({
    required UpdateAsset asset,
    required String version,
    required PlatformUpdater updater,
    String customProxy = '',
    OverlayState? overlay,
    required void Function(double progress) onProgress,
    required void Function() onInstalling,
  }) {
    if (isActive(version)) {
      throw StateError('update flow for $version already active');
    }
    return UpdateChecker._runExclusiveUpdateFlow(
      UpdateChecker._updateFlowKey(version),
      () async {
        final _UpdateDownloadSession session = _UpdateDownloadSession();
        try {
          final File outFile = await _downloadInSession(
            session,
            asset: asset,
            version: version,
            updater: updater,
            customProxy: customProxy,
            overlay: overlay,
            onProgress: onProgress,
          );
          session.status.value = t.update_installing;
          onInstalling();
          await updater.apply(outFile, version);
        } finally {
          session.dispose();
        }
      },
    );
  }

  /// 只下载、不安装（控制通道 `update download`）：与 [downloadAndApply] 同一条下载
  /// 引擎、同一把版本级互斥锁、同一个下载浮层；安装另由 [PlatformUpdater.apply] 接
  /// （`update install`）。
  ///
  /// [cancellation] 与浮层「取消」共用：任一处取消都以
  /// [UpdateDownloadCancelledException] 抛给调用方。已有同版本流在途时抛 [StateError]。
  static Future<File> download({
    required UpdateAsset asset,
    required String version,
    required PlatformUpdater updater,
    String customProxy = '',
    OverlayState? overlay,
    UpdateDownloadCancellation? cancellation,
    required void Function(double progress) onProgress,
  }) async {
    if (isActive(version)) {
      throw StateError('update flow for $version already active');
    }
    File? outFile;
    await UpdateChecker._runExclusiveUpdateFlow(
      UpdateChecker._updateFlowKey(version),
      () async {
        final _UpdateDownloadSession session = _UpdateDownloadSession(
          cancellation: cancellation,
        );
        try {
          outFile = await _downloadInSession(
            session,
            asset: asset,
            version: version,
            updater: updater,
            customProxy: customProxy,
            overlay: overlay,
            onProgress: onProgress,
          );
        } finally {
          session.dispose();
        }
      },
    );
    return outFile!;
  }

  /// [downloadAndApply] / [download] 共用的下载段（浮层、代理、强断、进度接线）。
  static Future<File> _downloadInSession(
    _UpdateDownloadSession session, {
    required UpdateAsset asset,
    required String version,
    required PlatformUpdater updater,
    required String customProxy,
    required OverlayState? overlay,
    required void Function(double progress) onProgress,
  }) async {
    if (overlay != null && overlay.mounted) session.showIn(overlay);
    final UpdateDownloadCancellation cancellation = session.cancellation;
    final HttpClient client = UpdateChecker._newUpdateHttpClient();
    try {
      await applyAppProxy(client, userProxy: customProxy);
      cancellation.registerAbort(() => client.close(force: true));
      return await UpdateChecker._downloadAssetForInstall(
        client: client,
        asset: asset,
        version: version,
        updater: updater,
        customProxy: customProxy,
        cancellation: cancellation,
        onProgress: (double value) {
          session.onProgress(value);
          onProgress(value);
        },
        onDiagnostics: session.onDiagnostics,
        onSourceNotice: session.onSourceNotice,
      );
    } finally {
      cancellation.clearAbort();
      client.close();
    }
  }
}
