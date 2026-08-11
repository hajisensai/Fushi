/// mokuro.moe 在线目录（Mokuro Bunko）REST client：纯数据模型 + 无状态请求封装。
///
/// 合同（2026-07-25 实测）：
/// - `GET /catalog/api/library` 无鉴权 → `{"series":[{name,path,cover,volumes:[...]}]}`；
/// - `GET /catalog/api/series?name=<enc>` → 单系列同构对象；
/// - 封面 `GET /catalog/api/cover?path=<enc>`；
/// - 卷包 `GET /mokuro-reader/<系列>/<卷>.cbz`（纯图片 zip，支持 Range）；
/// - OCR 数据同路径旁挂 `GET /mokuro-reader/<系列>/<卷>.mokuro`。
///
/// http 栈：`dart:io` [HttpClient] + `findProxyFromEnvironment`（与
/// `manga_ocr_model_downloader.dart` 同范式），[createClient] 可注入指向
/// loopback 测试服务器。系列名可含 `#` / 空格等字符，URL 段一律
/// [Uri.encodeComponent] 逐段编码。
library;

import 'dart:convert';
import 'dart:io';
import 'package:fushi/src/utils/net/app_http.dart';

/// 默认目录站点（偏好 `manga_online_catalog_base_url` 空值时的回退）。
const String kMokuroMoeDefaultBaseUrl = 'https://mokuro.moe';

/// 带状态码的 HTTP 失败。实现 [HttpException] 的隐式接口，`is HttpException`
/// 仍为真（旧调用点/测试的类型判断不受影响），额外暴露 [statusCode] 供下载
/// 队列区分「服务端瞬时故障（值得自动重试）」与「该资源就是没有（重试无用）」
/// ——404 的卷重试三轮只是白等几十秒。
class MokuroMoeHttpException implements HttpException {
  const MokuroMoeHttpException(this.statusCode, {this.uri});

  final int statusCode;

  @override
  final Uri? uri;

  @override
  String get message => 'mokuro.moe request failed: HTTP $statusCode';

  /// 服务端侧瞬时故障：5xx 网关/过载、408 请求超时、429 限流。
  /// 4xx 其余（404 缺卷、403 防盗链）是稳定结论，重试没有意义。
  bool get isTransient =>
      statusCode >= 500 || statusCode == 408 || statusCode == 429;

  @override
  String toString() => 'HttpException: $message, uri = $uri';
}

/// 归一 base URL：trim + 去尾斜杠；空串回退默认站点。
String normalizeMokuroMoeBaseUrl(String raw) {
  String s = raw.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s.isEmpty ? kMokuroMoeDefaultBaseUrl : s;
}

/// 目录里的一卷（`volumes[]` 条目）。字段缺失/类型不符时全部容错取默认值。
class MokuroMoeVolume {
  const MokuroMoeVolume({
    required this.name,
    this.cover = '',
    this.ocrPending = false,
    this.ocrActive = false,
  });

  factory MokuroMoeVolume.fromJson(Map<String, Object?> json) {
    return MokuroMoeVolume(
      name: json['name'] is String ? json['name']! as String : '',
      cover: json['cover'] is String ? json['cover']! as String : '',
      ocrPending: json['ocr_pending'] == true,
      ocrActive: json['ocr_active'] == true,
    );
  }

  /// 卷名（同时是 `/mokuro-reader/<系列>/<卷>.cbz` 的 URL 段与 CBZ 内顶层目录名）。
  final String name;

  /// 封面相对路径（喂 [MokuroMoeClient.coverUrl]；空串 = 无封面）。
  final String cover;

  /// 站点侧 OCR 尚未完成/正在跑（此时 `.mokuro` 可能缺失或不完整）。
  final bool ocrPending;
  final bool ocrActive;
}

/// 目录里的一个系列（`series[]` 条目 / `api/series` 响应体）。
class MokuroMoeSeries {
  const MokuroMoeSeries({
    required this.name,
    this.path = '',
    this.cover = '',
    this.volumes = const <MokuroMoeVolume>[],
  });

  factory MokuroMoeSeries.fromJson(Map<String, Object?> json) {
    final Object? rawVolumes = json['volumes'];
    return MokuroMoeSeries(
      name: json['name'] is String ? json['name']! as String : '',
      path: json['path'] is String ? json['path']! as String : '',
      cover: json['cover'] is String ? json['cover']! as String : '',
      volumes: rawVolumes is List
          ? rawVolumes
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> v) =>
                  MokuroMoeVolume.fromJson(v.cast<String, Object?>()))
              .toList()
          : const <MokuroMoeVolume>[],
    );
  }

  final String name;
  final String path;

  /// 系列封面相对路径（形如 `<series>/<file>.webp`）。
  final String cover;
  final List<MokuroMoeVolume> volumes;
}

/// mokuro.moe REST client。方法可被测试子类 override（fake client 注入对话框）。
class MokuroMoeClient {
  MokuroMoeClient({
    String baseUrl = kMokuroMoeDefaultBaseUrl,
    HttpClient Function()? createClient,
  })  : baseUrl = normalizeMokuroMoeBaseUrl(baseUrl),
        _createClient = createClient ?? _defaultClient;

  /// 已归一（无尾斜杠、非空）的站点根。
  final String baseUrl;

  final HttpClient Function() _createClient;

  // BUG-1498：原先只读 env 代理变量，读不到 GUI 系统代理；统一装配点补齐。
  static HttpClient _defaultClient() => createAppHttpClient();

  /// 拉全量目录（约千余系列，几百 KB JSON）。
  Future<List<MokuroMoeSeries>> fetchLibrary() async {
    final Object? root = await _getJson('$baseUrl/catalog/api/library');
    if (root is! Map) {
      throw const FormatException('mokuro.moe library: not a JSON object');
    }
    final Object? rawSeries = root.cast<String, Object?>()['series'];
    if (rawSeries is! List) return const <MokuroMoeSeries>[];
    return rawSeries
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> s) =>
            MokuroMoeSeries.fromJson(s.cast<String, Object?>()))
        .toList();
  }

  /// 拉单系列详情（与 library 条目同构）。
  Future<MokuroMoeSeries> fetchSeries(String name) async {
    final Object? root = await _getJson(
        '$baseUrl/catalog/api/series?name=${Uri.encodeComponent(name)}');
    if (root is! Map) {
      throw const FormatException('mokuro.moe series: not a JSON object');
    }
    return MokuroMoeSeries.fromJson(root.cast<String, Object?>());
  }

  /// 封面绝对 URL（[coverPath] = 模型里的 `cover` 相对路径）。
  String coverUrl(String coverPath) =>
      '$baseUrl/catalog/api/cover?path=${Uri.encodeComponent(coverPath)}';

  /// 一卷 CBZ（纯图片 zip）的绝对 URL。
  String cbzUrl(String series, String volume) =>
      '$baseUrl/mokuro-reader/${Uri.encodeComponent(series)}/'
      '${Uri.encodeComponent(volume)}.cbz';

  /// 一卷 `.mokuro`（OCR 数据 JSON）的绝对 URL。
  String mokuroUrl(String series, String volume) =>
      '$baseUrl/mokuro-reader/${Uri.encodeComponent(series)}/'
      '${Uri.encodeComponent(volume)}.mokuro';

  /// GET 一个 JSON 端点；非 200 抛 [HttpException]。
  Future<Object?> _getJson(String url) async {
    final HttpClient client = _createClient();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw MokuroMoeHttpException(
          response.statusCode,
          uri: Uri.parse(url),
        );
      }
      final String body = await utf8.decodeStream(response);
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}
