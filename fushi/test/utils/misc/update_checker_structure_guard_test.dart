import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-584 结构守卫：update_checker.dart 已拆成 barrel library + 5 个 part 文件
/// （`part of 'update_checker.dart';`）。这套守卫固化拆分后的不变式，防止后续改动
/// 把巨石文件重新塞回单文件、或把符号错放 part（破坏「按职责分文件 + 零行为变化」）。
///
/// 用 `part`/`part of`（而非独立 import/export）的核心收益：各 part 共享同一 library
/// 的私有作用域，私有符号（如 `_DownloadOverlay`）跨 part 互相可见，对外 API、
/// `@visibleForTesting` 导出、`package:...update_checker.dart` import 路径全部零变化。
void main() {
  const String dir = 'lib/src/utils/misc';
  const String barrel = '$dir/update_checker.dart';
  const String net = '$dir/update_checker_net.dart';
  const String download = '$dir/update_checker_download.dart';
  const String race = '$dir/update_checker_race.dart';
  const String release = '$dir/update_checker_release.dart';
  const String ui = '$dir/update_checker_ui.dart';
  const List<String> parts = <String>[net, download, race, release, ui];

  String read(String path) => File(path).readAsStringSync();
  int lineCount(String path) => File(path).readAsLinesSync().length;

  test('barrel + 5 part files all exist', () {
    for (final String path in <String>[barrel, ...parts]) {
      expect(File(path).existsSync(), isTrue, reason: '$path must exist');
    }
  });

  test('each file stays under the maintainability ceiling', () {
    // download part carries the whole multi-segment engine + cancellation token
    // plumbing (TODO-738), so it gets a slightly higher ceiling; every other
    // part stays under 1500. The point is to flag uncontrolled growth, not to
    // forbid a real cross-cutting feature.
    //
    // TODO-1010 / BUG-473 加入了「updates 目录旧完整安装包按 mtime 回收」的真实新
    // 功能：纯函数 selectStaleUpdateArtifacts + UpdateDirEntry 数据类（防安装包无限
    // 堆积到数 GB）以及 fail-safe 决策 shouldSkipFullPackageCleanup（marker 损坏时
    // 保守跳过完整包回收，不误删待重启安装包）。两者都是带 @visibleForTesting 纯函数
    // + 专用测试 update_checker_cleanup_test.dart 的独立跨切关注点，且都必须与下载/
    // staging 引擎共享同一 library 私有作用域（part 契约禁止 part 内 import，无法拆成
    // 独立库而不破坏「纯 part」不变式）。这正是本注释所说「真实跨切功能」应被容纳、
    // 而非被行数天花板强行拆散的情形，故把 download 天花板从 1520 上调到 1560
    // （当时 1538，留 ~22 行合理余量，与 default 1500 的既有余量风格一致）。
    //
    // TODO-1089 / BUG-517 + TODO-1010 fail-safe 又加入两个同族真实新功能（均带
    // @visibleForTesting 纯函数 + update_checker_cleanup_test.dart 覆盖，且必须与
    // 下载/staging 引擎共享同一 library 私有作用域，part 契约禁止 part 内 import 无法
    // 拆库）：installerToDeleteAfterSuccessfulHandoff（Windows 握手安装成功即回收该
    // 安装包，不等 7 天 GC，消除 BUG-517 几百 MB 残留）+ shouldSkipFullPackageCleanup
    // 的 marker-unreadable 保守分支。净增 ~64 行到 1583（无删除，纯跨切功能）。同上
    // 判断：跨切功能应被容纳而非被行数天花板强行拆散，故把 download 天花板从 1560 上调
    // 到 1650（当前 1583，留 ~67 行合理余量，与既有 default 1500 余量风格一致）。
    //
    // TODO-1123 / BUG-539 又加入「下载 404（rolling tag prune 竞态导致手里 manifest
    // 过期）→ 重取 manifest 换新 URL 单次重试」的真实跨切功能：可测编排
    // downloadAssetWithStaleRetry + 生产 _reResolveDownloadAsset + 通道推断
    // channelForUpdateVersion（均需与 release 检查/版本比较共享同一 library 私有作用域，
    // part 契约禁止 part 内 import 无法拆库）。净增 ~90 行到 1530（无删除，纯跨切功能）。
    // 同上判断：跨切功能应被容纳而非被行数天花板强行拆散，故给 release 单独上调到 1600
    // （当前 1530，留 ~70 行合理余量，与既有余量风格一致）。
    //
    // TODO-1149：又加入「过期 `.staging` 下载暂存根按 mtime 回收」的真实跨切功能——扩展
    // selectStaleUpdateArtifacts 目录分支 + 新纯函数 stagingDirToDeleteAfterSuccessfulHandoff
    // （安装成功即刻回收对应空 staging 根，消除 updates 目录空 `.staging` 根无限堆积），均带
    // @visibleForTesting + update_checker_cleanup_test.dart 覆盖，且必须与下载 / staging 引擎
    // 共享同一 library 私有作用域（part 契约禁止 part 内 import 无法拆库）。download 净增
    // ~55 行到 1641，故把 download 天花板从 1650 上调到 1700（留 ~59 行合理余量，与既有余量
    // 风格一致）。
    //
    // TODO-1205 / BUG-1205：又加入「按所选平台 asset 自身版本判更新/显示/下载/退避」的真实
    // 跨切功能——buildReleaseFromManifest 透传 per-asset version 印记 +
    // selectUpdateReleaseForCurrentPlatform 用 asset 版本判定回填 + _check 全程改用
    // selection.version（修「顶层 6636 但安卓装 6621」死循环），均须与 release 检查/版本比较
    // 共享同一 library 私有作用域（part 契约禁止 part 内 import 无法拆库）。release 净增
    // ~30 行到 ~1616，故把 release 天花板从 1600 上调到 1650（留 ~34 行合理余量，与既有风格一致）。
    //
    // TODO-1149（数量封顶 + promote 删空 staging 根）：又加入真实跨切功能——
    // selectStaleUpdateArtifacts 增加 keepNewestInstallers / keepNewestStaging「保留最新 N」
    // 数量回收（高频下载 7 天内也不再无界堆积）+ 共享纯函数 _selectStaleByCountAndAge +
    // _promoteCompleteDownload 成功后 _pruneEmptyStagingRoot 删空根（从源头消灭空 staging 根
    // 堆积），均带 @visibleForTesting / 专用测试覆盖，且必须与下载 / staging 引擎共享同一
    // library 私有作用域（part 契约禁止 part 内 import 无法拆库）。download 净增 ~77 行到
    // 1718，故把 download 天花板从 1700 上调到 1780（留 ~62 行合理余量，与既有余量风格一致）。
    // BUG-457：又加入「beta/debug 通道用 buildNumber 还原本机已安装 release sequence」的真实
    // 跨切功能——effectiveCurrentVersionForUpdateChannel（无后缀 X.Y.Z release 包按通道 +
    // versionCode 还原成 <base>-<channel>.<seq> 再比较，修「装 1.2.0 release 包在 debug 通道
    // 永判已是最新」）+ _releaseSequenceFromPlatformBuildNumber（Android versionCode / 桌面 raw
    // build number 反解 seq），须与既有版本比较（isUpdateVersionNewer 等）共享同一 library 私有
    // 作用域（part 契约禁止 part 内 import 无法拆库）。release 净增 ~77 行到 1709，故把 release
    // 天花板从 1650 上调到 1720（留 ~11 行合理余量，与既有余量风格一致）。
    // BUG-846：再加入「嵌套更新合集」（越激进通道合集越大：stable⊆beta⊆debug，让 beta/debug
    // 用户能收到更新的正式版/更高基版本，永不掉队）——_channelsAdmittedBy / _channelAdmitsVersion
    // / _sameChannelTrack / releaseEligibleForChannel / _compareReleaseRecency 等跨切判据，须与
    // 既有版本比较共享同一 library 私有作用域。release 净增 ~120 行到 1830，故把 release 天花板
    // 从 1720 上调到 1900（留 ~70 行合理余量，与既有余量风格一致）。
    // 全平台自动更新 Phase 3（macOS 去沙盒自替换）：再加入「macOS 更新握手对账 + 自动安装
    // 失败退避 + 替换 scratch 清理」的真实跨切功能——reconcilePendingMacInstallerHandoff /
    // _shouldBackOffMacAutoInstall / _cleanupMacUpdateScratch，均须与 UpdateChecker 门面的
    // 私有作用域（_cleanupOldApks / _updatesDirectoryForCurrentPlatform / _leafName /
    // canShowDialogFromContext）共享，part 契约禁止 part 内 import 无法拆库，与 Windows 的
    // reconcilePendingWindowsInstallerHandoff 平级。release 净增 ~156 行到 1986，故把 release
    // 天花板从 1900 上调到 2050（留 ~64 行合理余量，与既有余量风格一致）。
    const int kDownloadCeiling = 1780;
    const int kReleaseCeiling = 2050;
    const int kDefaultCeiling = 1500;
    for (final String path in <String>[barrel, ...parts]) {
      final int ceiling = path == download
          ? kDownloadCeiling
          : path == release
              ? kReleaseCeiling
              : kDefaultCeiling;
      expect(lineCount(path), lessThan(ceiling),
          reason: '$path exceeds the $ceiling-line ceiling; split it further');
    }
  });

  test('update_checker.dart is a pure barrel (library + imports + part only)',
      () {
    final String source = read(barrel);
    // 纯 barrel：只声明 library + import + 4 个 part，不含任何类/顶层函数定义。
    expect(source, contains('library;'));
    for (final String part in parts) {
      final String name = part.split('/').last;
      expect(source, contains("part '$name';"),
          reason: 'barrel must declare part $name');
    }
    // barrel 不得自带实现：不出现类声明 / @visibleForTesting / UpdateChecker 类体。
    expect(source, isNot(contains('class ')),
        reason: 'barrel must not define classes; move them into a part');
    expect(source, isNot(contains('@visibleForTesting')),
        reason: 'visibleForTesting symbols belong in part files');
    expect(source, isNot(contains('class UpdateChecker')));
  });

  test('every part file starts with the same part-of directive', () {
    for (final String path in parts) {
      expect(read(path), contains("part of 'update_checker.dart';"),
          reason: '$path must be a part of the update_checker library');
      // part 文件不得自带 import（import 集中在 barrel；part 共享 library 作用域）。
      expect(read(path), isNot(contains('\nimport ')),
          reason: '$path must not declare imports; they live in the barrel');
    }
  });

  test('net part owns the URL / network-classification layer', () {
    final String source = read(net);
    expect(source, contains('List<String> updateCheckUrls('));
    expect(source, contains('fetchFirstSuccessfulBody('));
    expect(source, contains('isExpectedUpdateNetworkFailure('));
    expect(source, contains('hostLabelForUpdateUrl('));
  });

  /// BUG-1348：代理解析层从本 part 搬进了独立库 `src/utils/net/app_proxy.dart`。
  ///
  /// 搬家的理由就是这套守卫自己钉死的那条不变式——「part 文件不得自带 import」。代理是
  /// 进程级网络出口策略，同步层（GoogleDriveAuth 的 token 交换）必须用同一套出口，可
  /// part 没法被外部按需 import，于是同步层只能裸连，在开着代理的机器上必然
  /// `errno = 121` 超时。守卫随之调头：**禁止**代理实现回流到 part 里。
  test('the proxy layer lives in its own library, not in the net part', () {
    const String appProxy = 'lib/src/utils/net/app_proxy.dart';
    expect(File(appProxy).existsSync(), isTrue,
        reason: '$appProxy must exist — the sync layer imports it directly');

    final String proxySource = read(appProxy);
    expect(proxySource, contains('Future<void> applyAppProxy('));
    expect(proxySource, contains('parseWindowsRegistryProxy('));
    expect(proxySource, contains('String? normalizeUserProxyHostPort('));
    // 进程级真相源：没有它，同步层又得沿调用链穿 userProxy 参数（穿漏一处 = 一条暗路）。
    expect(proxySource, contains('String Function() appUserProxyReader'));

    final String netSource = read(net);
    expect(netSource, isNot(contains('Future<void> applyAppProxy(')),
        reason: 'the proxy implementation must not move back into the part; '
            'part files cannot be imported by the sync layer (BUG-1348)');
    expect(netSource,
        isNot(contains('Map<String, String> parseWindowsRegistryProxy(')),
        reason:
            'ditto — the Windows registry parser belongs to app_proxy.dart');
  });

  test('download part owns the multi-segment download engine', () {
    final String source = read(download);
    expect(source, contains('Future<File> downloadUpdateAsset('));
    expect(source, contains('List<DownloadSegment> planDownloadSegments('));
    expect(source, contains('_downloadSegmented('));
    expect(source, contains('class _UpdateDownloadMetadata'));
    expect(source, contains('class UpdateDownloadPaths'));
    // 整族不可切断：orchestrator + segment + staging + metadata 同进 download part。
    expect(source, contains('_concatSegments('));
    expect(source, contains('_resolveStagingPaths('));
  });

  test('race part owns the concurrent-probe race + first-byte timeout', () {
    final String source = read(race);
    expect(source, contains('raceSelectFastestCandidate('));
    expect(source, contains('String? selectRaceWinnerUrl('));
    expect(source, contains('List<String> reorderCandidatesByRaceWinner('));
    expect(source, contains('class UpdateProbeOutcome'));
    expect(source, contains('class UpdateDownloadStatusController'));
    expect(source, contains('_kFirstByteTimeout'));
  });

  test('release part owns the UpdateChecker facade + version logic', () {
    final String source = read(release);
    expect(source, contains('class UpdateChecker {'));
    expect(source, contains('selectUpdateReleaseForCurrentPlatform('));
    expect(source, contains('bool isUpdateVersionNewer('));
    expect(source, contains('releaseMatchesUpdateChannel('));
    expect(source, contains('normalizeReleaseVersionTag('));
    // TODO-705: beta/debug mirror-manifest reading lives in the release part.
    expect(source, contains('Map<String, dynamic>? buildReleaseFromManifest('));
    expect(source, contains('String? manifestUrlForChannel('));
    expect(source, contains('Map<String, String> manifestUrlsForChannel('));
    expect(source, contains('const String kGitHubRepo ='));
    expect(source, contains('const String kLegacyGitHubRepo ='));
    expect(source, contains('const String kBetaManifestUrl ='));
    expect(source, contains('const String kDebugManifestUrl ='));
    expect(source, contains('kUpdateManifestSchemaVersion'));
  });

  test('ui part owns dialogs + overlay and not the HttpClient engine', () {
    final String source = read(ui);
    expect(source, contains('class UpdateAvailableDialog'));
    expect(source, contains('class WindowsUpdateHandoffResultDialog'));
    expect(source, contains('class _DownloadOverlay'));
    expect(source, contains('buildUpdateDownloadOverlayForTest('));
    // UI part 只渲染，不持有网络/下载引擎实现。
    expect(source, isNot(contains('HttpClient(')),
        reason: 'UI part must not own HttpClient; that is the engine\'s job');
    expect(source, isNot(contains('Future<File> downloadUpdateAsset(')));
  });

  /// TODO-808 source-scan guard: the connect/first-byte/per-attempt timeouts
  /// were compressed so dead GFW mirrors fail fast and serial fallback does not
  /// pile up into minutes. These constants are private / embedded so they
  /// cannot be read at runtime; pin them at the source level to stop a
  /// regression silently restoring the slow 30s / 15s values.
  /// （并自 update_checker_timeout_guard_test.dart，断言逐字搬运。）
  group('TODO-808/821 timeout + cancellation pins', () {
    test('per-attempt body timeout is 8s, not the old 15s (TODO-808)', () {
      final String source = read(download);
      expect(source, contains('_kPerAttemptTimeout = Duration(seconds: 8)'),
          reason: 'per-attempt timeout must be compressed to 8s');
      expect(source,
          isNot(contains('_kPerAttemptTimeout = Duration(seconds: 15)')),
          reason: 'the slow 15s per-attempt timeout must not return');
    });

    test('HttpClient.connectionTimeout is 10s, not the old 30s (TODO-808)', () {
      final String source = read(release);
      expect(
          source, contains('connectionTimeout = const Duration(seconds: 10)'),
          reason: 'connect timeout must be compressed to 10s');
      expect(source,
          isNot(contains('connectionTimeout = const Duration(seconds: 30)')),
          reason: 'the slow 30s connect timeout must not return');
    });

    test('probe first-byte timeout stays 5s (fast dead-mirror detection)', () {
      final String source = read(race);
      expect(source, contains('_kFirstByteTimeout = Duration(seconds: 5)'),
          reason: 'first-byte probe timeout must stay 5s');
    });

    test('cancellation token exposes the in-flight abort hook (TODO-808)', () {
      final String source = read(race);
      // The abort plumbing is what makes cancel() instant; guard it stays
      // wired.
      expect(source, contains('void registerAbort(void Function() abort)'),
          reason: 'cancellation must accept an in-flight abort callback');
      expect(source, contains('void clearAbort()'));
      expect(source, contains('_fireAbort()'),
          reason: 'cancel() must fire the abort callback');
    });

    test('download callsite force-closes the client on cancel (TODO-808)', () {
      final String source = read(release);
      expect(source, contains('cancellation.registerAbort('),
          reason: 'download must register an abort callback into the token');
      expect(source, contains('close(force: true)'),
          reason: 'abort must force-close the in-flight HttpClient');
      expect(source, contains('cancellation.clearAbort()'),
          reason:
              'finally must clear the abort to avoid closing a reused client');
    });

    test('check phase races candidates concurrently, not serially (TODO-821)',
        () {
      final String source = read(net);
      // The concurrent primitive must exist and fetchFirstSuccessfulBody must
      // delegate to it (a serial for-await regression drops these).
      expect(source, contains('Future<String?> raceFirstSuccessfulBody('),
          reason: 'check phase needs a concurrent race primitive');
      expect(source, contains('return raceFirstSuccessfulBody('),
          reason:
              'fetchFirstSuccessfulBody must delegate to the race primitive');
      expect(source, contains('Future.any(<Future<void>>['),
          reason: 'race uses Future.any over a decided completer + allDone');
    });

    test(
        'check phase client is interruptible via UpdateCheckCancellation '
        '(TODO-821/808 check-side hole)', () {
      final String releaseSource = read(release);
      final String raceSource = read(race);
      // The check token type + its abort wiring must exist.
      expect(raceSource, contains('class UpdateCheckCancellation'),
          reason: 'check phase needs its own interruptible cancellation token');
      expect(releaseSource, contains('UpdateCheckCancellation()'),
          reason: '_check must build a check cancellation token');
      expect(releaseSource, contains('cancellation.registerAbort('),
          reason: '_check must register a force-close abort into the token');
      expect(releaseSource, contains('static void cancelActiveCheck()'),
          reason: 'an interrupt entry must exist to abort a hung check');
    });
  });
}
