part of 'update_checker.dart';

/// 发布仓。改名 Fushi 后主名走新仓；GitHub 对仓库名大小写不敏感（实测
/// `raw.githubusercontent.com/JestJS/Jest/...` 与 `jestjs/jest` 同为 200），故沿用
/// 小写字面量，与仓库显示名 `Fushi` 无冲突。
const String kGitHubRepo = 'hajisensai/fushi';

/// 改名前的仓名，作回退位。**两个作用**：① 仓库还没实际改名的窗口期里，新构建靠它
/// 仍能查到更新（[kGitHubRepoFallbacks] 会逐个试）；② 真改名后它由 GitHub 永久
/// 重定向兜底。
///
/// 取代了更早的 `hdjsadgfwtg/hibiki`——那个不是独立仓库，是本仓的**旧账号名**
/// （`gh repo view hdjsadgfwtg/hibiki` 解析出的 nameWithOwner 就是
/// `hajisensai/hibiki`），一直靠同一套重定向工作；留着它只是多一跳同目标的链路，
/// 而 `hajisensai/hibiki` 是单跳、更近的名字。顺带说明这套重定向早已在生产验证过：
/// 旧账号名连 `raw.githubusercontent.com/.../update-manifest/latest-stable.json`
/// 都能 200，正是 GFW 下唯一可成功的那条检查路径。
const String kLegacyGitHubRepo = 'hajisensai/hibiki';

@visibleForTesting
const List<String> kGitHubRepoFallbacks = <String>[
  kGitHubRepo,
  kLegacyGitHubRepo,
];

final RegExp _kBetaReleaseTagPattern = RegExp(r'^v\d+(?:\.\d+)*-beta\.\d+$');
final RegExp _kDebugReleaseTagPattern =
    RegExp(r'^v\d+(?:\.\d+)*-debug\.\d+\+[0-9A-Fa-f]{7,40}$');
final RegExp _kBetaVersionPattern = RegExp(r'^\d+(?:\.\d+)*-beta\.\d+$');
final RegExp _kDebugVersionPattern = RegExp(r'^\d+(?:\.\d+)*-debug\.\d+$');

@visibleForTesting
class UpdateReleaseSelection {
  const UpdateReleaseSelection({
    required this.release,
    required this.version,
    required this.releaseNotes,
    required this.asset,
  });

  final Map<String, dynamic> release;
  final String version;
  final String releaseNotes;
  final UpdateAsset? asset;

  String? get htmlUrl => release['html_url'] as String?;
  String? get downloadUrl => asset?.url;
}

class UpdateChecker {
  UpdateChecker._();

  static final Map<String, Future<void>> _activeUpdateFlows =
      <String, Future<void>>{};

  /// 当前在途的检查阶段中断令牌（TODO-821）。`_check` 进入时登记，退出时清空。
  /// 同一时刻只跑一轮检查（`scheduleCheck` 走 post-frame 单次触发），单个足矣。
  static UpdateCheckCancellation? _activeCheckCancellation;

  /// 集成测试专用：置位后 [scheduleCheck] 直接短路，本进程不再发起任何更新检查。
  ///
  /// 焦点驱动 itest 与启动期自动检查是真实网络竞速：检查成功会弹「发现新版本」
  /// [DialogRoute]，其 ModalScope 抢走 primary focus，页面焦点断言随机失败
  /// （iOS 模拟器实测复现）。事后 [cancelActiveCheck] 无法根治——scheduleCheck
  /// 经 post-frame 才启动 `_check`，home 首帧当口取消时令牌还未登记（no-op），
  /// 而 `neverRemind` 是调用时刻已捕获的参数。集成测试与 app 同 isolate，测试在
  /// `app.main()` 之前置位本旗标即可确定性排除整轮检查。生产路径永不置位。
  @visibleForTesting
  static bool disableAutoCheckForTesting = false;

  /// 调度一轮更新检查（post-frame 单次触发）。
  ///
  /// TODO-898：新增可选结果回调，默认 `null` = 自动检查路径字节级零变化。
  /// - [onUpToDate]：检查完成且**无可更新版本**时触发（覆盖 `_check` 三条等价
  ///   「无更新」早退：无匹配 release / tag 为空 / 已是最新）。手动按钮据此给反馈。
  /// - [onError]：检查抛错（网络等）时触发。
  ///
  /// 返回 `Future<void>`，在整轮检查（含 post-frame 调度 + `_check` 全程）完成后
  /// 完成，供调用方（如手动按钮）`await` 后复位防连点旗标。旧调用忽略返回值即可，
  /// 向后兼容。
  static Future<void> scheduleCheck(
    BuildContext context,
    String currentVersion, {
    // BUG-457/BUG-816-类：本机平台构建号（Android=versionCode，桌面=raw build number）。
    // beta/debug 通道下若本机安装的是无预发布后缀的 `X.Y.Z`（如本地 `flutter build` 出的
    // release 包，versionName 直接取 pubspec `1.2.0`），用它还原本机 release sequence 再比较，
    // 否则同基预发布（`1.2.0-debug.7920`）在 semver 下永远 < `1.2.0`、永判「已是最新」。
    String? currentBuildNumber,
    bool neverRemind = false,
    bool autoInstall = false,
    bool betaChannel = false,
    bool debugChannel = false,
    String customProxy = '',
    void Function()? onUpToDate,
    void Function(Object error)? onError,
    // TODO-1024 / BUG-479：缓存优先 + 后台静默刷新。`cacheWriter` 在一次成功网络检查
    // 拿到最新 tag 后把结果写回缓存（供下次「检查更新」乐观即时反馈）。乐观读由调用方
    // 直接读 `appModel.updateCheckCache`（不经此参数）。默认 null = 不接缓存（旧调用零变化）。
    UpdateCheckCacheWriter? cacheWriter,
    // TODO-898 必修2：仅测试注入 fake「拉 release」函数指针，生产恒 null。
    @visibleForTesting
    Future<List<Map<String, dynamic>>> Function(
            HttpClient client, UpdateChannel channel)?
        fetchReleasesForTesting,
  }) {
    // 集成测试短路：见 [disableAutoCheckForTesting]。
    if (disableAutoCheckForTesting) return Future<void>.value();
    // 任何测试 harness 下自动短路：生产 `runApp` 的 binding 一定是
    // [WidgetsFlutterBinding]；flutter_test / integration_test 的 binding
    // （TestWidgetsFlutterBinding 及其子类）都不是它的子类。启动期自动更新检查
    // 是真实网络 + 可能弹 [DialogRoute] 抢焦点（BUG-1043），任何自动化测试里都
    // 不应发生；逐测试置位旗标无法覆盖 71 个 itest 且对新增测试不设防。
    if (WidgetsBinding.instance is! WidgetsFlutterBinding) {
      return Future<void>.value();
    }
    final UpdateChannel channel = debugChannel
        ? UpdateChannel.debug
        : betaChannel
            ? UpdateChannel.beta
            : UpdateChannel.stable;
    // BUG-846「谁后用谁」：算出本机 release sequence（beta/debug 版本串已带 `-<channel>.<seq>`
    // 直接取；无后缀 `X.Y.Z`（正式版包 / 本地 build）用平台构建号反解），透到比较层做跨轨
    // 序号全序比较。**不再**把本机版本伪造成 `<base>-<channel>.<seq>` 串——那会把真正的正式版
    // 安装误标成预发布轨，触发正式↔调试来回更新（BUG-846 乒乓根因）。
    final int? currentReleaseSeq = currentReleaseSequence(
      version: currentVersion,
      buildNumber: currentBuildNumber,
    );
    final Completer<void> completer = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _check(context, currentVersion,
              currentReleaseSeq: currentReleaseSeq,
              neverRemind: neverRemind,
              autoInstall: autoInstall,
              channel: channel,
              customProxy: customProxy,
              onUpToDate: onUpToDate,
              onError: onError,
              cacheWriter: cacheWriter,
              fetchReleases: fetchReleasesForTesting)
          .whenComplete(() {
        if (!completer.isCompleted) completer.complete();
      });
    });
    return completer.future;
  }

  static Future<void> _cleanupOldApks(
    String _, {
    String? activeAssetFileName,
  }) async {
    try {
      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      if (!updatesDir.existsSync()) return;
      final DateTime cutoff = DateTime.now().subtract(const Duration(days: 7));

      // TODO-1010：保护 Windows 待重启安装的 handoff 安装包——若存在 handoff 标记，
      // 它指向的安装包正等下次启动安装，绝不能当旧包回收。
      //
      // fail-safe（根因修复）：`WindowsUpdateHandoff.read` 在 marker JSON 损坏时
      // 内部吞掉 FormatException 返回 null——与「根本没有 marker」无法区分。若按
      // null 当作「无排除名单」照常清理，待重启安装包就会因 mtime>7 天被误删，
      // 破坏重启安装握手。因此：marker 文件存在但 read 拿不到记录 = 排除名单不可信，
      // 这一轮直接跳过完整包回收（保守保留），不降级成「无保护清理」。
      final File markerFile = WindowsUpdateHandoff.markerFile(updatesDir);
      final bool markerExists = markerFile.existsSync();
      String? handoffInstallerName;
      WindowsUpdateHandoffRecord? handoffRecord;
      try {
        handoffRecord = await WindowsUpdateHandoff.read(markerFile);
        if (handoffRecord != null && handoffRecord.installerPath.isNotEmpty) {
          handoffInstallerName =
              handoffRecord.installerPath.replaceAll(r'\', '/').split('/').last;
        }
      } catch (e) {
        debugPrint('[UpdateChecker] cleanup read handoff failed: $e');
        // 读取本身抛错（不只 read 内部吞掉的 FormatException）= 同样拿不到名单。
        handoffRecord = null;
      }
      final bool skipFullPackageCleanup = shouldSkipFullPackageCleanup(
        markerExists: markerExists,
        recordResolved: handoffRecord != null,
      );

      final List<UpdateDirEntry> dirEntries = <UpdateDirEntry>[];
      for (final FileSystemEntity entity in updatesDir.listSync()) {
        // TODO-1149 根因修复：目录条目的 `entity.uri.pathSegments.last` 恒为空串（Dart
        // 给目录 URI 补尾斜杠），此前使 `.staging` 根永不匹配 `.endsWith('.staging')`、
        // GC 形同虚设。改用按 `.path` 取叶子名，目录/文件一致可靠。
        final String name = _leafName(entity.path);
        if (entity is Directory) {
          // TODO-1149：目录也带**真实 mtime** 进 GC 决策——`.staging` 下载暂存根按自身
          // mtime 与安装包同策由 selectStaleUpdateArtifacts 一并回收（活跃下载 root mtime
          // 为今日→保留；promote 后残留的空根 / 无活动 >7 天→回收）。旧逻辑传 epoch-0 假
          // mtime 并在此内联删子目录，空根只靠被吞的 best-effort `deleteSync` 兜底，从不被
          // 确定性回收，导致空 `.staging` 根无限堆积。
          dirEntries.add(UpdateDirEntry(
            name: name,
            isDirectory: true,
            modified: entity.statSync().modified,
          ));
          continue;
        }
        if (entity is! File) continue;
        dirEntries.add(UpdateDirEntry(
          name: name,
          isDirectory: false,
          modified: entity.statSync().modified,
        ));
        // 既有职责：清理过期的临时/元数据文件（.part/.meta.json/.owner.json）。
        final bool isTemporary = name.endsWith('.part') ||
            name.endsWith('.meta.json') ||
            name.endsWith('.owner.json');
        if (!isTemporary) continue;
        if (entity.statSync().modified.isBefore(cutoff)) {
          try {
            entity.deleteSync();
          } catch (e) {
            debugPrint('[UpdateChecker] cleanup delete failed: $e');
          }
        }
      }

      // TODO-1010 根因修复：回收过期的**完整安装包**（旧版本 .exe/.apk/.AppImage…）。
      // 历史清理只删临时文件，完整产物从不回收，每升级一版多堆一个，长期到数 GB。
      // 纯函数挑出待删项；排除 handoff 待装包与 marker 自身（无 active asset，因为
      // 清理发生在选出本轮 asset 之前——下载阶段会自行复用/重下当前版本）。
      //
      // fail-safe bail-out：marker 存在但记录未解析出来（损坏）时跳过本轮
      // 完整包回收，以免误删待重启安装包。临时/元数据清理上面已做（不依赖排除名单）；
      // `.staging` 暂存根回收现随完整包 GC 一并按 mtime 处理（TODO-1149），marker 损坏时
      // 一并保守跳过本轮，下一轮正常清理（暂存根是下载 scratch，多留一轮无害）。
      if (skipFullPackageCleanup) {
        debugPrint('[UpdateChecker] handoff marker present but unreadable; '
            'skipping full-package cleanup this pass (fail-safe)');
        return;
      }
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: dirEntries,
        cutoff: cutoff,
        activeAssetFileName: activeAssetFileName,
        handoffInstallerFileName: handoffInstallerName,
      );
      for (final String name in stale) {
        final String path = '${updatesDir.path}${Platform.pathSeparator}$name';
        try {
          // `.staging` 暂存根是目录，递归删；其余是完整安装包文件（TODO-1149）。
          if (name.endsWith('.staging')) {
            Directory(path).deleteSync(recursive: true);
          } else {
            File(path).deleteSync();
          }
        } catch (e) {
          debugPrint('[UpdateChecker] cleanup stale artifact failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[UpdateChecker] cleanup scan failed: $e');
    }
  }

  static Future<void> _check(
    BuildContext context,
    String currentVersion, {
    // BUG-846「谁后用谁」：本机 release sequence（跨轨全序比较用）。null = 取不到（同基保守）。
    int? currentReleaseSeq,
    bool neverRemind = false,
    bool autoInstall = false,
    UpdateChannel channel = UpdateChannel.stable,
    String customProxy = '',
    void Function()? onUpToDate,
    void Function(Object error)? onError,
    // TODO-1024 / BUG-479：成功拿到最新 tag 后把结果写回缓存（供下次乐观显示）。默认
    // null = 不写缓存（旧调用字节级零变化）。
    UpdateCheckCacheWriter? cacheWriter,
    // TODO-898 必修2：可测 seam = 可选注入的「拉 release」函数指针。默认 null →
    // 走现有 _fetchReleasesForChannel（生产路径零改动，不拆 _check 网络层）；
    // 测试传 fake fetcher 即可覆盖三回调路径，不触网络。
    Future<List<Map<String, dynamic>>> Function(
            HttpClient client, UpdateChannel channel)?
        fetchReleases,
  }) async {
    final PlatformUpdater updater = updaterForCurrentPlatform();
    if (!updater.supportsUpdateCheck) return;
    final bool canInstall = updater.supportsInAppInstall;
    // 不能自装的平台忽略 autoInstall（无意义），但仍可「检查→打开发布页」。
    if (neverRemind && !(canInstall && autoInstall)) return;
    HttpClient? client;
    final UpdateCheckCancellation cancellation = UpdateCheckCancellation();
    _activeCheckCancellation = cancellation;
    try {
      await _cleanupOldApks(currentVersion);
      client = HttpClient();
      // TODO-808：检查阶段建连超时同步压到 10s（与下载一致），死镜像更快判死、回退更快。
      client.connectionTimeout = const Duration(seconds: 10);
      // 走系统/环境代理：用户开着 clash/v2ray 时检查请求经其出口直连 api.github.com
      // （纯 GFW 下唯一可成功路径，BUG-292）。无代理则等价直连，不破坏镜像回退。
      await applyAppProxy(client, userProxy: customProxy);

      // TODO-821：把「强断在途连接」回调登记进检查中断令牌——`cancelActiveCheck()` 被调时
      // 立即 close(force: true) 断开所有在途 socket，正在 await 的并发候选请求即刻抛错跳出，
      // 不再等建连/首字节/body 超时走完。finally 的 client.close() 与此关两次幂等。
      final HttpClient abortClient = client;
      cancellation.registerAbort(() => abortClient.close(force: true));

      final List<Map<String, dynamic>> releases =
          await (fetchReleases ?? _fetchReleasesForChannel)(client, channel);
      final UpdateReleaseSelection? selection =
          await selectUpdateReleaseForCurrentPlatform(
        releases,
        currentVersion: currentVersion,
        currentReleaseSeq: currentReleaseSeq,
        channel: channel,
        updater: updater,
      );
      if (selection == null) {
        // 无匹配 release = 等价「无可更新版本」（TODO-898）。
        onUpToDate?.call();
        return;
      }
      final Map<String, dynamic> json = selection.release;

      // TODO-1205：判更新/显示/下载/退避一律用 selection.version（= 所选平台 asset
      // 自身版本，已在 selection 里按 asset 版本判定回填），而非顶层 tag（全平台最大
      // seq）——否则落后平台会「顶层 6636 但安卓装 6621」无限提示死循环（BUG-1205）。
      final String version = selection.version;
      if (version.isEmpty) {
        // 无有效版本 = 等价「无可更新版本」（TODO-898，防御性）。
        onUpToDate?.call();
        return;
      }

      // TODO-1024 / BUG-479：写回缓存供下次「检查更新」乐观即时显示。TODO-1205：latestTag
      // 用 per-平台 effective 版本（与主判定同源），避免乐观提示显示顶层 6636 而实际只能
      // 装 6621 的误导。写缓存失败不影响检查流程，吞掉并记日志即可。
      if (cacheWriter != null) {
        final UpdateCheckCacheEntry entry = UpdateCheckCacheEntry(
          lastCheckEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
          latestTag: version,
          htmlUrl: (json['html_url'] as String?) ?? '',
          channel: channel,
        );
        try {
          await cacheWriter(entry);
        } catch (e) {
          debugPrint('[UpdateChecker] write update cache failed: $e');
        }
      }

      // selection 非空即已按 asset 版本判定为「比本机新」；这里保留防御性再判一次。
      // BUG-846：远端 seq 用所选 release 顶层 releaseSequence（正式版无预发布串靠它），
      // 本机 seq 用透传下来的 currentReleaseSeq，与选择阶段同源。
      if (!isUpdateVersionNewer(version, currentVersion, channel,
          remoteSeq: json['releaseSequence'] as int?,
          localSeq: currentReleaseSeq)) {
        // 已是最新（TODO-898）。
        onUpToDate?.call();
        return;
      }

      final releaseBody = json['body'] as String? ?? '';

      // 用 selection 里已按平台/ABI 选定的同一个 asset，不再重选（免重读设备 ABI）。
      final UpdateAsset? asset = selection.asset;
      final String? downloadUrl = asset?.url;

      // 无适配本平台的 asset（iOS / 未实现桌面 / 该 release 没传本平台包）→ 打开发布页。
      if (downloadUrl == null) {
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null && context.mounted) {
          _showFallbackDialog(context, version, releaseBody, htmlUrl);
        }
        return;
      }
      // TODO-1197/1198：Windows 自动安装死循环防护。装不成的安装器（WebView2 /
      // libmpv 占用致 Inno DeleteFile code5）会 exit→重启→又被自动装，无限循环。
      // 下载前先读 handoff 标记：若这个**确切目标版本**上一轮握手没装成（标记仍在），
      // 退避——改弹手动确认对话框让用户自行决定，不再静默重下重启。换成新版本会重置
      // 退避（见 WindowsUpdateHandoff.shouldBackOffAutoInstall）。读标记出错则 fail-open
      // 照常自动装，绝不「一次失败就永久不更新」。TODO-1205：candidateVersion 用
      // selection.version（与 marker 的 targetVersion = WindowsUpdater.apply 写入的版本同源，不错位）。
      // TODO-1197/1198 泛化到 macOS（Phase 3）：Windows 靠 Inno DeleteFile code5
      // 死循环，macOS 靠 zip 替换失败死循环，两者同策——同一目标版本上一轮握手没
      // 落地就退回手动确认，不再静默重下重启。各平台读各自的握手标记。
      final bool autoInstallBackoff = canInstall &&
          autoInstall &&
          ((Platform.isWindows &&
                  await _shouldBackOffWindowsAutoInstall(version)) ||
              (Platform.isMacOS &&
                  await _shouldBackOffMacAutoInstall(version)));
      if (!context.mounted) return;
      if (canInstall && autoInstall && !autoInstallBackoff) {
        _downloadAndInstall(context, asset!, version, updater,
            customProxy: customProxy);
      } else if (canInstall) {
        _showUpdateDialog(context, version, releaseBody, asset!, updater,
            customProxy: customProxy);
      } else {
        // 能检查但不能自装（本期 iOS/mac/Linux）：弹「前往下载」打开发布页。
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null) {
          _showFallbackDialog(context, version, releaseBody, htmlUrl);
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('UpdateChecker.check', e, stack);
      debugPrint('[Fushi] update check failed: $e');
      onError?.call(e); // TODO-898：手动检查失败反馈。
    } finally {
      // TODO-821：先注销 abort 回调（避免后续 cancel 误关已释放的 client），清空在途令牌，
      // 再常规关闭。中断路径已 close(force: true)，这里再 close() 幂等无害。
      cancellation.clearAbort();
      if (identical(_activeCheckCancellation, cancellation)) {
        _activeCheckCancellation = null;
      }
      client?.close();
    }
  }

  /// **检查阶段中断入口（TODO-821）**：强断当前在途的更新检查（若有）。卡在「正在连接
  /// 更新源」时由调用方（如页面退出 / 生命周期）调用，立即 close(force: true) 断开在途
  /// 检查连接，使整轮检查即刻收尾而非干等超时。无在途检查则 no-op。
  static void cancelActiveCheck() {
    _activeCheckCancellation?.cancel();
  }

  /// TODO-1197/1198：Windows 自动安装跨重启失败退避判据。读 handoff 标记判断
  /// [candidateVersion] 这个确切版本上一轮是否已装失败（标记仍在 = 没落地）；是则
  /// 返 true，调用方退回手动确认对话框，打断自动安装死循环。读标记出错 → 返 false
  /// （fail-open，绝不因读不到标记而永久不更新）。仅 Windows 有意义（只有 Windows 走
  /// handoff 标记），调用点已用 `Platform.isWindows` 门控。
  static Future<bool> _shouldBackOffWindowsAutoInstall(
    String candidateVersion,
  ) async {
    try {
      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      return await WindowsUpdateHandoff.shouldBackOffAutoInstall(
        markerFile: WindowsUpdateHandoff.markerFile(updatesDir),
        candidateVersion: candidateVersion,
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('UpdateChecker.autoInstallBackoff', e, stack);
      debugPrint('[Fushi] auto-install backoff check failed: $e');
      return false;
    }
  }

  /// 多镜像回退的更新检查请求（BUG-277）。生成「直连 + 各 gh 代理前缀」候选列表
  /// （[updateCheckUrls]），交给可注入核心 [fetchFirstSuccessfulBody] 逐个尝试：任一
  /// 返回 HTTP 200 即整体成功，单点不可达/超时自动回退下一个，全失败才返回 null。
  /// 每个候选带 [_kPerAttemptTimeout] 整体超时，避免坏镜像拖垮整轮检查。
  static Future<String?> _httpGetString(
    HttpClient client,
    String url, {
    Map<String, String> headers = const {},
  }) {
    return fetchFirstSuccessfulBody(
      updateCheckUrls(url),
      fetch: (String u) => _fetchOne(client, u, headers),
      onFailure: (String host, Object? error) {
        // 网络类失败（连不上/超时/TLS 握手）记一条可读的 i18n 摘要、不带堆栈，
        // 让用户在日志里看到「连不上哪个源」而不被原始堆栈噪音淹没；其它异常
        // （解析/逻辑错误）才是真问题，连堆栈一起记。
        if (error == null || isExpectedUpdateNetworkFailure(error)) {
          // TODO-1083：多镜像 failover 中途单个镜像连不上是**预期路径**（全失败才是真
          // 失败），当应用错误刷进报错日志纯属噪声。降级为诊断/取证——仍随上传带走供排障，
          // 但不进用户可见错误计数/正文（真解析/逻辑错走下面的 log()）。
          ErrorLogService.instance.logDiagnostic(
              'UpdateChecker.httpGet',
              t.update_network_failure(
                host: host,
                reason: describeUpdateNetworkFailureReason(error),
              ));
        } else {
          ErrorLogService.instance.log('UpdateChecker.httpGet', error);
        }
        debugPrint('[Fushi] update check failed ($host): $error');
      },
    );
  }

  static Future<String?> _httpGetStringFromGitHubRepos(
    HttpClient client,
    String Function(String repo) urlForRepo, {
    Map<String, String> headers = const {},
  }) async {
    for (final String repo in kGitHubRepoFallbacks) {
      final String? body = await _httpGetString(
        client,
        urlForRepo(repo),
        headers: headers,
      );
      if (body != null) return body;
    }
    return null;
  }

  /// 单个候选 URL 的一次抓取：HTTP 200 返回响应体，否则返回 null（让回退继续）。
  /// 带 [_kPerAttemptTimeout] 整体超时——TCP 连上却挂起的镜像会被判死并回退。
  static Future<String?> _fetchOne(
    HttpClient client,
    String url,
    Map<String, String> headers,
  ) async {
    Future<String?> attempt() async {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      for (final MapEntry<String, String> e in headers.entries) {
        request.headers.set(e.key, e.value);
      }
      final HttpClientResponse response = await request.close();
      if (response.statusCode == 200) {
        return response.transform(utf8.decoder).join();
      }
      await response.drain<void>();
      return null;
    }

    return attempt().timeout(_kPerAttemptTimeout);
  }

  /// BUG-846 嵌套合集拉取：越激进的通道合集越大，beta/debug 用户要能收到更新的正式版/
  /// 更高基版本，永不掉队。按 [_channelsAdmittedBy] 把本通道接纳的每个轨道各拉一次
  /// （stable→[stable]；beta→[stable,beta]；debug→[stable,beta,debug]）并合并——上层
  /// [selectUpdateReleaseForCurrentPlatform] 会按「最新优先」排序后择一，对多轨并集透明。
  static Future<List<Map<String, dynamic>>> _fetchReleasesForChannel(
    HttpClient client,
    UpdateChannel channel,
  ) async {
    final List<Map<String, dynamic>> merged = <Map<String, dynamic>>[];
    for (final UpdateChannel track in _channelsAdmittedBy(channel)) {
      merged.addAll(await _fetchReleasesForExactChannel(client, track));
    }
    return merged;
  }

  /// 单一轨道 [channel] 的 release 拉取（BUG-846 前的既有逻辑原样保留，仅从
  /// [_fetchReleasesForChannel] 抽出以便按合集并集复用）。
  static Future<List<Map<String, dynamic>>> _fetchReleasesForExactChannel(
    HttpClient client,
    UpdateChannel channel,
  ) async {
    if (channel == UpdateChannel.stable) {
      // BUG-846「谁后用谁」：正式版**优先**读 `latest-stable.json` 镜像清单——它顶层带
      // `releaseSequence`（CI `merge_update_manifest.py` 写入），是客户端唯一能拿到正式版
      // release sequence 的来源，据此才能与同基预发布按「谁后构建谁赢」比较。**回退**到原
      // 302 跳转 / API 直连（拿不到 seq，同基保守不 churn）。手动 GitHub Release 未发 manifest
      // 时自然走回退，fail-open。
      final Map<String, dynamic>? manifestRelease =
          await _fetchChannelReleaseFromManifest(client, channel);
      if (manifestRelease != null) {
        return <Map<String, dynamic>>[manifestRelease];
      }
      final Map<String, dynamic>? release = await _fetchStableRelease(client);
      return release == null
          ? const <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[release];
    }

    // beta/debug：**优先**读 CI 发到 `update-manifest` 孤儿分支的镜像清单
    // （TODO-705 方案 A）。`raw.githubusercontent.com` 经公共 gh 代理可透传
    // （与 stable 的 302 跳转同理，纯 GFW 无代理也能成功），而原 `api.github.com/.../releases`
    // 列表 API 经任何镜像都被 403（BUG-292），故 manifest 是 GFW 下 beta/debug 检查的
    // 唯一可成功路径。**回退**到 `api.github.com` 直连（有 VPN/系统代理时更权威、带真实
    // assets/notes），两条路返回值都是「与 GitHub API 同构的 release map 列表」，对上层
    // [selectUpdateReleaseForCurrentPlatform] 完全透明——纯叠加，不破坏既有行为。
    final Map<String, dynamic>? manifestRelease =
        await _fetchChannelReleaseFromManifest(client, channel);
    if (manifestRelease != null) {
      return <Map<String, dynamic>>[manifestRelease];
    }

    final body = await _httpGetStringFromGitHubRepos(
      client,
      (String repo) =>
          'https://api.github.com/repos/$repo/releases?per_page=20',
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return const <Map<String, dynamic>>[];
    final list = jsonDecode(body) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> release) {
      return releaseMatchesUpdateChannel(release, channel);
    }).toList(growable: false);
  }

  /// beta/debug 镜像清单读取（TODO-705 方案 A）：取该通道的 `latest-<channel>.json`
  /// （[manifestUrlForChannel]，经 [updateCheckUrls] 自带镜像回退），解析成与 GitHub API
  /// 同构的 release map（[buildReleaseFromManifest]）。任一镜像成功且能解析出合法
  /// release 即返回；URL 全失败、JSON 畸形、schemaVersion 不识别或重建后不匹配本通道
  /// → 返 null（调用方回退 `api.github.com` 直连）。
  static Future<Map<String, dynamic>?> _fetchChannelReleaseFromManifest(
    HttpClient client,
    UpdateChannel channel,
  ) async {
    for (final MapEntry<String, String> candidate
        in manifestUrlsForChannel(channel).entries) {
      final String? body = await _httpGetString(client, candidate.value);
      if (body == null) continue;
      final Map<String, dynamic>? release =
          buildReleaseFromManifest(body, repo: candidate.key);
      if (release == null) continue;
      if (!releaseMatchesUpdateChannel(release, channel)) continue;
      return release;
    }
    return null;
  }

  /// stable 通道检查（TODO-404 根因修复）：**优先**走 `github.com/.../releases/latest`
  /// 的 302 网页跳转拿最新 tag（公共 gh 代理可透传，纯 GFW 无代理也能成功），据 tag +
  /// 命名规则重建一个与 API 同构的 release map（[buildStableReleaseFromTag]）；**回退**到
  /// 原 `api.github.com` 直连（有 VPN/系统代理时更权威、还带真实 assets/release notes）。
  ///
  /// 两条路返回值结构一致，对上层 [_fetchReleasesForChannel] /
  /// [selectUpdateReleaseForCurrentPlatform] 完全透明——纯叠加，不破坏既有行为。
  static Future<Map<String, dynamic>?> _fetchStableRelease(
      HttpClient client) async {
    final _StableRedirectTag? redirect =
        await _fetchStableTagViaRedirect(client);
    if (redirect != null) {
      final Map<String, dynamic> release = buildStableReleaseFromTag(
        redirect.tag,
        repo: redirect.repo,
      );
      if (releaseMatchesUpdateChannel(release, UpdateChannel.stable)) {
        return release;
      }
    }
    return _fetchStableReleaseViaApi(client);
  }

  /// 原 `api.github.com/.../releases/latest` 直连路径（保留作 302 失败后的回退）。
  static Future<Map<String, dynamic>?> _fetchStableReleaseViaApi(
      HttpClient client) async {
    final body = await _httpGetStringFromGitHubRepos(
      client,
      (String repo) => 'https://api.github.com/repos/$repo/releases/latest',
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return null;
    final Map<String, dynamic> release =
        jsonDecode(body) as Map<String, dynamic>;
    if (!releaseMatchesUpdateChannel(release, UpdateChannel.stable)) {
      return null;
    }
    return release;
  }

  /// 逐候选（[updateCheckUrls]：直连优先 + 各 gh 代理前缀兜底）请求
  /// `releases/latest`，**关重定向跟随**读 3xx 的 `Location` 头，解析出 stable
  /// 最新 tag；任一候选拿到合法 tag 即整体成功，全失败返 null（TODO-404）。
  ///
  /// 复用 [fetchFirstSuccessfulBody] 保持「直连恒首位 / 逐镜像回退 / 任一成功即成功 /
  /// 全失败才失败 / 失败记日志」不变式（与 [_httpGetString] 同一范式）。
  static Future<_StableRedirectTag?> _fetchStableTagViaRedirect(
      HttpClient client) async {
    for (final String repo in kGitHubRepoFallbacks) {
      final String? tag = await fetchFirstSuccessfulBody(
        updateCheckUrls(stableReleasesLatestUrlForRepo(repo)),
        fetch: (String u) => _fetchRedirectTagOne(client, u),
        onFailure: (String host, Object? error) {
          if (error == null || isExpectedUpdateNetworkFailure(error)) {
            // TODO-1083：见上——预期的镜像不可达降级为诊断，不进用户可见报错日志。
            ErrorLogService.instance.logDiagnostic(
                'UpdateChecker.redirectTag',
                t.update_network_failure(
                  host: host,
                  reason: describeUpdateNetworkFailureReason(error),
                ));
          } else {
            ErrorLogService.instance.log('UpdateChecker.redirectTag', error);
          }
          debugPrint('[Fushi] update redirect-tag failed ($host): $error');
        },
      );
      if (tag != null) return _StableRedirectTag(repo: repo, tag: tag);
    }
    return null;
  }

  /// 单个候选 URL 的「读 302 → 解析 tag」一次尝试：关闭重定向跟随，3xx 且
  /// `Location` 头能解析出合法 tag 才返回该 tag（非 null = 成功），否则返 null（让回退
  /// 继续）。带 [_kPerAttemptTimeout] 整体超时——TCP 连上却挂起的镜像会被判死并回退。
  static Future<String?> _fetchRedirectTagOne(
    HttpClient client,
    String url,
  ) async {
    Future<String?> attempt() async {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      // 关重定向跟随：我们要的是 302 本身的 Location，而非跟到目标网页拿一坨 HTML。
      request.followRedirects = false;
      final HttpClientResponse response = await request.close();
      final int code = response.statusCode;
      final String? location =
          response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (code >= 300 && code < 400) {
        return parseLatestTagFromRedirectLocation(location);
      }
      return null;
    }

    return attempt().timeout(_kPerAttemptTimeout);
  }

  static void _showUpdateDialog(
    BuildContext context,
    String version,
    String releaseNotes,
    UpdateAsset asset,
    PlatformUpdater updater, {
    String customProxy = '',
  }) {
    showAppDialog<void>(
      context: context,
      builder: (ctx) => UpdateAvailableDialog(
        version: version,
        releaseNotes: releaseNotes,
        primaryLabel: t.update_download,
        onPrimary: () {
          Navigator.of(ctx).pop();
          _downloadAndInstall(context, asset, version, updater,
              customProxy: customProxy);
        },
      ),
    );
  }

  /// Fallback dialog for when no APK asset exists — opens browser.
  static void _showFallbackDialog(
    BuildContext context,
    String version,
    String releaseNotes,
    String htmlUrl,
  ) {
    showAppDialog<void>(
      context: context,
      builder: (ctx) => UpdateAvailableDialog(
        version: version,
        releaseNotes: releaseNotes,
        primaryLabel: t.update_download,
        onPrimary: () {
          Navigator.of(ctx).pop();
          launchUrl(
            Uri.parse(htmlUrl),
            mode: LaunchMode.externalApplication,
          );
        },
      ),
    );
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    UpdateAsset asset,
    String version,
    PlatformUpdater updater, {
    String customProxy = '',
  }) async {
    final String flowKey = _updateFlowKey(asset, version, updater);
    return _runExclusiveUpdateFlow(
      flowKey,
      () => _runDownloadAndInstall(context, asset, version, updater,
          customProxy: customProxy),
      onAlreadyActive: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.update_downloading)),
          );
        }
      },
    );
  }

  static String _updateFlowKey(
    UpdateAsset asset,
    String version,
    PlatformUpdater updater,
  ) =>
      '${updater.runtimeType}|$version|${asset.name}|${asset.url}';

  @visibleForTesting
  static Future<void> runExclusiveUpdateFlowForTest(
    String key,
    Future<void> Function() start, {
    void Function()? onAlreadyActive,
  }) {
    return _runExclusiveUpdateFlow(
      key,
      start,
      onAlreadyActive: onAlreadyActive,
    );
  }

  static Future<void> _runExclusiveUpdateFlow(
    String key,
    Future<void> Function() start, {
    void Function()? onAlreadyActive,
  }) async {
    final Future<void>? activeFlow = _activeUpdateFlows[key];
    if (activeFlow != null) {
      onAlreadyActive?.call();
      return activeFlow;
    }

    final Future<void> flow = Future<void>.sync(start);
    _activeUpdateFlows[key] = flow;
    try {
      await flow;
    } finally {
      if (identical(_activeUpdateFlows[key], flow)) {
        _activeUpdateFlows.remove(key);
      }
    }
  }

  /// BUG-427/TODO-852: the Android-only install-permission resume/retry net.
  ///
  /// [updater.apply] is invoked with the already-downloaded, already-validated
  /// [apkFile]. If it throws [PlatformException] with code
  /// `INSTALL_PERMISSION_REQUIRED` (Android API 26+ without "install unknown
  /// apps" permission), we hide the download overlay (without removing it, so
  /// the session stays alive), prompt the user, and on confirm recurse with the
  /// SAME [apkFile] — never re-downloading. Any other error rethrows so the
  /// caller's catch keeps the original "download failed" handling. Cancelling
  /// the prompt returns normally (the apk stays cached for a later attempt).
  static Future<void> _applyWithInstallRetry({
    required BuildContext context,
    required PlatformUpdater updater,
    required File apkFile,
    required String version,
    required ValueNotifier<bool> overlayVisible,
    required ValueNotifier<String> status,
  }) async {
    try {
      await updater.apply(apkFile, version);
    } on PlatformException catch (e) {
      if (e.code != 'INSTALL_PERMISSION_REQUIRED') rethrow;
      // Hide (do not remove) the overlay so the prompt is unobstructed while
      // the download session — including the cached apk — stays alive.
      overlayVisible.value = false;
      // BUG-427/TODO-852: the user may return from the system "install unknown
      // apps" setting after an Activity rebuild; bail if the context is gone
      // before driving any dialog/overlay off it.
      if (!context.mounted) return;
      final bool retry = await _promptInstallPermissionRetry(context);
      if (!retry) return;
      // Re-check after the (async) prompt: the Activity could have been rebuilt
      // while the dialog was up before we recurse and show the overlay again.
      if (!context.mounted) return;
      // Restore the overlay/installing status and retry with the SAME apk.
      overlayVisible.value = true;
      status.value = t.update_installing;
      await _applyWithInstallRetry(
        context: context,
        updater: updater,
        apkFile: apkFile,
        version: version,
        overlayVisible: overlayVisible,
        status: status,
      );
    }
  }

  /// BUG-427/TODO-852: ask the user to grant the install permission and retry.
  /// Returns true to retry, false to give up (apk stays cached). Guards against
  /// an unmounted context (the user may return from the system setting after an
  /// Activity rebuild, which would otherwise make showAppDialog throw).
  static Future<bool> _promptInstallPermissionRetry(
    BuildContext context,
  ) async {
    if (!context.mounted) return false;
    final bool? retry = await showAppDialog<bool>(
      context: context,
      builder: (_) => const InstallPermissionRetryDialog(),
    );
    return retry ?? false;
  }

  /// BUG-427/TODO-852: drive [_applyWithInstallRetry] from a widget test
  /// without a full download session (mirrors [runExclusiveUpdateFlowForTest]).
  @visibleForTesting
  static Future<void> applyWithInstallRetryForTest({
    required BuildContext context,
    required PlatformUpdater updater,
    required File apkFile,
    required String version,
    required ValueNotifier<bool> overlayVisible,
    required ValueNotifier<String> status,
  }) {
    return _applyWithInstallRetry(
      context: context,
      updater: updater,
      apkFile: apkFile,
      version: version,
      overlayVisible: overlayVisible,
      status: status,
    );
  }

  static Future<void> _runDownloadAndInstall(
    BuildContext context,
    UpdateAsset asset,
    String version,
    PlatformUpdater updater, {
    String customProxy = '',
  }) async {
    final progress = ValueNotifier<double>(0);
    // 体感快修（TODO-683）：进下载前显「正在连接更新源…」，首个进度/诊断信号到达再翻
    // 「正在下载更新…」。GFW 下坏候选累积超时期间不再让用户盯着「下载中 0%」误以为卡死。
    final status = ValueNotifier<String>(t.update_connecting);
    final statusController = UpdateDownloadStatusController(status);
    final diagnostics = ValueNotifier<UpdateDownloadDiagnostics?>(null);
    final overlayVisible = ValueNotifier<bool>(true);
    // 取消令牌（TODO-738）：遮罩「取消」按钮按下后置位，下载引擎在候选边界看到即中断。
    final cancellation = UpdateDownloadCancellation();
    late final OverlayEntry overlay;
    overlay = OverlayEntry(
      builder: (ctx) => ValueListenableBuilder<bool>(
        valueListenable: overlayVisible,
        builder: (_, visible, __) {
          if (!visible) return const SizedBox.shrink();
          return _DownloadOverlay(
            progress: progress,
            status: status,
            diagnostics: diagnostics,
            onHide: () => overlayVisible.value = false,
            onCancel: () {
              // 立即给反馈：置「正在取消…」并请求取消；引擎在下一个候选边界中断。
              cancellation.cancel();
              status.value = t.update_cancelling;
            },
          );
        },
      ),
    );

    final overlayState = Overlay.of(context);
    overlayState.insert(overlay);

    HttpClient? client;
    try {
      client = HttpClient();
      // TODO-808：建连超时从 30s 压到 10s——死镜像 TCP 连不上时更快判死、串行回退更快。
      client.connectionTimeout = const Duration(seconds: 10);
      client.idleTimeout = const Duration(seconds: 60);
      // 下载同样走系统/环境代理（与检查一致）：直连/镜像不通时经用户代理出口下载。
      // 手填代理同检查阶段优先（TODO-871/862）：全部下载入口都把 customProxy 透到这里。
      await applyAppProxy(client, userProxy: customProxy);

      // TODO-808：把「强断在途连接」回调登记进取消令牌——用户点「取消」时立即
      // close(force: true) 断开所有在途 socket，正在 await 的建连/读流即刻抛错跳出，
      // 不再等当前候选首字节/段超时走完。finally 的 client.close() 与此关两次幂等。
      final HttpClient abortClient = client;
      cancellation.registerAbort(() => abortClient.close(force: true));

      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      // 一个 asset 的实际下载（多镜像回退 + 分片 + 续传 + 校验全在引擎里）。抽成闭包，
      // 以便 TODO-1123 的「下载 404 → 重取 manifest 换新 URL 单次重试」复用同一套
      // 进度/诊断/取消接线，而不复制下载参数。
      final HttpClient downloadClient = client;
      Future<File> downloadAsset(UpdateAsset target) {
        return downloadUpdateAsset(
          asset: target,
          version: version,
          updatesDir: updatesDir,
          candidateUrls: updateCheckUrls(target.url),
          openUrl: (Uri uri, Map<String, String> headers) =>
              _openHttpDownload(downloadClient, uri, headers, version),
          onProgress: (double value) {
            // 首个真实进度（>0 = 已有字节落盘）才翻「下载中」；onProgress(0) 是请求前的
            // 初始占位，不能据它过早翻、否则 connecting 几乎不可见（失去体感意义）。
            if (value > 0) statusController.onFirstByte();
            progress.value = value;
          },
          onDiagnostics: (UpdateDownloadDiagnostics value) {
            // 诊断里 receivedBytes>0 同样表示已有字节到达，作为翻「下载中」的等价信号
            // （某些路径 diagnostics 比 onProgress 先携带非零字节，如续传起点）。
            if (value.receivedBytes > 0) statusController.onFirstByte();
            diagnostics.value = value;
          },
          onSourceFailure: (String url, Object error, StackTrace stack) {
            if (isExpectedUpdateNetworkFailure(error)) {
              // TODO-1083：见上——预期的镜像不可达降级为诊断，不进用户可见报错日志。
              ErrorLogService.instance.logDiagnostic(
                  'UpdateChecker.download',
                  t.update_network_failure(
                    host: hostLabelForUpdateUrl(url),
                    reason: describeUpdateNetworkFailureReason(error),
                  ));
            } else {
              ErrorLogService.instance
                  .log('UpdateChecker.download', error, stack);
            }
            debugPrint('[Fushi] download source failed ($url): $error');
          },
          cancellation: cancellation,
        );
      }

      // TODO-1123 / BUG-539 根因兜底：debug 通道的 rolling tag prune 竞态下，「检查」阶段
      // 解析出的 asset.url 可能在真正下载前被 CI 删掉 → 404。此时不再直接失败，而是重取一次
      // manifest（重走 selectAsset）拿到新 URL，与旧不同则用新 URL 单次重试。只重试一次，
      // 避免无限循环；重取仍 404 或拿不到新 URL 才把错误冒泡走原有失败路径。
      final File outFile = await downloadAssetWithStaleRetry(
        asset: asset,
        download: downloadAsset,
        reResolveAsset: () => _reResolveDownloadAsset(
          client: downloadClient,
          staleAsset: asset,
          version: version,
          updater: updater,
          customProxy: customProxy,
        ),
      );

      // TODO-1149：下载完成即回收同通道旧包 / 残留 staging 根（不等下次 GC / 启动 reconcile）。
      // 高频下载场景下每下一个新版就顺手清掉超出保留名额的旧安装包 + 空 staging 根，从源头
      // 抑制堆积。protect 刚下好的这个包（activeAssetFileName）——它正等安装 / handoff，绝不
      // 能被回收；handoff marker 尚未写入时靠这个名字排除，marker 写入后由 GC 自身保护。
      // best-effort：GC 全程 try/catch 吞异常，失败绝不影响安装流程。
      await _cleanupOldApks(version,
          activeAssetFileName: _leafName(outFile.path));

      status.value = t.update_installing;

      // BUG-427/TODO-852: on Android API 26+ without install permission the
      // native installApk throws PlatformException(INSTALL_PERMISSION_REQUIRED)
      // (the user is routed to the system setting). Wrap apply so that case is
      // handled in-place — keep the download session (overlay/notifiers/apk)
      // alive and let the user retry with the SAME already-downloaded apk —
      // instead of falling through to the catch below, showing
      // update_download_failed, and tearing the session + apk down (forcing a
      // re-download). Any other failure rethrows and follows the original path.
      if (context.mounted) {
        await _applyWithInstallRetry(
          context: context,
          updater: updater,
          apkFile: outFile,
          version: version,
          overlayVisible: overlayVisible,
          status: status,
        );
      } else {
        // Context torn down during download: fall back to a plain install
        // (no permission-retry UI possible without a live context). Any
        // PlatformException here surfaces through the catch below as before.
        await updater.apply(outFile, version);
      }
    } on UpdateDownloadCancelledException {
      // 用户主动取消（TODO-738）：不是失败，不记错误日志、不弹「下载失败」。
      debugPrint('[Fushi] update download cancelled by user');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.update_cancelled)),
        );
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('UpdateChecker.downloadAndInstall', e, stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${t.update_download_failed}: $e')),
        );
      }
    } finally {
      // TODO-808：先注销 abort 回调（避免 cancel 误关下一个 client），再常规关闭。
      // 取消路径已 close(force: true)，这里再 close() 幂等无害。
      cancellation.clearAbort();
      client?.close();
      overlay.remove();
      progress.dispose();
      status.dispose();
      diagnostics.dispose();
      overlayVisible.dispose();
    }
  }

  /// **可测的下载编排（TODO-1123 / BUG-539）**：先用 [asset] 下载；若失败被
  /// [isStaleAssetDownloadFailure] 判为 404（rolling tag prune 竞态导致手里 URL 过期），
  /// 调 [reResolveAsset] 重取一次 manifest 拿到新 asset，仅当新 URL 与旧不同才用它**单次**
  /// 重试下载。非 404 失败、重取拿不到新 asset、或新 URL 与旧相同 → 原样冒泡原错误
  /// （用户仍看到既有「下载失败」处理）。只重试一次，绝不无限循环。
  ///
  /// 用注入的 [download] / [reResolveAsset] 闭包承载 HTTP，纯逻辑可单测（无需真网络）。
  @visibleForTesting
  static Future<File> downloadAssetWithStaleRetry({
    required UpdateAsset asset,
    required Future<File> Function(UpdateAsset asset) download,
    required Future<UpdateAsset?> Function() reResolveAsset,
  }) async {
    try {
      return await download(asset);
    } catch (error, stack) {
      if (!isStaleAssetDownloadFailure(error)) {
        Error.throwWithStackTrace(error, stack);
      }
      debugPrint(
          '[Fushi] download asset 404 (stale manifest?); re-resolving manifest');
      final UpdateAsset? fresh = await reResolveAsset();
      if (fresh == null || fresh.url == asset.url) {
        // 重取拿不到新 asset，或 URL 未变（asset 真被删且 manifest 尚未更新）——
        // 无可重试的新目标，冒泡原始 404 走既有失败路径。
        Error.throwWithStackTrace(error, stack);
      }
      debugPrint('[Fushi] retrying download with re-resolved asset url');
      return download(fresh);
    }
  }

  /// **生产 re-resolve（TODO-1123 / BUG-539）**：下载 404 后重取本通道 release，重走
  /// [selectUpdateReleaseForCurrentPlatform] 拿到当前 [updater] 平台的最新 asset。
  ///
  /// 通道由 [version] 推断（[channelForUpdateVersion]，下载路径不显式携带 channel）。重取
  /// 用同一个已配代理的 [client]（走 [_fetchReleasesForChannel] 的镜像 manifest 优先 + API
  /// 回退）。任何失败/无匹配 → 返 null（调用方据此冒泡原始 404）。
  static Future<UpdateAsset?> _reResolveDownloadAsset({
    required HttpClient client,
    required UpdateAsset staleAsset,
    required String version,
    required PlatformUpdater updater,
    required String customProxy,
  }) async {
    try {
      final UpdateChannel channel = channelForUpdateVersion(version);
      final List<Map<String, dynamic>> releases =
          await _fetchReleasesForChannel(client, channel);
      // BUG-846：重取仅为换同版本的新下载 URL；本机 seq 从下载目标 [version] 串自取
      // （预发布串自带 seq；正式版无 buildNumber 上下文 → null → 同基保守，不影响换 URL）。
      final UpdateReleaseSelection? selection =
          await selectUpdateReleaseForCurrentPlatform(
        releases,
        currentVersion: version,
        currentReleaseSeq:
            currentReleaseSequence(version: version, buildNumber: null),
        channel: channel,
        updater: updater,
      );
      return selection?.asset;
    } catch (e, stack) {
      ErrorLogService.instance.log('UpdateChecker.reResolveAsset', e, stack);
      debugPrint('[Fushi] re-resolve download asset failed: $e');
      return null;
    }
  }

  static Future<void> reconcilePendingWindowsInstallerHandoff(
    BuildContext context,
    String currentVersion,
  ) async {
    if (!Platform.isWindows) return;
    if (!canShowDialogFromContext(context)) {
      const String message =
          'dialog navigator unavailable before handoff marker reconcile';
      ErrorLogService.instance.log('UpdateChecker.windowsHandoff', message);
      debugPrint('[Fushi] windows update handoff reconcile deferred: $message');
      return;
    }
    try {
      // BUG-533 根因修复：完整安装包的兜底 GC（`_cleanupOldApks` 的过期完整包回收，
      // TODO-1010）此前**只**在「检查更新」路径触发；用户关闭自动检查 / neverRemind
      // 短路时它永不跑，于是每升级一版残留的旧安装包（几百 MB）在 updates 目录里无限
      // 堆积（用户报告「安装包没有自动清除」）。handoff 成功即删（下方 TODO-1089）只
      // 负责**当次**那个包、且是一次性尝试（AV/句柄占用删失败即无重试锚点）。把兜底 GC
      // 挂到每次 Windows 启动的 reconcile 入口——不依赖任何用户动作，确定性回收历史堆积，
      // 也补回 handoff 一次性删除失败的漏网包。GC 自带 handoff 待装包保护，不误删待重启
      // 安装的包。
      await _cleanupOldApks(currentVersion);

      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: WindowsUpdateHandoff.markerFile(updatesDir),
        currentVersion: currentVersion,
      );
      if (result == null) return;

      // TODO-1089 根因修复：握手确认已成功安装到目标版本时，被这次更新安装的 setup.exe
      // 生命周期就此终结——立刻回收它，而不是等 `_cleanupOldApks` 的 7 天 GC 兜底（那个
      // GC 只在下次更新检查触发时才跑，关闭自动检查 / neverRemind 短路时永不跑，导致升级
      // 后 updates 目录里几百 MB 安装包一直残留，BUG-517）。纯函数守卫：仅安装成功分支、
      // 路径非空、且必须是 updates 根目录下的直属文件才删，绝不越界删任意路径。
      final String? installerToDelete = installerToDeleteAfterSuccessfulHandoff(
        installed: result.status == WindowsUpdateHandoffStatus.installed,
        installerPath: result.record.installerPath,
        updatesDirPath: updatesDir.path,
      );
      if (installerToDelete != null) {
        try {
          final File installer = File(installerToDelete);
          if (await installer.exists()) await installer.delete();
        } catch (e, stack) {
          // best-effort：删失败（AV/索引器占用等）不影响成功提示；下次 7 天 GC 兜底。
          ErrorLogService.instance
              .log('UpdateChecker.windowsHandoff.deleteInstaller', e, stack);
          debugPrint('[Fushi] delete installed update installer failed: $e');
        }
      }

      // TODO-1149 根因修复：安装成功时被这次更新用的下载 `.staging` 暂存根也生命周期终结
      // （promote 只删了内层 {id} 子目录，留下空根）——与安装包一起立刻回收，不留空根等
      // 7 天 GC 兜底（消除 updates 目录里空 `.staging` 根无限堆积）。纯函数守卫同安装包：
      // 仅安装成功、路径为 updates 根直属文件、按命名规则重建的 `.staging` 目录才删，绝不
      // 越界删任意路径。
      final String? stagingDirToDelete =
          stagingDirToDeleteAfterSuccessfulHandoff(
        installed: result.status == WindowsUpdateHandoffStatus.installed,
        installerPath: result.record.installerPath,
        updatesDirPath: updatesDir.path,
      );
      if (stagingDirToDelete != null) {
        try {
          final Directory stagingDir = Directory(stagingDirToDelete);
          if (await stagingDir.exists()) {
            await stagingDir.delete(recursive: true);
          }
        } catch (e, stack) {
          // best-effort：删失败（AV/句柄占用等）不影响成功提示；下次 GC 按 mtime 兜底。
          ErrorLogService.instance
              .log('UpdateChecker.windowsHandoff.deleteStaging', e, stack);
          debugPrint('[Fushi] delete installed update staging dir failed: $e');
        }
      }

      ErrorLogService.instance.log(
        'UpdateChecker.windowsHandoff',
        'status=${result.status.name}, target=${result.record.targetVersion}, '
            'current=$currentVersion, installer=${result.record.installerPath}, '
            'launcherPid=${result.record.launcherPid ?? 'unknown'}, '
            'pid=${result.record.installerPid ?? 'unknown'}, '
            'log=${result.record.innoLogPath}, '
            'logExists=${result.record.innoLogExists}, '
            'failureType=${result.record.installerFailureType ?? 'unknown'}',
      );
      if (!context.mounted) return;
      await showAppDialog<void>(
        context: context,
        barrierDismissible:
            result.status == WindowsUpdateHandoffStatus.installed,
        builder: (_) => WindowsUpdateHandoffResultDialog(result: result),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'UpdateChecker.windowsHandoff',
        e,
        stack,
      );
      debugPrint('[Fushi] windows update handoff reconcile failed: $e');
    }
  }

  /// macOS 自动安装跨重启失败退避（对齐 Windows）：读握手标记判断 [candidateVersion]
  /// 这个确切版本上一轮替换是否没落地（标记仍在 = 失败，reconcile 成功会删标记）；是
  /// 则返 true，调用方退回手动确认对话框，打断「装不成→重启→又自动装」死循环。读标记
  /// 出错 → false（fail-open）。仅 macOS 有意义（调用点已 `Platform.isMacOS` 门控）。
  static Future<bool> _shouldBackOffMacAutoInstall(
    String candidateVersion,
  ) async {
    try {
      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      return await MacUpdateHandoff.shouldBackOffAutoInstall(
        markerFile: MacUpdateHandoff.markerFile(updatesDir),
        candidateVersion: candidateVersion,
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('UpdateChecker.macAutoInstallBackoff', e, stack);
      debugPrint('[Fushi] mac auto-install backoff check failed: $e');
      return false;
    }
  }

  /// macOS 更新握手对账（Phase 3）：启动时读握手标记，据「当前版本是否已到目标」+
  /// 脚本写的 result 判定替换结果并提示，然后清理本轮 scratch。成功 → 删标记；未完成
  /// → 保留标记供退避、弹「更新未完成」并给「前往下载」入口。与 Windows 的
  /// [reconcilePendingWindowsInstallerHandoff] 平级，在 main.dart 启动流程并列调用。
  static Future<void> reconcilePendingMacInstallerHandoff(
    BuildContext context,
    String currentVersion,
  ) async {
    if (!Platform.isMacOS) return;
    if (!canShowDialogFromContext(context)) {
      const String message =
          'dialog navigator unavailable before mac handoff reconcile';
      ErrorLogService.instance.log('UpdateChecker.macHandoff', message);
      debugPrint('[Fushi] mac update handoff reconcile deferred: $message');
      return;
    }
    try {
      // 与 Windows 同：把兜底 GC 挂到启动 reconcile，不依赖用户动作确定性回收旧包。
      await _cleanupOldApks(currentVersion);

      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      final MacUpdateHandoffResult? result = await MacUpdateHandoff.reconcile(
        markerFile: MacUpdateHandoff.markerFile(updatesDir),
        resultFile: MacUpdateHandoff.resultFile(updatesDir),
        currentVersion: currentVersion,
      );
      if (result == null) return;

      final bool installed = result.status == MacUpdateHandoffStatus.installed;
      // 清理本轮替换 scratch（脚本/日志/暂存/备份）；标记本身仅在成功时已被 reconcile
      // 删除，未完成时保留供退避，故清理排除标记与 result 文件。
      await _cleanupMacUpdateScratch(updatesDir);

      ErrorLogService.instance.log(
        'UpdateChecker.macHandoff',
        'status=${result.status.name}, target=${result.record.targetVersion}, '
            'current=$currentVersion, '
            'message=${result.message ?? ''}',
      );

      if (!context.mounted) return;
      await showAppDialog<void>(
        context: context,
        barrierDismissible: installed,
        builder: (BuildContext ctx) {
          if (installed) {
            return AlertDialog(
              title: Text(t.update_install_success_title),
              content: Text(
                t.update_install_success_message(
                  version: result.record.targetVersion,
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(t.update_hide),
                ),
              ],
            );
          }
          final String detail = (result.message ?? '').trim();
          return AlertDialog(
            title: Text(t.update_install_incomplete_title),
            content: Text(
              detail.isEmpty
                  ? t.update_mac_install_incomplete_message
                  : '${t.update_mac_install_incomplete_message}\n\n$detail',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  launchUrl(
                    Uri.parse(
                        'https://github.com/$kGitHubRepo/releases/latest'),
                    mode: LaunchMode.externalApplication,
                  );
                },
                child: Text(t.update_download),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(t.update_hide),
              ),
            ],
          );
        },
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('UpdateChecker.macHandoff', e, stack);
      debugPrint('[Fushi] mac update handoff reconcile failed: $e');
    }
  }

  /// best-effort 清理 macOS 替换 scratch（`mac-update-*.sh` / `.log` / `.backup` /
  /// `.extracted` 等），排除握手标记与 result 文件（未完成时它们需保留供退避）。避免这些
  /// 非临时后缀的普通文件被 [selectStaleUpdateArtifacts] 当「安装包」占用 keep-newest 名额。
  static Future<void> _cleanupMacUpdateScratch(Directory updatesDir) async {
    try {
      if (!updatesDir.existsSync()) return;
      const String keepMarker = MacUpdateHandoff.markerFileName;
      const String keepResult = MacUpdateHandoff.resultFileName;
      for (final FileSystemEntity entity in updatesDir.listSync()) {
        final String name = _leafName(entity.path);
        if (!name.startsWith('mac-update-')) continue;
        if (name == keepMarker || name == keepResult) continue;
        try {
          if (entity is Directory) {
            entity.deleteSync(recursive: true);
          } else {
            entity.deleteSync();
          }
        } catch (e) {
          debugPrint('[UpdateChecker] mac scratch cleanup delete failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[UpdateChecker] mac scratch cleanup scan failed: $e');
    }
  }

  static bool canShowDialogFromContext(BuildContext context) {
    if (!context.mounted) return false;
    final NavigatorState? navigator =
        Navigator.maybeOf(context, rootNavigator: true);
    return navigator != null && navigator.mounted;
  }
}

/// stable 通道 release 列表页「最新版」入口。GitHub 对它返回 302 → 真实
/// `.../releases/tag/<tag>` 网页（**不是** API），公共 gh 代理会原样透传这个 302
/// （实测 ghfast.top 返回 302），所以纯 GFW 无代理用户也能从 `Location` 头解析出最新 tag
/// （TODO-404 / BUG-292）。与 `_fetchReleasesForChannel` 打的 `api.github.com` 形成
/// 对比：那个被镜像 403、检查注定失败。
const String kStableReleasesLatestUrl =
    'https://github.com/$kGitHubRepo/releases/latest';
const String kLegacyStableReleasesLatestUrl =
    'https://github.com/$kLegacyGitHubRepo/releases/latest';

@visibleForTesting
String stableReleasesLatestUrlForRepo(String repo) =>
    'https://github.com/$repo/releases/latest';

/// release 资产下载基址（`releases/download/<tag>/<name>` 拼在其后）。下载阶段经
/// [updateCheckUrls] 套镜像前缀；这些「下载」路径镜像真正可用（BUG-292）。
const String _kReleaseDownloadBase =
    'https://github.com/$kGitHubRepo/releases/download';

String _releaseDownloadBaseForRepo(String repo) {
  if (repo == kGitHubRepo) return _kReleaseDownloadBase;
  return 'https://github.com/$repo/releases/download';
}

/// **纯函数**：从 `releases/latest` 的 302 `Location` 头解析最新 tag。
///
/// [location] 形如 `https://github.com/owner/repo/releases/tag/v0.4.1`，也可能被镜像
/// 改写成 `https://ghfast.top/https://github.com/.../releases/tag/v0.4.1`、相对路径
/// `/owner/repo/releases/tag/v0.4.1`、或带 `?`/`#` 查询片段。安全做法：**只认
/// `releases/tag/<tag>` 这一段、丢弃域名**（防镜像把域名改写成钓鱼站后我们误信），用
/// `normalizeReleaseVersionTag` 归一化校验（非版本串返 null）。无 `releases/tag/` 段、
/// tag 段非合法版本、或入参为空 → 返 null（调用方回退 API 直连）。
@visibleForTesting
String? parseLatestTagFromRedirectLocation(String? location) {
  if (location == null) return null;
  final RegExpMatch? match =
      RegExp(r'releases/tag/(v?[^/?#]+)').firstMatch(location);
  if (match == null) return null;
  final String rawTag = Uri.decodeComponent(match.group(1)!);
  final String? normalized = normalizeReleaseVersionTag(rawTag);
  if (normalized == null || normalized.isEmpty) return null;
  // 把原始 tag 串保留下来交给下游（download URL 用原始 tag 段，含可能的前导 v），
  // 但调用方拿到这里的 [normalized] 仅用于「是否更新」判断；tag 段单独由
  // [buildStableReleaseFromTag] 处理。返回原始 tag 段（trim 后）以便拼下载 URL。
  return rawTag.trim();
}

/// **纯函数**：把 302 解析出的 stable [tag] 重建成与 GitHub API release 同构的 map，
/// 让它能直接喂给现有 [selectUpdateReleaseForCurrentPlatform] / `selectAsset` 整条链路，
/// 不在更新流程里另搞一套特例分支（TODO-404）。
///
/// 302 网页跳转拿不到 API 的 `assets` 清单与 `body`（release notes），故：
/// * `prerelease: false`、`draft: false`、`tag_name: <tag>` —— 让 stable 通道匹配通过。
/// * `assets`：用 [synthesizeStableAssetNames] 按命名规则重建（Android 全 ABI + Windows
///   setup），`browser_download_url` 拼 `releases/download/<tag>/<name>`，由 `selectAsset`
///   按平台/设备 ABI 自行挑。
/// * `body: ''`、`html_url`：notes 缺失时上层自然退化到「打开发布页」对话框。
@visibleForTesting
Map<String, dynamic> buildStableReleaseFromTag(
  String tag, {
  String repo = kGitHubRepo,
}) {
  final String trimmedTag = tag.trim();
  final String version = normalizeReleaseVersionTag(trimmedTag) ?? '';
  final List<Map<String, dynamic>> assets = <Map<String, dynamic>>[
    for (final String name in synthesizeStableAssetNames(version))
      <String, dynamic>{
        'name': name,
        'browser_download_url':
            '${_releaseDownloadBaseForRepo(repo)}/$trimmedTag/$name',
      },
  ];
  return <String, dynamic>{
    'tag_name': trimmedTag,
    'prerelease': false,
    'draft': false,
    'body': '',
    'html_url': '${stableReleasesHtmlUrlForRepo(repo)}/tag/$trimmedTag',
    'assets': assets,
  };
}

/// stable release 网页基址（`tag/<tag>` 拼其后，作为 fallback「打开发布页」目标）。
const String _kStableReleasesHtmlUrl =
    'https://github.com/$kGitHubRepo/releases';

String stableReleasesHtmlUrlForRepo(String repo) {
  if (repo == kGitHubRepo) return _kStableReleasesHtmlUrl;
  return 'https://github.com/$repo/releases';
}

/// CI 发到 `update-manifest` 孤儿分支的镜像清单本通道文件名前缀（TODO-705）。
/// 路径是 `raw.githubusercontent.com/<repo>/update-manifest/latest-<channel>.json`：
/// `raw` 资源经公共 gh 代理可透传（[updateCheckUrls] 套镜像前缀），是
/// 纯 GFW 下 beta/debug 检查唯一可成功路径（`api.github.com/.../releases` 列表被镜像 403）。
const String kBetaManifestUrl =
    'https://raw.githubusercontent.com/$kGitHubRepo/update-manifest/latest-beta.json';
const String kLegacyBetaManifestUrl =
    'https://raw.githubusercontent.com/$kLegacyGitHubRepo/update-manifest/latest-beta.json';

/// debug 通道镜像清单（见 [kBetaManifestUrl]）。
const String kDebugManifestUrl =
    'https://raw.githubusercontent.com/$kGitHubRepo/update-manifest/latest-debug.json';
const String kLegacyDebugManifestUrl =
    'https://raw.githubusercontent.com/$kLegacyGitHubRepo/update-manifest/latest-debug.json';

/// stable 通道镜像清单（BUG-846「谁后用谁」）。CI `publish_update_manifest.sh` 的 formal 分支
/// 已生成 `latest-stable.json`（`merge_update_manifest.py` 写顶层 `releaseSequence`）。客户端读它
/// 才能拿到正式版 release sequence，与同基预发布按「谁后构建谁赢」比较；读不到（手动 GitHub
/// Release 未发 manifest）则回退 302 跳转（无 seq，同基保守不 churn）。与 beta/debug 同构。
const String kStableManifestUrl =
    'https://raw.githubusercontent.com/$kGitHubRepo/update-manifest/latest-stable.json';
const String kLegacyStableManifestUrl =
    'https://raw.githubusercontent.com/$kLegacyGitHubRepo/update-manifest/latest-stable.json';

/// CI 生成镜像清单时识别的 schema 版本（TODO-705）。客户端只认该版本；
/// 未来结构不兼容的变更递增该号，旧客户端不识别则安全回退 API 直连。
const int kUpdateManifestSchemaVersion = 1;

/// **纯函数**：按通道返回镜像清单 URL（TODO-705 / BUG-846）。三通道均有 manifest
/// （stable 读它拿正式版 seq；读不到再回退 302）。
@visibleForTesting
String? manifestUrlForChannel(UpdateChannel channel) {
  final Map<String, String> urls = manifestUrlsForChannel(channel);
  if (urls.isEmpty) return null;
  return urls.values.first;
}

@visibleForTesting
Map<String, String> manifestUrlsForChannel(UpdateChannel channel) {
  return switch (channel) {
    UpdateChannel.beta => const <String, String>{
        kGitHubRepo: kBetaManifestUrl,
        kLegacyGitHubRepo: kLegacyBetaManifestUrl,
      },
    UpdateChannel.debug => const <String, String>{
        kGitHubRepo: kDebugManifestUrl,
        kLegacyGitHubRepo: kLegacyDebugManifestUrl,
      },
    UpdateChannel.stable => const <String, String>{
        kGitHubRepo: kStableManifestUrl,
        kLegacyGitHubRepo: kLegacyStableManifestUrl,
      },
  };
}

/// **纯函数**：把 CI 发到 `update-manifest` 分支的 `latest-<channel>.json` 原始响应体
/// 重建成与 GitHub API release 同构的 map，让它能直接喂给现有
/// [selectUpdateReleaseForCurrentPlatform] / `selectAsset` 整条链路，不在更新流程里另搭
/// 一套特例分支（TODO-705 方案 A，与 [buildStableReleaseFromTag] 同范式）。
///
/// manifest JSON 由 CI 生成，含：`schemaVersion`/`version`/`tag`/`prerelease`/`channel`/
/// `notes`/`assets[{name, browser_download_url}]`。重建映射：
/// * `tag_name: <tag>`、`prerelease: <prerelease>`、`draft: false` —— 让通道匹配通过。
/// * `body: <notes>` —— 从 manifest 恢复 release notes。
/// * `assets`：每项保留 `name` + **`browser_download_url`**（[UpdateAsset.fromReleaseAsset]
///   只读这个键，非 manifest 的 `url` 字段），由 `selectAsset` 按平台/设备 ABI 自行挑。
/// * `html_url`：拼发布页作为 fallback「打开发布页」目标。
///
/// **安全回退**：JSON 畸形 / 非对象 / `schemaVersion` 不等于 [kUpdateManifestSchemaVersion] /
/// 缺 `tag` / `assets` 缺合法项 → 返 null（调用方回退 API 直连，不报错）。
@visibleForTesting
Map<String, dynamic>? buildReleaseFromManifest(
  String body, {
  String repo = kGitHubRepo,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  final Object? schemaVersion = decoded['schemaVersion'];
  if (schemaVersion is! int || schemaVersion != kUpdateManifestSchemaVersion) {
    return null;
  }

  final Object? tagRaw = decoded['tag'];
  if (tagRaw is! String) return null;
  final String tag = tagRaw.trim();
  if (tag.isEmpty) return null;

  final String body0 =
      decoded['notes'] is String ? decoded['notes'] as String : '';
  final bool prerelease = decoded['prerelease'] == true;
  // TODO-1205 / BUG-846：透传顶层 `releaseSequence`（CI `merge_update_manifest.py` 写的
  // 全平台最大 seq）。正式版无预发布串带不了 seq，跨轨「谁后用谁」比较全靠它。
  final Object? topReleaseSeq = decoded['releaseSequence'];

  final List<Map<String, dynamic>> assets = <Map<String, dynamic>>[];
  final Object? assetsRaw = decoded['assets'];
  if (assetsRaw is List<dynamic>) {
    for (final Object? entry in assetsRaw) {
      if (entry is! Map<String, dynamic>) continue;
      final Object? name = entry['name'];
      final Object? downloadUrl = entry['browser_download_url'];
      if (name is! String || name.isEmpty) continue;
      if (downloadUrl is! String || downloadUrl.isEmpty) continue;
      final Map<String, dynamic> asset = <String, dynamic>{
        'name': name,
        'browser_download_url': downloadUrl,
      };
      // TODO-1205：透传 CI `merge_update_manifest.py` `_stamp` 写的 per-asset 印记（version/
      // tag/releaseSequence）。之前只留 name+url 丢了它们，客户端只能用顶层 tag（全平台
      // 最大 seq）判更新，落后平台被误判死循环；下游 UpdateAsset 读 version 按 asset 版本判。
      final Object? assetVersion = entry['version'];
      if (assetVersion is String && assetVersion.trim().isNotEmpty) {
        asset['version'] = assetVersion.trim();
      }
      final Object? assetTag = entry['tag'];
      if (assetTag is String && assetTag.trim().isNotEmpty) {
        asset['tag'] = assetTag.trim();
      }
      final Object? assetSeq = entry['releaseSequence'];
      if (assetSeq is int) {
        asset['releaseSequence'] = assetSeq;
      }
      assets.add(asset);
    }
  }
  if (assets.isEmpty) return null;

  return <String, dynamic>{
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': false,
    'body': body0,
    'html_url': '${stableReleasesHtmlUrlForRepo(repo)}/tag/$tag',
    if (topReleaseSeq is int) 'releaseSequence': topReleaseSeq,
    'assets': assets,
  };
}

class _StableRedirectTag {
  const _StableRedirectTag({
    required this.repo,
    required this.tag,
  });

  final String repo;
  final String tag;
}

@visibleForTesting
Future<UpdateReleaseSelection?> selectUpdateReleaseForCurrentPlatform(
  List<Map<String, dynamic>> releases, {
  required String currentVersion,
  // BUG-846「谁后用谁」：本机 release sequence（跨轨全序比较用）。null = 取不到（同基保守）。
  int? currentReleaseSeq,
  required UpdateChannel channel,
  required PlatformUpdater updater,
}) async {
  // BUG-846：合集是多轨并集（beta/debug 用户会同时拿到 stable/beta/debug 的 latest），
  // 必须先按「最新优先」排序再取第一个可用于本平台的更新，否则按拉取顺序会误选更旧的
  // release（如 beta 用户 beta 轨已到 1.3.0-beta.1，却因 stable 1.2.0 排在前而误选 1.2.0）。
  // 排序键=「谁后构建谁赢」：基版本降序 → 同基按 release sequence 降序（三通道同尺，正式版
  // seq 从 manifest 顶层 releaseSequence 取，预发布 seq 即版本串尾号）。与 isUpdateVersionNewer
  // 同尺，消除「排序偏预发布轨 vs 判据偏正式版」不一致这个乒乓根源。
  final List<Map<String, dynamic>> ordered = releases
      .where((Map<String, dynamic> r) => releaseEligibleForChannel(r, channel))
      .toList()
    ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final String va =
          normalizeReleaseVersionTag(a['tag_name'] as String? ?? '') ?? '';
      final String vb =
          normalizeReleaseVersionTag(b['tag_name'] as String? ?? '') ?? '';
      // 降序：新的在前。seq 从各自 release map 顶层取（正式版 302 回退无 → null）。
      return _compareReleaseRecency(vb, va,
          seqA: b['releaseSequence'] as int?,
          seqB: a['releaseSequence'] as int?);
    });

  UpdateReleaseSelection? fallback;
  for (final Map<String, dynamic> release in ordered) {
    final String? topVersion =
        normalizeReleaseVersionTag(release['tag_name'] as String? ?? '');
    if (topVersion == null || topVersion.isEmpty) continue;
    // 粗过滤：顶层 tag 是全平台最大 seq（TODO-1173），连它都不比本机新，
    // 本 release 对任何平台都无更新。保留这层既避开 up-to-date 时多余的 selectAsset。
    // BUG-846：远端 seq 用本 release 顶层 releaseSequence（正式版无预发布串靠它）。
    if (!isUpdateVersionNewer(topVersion, currentVersion, channel,
        remoteSeq: release['releaseSequence'] as int?,
        localSeq: currentReleaseSeq)) {
      continue;
    }

    final List<Map<String, dynamic>> assetMaps =
        (release['assets'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
    // BUG-846：asset 命名按 release **自身所属轨道**过滤（stable 包无 `-debug.` 后缀，
    // debug 包才有），故 selectAsset 传 release 自身轨道而非用户通道——否则 debug 用户
    // 处理并入合集的 stable release 时，会因 stable 包不含 `-debug.` 后缀被误拒、选不到包。
    // 「这个 release 属于哪个合集」的准入已由 releaseEligibleForChannel 在上面把关。
    final UpdateChannel releaseTrack = channelForUpdateVersion(topVersion);
    final UpdateAsset? asset =
        await updater.selectAsset(assetMaps, channel: releaseTrack);

    // TODO-1205：用**所选 asset 自身版本**判更新 + 显示，而非顶层 tag（全平台最大 seq）。
    // 顶层 6636 但安卓 asset=6621==本机时，用顶层会「有更新」→装回 6621→再提示的死循环。
    // 无版本印记（API/合成 stable/旧 manifest）→ fail-open 回退顶层。平台通用，非安卓特例。
    final String? assetVersion =
        asset == null ? null : normalizeReleaseVersionTag(asset.version ?? '');
    final String effectiveVersion = assetVersion ?? topVersion;
    if (asset != null &&
        !isUpdateVersionNewer(effectiveVersion, currentVersion, channel,
            remoteSeq: release['releaseSequence'] as int?,
            localSeq: currentReleaseSeq)) {
      // 顶层更新但本平台 asset 已是本机版本（或更旧）→ 对本机不是更新，跳过。
      continue;
    }

    final UpdateReleaseSelection selection = UpdateReleaseSelection(
      release: release,
      version: effectiveVersion,
      releaseNotes: release['body'] as String? ?? '',
      asset: asset,
    );
    if (asset != null) return selection;
    // Self-installing platforms must ignore wrong-platform releases instead of
    // treating independent Android/Windows workflow run numbers as comparable.
    if (!updater.supportsInAppInstall) fallback ??= selection;
  }
  return fallback;
}

@visibleForTesting
String? normalizeReleaseVersionTag(String tag) {
  final String normalized = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');
  if (!_looksLikeVersion(normalized)) return null;
  return _stripBuildMetadata(normalized);
}

@visibleForTesting
bool releaseMatchesUpdateChannel(
  Map<String, dynamic> release,
  UpdateChannel channel,
) {
  if (release['draft'] == true) return false;
  final String tag = release['tag_name'] as String? ?? '';
  final String? version = normalizeReleaseVersionTag(tag);
  if (version == null) return false;
  final bool prerelease = release['prerelease'] == true;
  return switch (channel) {
    UpdateChannel.stable => !prerelease && _prereleasePart(version) == null,
    UpdateChannel.beta =>
      prerelease && _releaseTagMatchesChannel(tag, UpdateChannel.beta),
    UpdateChannel.debug =>
      prerelease && _releaseTagMatchesChannel(tag, UpdateChannel.debug),
  };
}

/// BUG-846 嵌套合集准入的 release 过滤：[release] 本身所属通道被用户 [channel] 的嵌套
/// 合集接纳即合格（越激进通道合集越大）。与 [releaseMatchesUpdateChannel]（精确同通道）
/// 区别：后者只接纳恰好本通道，供 [_fetchStableRelease] 校验「这确实是 stable」等精确用途；
/// 本函数供选择/过滤阶段判「属于本通道合集」，复用精确判据不新造 pattern。
@visibleForTesting
bool releaseEligibleForChannel(
  Map<String, dynamic> release,
  UpdateChannel channel,
) {
  for (final UpdateChannel track in _channelsAdmittedBy(channel)) {
    if (releaseMatchesUpdateChannel(release, track)) return true;
  }
  return false;
}

/// TODO-1024 / BUG-479：通道感知的「远端 [tag] 是否比本地 [current] 新」公开判定，供
/// 缓存优先的乐观反馈（手动「检查更新」据缓存 tag 立刻分流「发现新版」/「已是最新」）。
/// 薄包 [isUpdateVersionNewer]（后者 `@visibleForTesting`，仅本库/测试内可用）。
bool updateTagIsNewerThanCurrent(
  String tag,
  String current,
  UpdateChannel channel, {
  int? remoteSeq,
  int? localSeq,
}) =>
    isUpdateVersionNewer(tag, current, channel,
        remoteSeq: remoteSeq, localSeq: localSeq);

/// **纯函数**：取版本的 release sequence（= `git rev-list --count HEAD`，三通道同一把尺）。
/// 预发布串 `-beta.<seq>` / `-debug.<seq>` 的尾段数字**就是** seq（CI `TAG=v${VERSION}-<ch>.${SEQ}`）；
/// 正式版无预发布段，seq 由 [explicitSeq]（manifest 顶层 `releaseSequence` / 本机 versionCode 反解）
/// 提供。都取不到 → null（同基无法判先后 → 调用方保守不更新，绝不 churn）。
int? _releaseSeqOf(String version, int? explicitSeq) {
  final String? pre = _prereleasePart(_stripBuildMetadata(version));
  if (pre != null) {
    final int? seq = int.tryParse(pre.split('.').last);
    if (seq != null) return seq;
  }
  return explicitSeq;
}

@visibleForTesting
bool isUpdateVersionNewer(
  String remote,
  String local,
  UpdateChannel channel, {
  // BUG-846「谁后用谁」：跨轨全序比较用的 release sequence。远端正式版无预发布串带不了 seq，
  // 靠 [remoteSeq]（manifest 顶层）；本机正式版靠 [localSeq]（versionCode 反解）。预发布串自带。
  int? remoteSeq,
  int? localSeq,
}) {
  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());

  // BUG-846 嵌套合集准入：越激进的通道合集越大——stable 只收 stable；beta 收
  // {stable,beta}；debug 收 {stable,beta,debug}。远端版本所属轨道若不在本通道合集里，
  // 一律不是更新（让 beta/debug 用户能收到更新的正式版/更高基版本，永不掉队）。
  if (!_channelAdmitsVersion(remoteVersion, channel)) return false;

  // 基版本不同：高基永远更新（pubspec 基版本随 commit 单调递增，高基=更晚构建）。
  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  // 同基：按 release sequence「谁后构建谁赢」（BUG-846 正式↔调试来回更新根治）。序号跨三
  // 通道同尺（都是 git rev-list --count HEAD），故正式版/beta/debug 同基可直接比先后，不再
  // 用 semver 的「正式版>预发布」——那与「预发布轨更晚构建」矛盾，正是乒乓根源。
  final int? rSeq = _releaseSeqOf(remoteVersion, remoteSeq);
  final int? lSeq = _releaseSeqOf(localVersion, localSeq);
  if (rSeq != null && lSeq != null) return rSeq > lSeq;

  // 任一侧序号未知（如正式版仅走 302 拿不到 seq，或本机构建号缺失）：同基无法判先后 →
  // 保守不更新。绝不在无法证实「远端更晚」时把用户在同基的两个轨道间来回推；等基版本上升
  // （上面 baseCompare>0）再更新。fail-open：不误升。
  return false;
}

/// BUG-846 嵌套合集：用户通道 [channel] 能接纳的所有轨道（含更保守的轨道），从最保守
/// 到本通道。「合集逐渐变大」——stable→[stable]；beta→[stable,beta]；
/// debug→[stable,beta,debug]。同时驱动拉取阶段的合集并集与准入判定。
List<UpdateChannel> _channelsAdmittedBy(UpdateChannel channel) {
  return switch (channel) {
    UpdateChannel.stable => const <UpdateChannel>[UpdateChannel.stable],
    UpdateChannel.beta => const <UpdateChannel>[
        UpdateChannel.stable,
        UpdateChannel.beta,
      ],
    UpdateChannel.debug => const <UpdateChannel>[
        UpdateChannel.stable,
        UpdateChannel.beta,
        UpdateChannel.debug,
      ],
  };
}

/// BUG-846：远端 [version] 所属轨道是否被 [channel] 的嵌套合集接纳。轨道由
/// [channelForUpdateVersion] 推断（正式版 → stable，`-beta.N`/`-debug.N` → 对应轨），
/// 与既有判据同一套 pattern，不新造。
bool _channelAdmitsVersion(String version, UpdateChannel channel) {
  return _channelsAdmittedBy(channel)
      .contains(channelForUpdateVersion(version));
}

/// **纯函数（BUG-846「谁后用谁」）**：本机安装版本的 release sequence，供跨轨全序比较。
///
/// beta/debug 包版本串已带 `-<channel>.<seq>` → 直接取尾号；无后缀 `X.Y.Z`（正式版包 / 本地
/// `flutter build`）→ 用平台构建号 [buildNumber]（Android versionCode / 桌面 raw build number）
/// 反解（[_releaseSequenceFromPlatformBuildNumber]）。取不到 → null（同基无法判先后 → 保守）。
///
/// **不再**把无后缀正式版伪造成 `<base>-<channel>.<seq>` 串（旧 `effectiveCurrentVersionFor…`
/// 的做法）——那会把真正的正式版安装误标成本通道预发布轨，触发正式↔调试来回更新（BUG-846
/// 乒乓根因）。现在只提取序号、不改轨道标签，正式版仍是正式版。
///
/// 生产调用点：[scheduleCheck] 内部（网络路径）+ 设置页手动检查的缓存乐观比较路径。
int? currentReleaseSequence({
  required String version,
  required String? buildNumber,
}) {
  return _releaseSeqOf(
    _stripBuildMetadata(version.trim()),
    _releaseSequenceFromPlatformBuildNumber(buildNumber),
  );
}

/// **纯函数（BUG-457）**：从平台构建号还原 CI release sequence（= `git rev-list --count HEAD`）。
///
/// * Android release APK 的 versionCode = `versionCodeBase(1e9) + 100*seq + abiOffset`
///   （见 `android/app/build.gradle` TODO-414），故 `>= 1e9` 时反解 `(code-1e9)~/100`，
///   并校验 abiOffset ∈ [0,3]（现有 ABI 分片偏移）以防误解非 CI 构建号。
/// * 桌面构建把原始 Flutter build number（= seq）直接透出，`< 1e9` 时原样返回。
///
/// 非数字 / 非正 / abiOffset 越界 → 返 null（调用方 fail-open 回退无还原，绝不误升）。
int? _releaseSequenceFromPlatformBuildNumber(String? buildNumber) {
  final int? parsed = int.tryParse(buildNumber?.trim() ?? '');
  if (parsed == null || parsed <= 0) return null;

  const int androidVersionCodeBase = 1000000000;
  if (parsed < androidVersionCodeBase) return parsed;

  final int adjusted = parsed - androidVersionCodeBase;
  final int abiOffset = adjusted % 100;
  if (abiOffset > 3) return null;
  final int releaseSequence = adjusted ~/ 100;
  return releaseSequence > 0 ? releaseSequence : null;
}

bool isVersionNewer(String remote, String local) {
  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());
  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  final String? remotePrerelease = _prereleasePart(remoteVersion);
  final String? localPrerelease = _prereleasePart(localVersion);
  if (remotePrerelease == null && localPrerelease != null) return true;
  if (remotePrerelease == null || localPrerelease == null) return false;
  return _comparePrerelease(remotePrerelease, localPrerelease) > 0;
}

/// BUG-846「谁后用谁」候选新旧比较（供合集并集选择排序，非「是否更新」判定）：`>0` 表示
/// [a] 比 [b] 更新。基版本降序主导；同基按 release sequence（`git rev-list --count HEAD`，三
/// 通道同尺）降序——正式版 seq 由 [seqA]/[seqB]（manifest 顶层 releaseSequence）提供，预发布
/// seq 即版本串尾号。序号缺失（正式版 302 回退无 seq）→ 同基视为并列（稳定排序保原序）。
/// 与 [isUpdateVersionNewer] 同尺，消除「排序偏预发布轨 vs 判据偏正式版」不一致这个乒乓根源。
int _compareReleaseRecency(String a, String b, {int? seqA, int? seqB}) {
  final String va = _stripBuildMetadata(a.trim());
  final String vb = _stripBuildMetadata(b.trim());
  final int baseCompare = _compareBaseVersion(va, vb);
  if (baseCompare != 0) return baseCompare;
  final int? ra = _releaseSeqOf(va, seqA);
  final int? rb = _releaseSeqOf(vb, seqB);
  if (ra != null && rb != null) return ra.compareTo(rb);
  return 0;
}

String _stripBuildMetadata(String version) => version.split('+').first;

bool _looksLikeVersion(String version) => RegExp(
      r'^\d+(?:\.\d+)*(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z][0-9A-Za-z.-]*)?$',
    ).hasMatch(version);

String _basePart(String version) =>
    _stripBuildMetadata(version).split('-').first;

String? _prereleasePart(String version) {
  final String stripped = _stripBuildMetadata(version);
  final int hyphen = stripped.indexOf('-');
  if (hyphen < 0 || hyphen == stripped.length - 1) return null;
  return stripped.substring(hyphen + 1);
}

List<int> _baseSegments(String version) => _basePart(version)
    .split('.')
    .map((String part) => int.tryParse(part) ?? 0)
    .toList(growable: false);

int _compareBaseVersion(String remote, String local) {
  final List<int> r = _baseSegments(remote);
  final List<int> l = _baseSegments(local);
  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    final int rv = i < r.length ? r[i] : 0;
    final int lv = i < l.length ? l[i] : 0;
    if (rv != lv) return rv.compareTo(lv);
  }
  return 0;
}

/// **纯函数（TODO-1123 / BUG-539）**：从版本串推断它属于哪个更新通道，供下载 404 后
/// 「重取本通道 manifest」的 re-resolve 使用（下载路径不再显式携带 channel）。
///
/// debug 预发布形如 `1.0.1-debug.6421`、beta 形如 `1.0.1-beta.3`，否则视为 stable。
/// 与 [_versionBelongsToChannel] / [releaseMatchesUpdateChannel] 的通道判定同一套 pattern，
/// 不新造判据。
@visibleForTesting
UpdateChannel channelForUpdateVersion(String version) {
  if (_versionBelongsToChannel(version, UpdateChannel.debug)) {
    return UpdateChannel.debug;
  }
  if (_versionBelongsToChannel(version, UpdateChannel.beta)) {
    return UpdateChannel.beta;
  }
  return UpdateChannel.stable;
}

bool _versionBelongsToChannel(String version, UpdateChannel channel) {
  final String normalized = _stripBuildMetadata(version.trim());
  return switch (channel) {
    UpdateChannel.beta => _kBetaVersionPattern.hasMatch(normalized),
    UpdateChannel.debug => _kDebugVersionPattern.hasMatch(normalized),
    UpdateChannel.stable => false,
  };
}

bool _releaseTagMatchesChannel(String tag, UpdateChannel channel) {
  final String normalized = tag.trim();
  return switch (channel) {
    UpdateChannel.beta => _kBetaReleaseTagPattern.hasMatch(normalized),
    UpdateChannel.debug => _kDebugReleaseTagPattern.hasMatch(normalized),
    UpdateChannel.stable => false,
  };
}

int _comparePrerelease(String remote, String local) {
  final List<String> r = remote.split('.');
  final List<String> l = local.split('.');
  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    if (i >= r.length) return -1;
    if (i >= l.length) return 1;
    final int part = _comparePrereleasePart(r[i], l[i]);
    if (part != 0) return part;
  }
  return 0;
}

int _comparePrereleasePart(String remote, String local) {
  final int? ri = int.tryParse(remote);
  final int? li = int.tryParse(local);
  if (ri != null && li != null) return ri.compareTo(li);
  if (ri != null) return -1;
  if (li != null) return 1;
  return remote.compareTo(local);
}
