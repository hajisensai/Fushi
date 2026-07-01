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
    const int kDownloadCeiling = 1650;
    const int kDefaultCeiling = 1500;
    for (final String path in <String>[barrel, ...parts]) {
      final int ceiling = path == download ? kDownloadCeiling : kDefaultCeiling;
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

  test('net part owns the URL / proxy / network-classification layer', () {
    final String source = read(net);
    expect(source, contains('List<String> updateCheckUrls('));
    expect(source, contains('fetchFirstSuccessfulBody('));
    expect(source, contains('applyUpdateProxy('));
    expect(source, contains('parseWindowsRegistryProxy('));
    expect(source, contains('isExpectedUpdateNetworkFailure('));
    expect(source, contains('hostLabelForUpdateUrl('));
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
}
