import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:fushi/src/mining/galgame_helper_installer.dart'
    show kGalgameHelperInstallDirectoryName;
import 'package:fushi/src/platform/desktop/windows_native_pre_exit.dart';
import 'package:fushi/src/platform/desktop/windows_process_query.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/mac_update_handoff.dart';
import 'package:fushi/src/utils/misc/update_handoff.dart';
import 'package:fushi/src/utils/misc/update_landing.dart';
import 'package:fushi/utils.dart'; // ErrorLogService

export 'update_handoff.dart'
    show
        WindowsDetectedInstallLocation,
        WindowsInnoDeleteFileFailure,
        WindowsInstallerDiagnostics,
        WindowsProcessInfo,
        parseWindowsInnoDeleteFileFailures;

enum UpdateChannel { stable, beta, debug }

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    this.sizeBytes,
    this.sha256Digest,
    this.version,
  });

  factory UpdateAsset.fromReleaseAsset(Map<String, dynamic> asset) {
    return UpdateAsset(
      name: asset['name'] as String? ?? '',
      url: asset['browser_download_url'] as String? ?? '',
      sizeBytes: _assetSizeBytes(asset['size']),
      sha256Digest: _assetSha256Digest(asset['digest'] ?? asset['sha256']),
      version: _assetVersionStamp(asset['version']),
    );
  }

  final String name;
  final String url;
  final int? sizeBytes;
  final String? sha256Digest;

  /// TODO-1205：CI 的 `merge_update_manifest.py` `_stamp` 写在**每个 manifest asset**
  /// 上的「本资产自身版本」（如 `1.0.1-debug.6621`）。manifest 顶层 `tag`/`version` 是
  /// **全平台最大 seq**（TODO-1173 单调 guard），落后平台的 asset 停在自己更旧的 seq；
  /// 判「有无更新」/显示版本必须用**这个 asset 自身版本**而不是顶层 tag，否则会出现
  /// 「顶层 6636 但安卓装的是 6621」→ 判有更新 → 装回 6621 → 再判有更新的死循环
  /// （TODO-1205 症状）。非 manifest 来源（GitHub API / 合成 stable 资产 / 旧 manifest 无
  /// 此印记）→ null，调用方 fail-open 回退顶层 tag（保持旧行为，不因缺印记卡住更新）。
  final String? version;

  UpdateAsset copyWith({
    String? name,
    String? url,
    int? sizeBytes,
    String? sha256Digest,
    String? version,
  }) =>
      UpdateAsset(
        name: name ?? this.name,
        url: url ?? this.url,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        sha256Digest: sha256Digest ?? this.sha256Digest,
        version: version ?? this.version,
      );
}

int? _assetSizeBytes(Object? raw) {
  if (raw is int && raw >= 0) return raw;
  if (raw is num && raw >= 0) return raw.toInt();
  if (raw is String) {
    final int? parsed = int.tryParse(raw.trim());
    if (parsed != null && parsed >= 0) return parsed;
  }
  return null;
}

String? _assetSha256Digest(Object? raw) {
  if (raw is! String) return null;
  final String normalized = raw.trim().toLowerCase();
  final String digest = normalized.startsWith('sha256:')
      ? normalized.substring('sha256:'.length)
      : normalized;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ? digest : null;
}

/// TODO-1205：读 manifest asset 上由 `merge_update_manifest.py` `_stamp` 写的 per-asset
/// `version` 印记（如 `1.0.1-debug.6621`）。只做非空字符串取出 + trim；版本串
/// 的归一化（去前导 v / 剪 build metadata）由消费方（update_checker 库）调
/// `normalizeReleaseVersionTag` 处理（本文件不属那个库，拿不到该函数）。非字符
/// 串 / 空串 → null（fail-open，调用方回退顶层 tag）。
String? _assetVersionStamp(Object? raw) {
  if (raw is! String) return null;
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 每平台的更新策略：选包（[selectAsset]）+ 安装（[apply]）。
/// 共享的 GitHub 拉取/版本比较/下载浮层仍在 UpdateChecker。
abstract class PlatformUpdater {
  /// 当前平台是否支持「检查更新」（iOS/未实现桌面也为 true，只是 apply=打开发布页）。
  bool get supportsUpdateCheck;

  /// 当前平台是否支持「应用内安装」（决定是否显示自动安装、是否走下载→apply）。
  bool get supportsInAppInstall;

  /// 从 release 的 [assets]（每项含 name / browser_download_url）挑本平台可安装包的
  /// 下载 URL；null = 无适配包（上层回退打开发布页）。
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  });

  /// 应用已下载到 [file] 的更新。仅在 [supportsInAppInstall] 为 true 时被调用。
  Future<void> apply(File file, String version);

  /// 不能应用内安装时，「前往下载」按钮该落到哪里。默认 = GitHub release 网页
  /// （[releaseHtmlUrl]），即所有桌面/未实现平台的既有行为。
  ///
  /// 做成平台方法而不是在 update_checker 里 `if (Platform.isIOS)`：「本平台的更新
  /// 从哪儿来」和「本平台怎么选包/怎么装」是同一个问题的三个面，属于同一个
  /// [PlatformUpdater]；散到调用方就会出现「某个入口忘了分流」的静默空档。
  Future<UpdateLanding> resolveDownloadLanding(String releaseHtmlUrl) async =>
      UpdateLanding(url: releaseHtmlUrl, kind: UpdateLandingKind.releasePage);
}

/// 本期支持「应用内安装」的平台集合（单一真相源；Linux 在其阶段加入）。macOS 走
/// 去沙盒后的 zip 替换（[MacUpdater] / [MacInstaller]，Phase 3）。iOS 平台禁止应用内
/// 安装可执行文件，永远只「检查→打开发布页」（[IosUpdater]），不在此集合。
bool platformSupportsInAppInstall() =>
    Platform.isAndroid || Platform.isWindows || Platform.isMacOS;

/// Flutter `--split-per-abi` 产出的 Android ABI 标签（CI 的 `app-<abi>-release.apk`
/// 即据此重命名为 `hibiki-<version>-<abi>.apk`，见 `.github/workflows/release.yml`）。
/// 作为「stable release 资产命名」单一真相源的一部分，供 [synthesizeStableAssetNames]
/// 在没有 GitHub API 资产清单时（TODO-404：纯 GFW 下检查只能拿到 302 跳转里的 tag）
/// 重建候选资产名。
const List<String> kAndroidReleaseAbis = <String>[
  'arm64-v8a',
  'armeabi-v7a',
  'x86_64',
];

/// **纯函数**：按 release 资产命名规则，为某个 stable [version]（已 normalize、不带前导
/// `v`）合成「本应存在于该 release 的可安装资产名」列表。
///
/// 根因背景（TODO-404 / BUG-292）：纯 GFW 且无代理时，更新「检查」打 `api.github.com`
/// 必被镜像 403，唯一可成功的是 `github.com/.../releases/latest` 的 302 网页跳转——但
/// 它只给得到 tag，给不到 GitHub API 的 `assets` 清单。下载阶段又必须知道精确资产名才
/// 能拼出 `releases/download/<tag>/<name>`。命名规则本就是确定的（CI 固定生成），故这里
/// 据 [kAndroidReleaseAbis] + Windows setup 命名把候选资产名重建出来，喂回现有
/// `selectAsset`（Android 仍按设备真实 ABI 自行挑、Windows 直接命中 setup），不在
/// update_checker 里硬编码命名、不绕过既有挑包逻辑。
///
/// 只覆盖「能应用内安装」的平台（Android / Windows，见 [platformSupportsInAppInstall]）；
/// 其余平台 `selectAsset` 本就返 null（走打开发布页），无需合成。仅用于 **stable** 通道
/// （beta/debug 的列表网页经镜像 403，改读 CI 发到 `update-manifest` 分支的 latest.json，
/// 由其自带 assets 清单，见 `update_checker_release.dart` 的 `buildReleaseFromManifest`，TODO-705）。
List<String> synthesizeStableAssetNames(String version) {
  final List<String> names = <String>[
    // 终态全 fushi（2026-08-07 用户拍板）。Windows 走「更新桥」（Phase 5）：
    // 本行已切 fushi——从本提交发布的最后一个 hibiki-* 名安装包即桥版本，
    // 老用户升到桥后即可识别后续 fushi-* 资产。Android 无更新桥（跨包名不能
    // 就地更新，迁移链即通道），其 APK 行保持旧名直到老包停止发布。
    'fushi-$version-windows-setup.exe',
    'fushi-$version-macos.zip',
    for (final String abi in kAndroidReleaseAbis) 'fushi-$version-$abi.apk',
  ];
  return List<String>.unmodifiable(names);
}

/// 所有平台都至少支持「检查更新 → 打开发布页」。
bool platformSupportsUpdateCheck() => true;

PlatformUpdater updaterForCurrentPlatform() {
  if (Platform.isAndroid) return AndroidUpdater();
  if (Platform.isWindows) return WindowsUpdater();
  if (Platform.isMacOS) return MacUpdater();
  if (Platform.isIOS) return IosUpdater();
  return UnsupportedUpdater();
}

/// 本产品族（`app.fushi.reader`）的发布资产名前缀。CI 对全平台产物统一按
/// `fushi-<version>-<平台后缀>` 命名，[synthesizeStableAssetNames] 合成的候选名同源。
const String kFushiAssetPrefix = 'fushi-';

/// **纯函数**：资产是否属于本产品族（BUG-1481）。
///
/// 改名过渡期两个产品从同一个 GitHub 仓库发版（桥包 `app.hibiki.reader` 的 `hibiki-*`
/// 与本体的 `fushi-*`），历史 release 里还躺着更早的无前缀资产。而挑包判据只看平台后缀
/// （`.apk` / `-windows-setup.exe` / `-macos.zip`），区分不出产品族——Android 上装到别族
/// 就是跨包名跨签名，系统直接拒（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）或并存成第二个
/// 空 app；桌面上则是把自己覆盖安装成已退场的老产品。
///
/// 判据用**白名单**而非「排除 hibiki-」：本族是新产品、资产名是闭集，全部由 CI 生成，
/// 没有需要兼容的无前缀历史产物（那些全属 hibiki 族）。白名单 fail-closed——真出现命名
/// 漂移是「不更新」，不是「装错产品」，方向上是安全的那侧；漂移由
/// `platform_updater_product_test.dart` 里 [synthesizeStableAssetNames] 的一致性用例挡住。
bool assetBelongsToThisProduct(String name) =>
    name.startsWith(kFushiAssetPrefix);

/// 从 asset map 安全取出可下载的 (name, url)。
///
/// 产品族过滤放在这里而不是各 `selectAsset`：这是所有平台把原始 asset map 变成候选的
/// **唯一漏斗**（Android/Windows/macOS 三个实现都经它），在漏斗上过滤意味着新增平台
/// 自动继承约束，也不存在「某个调用点忘了传 product 参数」这种静默装错包的空档。
/// 本族没有任何「有意去装别族产物」的场景，所以不需要把它做成可选参数。
Iterable<UpdateAsset> _downloadable(List<Map<String, dynamic>> assets) sync* {
  for (final Map<String, dynamic> a in assets) {
    final UpdateAsset asset = UpdateAsset.fromReleaseAsset(a);
    if (asset.name.isEmpty || asset.url.isEmpty) continue;
    if (!assetBelongsToThisProduct(asset.name)) continue;
    yield asset;
  }
}

bool _isDebugApkAsset(String name) =>
    name.endsWith('-debug.apk') || name.contains('-debug.');

bool _androidAssetMatchesChannel(String name, UpdateChannel channel) {
  if (!name.endsWith('.apk')) return false;
  return switch (channel) {
    UpdateChannel.debug => _isDebugApkAsset(name),
    UpdateChannel.stable || UpdateChannel.beta => !_isDebugApkAsset(name),
  };
}

/// **纯函数**：资产名是否是给 [abi] 这个设备架构的 APK。
///
/// 锚定成 `-<abi>.apk` 结尾，**不做子串匹配**。裸 `contains` 有两个真实故障：
/// * 32 位 `x86` 设备的 `SUPPORTED_ABIS` 首项是 `x86`，而 `x86` 是 `x86_64` 的子串
///   → 会挑到装不上的 64 位包；
/// * 设备上报的 `x86_64` 过去被写成 `x86-64` 再 `contains`，与 CI 真实产物名
///   `fushi-<version>-x86_64.apk` 永远对不上（`kAndroidReleaseAbis` 里就是 `x86_64`）。
///
/// 直接用设备上报的原始 ABI 串，不做 `_`→`-` 改写：CI 的资产名就是 Flutter
/// `--split-per-abi` 的 `app-<abi>-release.apk` 原样换前缀而来，两侧本就同形。
bool androidAssetMatchesAbi(String name, String abi) =>
    name.endsWith('-$abi.apk');

/// 候选里是否存在**任何**按架构切分的包。用于区分「这个 release 提供分架构包、只是
/// 没有本机这一档」与「这个 release 只有一个 universal 包」（debug 通道即后者）。
bool _hasPerAbiCandidate(Iterable<String> names) => names.any(
      (String n) => kAndroidReleaseAbis
          .any((String abi) => androidAssetMatchesAbi(n, abi)),
    );

bool _isDebugWindowsSetupAsset(String name) =>
    name.endsWith('-windows-setup.exe') && name.contains('-debug.');

bool _windowsAssetMatchesChannel(String name, UpdateChannel channel) {
  if (!name.endsWith('-windows-setup.exe')) return false;
  return switch (channel) {
    UpdateChannel.debug => _isDebugWindowsSetupAsset(name),
    UpdateChannel.stable ||
    UpdateChannel.beta =>
      !_isDebugWindowsSetupAsset(name),
  };
}

/// macOS 更新产物由 CI `release-desktop.yml` 的 apple job 以
/// `ditto -c -k --keepParent hibiki.app` 打成 `hibiki-<version>-macos.zip`。debug
/// 通道的版本串内嵌 `-debug.<seq>`，故 debug 包名恒含 `-debug.`（与 Windows 同规则）。
bool _isDebugMacosAsset(String name) =>
    name.endsWith('-macos.zip') && name.contains('-debug.');

bool _macosAssetMatchesChannel(String name, UpdateChannel channel) {
  if (!name.endsWith('-macos.zip')) return false;
  return switch (channel) {
    UpdateChannel.debug => _isDebugMacosAsset(name),
    UpdateChannel.stable || UpdateChannel.beta => !_isDebugMacosAsset(name),
  };
}

class AndroidUpdater extends PlatformUpdater {
  AndroidUpdater({Future<List<String>> Function()? abiProvider})
      : _abiProvider = abiProvider ?? _defaultAbis;

  final Future<List<String>> Function() _abiProvider;

  static Future<List<String>> _defaultAbis() async {
    try {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      return info.supportedAbis;
    } catch (e, s) {
      ErrorLogService.instance.log('PlatformUpdater.getAbi', e, s);
      return <String>[];
    }
  }

  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    final List<UpdateAsset> candidates = <UpdateAsset>[
      for (final UpdateAsset asset in _downloadable(assets))
        if (_androidAssetMatchesChannel(asset.name, channel)) asset,
    ];
    if (candidates.isEmpty) return null;
    final List<String> abis = await _abiProvider();
    // 设备 ABI 偏好顺序是 outer 循环，资产列表是 inner：先满足设备最优架构，拿不到
    // 再退让到次优。**资产顺序不参与架构决策**——GitHub API 按文件名升序返回资产，
    // 让它决定就成了「字母序选架构」。
    for (final String abi in abis) {
      for (final UpdateAsset asset in candidates) {
        if (androidAssetMatchesAbi(asset.name, abi)) return asset;
      }
    }
    // 无架构命中。只有当这批候选**根本没有分架构包**时才兜底取首个——那是 debug 通道的
    // universal 单包。若 release 明明提供了分架构包却没有本机这一档（含 [_abiProvider]
    // 取 ABI 失败返回空列表的情形），宁可返回 null 让上层退化成「打开发布页」，也不能
    // 静默塞一个装不上的架构给用户。
    if (_hasPerAbiCandidate(candidates.map((UpdateAsset a) => a.name))) {
      return null;
    }
    return candidates.first;
  }

  @override
  Future<void> apply(File file, String version) async {
    await AndroidInstaller.install(file.path);
  }
}

class WindowsUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    for (final UpdateAsset asset in _downloadable(assets)) {
      if (_windowsAssetMatchesChannel(asset.name, channel)) return asset;
    }
    return null;
  }

  @override
  Future<void> apply(File file, String version) async {
    await WindowsInstaller.runAndExit(
      file.path,
      targetVersion: version,
      handoffMarkerFile: WindowsUpdateHandoff.markerFile(file.parent),
    );
  }
}

/// macOS：去沙盒后的应用内自替换（Phase 3）。选 `-macos.zip` 包；apply 交给
/// [MacInstaller.runAndExit]——解压→写握手标记→分离脚本等本进程退出后替换
/// `/Applications/hibiki.app` 并重启→`exit(0)`。替换失败由脚本回滚旧版本、下次
/// 启动经 [MacUpdateHandoff.reconcile] 提示，绝不留坏档。
class MacUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    for (final UpdateAsset asset in _downloadable(assets)) {
      if (_macosAssetMatchesChannel(asset.name, channel)) return asset;
    }
    return null;
  }

  @override
  Future<void> apply(File file, String version) async {
    await MacInstaller.runAndExit(file.path, targetVersion: version);
  }
}

/// iOS：Apple 平台禁止应用内下载/执行外部可执行文件（即便当前不在 App Store，也守住
/// 合规边界便于将来上架）。永远只「检查版本→前往分发渠道」，[selectAsset] 恒 null 使
/// 上层走 `_showFallbackDialog`。
///
/// 「分发渠道」不是一条：TestFlight 装的包只能从 TestFlight 更新（TestFlight 本身就
/// 会自动更新，这里只是给用户一个手动入口），将来上架后 App Store 装的包只能从
/// App Store 更新，而 GitHub Release 里那个未签名 `fushi-<v>-ios.ipa` 只对 AltStore /
/// Sideloadly 侧载用户有意义。三者由**安装来源**（系统写的收据文件，见
/// [IosInstallSource]）决定，不由更新通道决定——按通道猜会把侧载用户送进 TestFlight
/// （他们进不去）、把 TestFlight 用户送去下一个装不上的 ipa。
class IosUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => false;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async =>
      null;

  @override
  Future<UpdateLanding> resolveDownloadLanding(String releaseHtmlUrl) async {
    final IosInstallSource source = await IosInstallSourceResolver.resolve();
    return iosUpdateLanding(source: source, releaseHtmlUrl: releaseHtmlUrl);
  }

  @override
  Future<void> apply(File file, String version) async {
    throw StateError('IosUpdater.apply must not be called');
  }
}

/// Linux（本期未实现应用内安装）：可检查但不能自装，回退打开发布页。
class UnsupportedUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => false;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async =>
      null;

  @override
  Future<void> apply(File file, String version) async {
    throw StateError('UnsupportedUpdater.apply must not be called');
  }
}

// ── 安装器（Task 4 落地 Windows，本 Task 落地 Android）──
/// Android 原生安装：仅 Android 注册的 installApk 通道（FileProvider + ACTION_VIEW，
/// 带 HBK-AUDIT-058 路径校验，见 MainActivity.java）。
class AndroidInstaller {
  static Future<void> install(String apkPath) async {
    await FushiChannels.update.invokeMethod('installApk', <String, String>{
      'path': apkPath,
    });
  }
}

/// Inno Setup 静默安装参数：
/// - `/VERYSILENT` + `/SP-`：抑制整个向导、跳过初始「准备安装」提示。
/// - `/SUPPRESSMSGBOXES`：配合 `/VERYSILENT` 抑制 Inno 的错误/选择弹窗，避免
///   `DeleteFile failed code 5` 把用户留在 Select action。
/// - `/NOCLOSEAPPLICATIONS` + `/NOFORCECLOSEAPPLICATIONS`：禁止 Inno /
///   RestartManager 自动关闭或强制结束任何残留 Hibiki / libmpv 持有进程。
/// - `/NORESTARTAPPLICATIONS`：不让 RestartManager 自动拉起被它管理的应用。
/// - `/NORESTART`：禁止安装器重启**操作系统**（我们只想重启 app，不重启系统）。
/// - `/DIR=`：应用内更新只写当前运行 `hibiki.exe` 所在目录，不追随注册表或历史路径。
List<String> windowsInstallerArgs(
  String installerPath, {
  String? logPath,
  String? targetInstallDir,
}) =>
    <String>[
      '/VERYSILENT',
      '/SP-',
      '/SUPPRESSMSGBOXES',
      '/NOCLOSEAPPLICATIONS',
      '/NOFORCECLOSEAPPLICATIONS',
      '/NORESTARTAPPLICATIONS',
      '/NORESTART',
      if (targetInstallDir != null && targetInstallDir.trim().isNotEmpty)
        '/DIR=$targetInstallDir',
      '/LOG=${logPath ?? windowsInstallerLogPath(installerPath)}',
    ];

const String kWindowsUpdateLauncherExecutable = 'fushi_update_launcher.exe';

String windowsUpdateLauncherPath({String? currentExecutablePath}) {
  final String executablePath =
      currentExecutablePath ?? Platform.resolvedExecutable;
  final int sep = _lastPathSeparatorIndex(executablePath);
  if (sep < 0) return kWindowsUpdateLauncherExecutable;
  return '${executablePath.substring(0, sep)}'
      '${Platform.pathSeparator}$kWindowsUpdateLauncherExecutable';
}

List<String> windowsUpdateLauncherArgs({
  required String markerPath,
  required int parentProcessId,
  required String installerPath,
  required List<String> installerArgs,
}) =>
    <String>[
      '--marker',
      markerPath,
      '--parent-pid',
      '$parentProcessId',
      '--installer',
      installerPath,
      '--',
      ...installerArgs,
    ];

String windowsInstallerLogPath(String installerPath) {
  final int sep = _lastPathSeparatorIndex(installerPath);
  final String dir = sep >= 0 ? installerPath.substring(0, sep) : '';
  final String name =
      sep >= 0 ? installerPath.substring(sep + 1) : installerPath;
  final String stem = name.toLowerCase().endsWith('.exe')
      ? name.substring(0, name.length - 4)
      : name;
  final String logName = '$stem.install.log';
  if (dir.isEmpty) return logName;
  return '$dir${Platform.pathSeparator}$logName';
}

int _lastPathSeparatorIndex(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  return slash > backslash ? slash : backslash;
}

/// Windows 安装器启动/校验失败。被 UpdateChecker 的下载流程 catch → SnackBar 优雅
/// 降级，绝不让损坏下载或启动失败演化成「app 静默消失」式崩溃。
class UpdateInstallerException implements Exception {
  UpdateInstallerException(this.message);

  final String message;

  @override
  String toString() => 'UpdateInstallerException: $message';
}

/// 下载产物是否是真正的 Windows 可执行文件：PE 文件以 DOS「MZ」魔数
/// (0x4D 0x5A) 开头。GFW 下走的 GitHub 代理镜像（ghfast.top / ghproxy）可能用
/// HTTP 200 回一个 HTML 限流/错误页，被原样写进 `hibiki-<v>.exe`；把这种字节喂给
/// `Process.start` 在 Windows 上行为不可控（ERROR_BAD_EXE_FORMAT 等），必须先拦掉。
bool isWindowsExecutableHeader(List<int> header) =>
    header.length >= 2 && header[0] == 0x4D && header[1] == 0x5A;

class WindowsInstallerStartedProcess {
  const WindowsInstallerStartedProcess({required this.pid});

  final int? pid;
}

class WindowsInstaller {
  static Future<WindowsInstallerStartedProcess> _startDetachedLauncherProcess(
    String executable,
    List<String> args,
  ) async {
    final Process process = await Process.start(
      executable,
      args,
      mode: ProcessStartMode.detached,
    );
    return WindowsInstallerStartedProcess(pid: process.pid);
  }

  /// 启动延迟 launcher（分离进程）后退出本进程。launcher 等当前 PID 退出后
  /// 再启动 Inno，让安装器看到 AppMutex 已释放。
  ///
  /// 根因修复（Windows 点自动更新崩溃）：
  /// 1. 先校验下载产物确实是 PE 可执行文件，避免把代理 HTML/截断文件喂给
  ///    `Process.start`（曾导致行为不可控）。
  /// 2. 仅当 launcher 进程**确实启动成功**后才 `exit(0)`；启动失败抛
  ///    [UpdateInstallerException]（上层 catch → SnackBar），绝不让本进程在没有
  ///    接班者的情况下静默消失（用户视角即「崩溃」）。
  static Future<void> runAndExit(
    String installerPath, {
    String? targetVersion,
    File? handoffMarkerFile,
    DateTime Function()? now,
    String? currentExecutablePath,
    Future<WindowsInstallerDiagnostics> Function()? collectDiagnostics,
    Future<WindowsInstallerStartedProcess> Function(
      String executable,
      List<String> args,
    )? startProcess,
    void Function(int code)? exitProcess,
  }) async {
    final DateTime Function() clock = now ?? DateTime.now;
    final String innoLogPath = windowsInstallerLogPath(installerPath);
    final String resolvedExecutablePath =
        currentExecutablePath ?? Platform.resolvedExecutable;
    final Directory currentInstallDir = File(resolvedExecutablePath).parent;
    final bool hasInjectedDiagnostics = collectDiagnostics != null;

    // Validate the downloaded file BEFORE collecting diagnostics. Diagnostics
    // shell out to `reg`, `powershell Get-CimInstance` and `tasklist /M` (a
    // whole-machine module enumeration that costs seconds); spending that on a
    // download we are about to delete is pure waste, and it made the user wait
    // ~10s just to be told "update failed". Failing fast here also means the
    // handoff marker is never written for an installer that can never launch.
    final File installer = File(installerPath);
    try {
      if (!installer.existsSync()) {
        throw UpdateInstallerException('installer not found: $installerPath');
      }
      final List<int> header = await _readHeaderBytes(installer);
      if (!isWindowsExecutableHeader(header)) {
        // 下载的不是真正的安装器（多半是代理返回的 HTML/损坏文件）：删掉脏文件，
        // 抛错让上层提示「更新失败」并保留 app 存活，而不是硬启动一个坏 exe。
        try {
          installer.deleteSync();
        } catch (_) {/* best-effort cleanup */}
        throw UpdateInstallerException(
            'downloaded file is not a Windows executable: $installerPath');
      }
    } catch (e, stack) {
      await _markLaunchFailed(handoffMarkerFile, e, clock(), stack);
      rethrow;
    }

    final WindowsInstallerDiagnostics rawDiagnostics =
        collectDiagnostics != null
            ? await collectDiagnostics()
            : Platform.isWindows
                ? await collectWindowsInstallerDiagnostics(
                    currentExecutablePath: resolvedExecutablePath,
                    currentProcessId: pid,
                  )
                : WindowsInstallerDiagnostics(
                    currentExecutablePath: resolvedExecutablePath,
                    currentInstallDir: currentInstallDir.path,
                    targetInstallDir: currentInstallDir.path,
                    detectedInstallLocations: <WindowsDetectedInstallLocation>[
                      WindowsDetectedInstallLocation(
                        source: 'current',
                        path: currentInstallDir.path,
                      ),
                    ],
                  );
    final String targetInstallDir =
        rawDiagnostics.targetInstallDir ?? currentInstallDir.path;
    final WindowsInstallerDiagnostics diagnostics = rawDiagnostics.copyWith(
      currentExecutablePath:
          rawDiagnostics.currentExecutablePath ?? resolvedExecutablePath,
      currentInstallDir:
          rawDiagnostics.currentInstallDir ?? currentInstallDir.path,
      targetInstallDir: targetInstallDir,
    );
    if (targetVersion != null && handoffMarkerFile != null) {
      await WindowsUpdateHandoff.writePending(
        markerFile: handoffMarkerFile,
        targetVersion: targetVersion,
        installerPath: installerPath,
        innoLogPath: innoLogPath,
        startedAt: clock(),
        diagnostics: diagnostics,
      );
      ErrorLogService.instance.log(
        'WindowsInstaller.handoff',
        'Prepared Windows update handoff: target=$targetVersion, '
            'installer=$installerPath, targetDir=$targetInstallDir, '
            'log=$innoLogPath',
      );
    }

    try {
      if (Platform.isWindows) {
        await ensureWindowsInstallTargetWritable(Directory(targetInstallDir));
      }
      if (Platform.isWindows || hasInjectedDiagnostics) {
        _throwIfWindowsInstallBlocked(diagnostics, innoLogPath);
      }

      final List<String> args = windowsInstallerArgs(
        installerPath,
        logPath: innoLogPath,
        targetInstallDir: Platform.isWindows ? targetInstallDir : null,
      );
      final bool useDelayedLauncher = handoffMarkerFile != null;
      final String executable = useDelayedLauncher
          ? windowsUpdateLauncherPath(
              currentExecutablePath: resolvedExecutablePath,
            )
          : installerPath;
      final List<String> launchArgs = useDelayedLauncher
          ? windowsUpdateLauncherArgs(
              markerPath: handoffMarkerFile.path,
              parentProcessId: pid,
              installerPath: installerPath,
              installerArgs: args,
            )
          : args;
      if (useDelayedLauncher &&
          startProcess == null &&
          Platform.isWindows &&
          !File(executable).existsSync()) {
        throw UpdateInstallerException(
            'update launcher not found: $executable');
      }
      ErrorLogService.instance.log(
        'WindowsInstaller.launch',
        useDelayedLauncher
            ? 'Launching Windows update launcher: $executable '
                'parent=$pid installer=$installerPath'
            : 'Launching Windows installer: $installerPath',
      );
      final Future<WindowsInstallerStartedProcess> Function(
        String executable,
        List<String> args,
      ) start = startProcess ?? _startDetachedLauncherProcess;
      final WindowsInstallerStartedProcess started = await start(
        executable,
        launchArgs,
      );
      ErrorLogService.instance.log(
        'WindowsInstaller.launch',
        useDelayedLauncher
            ? 'Windows update launcher launched: '
                'target=${targetVersion ?? 'unknown'}, '
                'launcherPid=${started.pid ?? 'unknown'}, log=$innoLogPath'
            : 'Windows installer launched: target=${targetVersion ?? 'unknown'}, '
                'pid=${started.pid ?? 'unknown'}, log=$innoLogPath',
      );
    } on ProcessException catch (e) {
      final exception = UpdateInstallerException(
        'failed to launch update installer handoff: ${e.message}',
      );
      await _markLaunchFailed(
        handoffMarkerFile,
        exception,
        clock(),
        StackTrace.current,
      );
      throw exception;
    } catch (e, stack) {
      await _markLaunchFailed(handoffMarkerFile, e, clock(), stack);
      rethrow;
    }

    // launcher 已成功启动（分离进程）。当前实例只让出自己的 AppMutex / exe 锁；
    // 其他 hibiki.exe / WebView2 实例交给安装器自己的 hibiki.iss InitializeSetup 处理
    // （先 WM_CLOSE 优雅关闭给落盘机会，再按 image 名强制结束），而不是靠 Inno
    // 的 RestartManager（已用 /NOCLOSEAPPLICATIONS + /NOFORCECLOSEAPPLICATIONS 关掉）。
    // 只有安装器杀不掉的真外部锁（非 hibiki/WebView2 占用目标目录 libmpv）才在 preflight
    // 硬中止并要求用户手动关闭（见 _throwIfWindowsInstallBlocked，TODO-1181）。
    await Future<void>.delayed(Duration.zero);
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.update);
    (exitProcess ?? exit)(0);
  }

  static Future<List<int>> _readHeaderBytes(File file) async {
    final RandomAccessFile raf = await file.open();
    try {
      return await raf.read(2);
    } finally {
      await raf.close();
    }
  }

  /// 启动安装器前的最后一道占用检查。**只对安装器无法自愈的真外部锁硬中止**；能被
  /// 安装器按 image 名关闭的进程（其他 `hibiki.exe` 实例 / WebView2 子进程）不再中止。
  ///
  /// 根因（TODO-1181）：`hibiki.iss` 的 `InitializeSetup()` 在 Inno 的 AppMutex 检查
  /// 之前，先对 `hibiki.exe` 树发 `WM_CLOSE`（优雅关闭，给正在写 DB 的其他实例落盘机会）、
  /// 轮询 `FushiSingleInstanceMutex` 释放，再按 image 名强制结束 `hibiki.exe` +
  /// `msedgewebview2.exe`。即安装器本就能自己关掉其他 Hibiki 实例并解开 mutex 死锁。旧的
  /// Dart 预检却在**启动安装器之前**就因「检测到其他 hibiki.exe」硬 throw，用户永远走不到
  /// 这段自愈，只能被迫手动关进程——是过度防御。故这里改为：安装器杀得掉的占用进程只记警告、
  /// 继续启动安装器交给 `.iss` 处理；只有安装器杀不掉的真外部锁（非 hibiki/WebView2 的进程
  /// 按 image 名占用目标目录里的 `libmpv-2.dll`）才保留硬中止。
  static void _throwIfWindowsInstallBlocked(
    WindowsInstallerDiagnostics diagnostics,
    String innoLogPath,
  ) {
    final List<WindowsProcessInfo> blockers =
        _blockingWindowsInstallProcesses(diagnostics);
    if (blockers.isEmpty) return;

    final String target = diagnostics.targetInstallDir ?? 'unknown';
    final List<WindowsProcessInfo> externalLocks = blockers
        .where((WindowsProcessInfo process) => !_installerCanClose(process))
        .toList(growable: false);
    if (externalLocks.isEmpty) {
      // 只剩安装器能强杀的 hibiki.exe / WebView2 实例：不中止，记警告后继续启动安装器，
      // 由 .iss InitializeSetup 的 WM_CLOSE(优雅落盘)→强杀 序列关掉它们并解开 mutex。
      ErrorLogService.instance.log(
        'WindowsInstaller.installBlockersDeferred',
        'Other Fushi/WebView2 processes are still running; continuing the '
            'update and letting the installer close them (WM_CLOSE then '
            'force-terminate via hibiki.iss). Target: $target. '
            'Deferred: ${_summarizeBlockingProcesses(blockers)}. '
            'Installer log: $innoLogPath',
      );
      return;
    }

    // 不再点名 libmpv：占用者现在还可能是**正被 hook 的游戏**（持有
    // `voice_hook/<arch>/` 下的 injector/hook DLL，见 [queryWindowsGalHookModuleHolders]）。
    // 写死一个组件名会让另一半占用场景的报错答非所问，而 Holders 列表本来就已经指名到
    // 进程路径了。
    throw UpdateInstallerException(
      'Fushi cannot install while a non-Fushi process is using files in the '
      'target directory (the installer cannot close it automatically). '
      'Target: $target. Holders: ${_summarizeBlockingProcesses(externalLocks)}. '
      'Close the listed process manually, then retry the installer. '
      'Installer log: $innoLogPath',
    );
  }

  /// 该占用进程是否能被 `hibiki.iss` 按 image 名强制结束（连同其子进程树）：
  /// 只有 `hibiki.exe`（含 popup/floating 等同 exe 子入口与其子进程树）和 WebView2 的
  /// `msedgewebview2.exe` 是安装器托管得到的。其余 image 名视为安装器杀不掉的真外部锁。
  static bool _installerCanClose(WindowsProcessInfo process) {
    final String name = _windowsImageName(process);
    // 过渡期两个 exe 名都认（安装器 fushi.iss 会同时结束两者）。
    return name == 'fushi.exe' ||
        name == 'hibiki.exe' ||
        name == 'msedgewebview2.exe';
  }

  /// 取进程的 Windows image 名（小写）：优先 [WindowsProcessInfo.name]，缺失时退回
  /// [WindowsProcessInfo.path] 的最后一段，保证 name 未被填充的诊断也能正确归类。
  static String _windowsImageName(WindowsProcessInfo process) {
    final String name = (process.name ?? '').trim();
    if (name.isNotEmpty) return name.toLowerCase();
    final String path = (process.path ?? '').trim();
    if (path.isEmpty) return '';
    final int sep = _lastPathSeparatorIndex(path);
    return (sep >= 0 ? path.substring(sep + 1) : path).toLowerCase();
  }

  static String _summarizeBlockingProcesses(
    List<WindowsProcessInfo> processes,
  ) =>
      processes
          .map(
            (WindowsProcessInfo process) =>
                'PID ${process.pid}: ${process.path ?? process.name ?? 'unknown'}',
          )
          .join('; ');

  static List<WindowsProcessInfo> _blockingWindowsInstallProcesses(
    WindowsInstallerDiagnostics diagnostics,
  ) {
    final Map<int, WindowsProcessInfo> blockers = <int, WindowsProcessInfo>{};
    for (final WindowsProcessInfo process
        in diagnostics.runningFushiProcesses) {
      blockers[process.pid] = process;
    }
    // libmpvModuleHolders 现在由 Restart Manager 按**目标目录里那个文件**给出
    // （见 [queryWindowsLibmpvModuleHolders]），每一个都已经是货真价实的占用者，
    // 无需再按 exe 路径 / 进程名过滤——旧的那层过滤是为了把 `tasklist /M` 的
    // 全机同名 DLL 结果收窄回来，同时也把「exe 在别处却持有我们这份 libmpv」
    // 的外部进程一并漏掉了。特殊情况就此消失。
    for (final WindowsProcessInfo process in diagnostics.libmpvModuleHolders) {
      blockers[process.pid] = process;
    }
    // galgame helper 组件的占用者（正在被 hook 的游戏 + `--hold` 的 injector host）。
    // 与 libmpv 同一条道理：Inno 换不掉被占用的文件，而静默安装参数会把这次失败吞掉，
    // 落地成「新本体 + 旧 helper」，下次开游戏就是 protocol_mismatch（BUG-1675）。
    for (final WindowsProcessInfo process in diagnostics.galHookModuleHolders) {
      blockers[process.pid] = process;
    }
    return blockers.values.toList(growable: false);
  }

  static Future<void> _markLaunchFailed(
    File? handoffMarkerFile,
    Object error,
    DateTime failedAt,
    StackTrace stack,
  ) async {
    ErrorLogService.instance.log('WindowsInstaller.launchFailed', error, stack);
    if (handoffMarkerFile == null) return;
    try {
      await WindowsUpdateHandoff.markLaunchFailed(
        markerFile: handoffMarkerFile,
        error: error.toString(),
        failedAt: failedAt,
      );
    } catch (e, s) {
      ErrorLogService.instance.log(
        'WindowsInstaller.markLaunchFailed',
        e,
        s,
      );
    }
  }
}

Future<WindowsInstallerDiagnostics> collectWindowsInstallerDiagnostics({
  required String currentExecutablePath,
  int? currentProcessId,
}) async {
  final String currentInstallDir = File(currentExecutablePath).parent.path;
  final String targetInstallDir = currentInstallDir;
  final List<WindowsDetectedInstallLocation> detectedInstallLocations =
      <WindowsDetectedInstallLocation>[
    WindowsDetectedInstallLocation(
      source: 'current',
      path: currentInstallDir,
    ),
    ...await queryWindowsRegisteredInstallLocations(),
    ...detectWindowsHistoricalInstallLocations(),
  ];
  final List<WindowsProcessInfo> runningFushiProcesses =
      (await queryWindowsFushiProcesses())
          .where((WindowsProcessInfo process) =>
              currentProcessId == null || process.pid != currentProcessId)
          .toList(growable: false);
  final List<WindowsProcessInfo> libmpvModuleHolders =
      (await queryWindowsLibmpvModuleHolders(targetInstallDir))
          .where((WindowsProcessInfo process) =>
              currentProcessId == null || process.pid != currentProcessId)
          .toList(growable: false);
  final List<WindowsProcessInfo> galHookModuleHolders =
      (await queryWindowsGalHookModuleHolders(targetInstallDir))
          .where((WindowsProcessInfo process) =>
              currentProcessId == null || process.pid != currentProcessId)
          .toList(growable: false);

  return WindowsInstallerDiagnostics(
    currentExecutablePath: currentExecutablePath,
    currentInstallDir: currentInstallDir,
    targetInstallDir: targetInstallDir,
    detectedInstallLocations: detectedInstallLocations,
    runningFushiProcesses: runningFushiProcesses,
    libmpvModuleHolders: libmpvModuleHolders,
    galHookModuleHolders: galHookModuleHolders,
    pathMismatchWarning: windowsInstallPathMismatchWarning(
      targetInstallDir: targetInstallDir,
      locations: detectedInstallLocations,
    ),
  );
}

Future<List<WindowsDetectedInstallLocation>>
    queryWindowsRegisteredInstallLocations() async {
  if (!Platform.isWindows) return const <WindowsDetectedInstallLocation>[];
  const String appId = r'{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}_is1';
  const String uninstallSubKey =
      r'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + appId;
  const List<(WindowsRegistryRoot, String)> keys =
      <(WindowsRegistryRoot, String)>[
    (WindowsRegistryRoot.currentUser, uninstallSubKey),
    (WindowsRegistryRoot.localMachine, uninstallSubKey),
  ];
  final List<WindowsDetectedInstallLocation> result =
      <WindowsDetectedInstallLocation>[];
  for (final (WindowsRegistryRoot root, String subKey) in keys) {
    try {
      result.addAll(
        windowsRegistryInstallLocations(
          installLocation: readWindowsRegistryString(
                root,
                subKey,
                'InstallLocation',
              ) ??
              readWindowsRegistryString(
                root,
                subKey,
                'Inno Setup: App Path',
              ),
          displayIcon: readWindowsRegistryString(root, subKey, 'DisplayIcon'),
        ),
      );
    } catch (_) {
      // Registry diagnostics are best-effort; absence should not block update.
    }
  }
  return _dedupeInstallLocations(result);
}

/// **纯函数**：把已读出的注册表值折成安装位置列表。
///
/// 取值方式（原先是 `reg query` 子进程，现在是 `RegQueryValueExW`）与折算规则
/// 分离，规则这层因此始终可单测，不依赖 Windows。
List<WindowsDetectedInstallLocation> windowsRegistryInstallLocations({
  required String? installLocation,
  required String? displayIcon,
}) {
  final List<WindowsDetectedInstallLocation> result =
      <WindowsDetectedInstallLocation>[];
  if (installLocation != null && installLocation.isNotEmpty) {
    result.add(
      WindowsDetectedInstallLocation(
        source: 'registered',
        path: installLocation,
      ),
    );
  }

  if (displayIcon != null && displayIcon.isNotEmpty) {
    final String path = _stripDisplayIconSuffix(displayIcon);
    // fushi.exe 是改名后的主 exe；\hibiki.exe 保留识别旧版注册表残留安装。
    if (path.toLowerCase().endsWith(r'\fushi.exe') ||
        path.toLowerCase().endsWith('/fushi.exe') ||
        path.toLowerCase().endsWith(r'\hibiki.exe') ||
        path.toLowerCase().endsWith('/hibiki.exe')) {
      result.add(
        WindowsDetectedInstallLocation(
          source: 'registered',
          path: File(path).parent.path,
        ),
      );
    }
  }
  return _dedupeInstallLocations(result);
}

List<WindowsDetectedInstallLocation> detectWindowsHistoricalInstallLocations() {
  if (!Platform.isWindows) return const <WindowsDetectedInstallLocation>[];
  final List<String> candidates = <String>[
    r'D:\Program\Hibiki',
    r'D:\APP\Hibiki',
    if ((Platform.environment['LOCALAPPDATA'] ?? '').isNotEmpty)
      '${Platform.environment['LOCALAPPDATA']}\\Hibiki',
  ];
  return _dedupeInstallLocations(
    <WindowsDetectedInstallLocation>[
      for (final String path in candidates)
        if (Directory(path).existsSync())
          WindowsDetectedInstallLocation(source: 'historical', path: path),
    ],
  );
}

String? windowsInstallPathMismatchWarning({
  required String targetInstallDir,
  required List<WindowsDetectedInstallLocation> locations,
}) {
  final List<WindowsDetectedInstallLocation> mismatches = locations
      .where((WindowsDetectedInstallLocation location) =>
          location.path.isNotEmpty &&
          !_windowsPathEquals(location.path, targetInstallDir))
      .toList(growable: false);
  if (mismatches.isEmpty) return null;
  final String details = mismatches
      .map((WindowsDetectedInstallLocation location) =>
          '${location.source}: ${location.path}')
      .join('; ');
  return 'Install locations differ from the running Fushi directory '
      '$targetInstallDir. This update will install only to the running '
      'directory. Other locations are left untouched; remove old shortcuts or '
      'old install folders manually if they are no longer needed. Detected: '
      '$details';
}

/// 我们自己的 image 名（含改名前的旧包，老安装仍在跑 hibiki.exe）。
const Set<String> kFushiImageNames = <String>{'fushi.exe', 'hibiki.exe'};

/// 走 Win32 快照，**不生成 powershell 子进程**（AV 行为检测把
/// 「进程 spawn powershell 查全机进程」算成高权重恶意信号，见
/// `windows_process_query.dart` 文件头）。语义与原 `Get-CimInstance
/// Win32_Process -Filter "Name = 'fushi.exe' OR Name = 'hibiki.exe'"` 等价。
Future<List<WindowsProcessInfo>> queryWindowsFushiProcesses() async {
  if (!Platform.isWindows) return const <WindowsProcessInfo>[];
  try {
    return windowsProcessesByNames(kFushiImageNames)
        .map((WindowsProcessEntry entry) => WindowsProcessInfo(
              pid: entry.pid,
              name: entry.name,
              path: entry.path,
            ))
        .toList(growable: false);
  } catch (_) {
    return const <WindowsProcessInfo>[];
  }
}

/// 目标安装目录里那个 `libmpv-2.dll` 现在被谁占着。
///
/// 原实现是 `tasklist /M libmpv-2.dll`：扫**全机每个进程的模块表**找同名 DLL，
/// 再由 [WindowsInstaller._blockingWindowsInstallProcesses] 按 exe 路径过滤回来。
/// 那是本次 AV 行为检测告警里权重最高的剩余动作（全机模块枚举），而且**答非所问**
/// ——它按 DLL 名匹配任意路径下的副本，却漏掉「exe 在别处、但正持有我们这一份
/// libmpv 的外部进程」，而那恰恰是硬中止分支要拦的情况（漏了的后果就是放行安装、
/// 然后 Inno 在拷贝阶段 `DeleteFile code 5` 失败，即 BUG-1459 的症状）。
///
/// 改用 Restart Manager 直接问「谁持有这个路径的文件」：不枚举无关进程，且返回的
/// 每一个都是货真价实的占用者，无需再按路径过滤。这也是安装器判占用的标准做法。
Future<List<WindowsProcessInfo>> queryWindowsLibmpvModuleHolders(
  String targetInstallDir,
) async {
  if (!Platform.isWindows || targetInstallDir.isEmpty) {
    return const <WindowsProcessInfo>[];
  }
  try {
    final String libmpv =
        '$targetInstallDir${Platform.pathSeparator}libmpv-2.dll';
    return windowsProcessesHoldingFile(libmpv)
        .map((WindowsProcessEntry entry) => WindowsProcessInfo(
              pid: entry.pid,
              name: entry.name,
              path: entry.path,
            ))
        .toList(growable: false);
  } catch (_) {
    return const <WindowsProcessInfo>[];
  }
}

/// 目标安装目录里的 galgame helper 组件（`voice_hook/<arch>/` 下的 exe/dll）现在被谁占着。
///
/// 与 [queryWindowsLibmpvModuleHolders] 同一个机制、同一个理由，但占用者不是本机的
/// 播放器进程而是**用户正在玩的游戏**：
/// - `fushi_voice_hook.dll` 被注入游戏进程后由该进程持有，直到游戏退出；
/// - `fushi_voice_injector.exe` 以 `--hold` 跑 host 模式维持共享内存，同样活到游戏退出
///   （injector_main.cpp 用法段）；
/// - `LunaHook*.dll` / `LunaHost*.dll` 由上面两者加载。
///
/// 🔴 这就是 protocol_mismatch 的根因（BUG-1675）：用户在游戏还开着时更新 Fushi，Inno
/// 的 `[Files]` 换不掉这些被锁的文件，而应用内更新用的是
/// `/VERYSILENT /SUPPRESSMSGBOXES`（见 [windowsSilentInstallArgs]），**这次失败是静默的**。
/// 落地结果是新 `fushi.exe`（读取端编译进当前 `kSharedVersion`）配旧 injector（写出旧版本号
/// 的共享内存段），下次启动游戏就是 `voice_hook open protocol_mismatch shm=13/want 15`。
/// 那条提示叫用户「关掉游戏重开」——对这个场景永远无效，因为坏的是磁盘上的文件。
///
/// 把这些文件纳入占用检测后，[WindowsInstaller._throwIfWindowsInstallBlocked] 会在**交接给
/// 安装器之前**硬中止并指名占用进程，坏状态从此不再产生。
///
/// 只查 `.exe` / `.dll`：同目录的 `.txt` / `.tpk` / `COPYING` 不会被任何进程加载，查了也只是
/// 白跑 Restart Manager 会话。目录不存在（未装 helper / 非 Windows 包）→ 空列表。
Future<List<WindowsProcessInfo>> queryWindowsGalHookModuleHolders(
  String targetInstallDir,
) async {
  if (!Platform.isWindows || targetInstallDir.isEmpty) {
    return const <WindowsProcessInfo>[];
  }
  try {
    final Directory root = Directory(
      '$targetInstallDir${Platform.pathSeparator}'
      '$kGalgameHelperInstallDirectoryName',
    );
    if (!root.existsSync()) return const <WindowsProcessInfo>[];
    // 按 pid 去重：一个游戏进程通常同时持有 hook DLL 和它加载的 LunaHook DLL，
    // 逐文件查会把同一个占用者报好几遍。
    final Map<int, WindowsProcessInfo> holders = <int, WindowsProcessInfo>{};
    for (final FileSystemEntity entity
        in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final String lower = entity.path.toLowerCase();
      if (!lower.endsWith('.dll') && !lower.endsWith('.exe')) continue;
      for (final WindowsProcessEntry entry
          in windowsProcessesHoldingFile(entity.path)) {
        holders[entry.pid] = WindowsProcessInfo(
          pid: entry.pid,
          name: entry.name,
          path: entry.path,
        );
      }
    }
    return holders.values.toList(growable: false);
  } catch (_) {
    return const <WindowsProcessInfo>[];
  }
}

/// 走 Win32 快照，**不生成 powershell 子进程**（理由同
/// [queryWindowsFushiProcesses]）。
Future<Map<int, WindowsProcessInfo>> queryWindowsProcessInfoForPids(
  Iterable<int> pids,
) async {
  final List<int> uniquePids = pids.toSet().where((int pid) => pid > 0).toList()
    ..sort();
  if (!Platform.isWindows || uniquePids.isEmpty) {
    return const <int, WindowsProcessInfo>{};
  }
  try {
    return windowsProcessesByIds(uniquePids).map(
      (int pid, WindowsProcessEntry entry) => MapEntry<int, WindowsProcessInfo>(
        pid,
        WindowsProcessInfo(pid: entry.pid, name: entry.name, path: entry.path),
      ),
    );
  } catch (_) {
    return const <int, WindowsProcessInfo>{};
  }
}

List<WindowsDetectedInstallLocation> _dedupeInstallLocations(
  Iterable<WindowsDetectedInstallLocation> locations,
) {
  final Set<String> seen = <String>{};
  final List<WindowsDetectedInstallLocation> result =
      <WindowsDetectedInstallLocation>[];
  for (final WindowsDetectedInstallLocation location in locations) {
    if (location.path.trim().isEmpty) continue;
    final String key = _normalizeWindowsPath(location.path);
    if (!seen.add(key)) continue;
    result.add(location);
  }
  return result;
}

String _stripDisplayIconSuffix(String value) {
  String path = value.trim();
  if (path.startsWith('"')) {
    final int closing = path.indexOf('"', 1);
    if (closing > 0) path = path.substring(1, closing);
  }
  return path.replaceFirst(RegExp(r',\d+$'), '').trim();
}

bool _windowsPathEquals(String a, String b) {
  return _normalizeWindowsPath(a) == _normalizeWindowsPath(b);
}

String _normalizeWindowsPath(String path) {
  return path
      .trim()
      .replaceAll('/', r'\')
      .replaceFirst(RegExp(r'\\+$'), '')
      .toLowerCase();
}

Future<void> ensureWindowsInstallTargetWritable(Directory installDir) async {
  final File probe = File(
    '${installDir.path}${Platform.pathSeparator}.fushi-update-write-test',
  );
  try {
    await installDir.create(recursive: true);
    await probe.writeAsString('hibiki updater preflight', flush: true);
  } catch (e) {
    throw UpdateInstallerException(
      'Cannot write to installation directory: ${installDir.path}. '
      'Close Fushi and run the installer as administrator, or reinstall '
      'Fushi to a user-writable folder. Details: $e',
    );
  } finally {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // Best-effort cleanup; a failed cleanup should not hide the real result.
    }
  }
}

// ── macOS 安装器（Phase 3：去沙盒后应用内自替换）───────────────────────────────

class MacSwapStartedProcess {
  const MacSwapStartedProcess({required this.pid});

  final int? pid;
}

/// **纯函数**：从运行中可执行文件路径反解出所属 `.app` 包路径。
///
/// macOS 下 `Platform.resolvedExecutable` 形如
/// `/Applications/hibiki.app/Contents/MacOS/hibiki`，取从右起第一个以 `.app` 结尾的
/// 路径段，返回到该段为止的前缀（即 bundle 根）。没有 `.app` 段（如以裸二进制运行、
/// 命令行测试）→ null，调用方据此拒绝应用内替换、回退打开发布页。
String? macAppBundlePathForExecutable(String executablePath) {
  final List<String> parts = executablePath.split('/');
  for (int i = parts.length - 1; i >= 0; i--) {
    if (parts[i].endsWith('.app')) {
      return parts.sublist(0, i + 1).join('/');
    }
  }
  return null;
}

/// POSIX 单引号转义：把字符串包进单引号，内部单引号用 `'\''` 拆开重接。
String _shSingleQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// **纯函数**：生成 macOS 更新替换脚本。等父进程（[parentPid]）退出→把旧
/// [targetAppPath] 移到 [backupPath]（可逆，不先删）→`ditto` 把新 [newAppPath] 拷入
/// 原位→去 quarantine→`open` 重启；任何一步失败即回滚旧包并 `open` 之，**绝不留坏档**。
/// 结果写进 [resultPath]（`{"status":"installed"|"failed","message":"..."}`），供下次
/// 启动 [MacUpdateHandoff.reconcile] 判定。抽成纯函数便于单测断言脚本结构。
String buildMacSwapScript({
  required int parentPid,
  required String newAppPath,
  required String targetAppPath,
  required String backupPath,
  required String extractDir,
  required String resultPath,
  required String logPath,
}) {
  final StringBuffer b = StringBuffer();
  b.writeln('#!/bin/sh');
  b.writeln(
      '# Fushi macOS in-app update swap (Phase 3). Waits for the running');
  b.writeln(
      '# app to exit, then swaps the .app bundle and relaunches. Restores');
  b.writeln(
      '# the previous bundle on any failure so a botched swap never leaves');
  b.writeln('# the user without a working app.');
  b.writeln('set -u');
  b.writeln('PARENT_PID=$parentPid');
  b.writeln('NEW_APP=${_shSingleQuote(newAppPath)}');
  b.writeln('TARGET_APP=${_shSingleQuote(targetAppPath)}');
  b.writeln('BACKUP=${_shSingleQuote(backupPath)}');
  b.writeln('EXTRACT_DIR=${_shSingleQuote(extractDir)}');
  b.writeln('RESULT=${_shSingleQuote(resultPath)}');
  b.writeln('LOG=${_shSingleQuote(logPath)}');
  b.writeln(
      r'''log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $1" >> "$LOG" 2>/dev/null || true; }''');
  b.writeln(
      r'''write_result() { printf '{"status":"%s","message":"%s"}' "$1" "$2" > "$RESULT" 2>/dev/null || true; }''');
  b.writeln(
      '# Wait (bounded ~60s) for the parent process to exit. Uses a `ps`');
  b.writeln(
      '# liveness probe (never terminates anything) so the swap only starts');
  b.writeln('# once Fushi has quit on its own and released the bundle.');
  b.writeln('i=0');
  b.writeln(r'while ps -p "$PARENT_PID" > /dev/null 2>&1; do');
  b.writeln(r'  i=$((i + 1))');
  b.writeln(r'  [ "$i" -gt 300 ] && break');
  b.writeln('  sleep 0.2');
  b.writeln('done');
  b.writeln('sleep 0.5');
  b.writeln('fail() {');
  b.writeln(r'  log "FAIL: $1"');
  b.writeln(r'  write_result failed "$1"');
  b.writeln(
      r'  open "$TARGET_APP" 2>/dev/null || open "$BACKUP" 2>/dev/null || true');
  b.writeln(r'  rm -rf "$EXTRACT_DIR" 2>/dev/null || true');
  b.writeln('  exit 1');
  b.writeln('}');
  b.writeln(r'[ -d "$NEW_APP" ] || fail "extracted app bundle missing"');
  b.writeln(
      '# Move the old bundle aside (reversible) rather than deleting first.');
  b.writeln(r'rm -rf "$BACKUP" 2>/dev/null || true');
  b.writeln(r'if [ -d "$TARGET_APP" ]; then');
  b.writeln(
      r'  mv "$TARGET_APP" "$BACKUP" || fail "cannot move current app aside"');
  b.writeln('fi');
  b.writeln(r'if /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then');
  b.writeln(
      r'  /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true');
  b.writeln(r'  rm -rf "$BACKUP" 2>/dev/null || true');
  b.writeln(r'  rm -rf "$EXTRACT_DIR" 2>/dev/null || true');
  b.writeln(r'  log "OK swapped -> $TARGET_APP"');
  b.writeln('  write_result installed ""');
  b.writeln(r'  open "$TARGET_APP" || fail "installed but relaunch failed"');
  b.writeln('  exit 0');
  b.writeln('else');
  b.writeln('  # Restore the previous bundle.');
  b.writeln(r'  rm -rf "$TARGET_APP" 2>/dev/null || true');
  b.writeln(r'  [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET_APP"');
  b.writeln(
      r'  fail "failed to copy new app into place; restored previous version"');
  b.writeln('fi');
  return b.toString();
}

/// PK zip 魔数（0x50 0x4B）。GFW 代理镜像可能 HTTP 200 回 HTML 限流页被原样写进
/// `.zip`，解压/替换前先拦掉（对齐 Windows 的 MZ 校验）。
bool isZipHeader(List<int> header) =>
    header.length >= 2 && header[0] == 0x50 && header[1] == 0x4B;

class MacInstaller {
  /// 解压下载好的 `-macos.zip`→写握手标记与替换脚本→分离启动脚本→退出本进程，
  /// 让脚本在本进程退出后替换 `/Applications/hibiki.app` 并重启。
  ///
  /// 根因防护（对齐 Windows 的崩溃防护）：
  /// 1. 先校验产物确实是 zip（PK 魔数），拦掉代理 HTML/截断文件。
  /// 2. 解压产物无 `.app` / 找不到运行中 bundle → 抛 [UpdateInstallerException]
  ///    （上层 catch → SnackBar），绝不在没有接班脚本时静默退出。
  /// 3. 仅当分离脚本**确实启动成功**后才 `exit(0)`。
  static Future<void> runAndExit(
    String zipPath, {
    required String targetVersion,
    String? currentExecutablePath,
    int? currentPid,
    Future<MacSwapStartedProcess> Function(String scriptPath)? startProcess,
    void Function(int code)? exitProcess,
    DateTime Function()? now,
  }) async {
    final DateTime Function() clock = now ?? DateTime.now;
    final File zip = File(zipPath);

    // 1. 校验是真 zip。
    List<int> head;
    final RandomAccessFile raf = await zip.open();
    try {
      head = await raf.read(4);
    } finally {
      await raf.close();
    }
    if (!isZipHeader(head)) {
      throw UpdateInstallerException(
        'Downloaded macOS update is not a valid zip archive '
        '(${head.length} bytes read); refusing to install.',
      );
    }

    // 2. 反解运行中 app bundle 路径。
    final String execPath =
        currentExecutablePath ?? Platform.resolvedExecutable;
    final String? appBundle = macAppBundlePathForExecutable(execPath);
    if (appBundle == null) {
      throw UpdateInstallerException(
        'Cannot locate the running .app bundle from "$execPath"; in-app '
        'update requires Fushi launched as an .app.',
      );
    }

    // 3. 解压到 updates 目录下的暂存目录。
    final Directory updatesDir = zip.parent;
    final Directory extractDir = Directory(
      '${updatesDir.path}${Platform.pathSeparator}'
      'mac-update-$targetVersion.extracted',
    );
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }
    await extractDir.create(recursive: true);
    final ProcessResult unzip = await Process.run(
      '/usr/bin/ditto',
      <String>['-x', '-k', zipPath, extractDir.path],
    );
    if (unzip.exitCode != 0) {
      throw UpdateInstallerException(
        'Failed to extract macOS update zip (ditto exit ${unzip.exitCode}): '
        '${unzip.stderr}',
      );
    }

    // 4. 在解压目录里找唯一 `.app`。
    final String? newApp = _findAppBundleIn(extractDir);
    if (newApp == null) {
      throw UpdateInstallerException(
        'Extracted macOS update contains no .app bundle under '
        '${extractDir.path}.',
      );
    }

    // 5. 写握手标记 + 替换脚本。
    final File markerFile = MacUpdateHandoff.markerFile(updatesDir);
    final File resultFile = MacUpdateHandoff.resultFile(updatesDir);
    await MacUpdateHandoff.writePending(
      markerFile: markerFile,
      targetVersion: targetVersion,
      targetAppPath: appBundle,
      startedAt: clock(),
    );
    final int parentPid = currentPid ?? pid;
    final String backupPath = '${updatesDir.path}${Platform.pathSeparator}'
        'mac-update-$targetVersion.backup';
    final String logPath = '${updatesDir.path}${Platform.pathSeparator}'
        'mac-update-$targetVersion.log';
    final String script = buildMacSwapScript(
      parentPid: parentPid,
      newAppPath: newApp,
      targetAppPath: appBundle,
      backupPath: backupPath,
      extractDir: extractDir.path,
      resultPath: resultFile.path,
      logPath: logPath,
    );
    final File scriptFile = File(
      '${updatesDir.path}${Platform.pathSeparator}'
      'mac-update-$targetVersion.sh',
    );
    await scriptFile.writeAsString(script, flush: true);

    // 6. 分离启动脚本（脚本自己等本进程退出后再替换）。
    final MacSwapStartedProcess started =
        await (startProcess ?? _startDetachedScript)(scriptFile.path);
    if (started.pid == null) {
      // 脚本没起来 = 不会有替换发生，本轮失败此刻已由上层 catch → SnackBar 告知。
      // 删掉刚写的握手标记，避免下次启动 reconcile 误报「更新未完成」重复打扰。
      try {
        if (await markerFile.exists()) await markerFile.delete();
      } catch (_) {
        // best-effort：删失败也无大碍，reconcile 幂等只提示一次。
      }
      throw UpdateInstallerException(
        'Failed to start the macOS update swap script; keeping the current '
        'version.',
      );
    }

    // 7. 退出本进程，让脚本接管替换。
    (exitProcess ?? _defaultExit)(0);
  }

  static Future<MacSwapStartedProcess> _startDetachedScript(
    String scriptPath,
  ) async {
    final Process process = await Process.start(
      '/bin/sh',
      <String>[scriptPath],
      mode: ProcessStartMode.detached,
    );
    return MacSwapStartedProcess(pid: process.pid);
  }

  static void _defaultExit(int code) => exit(code);

  static String? _findAppBundleIn(Directory dir) {
    try {
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is Directory && entity.path.endsWith('.app')) {
          return entity.path;
        }
      }
    } catch (_) {
      // 目录读取失败 → 返回 null，调用方抛「无 .app」错误。
    }
    return null;
  }
}
