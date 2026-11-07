/// 服务端发布包的版本身份与更新源解析（远程自更新用）。
///
/// 发布包根目录（`bin/` 的上一级）里有一份 `release.json`，由 `release-server.yml`
/// 打包时写入：`{"version": "0.1.0", "sequence": 1234, "tag": "v0.1.0-beta.1234",
/// "channel": "beta"}`。没有这份文件 = 不是发布包（本机 `dart run` / 自己 `dart build
/// cli` 出的 bundle），远程更新不可用。
///
/// 更新源是独立发布仓 `hajisensai/fushi-server` 的 GitHub Releases。新旧只比发布序号
/// （`tool/release_sequence.sh` 的单调序列，包名里带着）：beta 通道看最近的 release
/// 列表（beta 与 formal 都收），formal 通道只看 `releases/latest`。
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

/// 独立发布仓（服务端 Release 落在这里，不在 app 仓）。
const String kServerReleaseRepo = 'hajisensai/fushi-server';

/// 发布包根目录里的版本身份文件名。
const String kServerReleaseInfoFile = 'release.json';

/// 本机运行中的发布包的版本身份。
class ServerReleaseInfo {
  const ServerReleaseInfo({
    required this.version,
    required this.sequence,
    required this.tag,
    required this.channel,
  });

  /// `packages/fushi_server/pubspec.yaml` 的 `version:`。
  final String version;

  /// 发布序号（单调递增；新旧只比它）。
  final int sequence;

  /// Release tag（`v<version>` 或 `v<version>-beta.<seq>`）。
  final String tag;

  /// `beta` / `formal`。
  final String channel;

  bool get isBeta => channel != 'formal';

  /// 给 client 看的版本号：tag 去掉前导 `v`。
  String get displayVersion => displayVersionOfTag(tag);

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
        channel: channel == 'formal' ? 'formal' : 'beta',
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

/// 正在运行的可执行文件所在的发布包根目录（`<root>/bin/<exe>` 的 `<root>`）；
/// 可执行文件不在 `bin/` 下（`dart run`）→ null。
Directory? currentBundleRoot({String? executablePath}) {
  final String exe = executablePath ?? Platform.resolvedExecutable;
  final String binDir = p.dirname(exe);
  if (p.basename(binDir) != 'bin') return null;
  return Directory(p.dirname(binDir));
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
    required this.sequence,
    required this.assetName,
    required this.downloadUrl,
    required this.sha256,
    required this.size,
  });

  final String tag;
  final int sequence;
  final String assetName;
  final Uri downloadUrl;

  /// GitHub 给每个 release 资产算的 `digest`（小写 hex）；没有 → null（不装）。
  final String? sha256;
  final int? size;

  String get displayVersion => displayVersionOfTag(tag);
}

/// 从 GitHub release JSON（单个对象或列表）里挑出比 [current] 新、且有本平台包的
/// 最高序号候选；没有 → null。草稿一律跳过；formal 通道不收 prerelease。
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
final RegExp _assetName = RegExp(r'^fushi_server-[^-]+-(\d+)(-.+)$');

ServerReleaseCandidate? _candidateOf(String tag, Map asset, String suffix) {
  final Object? name = asset['name'];
  final Object? url = asset['browser_download_url'];
  if (name is! String || url is! String) return null;
  final RegExpMatch? m = _assetName.firstMatch(name);
  if (m == null || m.group(2) != suffix) return null;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !isServerReleaseDownloadUrl(uri)) return null;
  final Object? size = asset['size'];
  return ServerReleaseCandidate(
    tag: tag,
    sequence: int.parse(m.group(1)!),
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
