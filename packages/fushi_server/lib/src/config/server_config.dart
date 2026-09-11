/// `fushi_server.yaml` 配置文件：加载 / 默认值 / 写回。
///
/// 一个文件即全部配置，没有环境变量矩阵（`FUSHI_FFMPEG` 这类引擎既有覆盖除外）。
/// 首次 `serve` 找不到文件就按默认值生成一份（含新生成的 admin token），
/// 之后只在用户改 WebUI 设置或 CLI `admin` 子命令时写回。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// 一条扫描根：服务端库的来源目录。
class LibraryRootConfig {
  const LibraryRootConfig({
    required this.id,
    required this.path,
    this.kind = 'video',
    this.enabled = true,
  });

  factory LibraryRootConfig.fromYaml(Object? raw, int index) {
    if (raw is! Map) {
      throw FormatException('libraries[$index] 必须是映射（id/path/kind）');
    }
    final String? path = raw['path']?.toString();
    if (path == null || path.trim().isEmpty) {
      throw FormatException('libraries[$index].path 不能为空');
    }
    return LibraryRootConfig(
      id: raw['id']?.toString() ?? 'lib$index',
      path: path,
      kind: raw['kind']?.toString() ?? 'video',
      enabled: raw['enabled'] != false,
    );
  }

  final String id;
  final String path;

  /// `video` | `book`（epub）| `manga`（页图目录）。
  final String kind;
  final bool enabled;

  Map<String, Object?> toYamlMap() => <String, Object?>{
        'id': id,
        'path': path,
        'kind': kind,
        'enabled': enabled,
      };
}

class ServerConfig {
  const ServerConfig({
    required this.dataDir,
    required this.port,
    required this.bind,
    required this.tls,
    required this.deviceName,
    required this.lanRequiresPin,
    required this.libraries,
    required this.ffmpegPath,
    required this.ffprobePath,
    required this.adminToken,
    required this.uploadQuotaBytes,
    required this.subtitleLanguage,
    required this.metadataLocale,
    required this.qbittorrentUrl,
    required this.qbittorrentUsername,
    required this.qbittorrentPassword,
    required this.ortLibraryPath,
    required this.adminPort,
    required this.adminBind,
    required this.torrentEngine,
    required this.torrentLibraryPath,
    required this.torrentListen,
  });

  static const int defaultPort = 38765;

  /// WebUI / admin API 单独一个端口：互联协议端口只跑冻结面上的 `/api/*`，
  /// admin 鉴权（admin token）与 per-peer token 完全分开。
  static const int defaultAdminPort = 38780;

  /// `torrent.engine` 三态：auto = 有随包/系统 libfushi_torrent_ffi 就内置，否则
  /// 配了 qBittorrent 就外接；embedded / qbittorrent = 显式指定（不满足即 unsupported）。
  static const String torrentEngineAuto = 'auto';
  static const String torrentEngineEmbedded = 'embedded';
  static const String torrentEngineQbittorrent = 'qbittorrent';
  static const String defaultTorrentListen = '0.0.0.0:6881,[::]:6881';

  /// `metadata_locale` 默认值。app 侧资料语言跟随界面语言，无头服务端没有界面
  /// 语言，只能给一个**可见、可改**的配置默认；取 zh-CN 是延续本服务端此前的
  /// 实际行为（WebUI 本身只有中文），不是把中文当隐含常量——那种写死在引擎里、
  /// 用户无处可改的才是 BUG-2454 修掉的东西。
  static const String defaultMetadataLocale = 'zh-CN';

  factory ServerConfig.defaults({required String dataDir}) => ServerConfig(
        dataDir: dataDir,
        port: defaultPort,
        bind: '0.0.0.0',
        tls: true,
        deviceName: Platform.localHostname,
        lanRequiresPin: true,
        libraries: const <LibraryRootConfig>[],
        ffmpegPath: null,
        ffprobePath: null,
        adminToken: null,
        uploadQuotaBytes: 50 * 1024 * 1024 * 1024,
        subtitleLanguage: 'ja',
        metadataLocale: defaultMetadataLocale,
        qbittorrentUrl: null,
        qbittorrentUsername: null,
        qbittorrentPassword: null,
        ortLibraryPath: null,
        adminPort: defaultAdminPort,
        adminBind: '0.0.0.0',
        torrentEngine: torrentEngineAuto,
        torrentLibraryPath: null,
        torrentListen: defaultTorrentListen,
      );

  final String dataDir;
  final int port;
  final String bind;
  final bool tls;
  final String deviceName;

  /// 无头服务端没有审批 UI，PIN 是唯一的人因；默认恒需 PIN。
  final bool lanRequiresPin;
  final List<LibraryRootConfig> libraries;

  /// ffmpeg / ffprobe 可执行路径：装进引擎 `ffmpegPathOverride` / `ffprobePathOverride`
  /// （显式覆盖，优先于 `FUSHI_FFMPEG` 环境变量与 PATH）。null = 不装。
  final String? ffmpegPath;
  final String? ffprobePath;

  /// WebUI / admin API 的凭据；null = 首次启动生成并写回。
  final String? adminToken;
  final int uploadQuotaBytes;

  /// 视频 sidecar 字幕匹配语言代码。
  final String subtitleLanguage;

  /// 刮削资料语言（BCP-47，如 `ja` / `zh-CN`）：TMDB 文字与海报语言、简介语言
  /// 感知都由它派生。偏好表里显式设过 `video_metadata_locale` 时以偏好为准。
  final String metadataLocale;
  final String? qbittorrentUrl;
  final String? qbittorrentUsername;
  final String? qbittorrentPassword;

  /// onnxruntime 动态库覆盖路径（null = asr_onnx_ffi 默认候选）。
  final String? ortLibraryPath;

  /// WebUI / admin API 监听端口与地址（0 = 关闭 WebUI）。
  final int adminPort;
  final String adminBind;

  /// 内置 torrent 引擎：`torrent.engine` / `torrent.library`（显式 .so 路径）/
  /// `torrent.listen`（libtorrent 监听接口串）。
  final String torrentEngine;
  final String? torrentLibraryPath;
  final String torrentListen;

  ServerConfig copyWith({
    int? port,
    String? bind,
    bool? tls,
    String? deviceName,
    bool? lanRequiresPin,
    List<LibraryRootConfig>? libraries,
    String? ffmpegPath,
    String? ffprobePath,
    String? adminToken,
    int? uploadQuotaBytes,
    String? subtitleLanguage,
    String? metadataLocale,
    String? qbittorrentUrl,
    String? qbittorrentUsername,
    String? qbittorrentPassword,
    String? ortLibraryPath,
    int? adminPort,
    String? adminBind,
    String? torrentEngine,
    String? torrentLibraryPath,
    String? torrentListen,
  }) =>
      ServerConfig(
        dataDir: dataDir,
        port: port ?? this.port,
        bind: bind ?? this.bind,
        tls: tls ?? this.tls,
        deviceName: deviceName ?? this.deviceName,
        lanRequiresPin: lanRequiresPin ?? this.lanRequiresPin,
        libraries: libraries ?? this.libraries,
        ffmpegPath: ffmpegPath ?? this.ffmpegPath,
        ffprobePath: ffprobePath ?? this.ffprobePath,
        adminToken: adminToken ?? this.adminToken,
        uploadQuotaBytes: uploadQuotaBytes ?? this.uploadQuotaBytes,
        subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
        metadataLocale: metadataLocale ?? this.metadataLocale,
        qbittorrentUrl: qbittorrentUrl ?? this.qbittorrentUrl,
        qbittorrentUsername: qbittorrentUsername ?? this.qbittorrentUsername,
        qbittorrentPassword: qbittorrentPassword ?? this.qbittorrentPassword,
        ortLibraryPath: ortLibraryPath ?? this.ortLibraryPath,
        adminPort: adminPort ?? this.adminPort,
        adminBind: adminBind ?? this.adminBind,
        torrentEngine: torrentEngine ?? this.torrentEngine,
        torrentLibraryPath: torrentLibraryPath ?? this.torrentLibraryPath,
        torrentListen: torrentListen ?? this.torrentListen,
      );

  /// 从 YAML 文本解析；缺项取默认。[dataDir] 相对路径按配置文件所在目录解析。
  static ServerConfig parse(String text, {required String configDir}) {
    final Object? doc = loadYaml(text);
    final Map<dynamic, dynamic> map =
        doc is Map ? doc : const <dynamic, dynamic>{};
    String dataDir = map['data_dir']?.toString() ?? 'data';
    if (!p.isAbsolute(dataDir)) dataDir = p.normalize(p.join(configDir, dataDir));
    final ServerConfig base = ServerConfig.defaults(dataDir: dataDir);
    final Object? libsRaw = map['libraries'];
    final List<LibraryRootConfig> libraries = <LibraryRootConfig>[
      if (libsRaw is List)
        for (int i = 0; i < libsRaw.length; i++)
          LibraryRootConfig.fromYaml(libsRaw[i], i),
    ];
    final Object? qb = map['qbittorrent'];
    final Map<dynamic, dynamic> qbMap =
        qb is Map ? qb : const <dynamic, dynamic>{};
    final Object? torrent = map['torrent'];
    final Map<dynamic, dynamic> torrentMap =
        torrent is Map ? torrent : const <dynamic, dynamic>{};
    final String engine = torrentMap['engine']?.toString() ?? base.torrentEngine;
    if (engine != torrentEngineAuto &&
        engine != torrentEngineEmbedded &&
        engine != torrentEngineQbittorrent) {
      throw FormatException('torrent.engine 只能是 auto / embedded / qbittorrent，实际 "$engine"');
    }
    return base.copyWith(
      port: _int(map['port']) ?? base.port,
      bind: map['bind']?.toString() ?? base.bind,
      tls: _bool(map['tls']) ?? base.tls,
      deviceName: map['device_name']?.toString() ?? base.deviceName,
      lanRequiresPin: _bool(map['lan_requires_pin']) ?? base.lanRequiresPin,
      libraries: libraries,
      ffmpegPath: map['ffmpeg']?.toString(),
      ffprobePath: map['ffprobe']?.toString(),
      adminToken: map['admin_token']?.toString(),
      uploadQuotaBytes: _int(map['upload_quota_bytes']) ?? base.uploadQuotaBytes,
      subtitleLanguage:
          map['subtitle_language']?.toString() ?? base.subtitleLanguage,
      metadataLocale:
          map['metadata_locale']?.toString() ?? base.metadataLocale,
      qbittorrentUrl: qbMap['url']?.toString(),
      qbittorrentUsername: qbMap['username']?.toString(),
      qbittorrentPassword: qbMap['password']?.toString(),
      ortLibraryPath: map['onnxruntime_library']?.toString(),
      adminPort: _int(map['admin_port']) ?? base.adminPort,
      adminBind: map['admin_bind']?.toString() ?? base.adminBind,
      torrentEngine: engine,
      torrentLibraryPath: torrentMap['library']?.toString(),
      torrentListen: torrentMap['listen']?.toString() ?? base.torrentListen,
    );
  }

  static Future<ServerConfig> load(File file) async {
    final String text = await file.readAsString();
    return parse(text, configDir: file.parent.path);
  }

  /// 序列化成可读 YAML（手写：yaml 包只解析不生成，且这里键有限、顺序固定）。
  String toYaml() {
    final StringBuffer b = StringBuffer();
    b.writeln('# fushi_server 配置。改完重启 serve 生效（端口/TLS/绑定地址）。');
    b.writeln('data_dir: ${_q(dataDir)}');
    b.writeln('port: $port');
    b.writeln('bind: ${_q(bind)}');
    b.writeln('tls: $tls');
    b.writeln('device_name: ${_q(deviceName)}');
    b.writeln('lan_requires_pin: $lanRequiresPin');
    b.writeln('admin_port: $adminPort');
    b.writeln('admin_bind: ${_q(adminBind)}');
    b.writeln('subtitle_language: ${_q(subtitleLanguage)}');
    b.writeln('metadata_locale: ${_q(metadataLocale)}');
    if (ffmpegPath != null) b.writeln('ffmpeg: ${_q(ffmpegPath!)}');
    if (ffprobePath != null) b.writeln('ffprobe: ${_q(ffprobePath!)}');
    if (ortLibraryPath != null) {
      b.writeln('onnxruntime_library: ${_q(ortLibraryPath!)}');
    }
    b.writeln('upload_quota_bytes: $uploadQuotaBytes');
    if (adminToken != null) b.writeln('admin_token: ${_q(adminToken!)}');
    b.writeln('torrent:');
    b.writeln('  engine: ${_q(torrentEngine)}');
    if (torrentLibraryPath != null) b.writeln('  library: ${_q(torrentLibraryPath!)}');
    b.writeln('  listen: ${_q(torrentListen)}');
    if (qbittorrentUrl != null) {
      b.writeln('qbittorrent:');
      b.writeln('  url: ${_q(qbittorrentUrl!)}');
      if (qbittorrentUsername != null) {
        b.writeln('  username: ${_q(qbittorrentUsername!)}');
      }
      if (qbittorrentPassword != null) {
        b.writeln('  password: ${_q(qbittorrentPassword!)}');
      }
    }
    b.writeln('libraries:');
    if (libraries.isEmpty) b.writeln('  []');
    for (final LibraryRootConfig lib in libraries) {
      b.writeln('  - id: ${_q(lib.id)}');
      b.writeln('    path: ${_q(lib.path)}');
      b.writeln('    kind: ${_q(lib.kind)}');
      b.writeln('    enabled: ${lib.enabled}');
    }
    return b.toString();
  }

  Future<void> save(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(toYaml(), flush: true);
  }

  static int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');

  static bool? _bool(Object? v) {
    if (v is bool) return v;
    final String s = '${v ?? ''}'.toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
    return null;
  }

  /// YAML 双引号字符串（转义反斜杠与引号）。
  static String _q(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
