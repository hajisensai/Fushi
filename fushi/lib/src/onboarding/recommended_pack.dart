import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/download_plan.dart';
import 'package:fushi/src/utils/misc/resumable_downloader.dart';
import 'package:fushi/src/utils/misc/segmented_downloader.dart';
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
///
/// 分片分发（可选，见 [RecommendedPackManifest.toDownloadPlan]）再加：
/// `"mirrors":[…整包镜像…]`、`"part_size_bytes":268435456`，或物理切片的
/// `"parts":[{"name":…,"offset":…,"length":…,"sha256":…}]` + `"part_base_urls":[…]`。
const String kRecommendedPackManifestUrl =
    'https://dl.wrds.xyz/fushi-recommended-manifest.json';

/// 展示用体积标签（近似值，随包更新；清单带 size_bytes 时以清单为准展示）。
const String kRecommendedPackSizeLabel = '9.5 GB';

/// 清单没给 `part_size_bytes` 时，整包 Range 模式的默认切段大小。
///
/// 64 MiB：9.5 GB 约 152 段——段够多才能在几个镜像间摊开、单段失败重下的代价也小；
/// 再小则请求数与进度落盘开销开始压过收益。
const int kRecommendedPackDefaultPartSize = 64 * 1024 * 1024;

/// 单片切片的来源。
@immutable
class RecommendedPackPart {
  const RecommendedPackPart({
    required this.name,
    required this.offset,
    required this.length,
    this.sha256,
  });

  /// 切片文件名，拼在 `part_base_urls` 后面。
  final String name;
  final int offset;
  final int length;
  final String? sha256;
}

/// 推荐包清单：稳定 URL 下发的当前包指针。[url] 必填；[sha256]（小写 hex，可选）
/// 提供时下载完成后做完整性校验；[sizeBytes]（可选）用于展示，也是**开启分片并发
/// 下载的前提**（没有总长就没法切段）。
@immutable
class RecommendedPackManifest {
  const RecommendedPackManifest({
    required this.url,
    this.version,
    this.sha256,
    this.sizeBytes,
    this.mirrors = const <String>[],
    this.parts = const <RecommendedPackPart>[],
    this.partBaseUrls = const <String>[],
    this.partSizeBytes,
  });

  final String url;
  final String? version;
  final String? sha256;
  final int? sizeBytes;

  /// 整包镜像（与 [url] 同内容的其它主机），Range 模式下与 [url] 一起轮换。
  final List<String> mirrors;

  /// 物理切片表（可选）。给出时每片各自是一个可独立下载的资源，可以撒在多台主机上
  /// ——单片 ≤2 GB 时 GitHub Release 也装得下。
  final List<RecommendedPackPart> parts;

  /// 切片所在目录（可多个互为镜像），与 [RecommendedPackPart.name] 拼成完整 URL。
  final List<String> partBaseUrls;

  /// 整包 Range 模式的切段大小；缺省用 [kRecommendedPackDefaultPartSize]。
  final int? partSizeBytes;

  /// 整包来源列表：主 URL 在前，镜像在后。
  List<String> get wholeFileUrls => <String>[url, ...mirrors];

  /// 把清单翻成分片下载计划。信息不足（不知道总长）时返回 null，调用方回退到
  /// 「探测总长」或单流下载。
  ///
  /// 两种形态最终都落成同一个 [DownloadPlan]：物理切片给每片挂切片 URL
  /// （`remoteOffset` = 0），整包镜像再作为**额外来源**挂上去（`remoteOffset` =
  /// 该片偏移）——于是「GitHub 放切片、CF 放整包」可以互为镜像，下载器不需要知道
  /// 这回事。
  DownloadPlan? toDownloadPlan() {
    if (parts.isNotEmpty && partBaseUrls.isNotEmpty) {
      final DownloadPlan? sliced = _slicedPlan();
      if (sliced != null) return sliced;
    }
    final int? total = sizeBytes;
    if (total == null || total <= 0) return null;
    return DownloadPlan.ranged(
      urls: wholeFileUrls,
      totalBytes: total,
      partSize: partSizeBytes ?? kRecommendedPackDefaultPartSize,
      sha256: sha256,
      version: version,
    );
  }

  DownloadPlan? _slicedPlan() {
    int total = 0;
    for (final RecommendedPackPart part in parts) {
      total += part.length;
    }
    // 清单自相矛盾（切片总长 ≠ 声明总长）时不猜，退回整包 Range 模式。
    if (sizeBytes != null && sizeBytes != total) return null;
    final List<DownloadPart> planParts = <DownloadPart>[];
    for (int i = 0; i < parts.length; i++) {
      final RecommendedPackPart part = parts[i];
      planParts.add(DownloadPart(
        index: i,
        offset: part.offset,
        length: part.length,
        sha256: part.sha256,
        sources: <DownloadSource>[
          for (final String base in partBaseUrls)
            DownloadSource(url: _joinUrl(base, part.name)),
          for (final String whole in wholeFileUrls)
            DownloadSource(url: whole, remoteOffset: part.offset),
        ],
      ));
    }
    try {
      return DownloadPlan(
        totalBytes: total,
        parts: planParts,
        sha256: sha256,
        version: version,
      );
    } on ArgumentError {
      // 切片表有缝/重叠：宁可退回整包 Range，也不下一个注定拼错的包。
      return null;
    }
  }

  static String _joinUrl(String base, String name) =>
      base.endsWith('/') ? '$base$name' : '$base/$name';
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
  final String? sha256Hex = _parseSha256(decoded['sha256']);
  if (decoded['sha256'] is String &&
      (decoded['sha256'] as String).isNotEmpty &&
      sha256Hex == null) {
    return null;
  }
  final Object? sizeBytes = decoded['size_bytes'];
  final Object? version = decoded['version'];
  final Object? partSize = decoded['part_size_bytes'];
  return RecommendedPackManifest(
    url: url,
    version: version is String ? version : null,
    sha256: sha256Hex,
    sizeBytes: sizeBytes is int && sizeBytes > 0 ? sizeBytes : null,
    mirrors: _parseHttpsList(decoded['mirrors']),
    partBaseUrls: _parseHttpsList(decoded['part_base_urls']),
    parts: _parseParts(decoded['parts']),
    partSizeBytes: partSize is int && partSize > 0 ? partSize : null,
  );
}

String? _parseSha256(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final String lower = raw.toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(lower) ? lower : null;
}

List<String> _parseHttpsList(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? item in raw)
      if (item is String && item.startsWith('https://')) item,
  ];
}

List<RecommendedPackPart> _parseParts(Object? raw) {
  if (raw is! List) return const <RecommendedPackPart>[];
  final List<RecommendedPackPart> parsed = <RecommendedPackPart>[];
  for (final Object? item in raw) {
    if (item is! Map<String, dynamic>) return const <RecommendedPackPart>[];
    final Object? name = item['name'];
    final Object? offset = item['offset'];
    final Object? length = item['length'];
    if (name is! String ||
        name.isEmpty ||
        name.contains('/') ||
        offset is! int ||
        offset < 0 ||
        length is! int ||
        length <= 0) {
      // 一条坏记录就整表作废：半张切片表比没有更危险。
      return const <RecommendedPackPart>[];
    }
    parsed.add(RecommendedPackPart(
      name: name,
      offset: offset,
      length: length,
      sha256: _parseSha256(item['sha256']),
    ));
  }
  return parsed;
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

/// 推荐包下载器。优先**分片并发 + 多镜像**（[SegmentedDownloader]）：一次开
/// [SegmentedDownloader.kDefaultDownloadConcurrency] 条连接分头取，单片失败只重下
/// 该片并轮换镜像，进度落 `<name>.mpart.json` 跨进程可续。
///
/// 服务器不支持 Range（探测拿不到总长）时退回**单流续传**旧路径——那条路一直在，
/// 不因为新增并发而丢掉任何一种能下成的场景。
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
    this.manifest,
    this.concurrency = SegmentedDownloader.kDefaultDownloadConcurrency,
  }) : _packDir = packDir;

  /// 从清单构造：URL / sha256 / 分片计划一起跟着清单走。
  factory RecommendedPackDownloader.fromManifest({
    required Directory packDir,
    required RecommendedPackManifest manifest,
    int concurrency = SegmentedDownloader.kDefaultDownloadConcurrency,
  }) =>
      RecommendedPackDownloader(
        packDir: packDir,
        url: manifest.url,
        sha256Hex: manifest.sha256,
        manifest: manifest,
        concurrency: concurrency,
      );

  final Directory _packDir;

  /// 下载地址：默认内置回退直链；清单拉取成功时用清单里的最新 URL（文件名随
  /// 版本变，新旧版本的完整包/半截包自然分开存放）。
  final String url;

  /// 期望的 sha256（小写 hex，来自清单，可选）。提供时下载完成后流式校验，
  /// 不符即删档报错——坏包/被截断的包不进备份导入。
  final String? sha256Hex;

  /// 清单（可选）。带分片信息时走分片并发；为 null 时按内置直链探测。
  final RecommendedPackManifest? manifest;

  /// 并发段数。
  final int concurrency;

  String get _fileName => Uri.parse(url).pathSegments.last;

  /// 下载完成的推荐包文件（可能尚不存在）。
  File get packFile => File(p.join(_packDir.path, _fileName));

  /// 单流续传的半截文件。
  File get _partFile => File(p.join(_packDir.path, '$_fileName.part'));

  /// 分片下载的半截文件（预分配到完整大小）。与单流的 `.part` **分开命名**：两条
  /// 路的半截文件语义不同（一个是「已下这么多字节」，一个是「预分配好、按片填」），
  /// 共用一个名字会让另一条路把对方的半截当成自己的断点。
  File get _multiPartFile => File(p.join(_packDir.path, '$_fileName.mpart'));

  File get _multiPartProgressFile =>
      File(p.join(_packDir.path, '$_fileName.mpart.json'));

  File get _importedFlagFile => File(p.join(_packDir.path, 'imported.flag'));

  /// 单流路径的服务端校验子（ETag / Last-Modified）落盘处，供跨进程续传带
  /// `If-Range`。分片路径把校验子记在自己的进度文件里，不用这个。
  File get _partValidatorFile =>
      File(p.join(_packDir.path, '$_fileName.part.etag'));

  String? _readSingleStreamValidator() {
    try {
      if (!_partValidatorFile.existsSync()) return null;
      final String value = _partValidatorFile.readAsStringSync().trim();
      return value.isEmpty ? null : value;
    } on FileSystemException {
      return null;
    }
  }

  void _writeSingleStreamValidator(String? value) {
    try {
      if (value == null || value.isEmpty) {
        if (_partValidatorFile.existsSync()) _partValidatorFile.deleteSync();
        return;
      }
      _partValidatorFile.writeAsStringSync(value);
    } on FileSystemException {
      // 校验子写不下只影响续传安全性判定，不该中断下载。
    }
  }

  bool get hasCompletedFile => packFile.existsSync();

  /// 已下字节（两条路合一）。分片路的 `.mpart` 是**预分配**的完整大小，长度不代表
  /// 进度，必须读进度文件——否则 UI 一进来就显示「已下 9.5 GB」。
  int get partialBytes {
    try {
      if (_multiPartProgressFile.existsSync()) {
        return _receivedFromProgressFile();
      }
      return _partFile.existsSync() ? _partFile.lengthSync() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  int _receivedFromProgressFile() {
    try {
      final Object? decoded =
          json.decode(_multiPartProgressFile.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return 0;
      final Object? parts = decoded['parts'];
      if (parts is! Map<String, dynamic>) return 0;
      int sum = 0;
      for (final Object? value in parts.values) {
        if (value is int && value > 0) sum += value;
      }
      return sum;
    } catch (_) {
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
    try {
      final DownloadPlan? plan = await _resolvePlan(dio, cancelToken);
      if (plan != null) {
        return await _downloadSegmented(
          plan: plan,
          dio: dio,
          progress: progress,
          receivedBytes: receivedBytes,
          cancelToken: cancelToken,
        );
      }
      return await _downloadSingleStream(
        dio: dio,
        progress: progress,
        receivedBytes: receivedBytes,
        cancelToken: cancelToken,
      );
    } finally {
      dio.close();
    }
  }

  /// 定分片计划：清单能直接给出就用清单；否则探一次总长（顺带验服务器支不支持
  /// Range）。拿不到就返回 null → 单流路径。
  Future<DownloadPlan?> _resolvePlan(Dio dio, CancelToken? cancelToken) async {
    final DownloadPlan? fromManifest = manifest?.toDownloadPlan();
    if (fromManifest != null) return fromManifest;

    final int? total = await _probeTotalBytes(dio, cancelToken);
    if (total == null || total <= 0) return null;
    return DownloadPlan.ranged(
      urls: manifest?.wholeFileUrls ?? <String>[url],
      totalBytes: total,
      partSize: manifest?.partSizeBytes ?? kRecommendedPackDefaultPartSize,
      sha256: sha256Hex,
      version: manifest?.version,
    );
  }

  /// `Range: bytes=0-0` 探针：只要 1 个字节，从 `Content-Range` 读总长。
  /// 服务器回 200（忽略 Range）就说明不支持断点，返回 null 走单流。
  Future<int?> _probeTotalBytes(Dio dio, CancelToken? cancelToken) async {
    try {
      final Response<ResponseBody> response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, Object?>{'range': 'bytes=0-0'},
          validateStatus: (int? status) => status == 200 || status == 206,
        ),
      );
      final ResponseBody? body = response.data;
      // 探针的 body 至多 1 字节（206）；若服务器忽略 Range 回了 200，body 是整个
      // 9.5 GB——必须断连，绝不 drain。
      if (body != null) {
        await body.stream.listen(null, cancelOnError: true).cancel();
      }
      if (response.statusCode != 206) return null;
      final String? contentRange = response.headers.value('content-range');
      if (contentRange == null) return null;
      final RegExpMatch? match =
          RegExp(r'^bytes\s+\d+-\d+/(\d+)$').firstMatch(contentRange.trim());
      if (match == null) return null;
      return int.tryParse(match.group(1)!);
    } catch (_) {
      return null;
    }
  }

  Future<File> _downloadSegmented({
    required DownloadPlan plan,
    required Dio dio,
    required ValueNotifier<double> progress,
    required ValueNotifier<int> receivedBytes,
    CancelToken? cancelToken,
  }) async {
    final SegmentedDownloader downloader = SegmentedDownloader(
      plan: plan,
      destination: packFile,
      partFile: _multiPartFile,
      progressFile: _multiPartProgressFile,
      concurrency: concurrency,
      isCancelled: () => cancelToken?.isCancelled ?? false,
      onProgress: (int received, int total) {
        receivedBytes.value = received;
        if (total > 0) progress.value = received / total;
      },
      open: (Uri uri, Map<String, String> headers) async {
        final Response<ResponseBody> response = await dio.get<ResponseBody>(
          uri.toString(),
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: <String, Object?>{...headers},
            validateStatus: (int? status) =>
                status != null && status >= 200 && status < 400,
          ),
        );
        return ResumableDownloadResponse(
          statusCode: response.statusCode ?? 0,
          headers: <String, String>{
            for (final MapEntry<String, List<String>> entry
                in response.headers.map.entries)
              entry.key: entry.value.join(','),
          },
          stream: response.data!.stream,
        );
      },
    );
    return downloader.download();
  }

  /// 单流续传旧路径：服务器不支持 Range 时的兜底。行为与引入分片前逐字一致。
  Future<File> _downloadSingleStream({
    required Dio dio,
    required ValueNotifier<double> progress,
    required ValueNotifier<int> receivedBytes,
    CancelToken? cancelToken,
  }) async {
    int existing = _partFile.existsSync() ? _partFile.lengthSync() : 0;
    // 续传必须带 If-Range：这条路会在「探针因网络抖动失败」时接手一台其实支持
    // Range 的服务器，没有校验子就会把旧断点续到**换过的新包**上，只能靠末尾
    // sha256 事后打回——代价是白下一整个 9.5 GB。
    final String? validator =
        existing > 0 ? _readSingleStreamValidator() : null;
    final Response<ResponseBody> response = await dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: <String, Object?>{
          if (existing > 0) 'range': 'bytes=$existing-',
          if (validator != null) 'if-range': validator,
        },
        validateStatus: (int? status) => status == 200 || status == 206,
      ),
    );
    if (existing > 0 && response.statusCode == 200) {
      // 服务器忽略 Range 或校验子过期（服务端换包）：append 会拼出坏包，只能丢
      // 半截从头写。
      existing = 0;
      if (_partFile.existsSync()) _partFile.deleteSync();
    }
    _writeSingleStreamValidator(
      response.headers.value('etag') ?? response.headers.value('last-modified'),
    );
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
        _writeSingleStreamValidator(null);
        throw Exception('recommended pack sha256 mismatch: '
            'got $digest, expected $sha256Hex');
      }
    }
    _partFile.renameSync(packFile.path);
    _writeSingleStreamValidator(null);
    return packFile;
  }
}
