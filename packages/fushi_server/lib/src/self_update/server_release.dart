/// 服务端发布包的版本身份与更新源解析（远程自更新用）。
///
/// 发布包根目录（`bin/` 的上一级）里有一份 `release.json`，由 `release-server.yml`
/// 打包时写入：`{"version": "3.4.0", "sequence": 1234, "tag": "v3.4.0-beta.1234",
/// "channel": "beta"}`。版本与通道和 app 一致（2026-11-24 起）：formal / beta / debug。没有这份文件 = 不是发布包（本机 `dart run` / 自己 `dart build
/// cli` 出的 bundle），远程更新不可用。
///
/// 更新源是独立发布仓 `hajisensai/fushi-server` 的 GitHub Releases。新旧只比发布序号
/// （`tool/release_sequence.sh` 的单调序列，包名里带着）：formal 通道只看
/// `releases/latest`；beta 通道看最近的 release 列表（beta 与 formal 都收，不收滚动的
/// debug 包）；debug 通道在列表之外再看 [kServerDebugRollingTag]，三者都收。
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

/// 独立发布仓（服务端 Release 落在这里，不在 app 仓）。
const String kServerReleaseRepo = 'hajisensai/fushi-server';

/// 调试通道的固定滚动 release tag（每次 develop 构建替换资产，不堆 prerelease）。
const String kServerDebugRollingTag = 'debug-rolling';

/// 发布包根目录里的版本身份文件名。
const String kServerReleaseInfoFile = 'release.json';

/// 容器镜像标记：`packages/fushi_server/docker/` 的两份 Dockerfile 都设
/// `FUSHI_CONTAINER=1`。镜像里的程序文件属于镜像层，更新靠拉新镜像重建容器；就地换包
/// 会被下一次重建丢掉，退出码 75 也没有 systemd 去接。
const String kServerContainerEnv = 'FUSHI_CONTAINER';

/// 是否运行在 Fushi 容器镜像里（[kServerContainerEnv] 非空且不是 `0` / `false`）。
bool serverRunsInContainerImage({Map<String, String>? environment}) {
  final String? value =
      (environment ?? Platform.environment)[kServerContainerEnv];
  if (value == null) return false;
  final String v = value.trim().toLowerCase();
  return v.isNotEmpty && v != '0' && v != 'false';
}

/// 本机运行中的发布包的版本身份。
class ServerReleaseInfo {
  const ServerReleaseInfo({
    required this.version,
    required this.sequence,
    required this.tag,
    required this.channel,
  });

  /// 发布时 `fushi/pubspec.yaml` 的 `version:`（与 app 同号；2026-11-24 之前的包是
  /// `packages/fushi_server/pubspec.yaml` 的独立版本 `0.1.0`）。
  final String version;

  /// 发布序号（单调递增；新旧只比它）。
  final int sequence;

  /// Release tag（`v<version>`、`v<version>-beta.<seq>` 或 [kServerDebugRollingTag]）。
  final String tag;

  /// `formal` / `beta` / `debug`。
  final String channel;

  /// 不是正式版通道（更新源要看 release 列表，而不只是 `releases/latest`）。
  bool get isBeta => channel != 'formal';

  bool get isDebug => channel == 'debug';

  /// 给 client 看的版本号：tag 去掉前导 `v`；滚动 debug 包的 tag 不带版本，
  /// 显示 `<version>-debug.<sequence>`。
  String get displayVersion =>
      displayVersionOf(tag: tag, version: version, sequence: sequence);

  /// 解析 `release.json`；字段缺失或类型不对 → null（当成不是发布包）。
  static ServerReleaseInfo? tryParse(String raw) {
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) return null;
      final Object? version = json['version'];
      final Object? sequence = json['sequence'];
      final Object? tag = json['tag'];
      final Object? channel = json['channel'];
      if (version is! String || version.isEmpty) return null;
      if (sequence is! int || sequence <= 0) return null;
      if (tag is! String || tag.isEmpty) return null;
      return ServerReleaseInfo(
        version: version,
        sequence: sequence,
        tag: tag,
        channel: switch (channel) {
          'formal' => 'formal',
          'debug' => 'debug',
          _ => 'beta',
        },
      );
    } on FormatException {
      return null;
    }
  }

  /// 读 [bundleRoot] 下的 `release.json`；没有或解析不了 → null。
  static ServerReleaseInfo? readFrom(Directory bundleRoot) {
    final File file = File(p.join(bundleRoot.path, kServerReleaseInfoFile));
    if (!file.existsSync()) return null;
    return tryParse(file.readAsStringSync());
  }
}

String displayVersionOfTag(String tag) =>
    tag.startsWith('v') ? tag.substring(1) : tag;

/// [displayVersionOfTag]，但滚动 debug tag 换成 `<version>-debug.<sequence>`。
String displayVersionOf({
  required String tag,
  required String version,
  required int sequence,
}) => tag == kServerDebugRollingTag
    ? '$version-debug.$sequence'
    : displayVersionOfTag(tag);

/// 正在运行的可执行文件所在的发布包根目录（`<root>/bin/<exe>` 的 `<root>`）；
/// 可执行文件不在 `bin/` 下（`dart run`）→ null。
Directory? currentBundleRoot({String? executablePath}) {
  final String exe = executablePath ?? Platform.resolvedExecutable;
  final String binDir = p.dirname(exe);
  if (p.basename(binDir) != 'bin') return null;
  return Directory(p.dirname(binDir));
}

/// 正在运行的是**发布包**时返回它的根目录：`bin/` 的上一级、且有 `release.json`。
/// `dart run` / `dart test`（可执行文件是 SDK 的 `bin/dart`，上一级是 SDK 根）、自己
/// `dart build cli` 出的 bundle → null。换包 / 启动清理只认这个，免得把 SDK 根当安装
/// 目录去删东西。
Directory? currentReleaseBundleRoot({String? executablePath}) {
  final Directory? root = currentBundleRoot(executablePath: executablePath);
  if (root == null) return null;
  return File(p.join(root.path, kServerReleaseInfoFile)).existsSync()
      ? root
      : null;
}

/// 本机平台对应的发布包后缀；没有发布包的平台（macOS / arm64 …）→ null。
String? serverReleaseAssetSuffix({Abi? abi}) => switch (abi ?? Abi.current()) {
  Abi.linuxX64 => '-linux-x64.tar.gz',
  Abi.windowsX64 => '-windows-x64.zip',
  _ => null,
};

/// 一个可装的更新：哪个 release、哪个包、校验值。
class ServerReleaseCandidate {
  const ServerReleaseCandidate({
    required this.tag,
    required this.version,
    required this.sequence,
    required this.assetName,
    required this.downloadUrl,
    required this.sha256,
    required this.size,
  });

  final String tag;

  /// 包名里的版本段（`fushi_server-<version>-<seq>…`）。
  final String version;
  final int sequence;
  final String assetName;
  final Uri downloadUrl;

  /// GitHub 给每个 release 资产算的 `digest`（小写 hex）；没有 → null（不装）。
  final String? sha256;
  final int? size;

  String get displayVersion =>
      displayVersionOf(tag: tag, version: version, sequence: sequence);
}

/// 从 GitHub release JSON（单个对象或列表）里挑出比 [current] 新、且有本平台包的
/// 最高序号候选；没有 → null。草稿一律跳过；formal 通道不收 prerelease；滚动 debug
/// release 只给 debug 通道（beta 装机不能被推到调试包上）。
ServerReleaseCandidate? pickServerUpdate({
  required Object? releasesJson,
  required ServerReleaseInfo current,
  required String assetSuffix,
}) {
  final List<Object?> releases = releasesJson is List
      ? releasesJson
      : <Object?>[releasesJson];
  ServerReleaseCandidate? best;
  for (final Object? release in releases) {
    if (release is! Map) continue;
    if (release['draft'] == true) continue;
    if (!current.isBeta && release['prerelease'] == true) continue;
    final Object? tag = release['tag_name'];
    final Object? assets = release['assets'];
    if (tag is! String || assets is! List) continue;
    if (tag == kServerDebugRollingTag && !current.isDebug) continue;
    for (final Object? asset in assets) {
      if (asset is! Map) continue;
      final ServerReleaseCandidate? candidate = _candidateOf(
        tag,
        asset,
        assetSuffix,
      );
      if (candidate == null || candidate.sequence <= current.sequence) {
        continue;
      }
      if (best == null || candidate.sequence > best.sequence) best = candidate;
    }
  }
  return best;
}

/// 包名形如 `fushi_server-<version>-<seq><suffix>`。
final RegExp _assetName = RegExp(r'^fushi_server-([^-]+)-(\d+)(-.+)$');

ServerReleaseCandidate? _candidateOf(String tag, Map asset, String suffix) {
  final Object? name = asset['name'];
  final Object? url = asset['browser_download_url'];
  if (name is! String || url is! String) return null;
  final RegExpMatch? m = _assetName.firstMatch(name);
  if (m == null || m.group(3) != suffix) return null;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !isServerReleaseDownloadUrl(uri)) return null;
  final Object? size = asset['size'];
  return ServerReleaseCandidate(
    tag: tag,
    version: m.group(1)!,
    sequence: int.parse(m.group(2)!),
    assetName: name,
    downloadUrl: uri,
    sha256: normalizeSha256Digest(asset['digest']),
    size: size is int && size > 0 ? size : null,
  );
}

/// 下载地址必须是 [kServerReleaseRepo] 自己的 release 资产
/// （`https://github.com/<repo>/releases/download/...`）。校验值与地址出自同一份
/// release JSON，挡不住「JSON 指去别处」；把来源钉死在发布仓上，被改写的地址
/// 连下载都不会发生。
bool isServerReleaseDownloadUrl(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'github.com' &&
    !uri.hasPort &&
    uri.path.startsWith('/$kServerReleaseRepo/releases/download/') &&
    !uri.pathSegments.contains('..');

/// `sha256:<hex>` / `<hex>` → 小写 hex；不是 64 位 hex → null。
String? normalizeSha256Digest(Object? raw) {
  if (raw is! String) return null;
  String value = raw.trim().toLowerCase();
  if (value.startsWith('sha256:')) value = value.substring('sha256:'.length);
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(value) ? value : null;
}
