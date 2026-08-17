import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:path/path.dart' as p;

/// 官方推荐包（词典 + 日/英发音音频库，Fushi 备份 zip 格式）分发地址。
/// 与 `docs/user-guide.md` 的链接同源；这是**清单拉取失败时的回退直链**——
/// 正常更新路径是改 [kRecommendedPackManifestUrl] 指向的清单（换包零发版），
/// 只有清单机制本身变更时才需要动这里。
const String kRecommendedPackCloudflareUrl =
    'https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip';
const String kRecommendedPackGoogleDriveUrl =
    'https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing';

/// 推荐包**稳定清单**地址：换包时上传新 zip + 更新这份 json 即可，app 零发版。
/// 格式（字段见 [RecommendedPackManifest]）：
/// `{"version":"2026-08-14","url":"https://dl.wrds.xyz/….fushi.zip",`
/// `"sha256":"<hex>","size_bytes":10200000000}`
const String kRecommendedPackManifestUrl =
    'https://dl.wrds.xyz/fushi-recommended-manifest.json';

/// 展示用体积标签（近似值，随包更新；清单带 size_bytes 时以清单为准展示）。
const String kRecommendedPackSizeLabel = '9.5 GB';

/// 推荐包清单：稳定 URL 下发的当前包指针。[url] 必填；[sha256]（小写 hex，可选）
/// 提供时下载完成后做完整性校验；[sizeBytes]（可选）用于展示。
@immutable
class RecommendedPackManifest {
  const RecommendedPackManifest({
    required this.url,
    this.version,
    this.sha256,
    this.sizeBytes,
  });

  final String url;
  final String? version;
  final String? sha256;
  final int? sizeBytes;
}

/// 解析清单 json（纯函数，便于单测）。结构不合法 / url 缺失或非 https 时返回
/// null（调用方回退内置直链）——清单是优化路径，绝不因它坏掉挡住下载。
RecommendedPackManifest? parseRecommendedPackManifest(String jsonText) {
  final Object? decoded;
  try {
    decoded = json.decode(jsonText);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final Object? url = decoded['url'];
  if (url is! String || !url.startsWith('https://')) return null;
  final Object? sha256Raw = decoded['sha256'];
  final String? sha256Hex = sha256Raw is String && sha256Raw.isNotEmpty
      ? sha256Raw.toLowerCase()
      : null;
  if (sha256Hex != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256Hex)) {
    return null;
  }
  final Object? sizeBytes = decoded['size_bytes'];
  final Object? version = decoded['version'];
  return RecommendedPackManifest(
    url: url,
    version: version is String ? version : null,
    sha256: sha256Hex,
    sizeBytes: sizeBytes is int && sizeBytes > 0 ? sizeBytes : null,
  );
}

/// 拉取稳定清单；网络失败 / 超时 / 内容不合法一律返回 null（回退内置直链）。
Future<RecommendedPackManifest?> fetchRecommendedPackManifest() async {
  try {
    final Dio dio = createAppDio(
      options: BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        responseType: ResponseType.plain,
      ),
    );
    final Response<String> response =
        await dio.get<String>(kRecommendedPackManifestUrl);
    final String? body = response.data;
    if (body == null) return null;
    return parseRecommendedPackManifest(body);
  } catch (_) {
    return null;
  }
}

/// 推荐包断点续传下载器。半截文件落 `<name>.part`，完成后原子改名为最终文件名；
/// 再次调用 [download] 会带 `Range` 续传（服务器忽略 Range 时自动从头重下）。
///
/// 导入推荐包会走备份导入流程并**重启进程**，没有机会在导入成功后删包——所以
/// [markImportStarted] 在启动导入前落一个 flag 文件，重启回来后由
/// [cleanupIfImported]（新手引导页 initState 调）把整个包目录删掉，不让 9.5 GB
/// 的 zip 静默常驻磁盘。
class RecommendedPackDownloader {
  RecommendedPackDownloader({
    required Directory packDir,
    this.url = kRecommendedPackCloudflareUrl,
    this.sha256Hex,
  }) : _packDir = packDir;

  final Directory _packDir;

  /// 下载地址：默认内置回退直链；清单拉取成功时用清单里的最新 URL（文件名随
  /// 版本变，新旧版本的完整包/半截包自然分开存放）。
  final String url;

  /// 期望的 sha256（小写 hex，来自清单，可选）。提供时下载完成后流式校验，
  /// 不符即删档报错——坏包/被截断的包不进备份导入。
  final String? sha256Hex;

  String get _fileName => Uri.parse(url).pathSegments.last;

  /// 下载完成的推荐包文件（可能尚不存在）。
  File get packFile => File(p.join(_packDir.path, _fileName));

  File get _partFile => File(p.join(_packDir.path, '$_fileName.part'));

  File get _importedFlagFile => File(p.join(_packDir.path, 'imported.flag'));

  bool get hasCompletedFile => packFile.existsSync();

  int get partialBytes {
    try {
      return _partFile.existsSync() ? _partFile.lengthSync() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  /// 启动备份导入前打标；导入完成后进程重启，由 [cleanupIfImported] 收尾删包。
  Future<void> markImportStarted() async {
    _packDir.createSync(recursive: true);
    await _importedFlagFile.writeAsString('1');
  }

  /// 若曾进入导入（flag 在），删除整个包目录（best-effort）。
  Future<void> cleanupIfImported() async {
    if (!_importedFlagFile.existsSync()) return;
    try {
      if (_packDir.existsSync()) await _packDir.delete(recursive: true);
    } on FileSystemException {
      // 占用/权限问题不阻断引导；下次进入再试。
    }
  }

  /// 下载（或续传）推荐包。[progress] 0..1（服务器没报总大小时保持不动）；
  /// [receivedBytes] 为已收字节（含续传前的半截）。取消经 [cancelToken]，半截
  /// 文件保留供下次续传。总大小已知时按字节数校验，截断包不会进入导入。
  Future<File> download({
    required ValueNotifier<double> progress,
    required ValueNotifier<int> receivedBytes,
    CancelToken? cancelToken,
  }) async {
    _packDir.createSync(recursive: true);
    if (hasCompletedFile) return packFile;

    // 公网出站统一走 createAppDio（应用代理出口，outbound 纪律守卫的装配点）。
    // 只限连接建立超时；传输本身不设整体超时（9.5 GB 大包），取消按钮 +
    // 断点续传兜底。
    final Dio dio = createAppDio(
      options: BaseOptions(followRedirects: true, maxRedirects: 5),
    );
    int existing = partialBytes;
    final Response<ResponseBody> response = await dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: <String, Object?>{
          if (existing > 0) 'range': 'bytes=$existing-',
        },
        validateStatus: (int? status) => status == 200 || status == 206,
      ),
    );
    if (existing > 0 && response.statusCode == 200) {
      // 服务器忽略 Range（回整文件）：append 会拼出坏包，只能丢半截从头写。
      existing = 0;
      if (_partFile.existsSync()) _partFile.deleteSync();
    }
    final int? remaining =
        int.tryParse(response.headers.value('content-length') ?? '');
    final int? total = remaining == null ? null : existing + remaining;

    final IOSink sink = _partFile.openWrite(
      mode: existing > 0 ? FileMode.append : FileMode.write,
    );
    int received = existing;
    try {
      await for (final Uint8List chunk in response.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        receivedBytes.value = received;
        if (total != null && total > 0) {
          progress.value = received / total;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      throw Exception('recommended pack download truncated: '
          '$received / $total bytes');
    }
    if (sha256Hex != null) {
      final Digest digest = await sha256.bind(_partFile.openRead()).first;
      if (digest.toString() != sha256Hex) {
        // 坏包不留：删掉半截，下次从头下（续传一个已知坏的文件没有意义）。
        _partFile.deleteSync();
        throw Exception('recommended pack sha256 mismatch: '
            'got $digest, expected $sha256Hex');
      }
    }
    _partFile.renameSync(packFile.path);
    return packFile;
  }
}
