/// 无头服务端的互联远程自更新：[HostSelfUpdater] 的服务端实现（app 侧对应
/// `fushi/lib/src/updates/host_self_update_service.dart`）。
///
/// 流程：查 `hajisensai/fushi-server` Releases → 下载本平台包到安装目录的暂存区 →
/// 核对 GitHub 给的 SHA-256 → 系统 tar 解包 → [swapServerBundle] 换文件 →
/// [onInstalled]（`serve` 收到后停服并以 [kExitSelfUpdated] 退出，由 systemd / 服务管理器拉起
/// 新版）。client 看到的是连接断开、重连后版本号变了（与桌面 host 同一种结局）。
///
/// 平台门只有一处（[platformSupported]）：发布包（有 `release.json`）+ 有对应发布
/// 包的平台（Linux / Windows x64）。用户开关是配置 `remote_update`（默认关）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:fushi_engine/utils/net/app_http.dart'
    show createAppHttpIoClient;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi_server/src/self_update/server_bundle_swap.dart';
import 'package:fushi_server/src/self_update/server_release.dart';

/// 取 Releases JSON（测试缝；生产 = GitHub REST API）。
typedef ServerReleaseFetcher = Future<Object?> Function(Uri url);

/// 把 [url] 下载到 [into]，边下边报进度（测试缝；生产 = [downloadServerPackage]）。
typedef ServerPackageDownloader =
    Future<void> Function(
      Uri url,
      File into, {
      required void Function(double progress) onProgress,
      int? expectedSize,
    });

/// 服务端退出码：装好了新版（或启动收尾把中断的换包还原了），等服务管理器重启。
///
/// 专用码，不与任何别的退出码共用：75（EX_TEMPFAIL）是冲突（数据目录被占、端口被占、
/// ctl 409……，见 `command_io.dart` 的 `kExitConflict`），服务单元要能「75 不重启、
/// 这个码重启」——两者共用一个码时，数据目录被另一个实例占着的服务端会被服务管理器
/// 无限重启。选 10：非零（systemd `Restart=on-failure`、NSSM 默认都会拉起），不在
/// LSB（1–7）、sysexits（64–78）、shell（≥126）与 systemd 自用（200+）的有含义区间里。
/// 契约钉在 `cli_exit_code_test.dart`。
const int kExitSelfUpdated = 10;

class ServerSelfUpdater implements HostSelfUpdater {
  ServerSelfUpdater({
    required this.installRoot,
    required this.current,
    required this.assetSuffix,
    required Future<bool> Function() isAllowed,
    required this.onInstalled,
    ServerReleaseFetcher? fetchReleases,
    ServerPackageDownloader? download,
    ServerArchiveExtractor? extract,
    DateTime Function()? now,
    this.refreshThrottle = const Duration(minutes: 5),
    String? platform,
  }) : _isAllowed = isAllowed,
       _fetch = fetchReleases ?? fetchGitHubJson,
       _download = download ?? downloadServerPackage,
       _extract = extract ?? extractServerArchiveWithTar,
       _now = now ?? DateTime.now,
       _platform = platform ?? Platform.operatingSystem;

  /// 用运行中的可执行文件定位安装目录与版本身份。不是发布包 / 平台没有发布包时
  /// 照样返回实例，只是 [platformSupported] 为假（端点回 unsupported，能力位仍在，
  /// client 能说清「这台服务端不能远程更新」而不是「不懂」）。
  factory ServerSelfUpdater.forRunningBundle({
    required Future<bool> Function() isAllowed,
    required void Function() onInstalled,
  }) {
    final Directory? root = currentReleaseBundleRoot();
    return ServerSelfUpdater(
      installRoot: root,
      current: root == null ? null : ServerReleaseInfo.readFrom(root),
      assetSuffix: serverReleaseAssetSuffix(),
      isAllowed: isAllowed,
      onInstalled: onInstalled,
    );
  }

  /// 安装目录（`bin/` 的上一级）；不是发布包 → null。
  final Directory? installRoot;

  /// 本机发布包的版本身份；没有 `release.json` → null。
  final ServerReleaseInfo? current;

  /// 本平台发布包后缀；没有发布包的平台 → null。
  final String? assetSuffix;

  /// 新版已换进安装目录：`serve` 据此停服退出。
  final void Function() onInstalled;

  final Duration refreshThrottle;

  final Future<bool> Function() _isAllowed;
  final ServerReleaseFetcher _fetch;
  final ServerPackageDownloader _download;
  final ServerArchiveExtractor _extract;
  final DateTime Function() _now;
  final String _platform;

  ServerReleaseCandidate? _latest;
  DateTime? _lastResolvedAt;
  Future<void>? _resolving;
  HostUpdatePhase _phase = HostUpdatePhase.idle;

  /// [startUpdate] 已过 busy 检查、正在重查更新源（还没进 downloading）。检查与
  /// 占位之间隔着一次 await：不同步占位，并发的两次触发都能过检查，各跑一遍
  /// [_run]，在同一个暂存目录里互删、重复换包。
  bool _starting = false;
  double? _progress;
  String? _error;

  @override
  bool get platformSupported =>
      installRoot != null && current != null && assetSuffix != null;

  @override
  Future<bool> isRemoteUpdateAllowed() => _isAllowed();

  @override
  Future<HostUpdateStatus> status({bool refresh = false}) async {
    if (refresh && platformSupported && !_phase.isBusy) {
      await _refreshLatest();
    }
    return _snapshot(await _isAllowed());
  }

  @override
  Future<HostUpdateStatus> startUpdate() async {
    if (_starting || _phase.isBusy) {
      throw const HostUpdateRejected(HostUpdateDenial.busy);
    }
    _starting = true;
    try {
      await _refreshLatest(force: true);
      final ServerReleaseCandidate? latest = _latest;
      if (latest == null) {
        throw const HostUpdateRejected(HostUpdateDenial.noUpdate);
      }
      // 与上面的检查之间不再有 await：占位（_starting → downloading）不留空档。
      _phase = HostUpdatePhase.downloading;
      _progress = 0;
      _error = null;
      final HostUpdateStatus accepted = _snapshot(true);
      unawaited(_run(latest));
      return accepted;
    } finally {
      _starting = false;
    }
  }

  Future<void> _run(ServerReleaseCandidate latest) async {
    final Directory staging = Directory(
      p.join(installRoot!.path, kServerUpdateStagingDir),
    );
    try {
      final String? expected = latest.sha256;
      if (expected == null) {
        // 不装校验不了的包：GitHub 给每个 release 资产都算 digest，缺了就是异常。
        throw const ServerUpdateException('missing_digest');
      }
      if (staging.existsSync()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final File archive = File(p.join(staging.path, latest.assetName));
      await _download(
        latest.downloadUrl,
        archive,
        expectedSize: latest.size,
        onProgress: (double v) => _progress = v,
      );
      final String actual = (await sha256.bind(archive.openRead()).first)
          .toString();
      if (actual != expected) {
        throw ServerUpdateException(
          'digest_mismatch',
          'expected $expected, got $actual',
        );
      }
      _phase = HostUpdatePhase.installing;
      _progress = null;
      final Directory extracted = Directory(p.join(staging.path, 'extract'));
      await _extract(archive, extracted);
      final Directory bundle = Directory(
        p.join(extracted.path, kServerBundleDirName),
      );
      _checkExtractedBundle(bundle, latest);
      await swapServerBundle(newBundle: bundle, installRoot: installRoot!);
      engineLog.logDiagnostic(
        'ServerSelfUpdate',
        'installed ${latest.displayVersion} '
            '(was ${current!.displayVersion}); exiting for restart',
      );
      onInstalled();
    } catch (e, stack) {
      engineLog.log('ServerSelfUpdate.run', e, stack);
      _phase = HostUpdatePhase.failed;
      _progress = null;
      _error = e is ServerUpdateException ? e.code : '$e';
      try {
        if (staging.existsSync()) await staging.delete(recursive: true);
      } on FileSystemException {
        // 下次启动的 cleanupAfterServerUpdate 再删。
      }
    }
  }

  /// 解出来的必须是同一序号、同一平台的完整发布包：有可执行文件、`release.json`
  /// 与 release 对得上。
  void _checkExtractedBundle(Directory bundle, ServerReleaseCandidate latest) {
    final String exe = Platform.isWindows ? 'fushi_server.exe' : 'fushi_server';
    if (!File(p.join(bundle.path, 'bin', exe)).existsSync()) {
      throw const ServerUpdateException('bad_package', 'no bin/ executable');
    }
    final ServerReleaseInfo? info = ServerReleaseInfo.readFrom(bundle);
    if (info == null || info.sequence != latest.sequence) {
      throw ServerUpdateException(
        'bad_package',
        'release.json sequence ${info?.sequence} != ${latest.sequence}',
      );
    }
  }

  /// 节流地重查；并发合并成一次。查失败只留痕，保留上一次结果。
  Future<void> _refreshLatest({bool force = false}) {
    if (!platformSupported) return Future<void>.value();
    final DateTime? last = _lastResolvedAt;
    if (!force && last != null && _now().difference(last) < refreshThrottle) {
      return Future<void>.value();
    }
    return _resolving ??= () async {
      try {
        final ServerReleaseInfo info = current!;
        final Uri url = info.isBeta
            ? Uri.https(
                'api.github.com',
                '/repos/$kServerReleaseRepo/releases',
                <String, String>{'per_page': '20'},
              )
            : Uri.https(
                'api.github.com',
                '/repos/$kServerReleaseRepo/releases/latest',
              );
        _latest = pickServerUpdate(
          releasesJson: await _fetch(url),
          current: info,
          assetSuffix: assetSuffix!,
        );
        _lastResolvedAt = _now();
      } catch (e, stack) {
        engineLog.log('ServerSelfUpdate.resolve', e, stack);
      } finally {
        _resolving = null;
      }
    }();
  }

  HostUpdateStatus _snapshot(bool allowed) => HostUpdateStatus(
    currentVersion: current?.displayVersion ?? 'dev',
    platform: _platform,
    supported: platformSupported,
    remoteUpdateAllowed: allowed,
    latestVersion: _latest?.displayVersion,
    phase: _phase,
    progress: _progress,
    error: _error,
  );
}

const Map<String, String> _githubHeaders = <String, String>{
  'Accept': 'application/vnd.github+json',
  'User-Agent': 'fushi_server',
  'X-GitHub-Api-Version': '2022-11-28',
};

/// GitHub REST 取 JSON；非 200 抛出。
Future<Object?> fetchGitHubJson(Uri url) async {
  final http.Client client = createAppHttpIoClient();
  try {
    final http.Response r = await client
        .get(url, headers: _githubHeaders)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw HttpException('GitHub ${r.statusCode}', uri: url);
    }
    return jsonDecode(r.body);
  } finally {
    client.close();
  }
}

/// 流式下载到 [into]，按 [expectedSize]（或 Content-Length）报进度。
///
/// 两道超时：[headerTimeout] 等响应头；[idleTimeout] 是读正文时两块数据之间的最长
/// 空档（不是总时长——慢而不断的下载照常完成）。连接卡死不报错也不关时，没有这道
/// 空闲超时 `await for` 会永远等下去，更新永远停在 downloading、再也触发不了。
/// 超时抛 [ServerUpdateException]（`download_timeout` / `download_stalled`），由
/// [ServerSelfUpdater] 转成失败态并清掉暂存。[client] 是测试缝（传入的不负责关）。
Future<void> downloadServerPackage(
  Uri url,
  File into, {
  required void Function(double progress) onProgress,
  int? expectedSize,
  http.Client? client,
  Duration headerTimeout = const Duration(seconds: 60),
  Duration idleTimeout = const Duration(seconds: 60),
}) async {
  final http.Client httpClient = client ?? createAppHttpIoClient();
  try {
    final http.Request req = http.Request('GET', url)
      ..headers['User-Agent'] = 'fushi_server';
    final http.StreamedResponse res;
    try {
      res = await httpClient.send(req).timeout(headerTimeout);
    } on TimeoutException {
      throw ServerUpdateException(
        'download_timeout',
        'no response headers in ${headerTimeout.inSeconds}s',
      );
    }
    if (res.statusCode != 200) {
      throw HttpException('download ${res.statusCode}', uri: url);
    }
    final int? total = expectedSize ?? res.contentLength;
    final IOSink sink = into.openWrite();
    int received = 0;
    try {
      // 退出 await for（含超时抛出）会取消订阅，底层连接随之断开。
      await for (final List<int> chunk in res.stream.timeout(idleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          onProgress((received / total).clamp(0, 1).toDouble());
        }
      }
    } on TimeoutException {
      throw ServerUpdateException(
        'download_stalled',
        'no data for ${idleTimeout.inMilliseconds}ms after $received bytes',
      );
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      throw ServerUpdateException(
        'download_incomplete',
        '$received of $total bytes',
      );
    }
  } finally {
    if (client == null) httpClient.close();
  }
}
