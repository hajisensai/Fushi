part of 'update_checker.dart';

/// Hibiki→Fushi 跨包名迁移的「取包」侧（改名迁移计划 P1-3 一键迁移）。
///
/// 为什么放在 update_checker 这个 library 里、而不是 `src/migration/` 下：拿 release
/// 清单要用 [UpdateChecker._fetchReleasesForChannel]（镜像 manifest 优先 + API 回退 +
/// 代理），下载安装要用 [UpdateChecker._downloadAndInstall]（下载浮层 / 多镜像回退 /
/// 断点续传 / 取消 / Android 安装权限回跳）。这些全是 library 私有符号，part 契约又
/// 禁止 part 内 import，拆出去只能把整条下载链路重写一遍——而那条链路的坑
/// （403 镜像、stale 404、权限回跳）已经踩平了，重写等于重新踩一遍。

/// 迁移目标（Fushi）安装包的解析结果。
///
/// 与 [UpdateReleaseSelection] 刻意分开：那个类的语义是「相对本机的更新」，带版本
/// 比较与 release notes；这里只是「去哪儿下 Fushi」，没有「更新」这层含义。
class MigrationTargetAsset {
  const MigrationTargetAsset({
    required this.asset,
    required this.version,
  });

  final UpdateAsset asset;

  /// Fushi 自身版本串（仅用于下载浮层文案与临时文件名）。
  final String version;
}

/// 解析当前通道下最新的 Fushi 安装包。
///
/// 与自更新的关键差异：**不做版本比较**。Fushi 是另一个包名、另一条版本线，
/// 「远端比本机新吗」这个问题在这里没有意义——要的永远是当前通道下最新的那个
/// Fushi 包。故复用 [UpdateChecker._fetchReleasesForChannel] 的镜像/回退拉取与
/// `selectAsset` 的按 ABI 挑包，但绕开 [selectUpdateReleaseForCurrentPlatform]
/// 的版本判据。
///
/// 返回 null = 本通道下找不到 Fushi 产物。调用方据此提示并允许重试，**绝不能**
/// 退化成「装桥包自己」——产品族过滤由 [ReleaseProduct.fushi] 硬保证。
Future<MigrationTargetAsset?> resolveMigrationTargetAsset({
  UpdateChannel channel = UpdateChannel.stable,
  String customProxy = '',
}) async {
  final HttpClient client = HttpClient();
  try {
    await applyAppProxy(client, userProxy: customProxy);
    final List<Map<String, dynamic>> releases =
        await UpdateChecker._fetchReleasesForChannel(client, channel);
    final PlatformUpdater updater = updaterForCurrentPlatform();
    // 「谁后构建谁赢」——与自更新同一把尺（[_compareReleaseRecency]），
    // 避免多轨并集里按拉取顺序误选更旧的 Fushi。
    final List<Map<String, dynamic>> ordered = releases
        .where(
            (Map<String, dynamic> r) => releaseEligibleForChannel(r, channel))
        .toList()
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
        final String va =
            normalizeReleaseVersionTag(a['tag_name'] as String? ?? '') ?? '';
        final String vb =
            normalizeReleaseVersionTag(b['tag_name'] as String? ?? '') ?? '';
        return _compareReleaseRecency(vb, va,
            seqA: b['releaseSequence'] as int?,
            seqB: a['releaseSequence'] as int?);
      });
    for (final Map<String, dynamic> release in ordered) {
      final String? topVersion =
          normalizeReleaseVersionTag(release['tag_name'] as String? ?? '');
      if (topVersion == null || topVersion.isEmpty) continue;
      final List<Map<String, dynamic>> assetMaps =
          (release['assets'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
      // 轨道按 release 自身取（stable 包无 `-debug.` 后缀），与自更新同理。
      final UpdateAsset? asset = await updater.selectAsset(
        assetMaps,
        channel: channelForUpdateVersion(topVersion),
        product: ReleaseProduct.fushi,
      );
      if (asset == null) continue;
      return MigrationTargetAsset(
        asset: asset,
        // 版本仅用于下载浮层文案与临时文件名；asset 自带版本印记时优先用它
        // （与自更新同源：manifest 给 asset 打版本印记，API 路径没有则回退 tag）。
        version: normalizeReleaseVersionTag(asset.version ?? '') ?? topVersion,
      );
    }
    return null;
  } catch (e, stack) {
    ErrorLogService.instance
        .log('UpdateChecker.resolveMigrationTarget', e, stack);
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 下载并安装迁移目标包。
///
/// 直接复用自更新的 [UpdateChecker._downloadAndInstall]：下载浮层、多镜像回退、
/// 断点续传、取消，以及 Android `INSTALL_PERMISSION_REQUIRED` 的授权重试全部照旧。
Future<void> downloadAndInstallMigrationTarget(
  BuildContext context,
  MigrationTargetAsset target, {
  String customProxy = '',
}) =>
    UpdateChecker._downloadAndInstall(
      context,
      target.asset,
      target.version,
      updaterForCurrentPlatform(),
      customProxy: customProxy,
    );
