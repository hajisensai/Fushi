/// 复习（SRS）入门预置卡组：清单（数据）+ 下载（校验哈希、可续传、可取消）。
///
/// 预置包**不随包内置**、首次使用时从作者自己的发布地址下载：
/// - Kaishi 1.5k（donkuri/Kaishi）仓库没有声明许可证，内容又派生自 Core 2k / Tango 等既有
///   卡组，Fushi 没有再分发它的授权；只能让用户从作者发布页直接取。
/// - 体积大（带全部单词 / 例句音频与配图，约 104 MB），塞进安装包对不学这门语言的人纯属负担。
///
/// 每个包钉死一个具体版本的下载地址 + 字节数 + sha256：作者发新版不会让旧清单悄悄下到
/// 别的内容，下坏 / 被篡改的包一律在导入前拒掉。升级某个包 = 改清单里这一项的三样值。
///
/// iOS 合规：这里只从清单里固定的几个地址下载学习卡组（与词典「推荐下载」同类），不是
/// 用户可配的内容源、不加载第三方扩展、也不是通用下载器，不属于
/// `StoreRestrictedCapability` 的任何一类，五个平台都提供。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto show sha256;
import 'package:crypto/crypto.dart' show Digest;
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:meta/meta.dart';

/// 清单里「许可证未声明」的取值（UI 翻成「作者未声明许可，从作者发布页下载」）。
const String kSrsStarterLicenseUnspecified = 'unspecified';

/// 一个入门预置卡组。
@immutable
class SrsStarterPack {
  const SrsStarterPack({
    required this.id,
    required this.name,
    required this.language,
    required this.cardCount,
    required this.deckName,
    required this.version,
    required this.source,
    required this.homepage,
    required this.license,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });

  /// 稳定 id（任务判重、下载落盘文件名用）。
  final String id;

  /// 展示名。
  final String name;

  /// 学习目标语言（ISO 639-1，如 `ja`）。
  final String language;

  /// 卡片数。
  final int cardCount;

  /// 导入后的顶层牌组名：当前 profile 的牌组里已有同名牌组即视为「已添加」。
  final String deckName;

  /// 钉死的版本号（展示用）。
  final String version;

  /// 来源（作者 / 仓库，展示用）。
  final String source;

  /// 来源主页（展示用，https）。
  final Uri homepage;

  /// 许可：SPDX 标识，或 [kSrsStarterLicenseUnspecified]。
  final String license;

  /// 下载地址（https，钉死版本）。
  final Uri url;

  /// 包的精确字节数（完整性判据之一）。
  final int sizeBytes;

  /// 包的 sha256（小写十六进制）。
  final String sha256;
}

/// 清单格式不对。
class SrsStarterManifestException implements Exception {
  const SrsStarterManifestException(this.message);

  final String message;

  @override
  String toString() => 'SrsStarterManifestException: $message';
}

final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
final RegExp _languagePattern = RegExp(r'^[a-z]{2,3}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

String _string(Map<String, Object?> json, String key, String where) {
  final Object? v = json[key];
  if (v is! String || v.trim().isEmpty) {
    throw SrsStarterManifestException('$where: "$key" must be a string');
  }
  return v.trim();
}

int _positiveInt(Map<String, Object?> json, String key, String where) {
  final Object? v = json[key];
  if (v is! int || v <= 0) {
    throw SrsStarterManifestException('$where: "$key" must be > 0');
  }
  return v;
}

Uri _httpsUri(Map<String, Object?> json, String key, String where) {
  final Uri? uri = Uri.tryParse(_string(json, key, where));
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw SrsStarterManifestException('$where: "$key" must be an https URL');
  }
  return uri;
}

/// 解析清单 JSON（`{"version": 1, "packs": [...]}`）。任一项不合法整份拒掉（清单随版本
/// 发布，坏了是开发期错误，不该在运行时悄悄少几项）。
List<SrsStarterPack> parseSrsStarterPackManifest(String source) {
  final Object? root;
  try {
    root = jsonDecode(source);
  } on FormatException catch (e) {
    throw SrsStarterManifestException('invalid JSON: ${e.message}');
  }
  if (root is! Map<String, Object?> || root['version'] != 1) {
    throw const SrsStarterManifestException('unsupported manifest version');
  }
  final Object? packs = root['packs'];
  if (packs is! List<Object?>) {
    throw const SrsStarterManifestException('"packs" must be a list');
  }
  final List<SrsStarterPack> out = <SrsStarterPack>[];
  final Set<String> ids = <String>{};
  for (int i = 0; i < packs.length; i++) {
    final Object? raw = packs[i];
    final String where = 'packs[$i]';
    if (raw is! Map<String, Object?>) {
      throw SrsStarterManifestException('$where must be an object');
    }
    final String id = _string(raw, 'id', where);
    if (!_idPattern.hasMatch(id)) {
      throw SrsStarterManifestException('$where: bad id "$id"');
    }
    if (!ids.add(id)) {
      throw SrsStarterManifestException('$where: duplicate id "$id"');
    }
    final String language = _string(raw, 'language', where);
    if (!_languagePattern.hasMatch(language)) {
      throw SrsStarterManifestException('$where: bad language "$language"');
    }
    final String sha = _string(raw, 'sha256', where).toLowerCase();
    if (!_sha256Pattern.hasMatch(sha)) {
      throw SrsStarterManifestException('$where: bad sha256');
    }
    out.add(
      SrsStarterPack(
        id: id,
        name: _string(raw, 'name', where),
        language: language,
        cardCount: _positiveInt(raw, 'cardCount', where),
        deckName: _string(raw, 'deckName', where),
        version: _string(raw, 'version', where),
        source: _string(raw, 'source', where),
        homepage: _httpsUri(raw, 'homepage', where),
        license: _string(raw, 'license', where),
        url: _httpsUri(raw, 'url', where),
        sizeBytes: _positiveInt(raw, 'sizeBytes', where),
        sha256: sha,
      ),
    );
  }
  return List<SrsStarterPack>.unmodifiable(out);
}

/// 内置清单。新增一项前先确认：作者允许下载使用、地址钉在具体版本、字节数与 sha256 是
/// 自己实下一遍算出来的（不是抄发布页）。
const String kSrsStarterPackManifestJson = '''
{
  "version": 1,
  "packs": [
    {
      "id": "kaishi-1.5k",
      "name": "Kaishi 1.5k",
      "language": "ja",
      "cardCount": 1501,
      "deckName": "Kaishi 1.5k",
      "version": "2.4.3",
      "source": "donkuri/Kaishi (GitHub)",
      "homepage": "https://github.com/donkuri/kaishi",
      "license": "unspecified",
      "url": "https://github.com/donkuri/kaishi/releases/download/v2.4.3/Kaishi.1.5k.v2.4.3.apkg",
      "sizeBytes": 108692963,
      "sha256": "33da6f5a8b5d5cf12ccd79f6279775fc44b1de54159aad189a2e691386fce464"
    }
  ]
}
''';

/// 内置清单解析结果。
final List<SrsStarterPack> kSrsStarterPacks = parseSrsStarterPackManifest(
  kSrsStarterPackManifestJson,
);

/// 按偏好语言排序：[preferredLanguages] 里的语言排前（按给出顺序），其余按语言、名字。
List<SrsStarterPack> sortSrsStarterPacks(
  Iterable<SrsStarterPack> packs, {
  List<String> preferredLanguages = const <String>[],
}) {
  int rank(SrsStarterPack p) {
    final int i = preferredLanguages.indexOf(p.language);
    return i < 0 ? preferredLanguages.length : i;
  }

  return packs.toList()..sort((SrsStarterPack a, SrsStarterPack b) {
    final int r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final int l = a.language.compareTo(b.language);
    if (l != 0) return l;
    return a.name.compareTo(b.name);
  });
}

/// 下载被取消。
class SrsStarterDownloadCancelled implements Exception {
  const SrsStarterDownloadCancelled();

  @override
  String toString() => 'SrsStarterDownloadCancelled';
}

/// 一次下载的取消开关：[cancel] 强制关掉在用的 [HttpClient]，正在读的响应流立刻报错。
class SrsStarterDownloadCancelToken {
  bool _cancelled = false;
  HttpClient? _client;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _client?.close(force: true);
  }

  void _attach(HttpClient client) {
    _client = client;
    if (_cancelled) client.close(force: true);
  }
}

Future<ResumableDownloadResponse> _openGet(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
) async {
  final HttpClientRequest request = await client.getUrl(uri);
  request.followRedirects = true;
  request.maxRedirects = 8;
  headers.forEach(request.headers.set);
  final HttpClientResponse response = await request.close();
  final Map<String, String> responseHeaders = <String, String>{};
  response.headers.forEach(
    (String name, List<String> values) =>
        responseHeaders[name] = values.join(', '),
  );
  return ResumableDownloadResponse(
    statusCode: response.statusCode,
    headers: responseHeaders,
    stream: response,
  );
}

/// 预置包落盘路径（`<dir>/<id>-<sha 前 12 位>.apkg`）：换版本 = 换文件，旧 `.part` 不会被
/// 续到新版本上。
File srsStarterPackFile(Directory dir, SrsStarterPack pack) => File(
  '${dir.path}${Platform.pathSeparator}'
  '${pack.id}-${pack.sha256.substring(0, 12)}.apkg',
);

/// 下载 [pack] 到 [dir]，返回校验过（字节数 + sha256）的包文件。
///
/// - 出站走 [createAppHttpClient]（应用代理）；[clientFactory] / [open] 只给测试注入。
/// - 中断留下 `.part`，下次续传；校验不过删掉 `.part` 抛 [ResumableDownloadIntegrityException]。
/// - [cancel] 触发后抛 [SrsStarterDownloadCancelled]（`.part` 保留，可续）。
/// - 目标文件已存在且校验通过直接返回，不重下。
Future<File> downloadSrsStarterPack({
  required SrsStarterPack pack,
  required Directory dir,
  void Function(int received, int total)? onProgress,
  SrsStarterDownloadCancelToken? cancel,
  HttpClient Function()? clientFactory,
  ResumableDownloadOpen? open,
}) async {
  final File target = srsStarterPackFile(dir, pack);
  if (await target.exists() && await target.length() == pack.sizeBytes) {
    // 上次下完、导入前被打断：同样要过哈希，坏文件删掉重下。
    final Digest digest = await crypto.sha256.bind(target.openRead()).first;
    if (digest.toString() == pack.sha256) {
      onProgress?.call(pack.sizeBytes, pack.sizeBytes);
      return target;
    }
    await target.delete();
  }
  if (cancel?.isCancelled ?? false) throw const SrsStarterDownloadCancelled();
  await dir.create(recursive: true);
  final HttpClient client = (clientFactory ?? createAppHttpClient)();
  cancel?._attach(client);
  try {
    return await ResumableDownloader(
      url: pack.url.toString(),
      destination: target,
      partFile: File('${target.path}.part'),
      open:
          open ??
          (Uri uri, Map<String, String> headers) =>
              _openGet(client, uri, headers),
      expectedSize: pack.sizeBytes,
      expectedSha256: pack.sha256,
      firstByteTimeout: const Duration(seconds: 60),
      bodyTimeout: const Duration(seconds: 60),
      onProgress: (int received, int? _) {
        if (cancel?.isCancelled ?? false) {
          throw const SrsStarterDownloadCancelled();
        }
        onProgress?.call(received, pack.sizeBytes);
      },
    ).download();
  } catch (e) {
    if (cancel?.isCancelled ?? false) {
      throw const SrsStarterDownloadCancelled();
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}
