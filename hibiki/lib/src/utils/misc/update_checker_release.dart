part of 'update_checker.dart';

const String kGitHubRepo = 'hajisensai/hibiki';
const String kLegacyGitHubRepo = 'hdjsadgfwtg/hibiki';

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
    final UpdateChannel channel = debugChannel
        ? UpdateChannel.debug
        : betaChannel
            ? UpdateChannel.beta
            : UpdateChannel.stable;
    final Completer<void> completer = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _check(context, currentVersion,
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

  static Future<void> _cleanupOldApks(String _) async {
    try {
      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      if (!updatesDir.existsSync()) return;
      final DateTime cutoff = DateTime.now().subtract(const Duration(days: 7));

      // TODO-1010：保护 Windows 待重启安装的 handoff 安装包——若存在 handoff 标记，
      // 它指向的安装包正等下次启动安装，绝不能当旧包回收。
      String? handoffInstallerName;
      try {
        final WindowsUpdateHandoffRecord? record =
            await WindowsUpdateHandoff.read(
                WindowsUpdateHandoff.markerFile(updatesDir));
        if (record != null && record.installerPath.isNotEmpty) {
          handoffInstallerName =
              record.installerPath.replaceAll(r'\', '/').split('/').last;
        }
      } catch (e) {
        debugPrint('[UpdateChecker] cleanup read handoff failed: $e');
      }

      final List<UpdateDirEntry> dirEntries = <UpdateDirEntry>[];
      for (final FileSystemEntity entity in updatesDir.listSync()) {
        final String name = entity.uri.pathSegments.last;
        if (entity is Directory) {
          dirEntries.add(UpdateDirEntry(
            name: name,
            isDirectory: true,
            modified: DateTime.fromMillisecondsSinceEpoch(0),
          ));
          if (!name.endsWith('.staging')) continue;
          for (final FileSystemEntity child in entity.listSync()) {
            try {
              if (child.statSync().modified.isBefore(cutoff)) {
                child.deleteSync(recursive: true);
              }
            } catch (e) {
              debugPrint('[UpdateChecker] cleanup staging failed: $e');
            }
          }
          try {
            if (entity.listSync().isEmpty) entity.deleteSync();
          } catch (_) {
            // The staging root can stay around until the next cleanup pass.
          }
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
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: dirEntries,
        cutoff: cutoff,
        handoffInstallerFileName: handoffInstallerName,
      );
      for (final String name in stale) {
        try {
          File('${updatesDir.path}${Platform.pathSeparator}$name').deleteSync();
        } catch (e) {
          debugPrint('[UpdateChecker] cleanup stale installer failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[UpdateChecker] cleanup scan failed: $e');
    }
  }

  static Future<void> _check(
    BuildContext context,
    String currentVersion, {
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
      await applyUpdateProxy(client, userProxy: customProxy);

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
        channel: channel,
        updater: updater,
      );
      if (selection == null) {
        // 无匹配 release = 等价「无可更新版本」（TODO-898）。
        onUpToDate?.call();
        return;
      }
      final Map<String, dynamic> json = selection.release;

      final String? tagName =
          normalizeReleaseVersionTag(json['tag_name'] as String? ?? '');
      if (tagName == null || tagName.isEmpty) {
        // tag 为空 = 等价「无可更新版本」（TODO-898）。
        onUpToDate?.call();
        return;
      }

      // TODO-1024 / BUG-479：一次成功网络检查已拿到本通道最新 tag，写回缓存供下次
      // 「检查更新」乐观即时显示（不再每次冷查 GitHub 才知道结果）。写缓存的失败绝不
      // 能影响本轮检查流程，吞掉并记日志即可。
      if (cacheWriter != null) {
        final UpdateCheckCacheEntry entry = UpdateCheckCacheEntry(
          lastCheckEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
          latestTag: tagName,
          htmlUrl: (json['html_url'] as String?) ?? '',
          channel: channel,
        );
        try {
          await cacheWriter(entry);
        } catch (e) {
          debugPrint('[UpdateChecker] write update cache failed: $e');
        }
      }

      if (!isUpdateVersionNewer(tagName, currentVersion, channel)) {
        // 已是最新（TODO-898）。
        onUpToDate?.call();
        return;
      }

      final releaseBody = json['body'] as String? ?? '';

      final assets = json['assets'] as List<dynamic>? ?? [];
      final List<Map<String, dynamic>> assetMaps =
          assets.whereType<Map<String, dynamic>>().toList(growable: false);
      final UpdateAsset? asset =
          await updater.selectAsset(assetMaps, channel: channel);
      final String? downloadUrl = asset?.url;

      // 无适配本平台的 asset（iOS / 未实现桌面 / 该 release 没传本平台包）→ 打开发布页。
      if (downloadUrl == null) {
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null && context.mounted) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
        return;
      }
      if (!context.mounted) return;
      if (canInstall && autoInstall) {
        _downloadAndInstall(context, asset!, tagName, updater,
            customProxy: customProxy);
      } else if (canInstall) {
        _showUpdateDialog(context, tagName, releaseBody, asset!, updater,
            customProxy: customProxy);
      } else {
        // 能检查但不能自装（本期 iOS/mac/Linux）：弹「前往下载」打开发布页。
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('UpdateChecker.check', e, stack);
      debugPrint('[Hibiki] update check failed: $e');
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
          ErrorLogService.instance.log(
              'UpdateChecker.httpGet',
              t.update_network_failure(
                host: host,
                reason: describeUpdateNetworkFailureReason(error),
              ));
        } else {
          ErrorLogService.instance.log('UpdateChecker.httpGet', error);
        }
        debugPrint('[Hibiki] update check failed ($host): $error');
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

  static Future<List<Map<String, dynamic>>> _fetchReleasesForChannel(
    HttpClient client,
    UpdateChannel channel,
  ) async {
    if (channel == UpdateChannel.stable) {
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
            ErrorLogService.instance.log(
                'UpdateChecker.redirectTag',
                t.update_network_failure(
                  host: host,
                  reason: describeUpdateNetworkFailureReason(error),
                ));
          } else {
            ErrorLogService.instance.log('UpdateChecker.redirectTag', error);
          }
          debugPrint('[Hibiki] update redirect-tag failed ($host): $error');
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
      await applyUpdateProxy(client, userProxy: customProxy);

      // TODO-808：把「强断在途连接」回调登记进取消令牌——用户点「取消」时立即
      // close(force: true) 断开所有在途 socket，正在 await 的建连/读流即刻抛错跳出，
      // 不再等当前候选首字节/段超时走完。finally 的 client.close() 与此关两次幂等。
      final HttpClient abortClient = client;
      cancellation.registerAbort(() => abortClient.close(force: true));

      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      final File outFile = await downloadUpdateAsset(
        asset: asset,
        version: version,
        updatesDir: updatesDir,
        candidateUrls: updateCheckUrls(asset.url),
        openUrl: (Uri uri, Map<String, String> headers) =>
            _openHttpDownload(client!, uri, headers, version),
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
            ErrorLogService.instance.log(
                'UpdateChecker.download',
                t.update_network_failure(
                  host: hostLabelForUpdateUrl(url),
                  reason: describeUpdateNetworkFailureReason(error),
                ));
          } else {
            ErrorLogService.instance
                .log('UpdateChecker.download', error, stack);
          }
          debugPrint('[Hibiki] download source failed ($url): $error');
        },
        cancellation: cancellation,
      );

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
      debugPrint('[Hibiki] update download cancelled by user');
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

  static Future<void> reconcilePendingWindowsInstallerHandoff(
    BuildContext context,
    String currentVersion,
  ) async {
    if (!Platform.isWindows) return;
    if (!canShowDialogFromContext(context)) {
      const String message =
          'dialog navigator unavailable before handoff marker reconcile';
      ErrorLogService.instance.log('UpdateChecker.windowsHandoff', message);
      debugPrint(
          '[Hibiki] windows update handoff reconcile deferred: $message');
      return;
    }
    try {
      final Directory updatesDir = await _updatesDirectoryForCurrentPlatform();
      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: WindowsUpdateHandoff.markerFile(updatesDir),
        currentVersion: currentVersion,
      );
      if (result == null) return;

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
      debugPrint('[Hibiki] windows update handoff reconcile failed: $e');
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

/// CI 生成镜像清单时识别的 schema 版本（TODO-705）。客户端只认该版本；
/// 未来结构不兼容的变更递增该号，旧客户端不识别则安全回退 API 直连。
const int kUpdateManifestSchemaVersion = 1;

/// **纯函数**：按通道返回镜像清单 URL（TODO-705）。beta/debug 有 manifest；
/// stable 走 302 跳转、不走 manifest（返 null）。
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
    UpdateChannel.stable => const <String, String>{},
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

  final List<Map<String, dynamic>> assets = <Map<String, dynamic>>[];
  final Object? assetsRaw = decoded['assets'];
  if (assetsRaw is List<dynamic>) {
    for (final Object? entry in assetsRaw) {
      if (entry is! Map<String, dynamic>) continue;
      final Object? name = entry['name'];
      final Object? downloadUrl = entry['browser_download_url'];
      if (name is! String || name.isEmpty) continue;
      if (downloadUrl is! String || downloadUrl.isEmpty) continue;
      assets.add(<String, dynamic>{
        'name': name,
        'browser_download_url': downloadUrl,
      });
    }
  }
  if (assets.isEmpty) return null;

  return <String, dynamic>{
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': false,
    'body': body0,
    'html_url': '${stableReleasesHtmlUrlForRepo(repo)}/tag/$tag',
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
  required UpdateChannel channel,
  required PlatformUpdater updater,
}) async {
  UpdateReleaseSelection? fallback;
  for (final Map<String, dynamic> release in releases) {
    if (!releaseMatchesUpdateChannel(release, channel)) continue;
    final String? version =
        normalizeReleaseVersionTag(release['tag_name'] as String? ?? '');
    if (version == null || version.isEmpty) continue;
    if (!isUpdateVersionNewer(version, currentVersion, channel)) continue;

    final List<Map<String, dynamic>> assetMaps =
        (release['assets'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
    final UpdateAsset? asset =
        await updater.selectAsset(assetMaps, channel: channel);
    final UpdateReleaseSelection selection = UpdateReleaseSelection(
      release: release,
      version: version,
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

/// TODO-1024 / BUG-479：通道感知的「远端 [tag] 是否比本地 [current] 新」公开判定，供
/// 缓存优先的乐观反馈（手动「检查更新」据缓存 tag 立刻分流「发现新版」/「已是最新」）。
/// 薄包 [isUpdateVersionNewer]（后者 `@visibleForTesting`，仅本库/测试内可用）。
bool updateTagIsNewerThanCurrent(
  String tag,
  String current,
  UpdateChannel channel,
) =>
    isUpdateVersionNewer(tag, current, channel);

@visibleForTesting
bool isUpdateVersionNewer(
  String remote,
  String local,
  UpdateChannel channel,
) {
  if (channel == UpdateChannel.stable) return isVersionNewer(remote, local);

  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());
  if (!_versionBelongsToChannel(remoteVersion, channel)) return false;

  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  final String? localPrerelease = _prereleasePart(localVersion);
  if (localPrerelease == null) return true;
  if (!_prereleaseBelongsToChannel(localPrerelease, channel)) return true;

  final String remotePrerelease = _prereleasePart(remoteVersion)!;
  return _comparePrerelease(remotePrerelease, localPrerelease) > 0;
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

bool _prereleaseBelongsToChannel(String prerelease, UpdateChannel channel) {
  final String normalized = prerelease.trim();
  return switch (channel) {
    UpdateChannel.beta => _kBetaVersionPattern.hasMatch('0.0.0-$normalized'),
    UpdateChannel.debug => _kDebugVersionPattern.hasMatch('0.0.0-$normalized'),
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
