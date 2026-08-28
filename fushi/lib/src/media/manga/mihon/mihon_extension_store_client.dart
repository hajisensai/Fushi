import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';
import 'package:fushi/src/utils/net/url_input_normalizer.dart';

const int mihonStoreMaxBytes = 10 * 1024 * 1024;
const int mihonExtensionApkMaxBytes = 100 * 1024 * 1024;

enum MihonStoreFormat { currentJson, currentProtobuf, legacy }

@immutable
class MihonStore {
  const MihonStore({
    required this.indexUrl,
    required this.name,
    required this.badgeLabel,
    required this.signingKey,
    required this.contact,
    required this.format,
    required this.extensionListUrl,
    this.embeddedExtensions = const <MihonAvailableExtension>[],
  });

  final String indexUrl;
  final String name;
  final String badgeLabel;
  final String signingKey;
  final Map<String, String?> contact;
  final MihonStoreFormat format;
  final String? extensionListUrl;
  final List<MihonAvailableExtension> embeddedExtensions;
}

@immutable
class MihonAvailableSource {
  const MihonAvailableSource({
    required this.id,
    required this.name,
    required this.language,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String language;
  final String baseUrl;
}

@immutable
class MihonAvailableExtension {
  const MihonAvailableExtension({
    required this.storeUrl,
    required this.name,
    required this.packageName,
    required this.apkUrl,
    required this.iconUrl,
    required this.libVersion,
    required this.versionCode,
    required this.versionName,
    required this.language,
    required this.contentWarning,
    required this.sources,
  });

  final String storeUrl;
  final String name;
  final String packageName;
  final String apkUrl;
  final String iconUrl;
  final String libVersion;
  final int versionCode;
  final String versionName;
  final String language;
  final int contentWarning;
  final List<MihonAvailableSource> sources;
}

@immutable
class MihonStoreFetchResult {
  const MihonStoreFetchResult({
    required this.store,
    required this.etag,
    required this.lastModified,
    this.notModified = false,
  });

  final MihonStore? store;
  final String? etag;
  final String? lastModified;
  final bool notModified;
}

/// 开一只新的单调秒表，返回的函数报「从开表到现在」。
///
/// 用 [Stopwatch] 而不是 `DateTime.now()`：墙钟会被 NTP 校时 / 时区切换往前后跳，
/// 一次跳变要么让预算瞬间过期（一个镜像都不试）要么推后几小时（总闸形同虚设）。
typedef MihonElapsedClockFactory = Duration Function() Function();

Duration Function() _monotonicClock() {
  final Stopwatch stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

/// 一次**公开操作**（fetchStore / fetchExtensions / downloadApk）的时间预算。
///
/// 单位是「操作」不是「资源」：一次「添加仓库」会顺着 `index.min.json` →
/// `repo.json` → `index_v2` 的索引链发起最多 `_maxIndexHops + 1` 次独立取数，
/// 加上 `fetchExtensions` 那次。预算若按资源各起一份，用户在全阻断网络下要等的
/// 是 预算 × 取数次数，而不是预算。
class _FetchBudget {
  _FetchBudget.withClock(this.total, MihonElapsedClockFactory clock)
      : _elapsed = clock();

  final Duration total;
  final Duration Function() _elapsed;

  Duration get remaining => total - _elapsed();

  bool get isExhausted => remaining <= Duration.zero;

  /// [ceiling] 与剩余预算里更小的那个，且至少 1ms（`Future.timeout` 不接受负数）。
  Duration capped(Duration ceiling) {
    final Duration left = remaining;
    final Duration value = left < ceiling ? left : ceiling;
    return value < const Duration(milliseconds: 1)
        ? const Duration(milliseconds: 1)
        : value;
  }
}

class MihonExtensionStoreClient {
  MihonExtensionStoreClient({
    http.Client? client,
    this.fetchBudget = const Duration(seconds: 90),
    this.downloadBudget = const Duration(minutes: 10),
    this.bodyStallTimeout = const Duration(seconds: 30),
    MihonElapsedClockFactory? elapsedClock,
  })  : _client = client ?? createAppHttpIoClient(),
        _elapsedClock = elapsedClock ?? _monotonicClock;

  final http.Client _client;

  /// 一次索引/扩展列表拉取（含索引链上的每一跳、全部镜像候选与重定向嵌套）的
  /// **总**时间预算：镜像回退把最坏情况从一次 20s 超时放大成 直连 + 5 镜像 ×
  /// 每次 30s、再乘索引跳数与重定向嵌套——没有总闸的话一台镜像也不通的机器
  /// 一次刷新要挂几分钟。
  final Duration fetchBudget;

  /// APK 下载的总预算。与 [fetchBudget] 分开：索引是几十 KB 的小文档，APK 上限
  /// 100 MiB，拿 90s 当硬顶等于把慢网络上的正常下载掐断。真正防「回了 200
  /// 就不再发字节」的是 [_kBodyStallTimeout]，本预算只兜住总时长。
  final Duration downloadBudget;

  /// 响应体的 **stall** 超时——计的是「两个数据块之间的间隔」，不是总时长。
  ///
  /// `app_http.dart` 的文件头写明它只管连接建立、响应体传输不设默认时限
  /// （一刀切会掐断几百 MB 的下载），「需要 stall 超时的链路自己在上层设」；
  /// 这里就是那个上层。一个回 200 然后不发一个字节的公共代理，修复前能让整条
  /// 链无限挂住（候选从 1 扩到 6 之后撞上的概率乘了 6）；一个慢但一直在传的
  /// 100 MiB APK 不受影响。
  final Duration bodyStallTimeout;

  final MihonElapsedClockFactory _elapsedClock;

  /// 单个候选的**响应头**上限：一个死候选不该把整份预算吃光、饿死后面的镜像。
  static const Duration _kHeadersTimeout = Duration(seconds: 30);

  /// 跟随「一份索引指向另一份索引」的最大跳数。
  ///
  /// 真实形态最多两跳：`index.min.json` 推导出 `repo.json`，`repo.json`
  /// 的 `index_v2` 再指向 `index.pb`。但 `index_v2` 是仓库方自由填的地址，
  /// 完全可以指回一个 `index.min.json`，形成环。没有上限的话一个恶意（或只是
  /// 写错的）仓库就能让客户端无限递归下去。
  static const int _maxIndexHops = 3;

  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) =>
      _fetchStore(
        rawUrl,
        etag: etag,
        lastModified: lastModified,
        allowInsecure: allowInsecure,
        hop: 0,
        budget: _FetchBudget.withClock(fetchBudget, _elapsedClock),
      );

  Future<MihonStoreFetchResult> _fetchStore(
    String rawUrl, {
    required int hop,
    required _FetchBudget budget,
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async {
    if (hop > _maxIndexHops) {
      throw const MihonRuntimeException(
        'TOO_MANY_INDEX_HOPS',
        'Extension store index points at itself in a loop',
      );
    }
    final Uri indexUrl = _validatedUri(rawUrl, allowInsecure: allowInsecure);
    final _Fetched<_StoreDocument> response = await _get<_StoreDocument>(
      indexUrl,
      parse: (Uint8List bytes) => _parseStoreDocument(indexUrl, bytes),
      budget: budget,
      etag: etag,
      lastModified: lastModified,
      allowNotModified: true,
      allowInsecure: allowInsecure,
    );
    if (response.notModified) {
      return MihonStoreFetchResult(
        store: null,
        etag: response.etag ?? etag,
        lastModified: response.lastModified ?? lastModified,
        notModified: true,
      );
    }
    final _StoreDocument document = response.value!;
    final Uri? nextIndexUrl = document.nextIndexUrl;
    if (nextIndexUrl != null) {
      return _fetchStore(
        nextIndexUrl.toString(),
        allowInsecure: allowInsecure,
        hop: hop + 1,
        budget: budget,
      );
    }
    return MihonStoreFetchResult(
      store: document.store,
      etag: response.etag,
      lastModified: response.lastModified,
    );
  }

  /// **纯函数**：把一份索引响应体解析成「一份可用的仓库」或「指向下一份索引的
  /// 跳转」。不发网络——所以它可以在镜像候选循环**内**跑，一个返回 HTML 错误页
  /// 的镜像会被当场判死、换下一个候选，而不是把 200 当成成功、留给上层解析炸掉。
  static _StoreDocument _parseStoreDocument(Uri indexUrl, Uint8List raw) {
    final Uint8List bytes = _decodeGzip(raw, maxBytes: mihonStoreMaxBytes);
    final int first = _firstNonWhitespace(bytes);
    if (first == 0x5b) {
      if (!indexUrl.path.endsWith('/index.min.json')) {
        throw const MihonRuntimeException(
          'INVALID_LEGACY_STORE',
          'Legacy extension list URL must end with /index.min.json',
        );
      }
      // `repo.json` 就是下面 `0x7b` 分支处理的那份文档，直接跳过去。
      //
      // 这里曾经自己又调一遍 `_parseLegacyStore`，于是 `index_v2` 被整个吞掉：
      // 对象分支会跟着 `index_v2` 走到新索引，数组分支拿着同一份 `repo.json`
      // 却停在旧格式。keiyoushi 已经迁到 `index_v2`，它的 `index.min.json` 只剩两条
      // 占位条目，推出来的 `apk/` 直链在仓库里根本不存在——填这个地址的用户
      // 装什么都是 `STORE_HTTP_404`。
      //
      // 顺带修掉一个错配：旧实现把 `index.min.json` 响应的 etag 跟着
      // `repo.json` 这个地址一起落库，下次条件请求的 etag 压根不属于那个地址。
      return _StoreDocument.hop(
        indexUrl.replace(
          path: indexUrl.path.replaceFirst(
            RegExp(r'/index\.min\.json$'),
            '/repo.json',
          ),
        ),
      );
    }
    if (first == 0x7b) {
      final Map<String, Object?> json = _jsonObject(bytes);
      if (!json.containsKey('meta')) {
        return _StoreDocument.store(_parseCurrentStoreJson(indexUrl, json));
      }
      final MihonStore legacy = _parseLegacyStore(indexUrl, json);
      final Object? indexV2 = json['index_v2'];
      if (indexV2 is String && indexV2.trim().isNotEmpty) {
        return _StoreDocument.hop(indexUrl.resolve(indexV2));
      }
      return _StoreDocument.store(legacy);
    }
    return _StoreDocument.store(_parseCurrentStoreProto(indexUrl, bytes));
  }

  Future<List<MihonAvailableExtension>> fetchExtensions(
    MihonStore store, {
    bool allowInsecure = false,
  }) async {
    if (store.embeddedExtensions.isNotEmpty) {
      return store.embeddedExtensions;
    }
    final _FetchBudget budget =
        _FetchBudget.withClock(fetchBudget, _elapsedClock);
    final Uri indexUrl = Uri.parse(store.indexUrl);
    if (store.format == MihonStoreFormat.legacy) {
      final Uri listUrl = indexUrl.replace(
        path: indexUrl.path.replaceFirst(
          RegExp(r'/repo\.json$'),
          '/index.min.json',
        ),
      );
      final Uri base = indexUrl.resolve('.');
      final _Fetched<List<MihonAvailableExtension>> response =
          await _get<List<MihonAvailableExtension>>(
        listUrl,
        parse: (Uint8List bytes) =>
            _parseLegacyExtensionList(store, base, bytes),
        budget: budget,
        allowInsecure: allowInsecure,
      );
      return response.value!;
    }
    final String? rawListUrl = store.extensionListUrl;
    if (rawListUrl == null || rawListUrl.isEmpty) return const [];
    final Uri listUrl = _validatedUri(
      indexUrl.resolve(rawListUrl).toString(),
      allowInsecure: allowInsecure,
    );
    final _Fetched<List<MihonAvailableExtension>> response =
        await _get<List<MihonAvailableExtension>>(
      listUrl,
      parse: (Uint8List bytes) =>
          _parseCurrentExtensionList(store, listUrl, bytes),
      budget: budget,
      allowInsecure: allowInsecure,
    );
    return response.value!;
  }

  /// **纯函数**：旧格式 `index.min.json` 的响应体 → 扩展列表。同
  /// [_parseStoreDocument]，解析要在候选循环内跑才挡得住 HTML 错误页。
  static List<MihonAvailableExtension> _parseLegacyExtensionList(
    MihonStore store,
    Uri base,
    Uint8List raw,
  ) {
    final Object? decoded = jsonDecode(
      utf8.decode(_decodeGzip(raw, maxBytes: mihonStoreMaxBytes)),
    );
    if (decoded is! List<Object?>) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Legacy extension index is not a JSON array',
      );
    }
    return decoded
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> item) => _parseLegacyExtension(
              store,
              base,
              item.cast<String, Object?>(),
            ))
        .toList(growable: false);
  }

  /// **纯函数**：新格式扩展列表（JSON 或 protobuf）的响应体 → 扩展列表。
  static List<MihonAvailableExtension> _parseCurrentExtensionList(
    MihonStore store,
    Uri listUrl,
    Uint8List raw,
  ) {
    final Uint8List bytes = _decodeGzip(raw, maxBytes: mihonStoreMaxBytes);
    if (_firstNonWhitespace(bytes) == 0x7b) {
      final Map<String, Object?> json = _jsonObject(bytes);
      final List<Object?> values =
          json['extensions'] as List<Object?>? ?? const <Object?>[];
      return values
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> item) => _parseCurrentExtensionJson(
                store,
                listUrl,
                item.cast<String, Object?>(),
              ))
          .toList(growable: false);
    }
    return _parseExtensionListProto(store, listUrl, bytes);
  }

  Future<Uint8List> downloadApk(
    String rawUrl, {
    bool allowInsecure = false,
  }) async {
    final Uri url = _validatedUri(rawUrl, allowInsecure: allowInsecure);
    final _Fetched<Uint8List> response = await _get<Uint8List>(
      url,
      parse: _requireApk,
      budget: _FetchBudget.withClock(downloadBudget, _elapsedClock),
      maxBytes: mihonExtensionApkMaxBytes,
      allowInsecure: allowInsecure,
    );
    return response.value!;
  }

  /// APK 的内容可用性判据：ZIP 本地文件头魔数。公共 gh 代理限流时回的是
  /// 200 + HTML 错误页；没有这道判据它会被当成一个「下载成功」的安装包，
  /// 而且后面 5 个候选一个都不会试。
  static Uint8List _requireApk(Uint8List bytes) {
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4b ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      throw const MihonRuntimeException(
        'INVALID_APK',
        'Downloaded file is not an APK archive',
      );
    }
    return bytes;
  }

  void close() => _client.close();

  /// 拉一份资源、**在候选循环内**把响应体解析成 [T]，GitHub 直链不通或镜像返回
  /// 不可用内容时逐个换公共镜像（BUG-1875）。
  ///
  /// 仓库索引 / 扩展列表 / APK 几乎全在 GitHub raw / release 直链上，GFW 机器直连
  /// `github.com` 会吃满 20s 连接超时然后整轮失败——而 app 早就有一份对这类直链有效
  /// 的镜像名单（[gitHubMirrorCandidates]），只是这里从没用上。
  ///
  /// **判据是「内容可用」而不是「HTTP 层没抛」**：公共 gh 代理限流时的常见形态是
  /// 200 + 一页 HTML。[parse] 在循环**内**跑，所以那种响应会被当场判死、换下一个
  /// 候选；把解析留到 `_get` 返回之后（旧实现）等于「直连传输失败 → 镜像1 返 HTML →
  /// 上层解析炸 → 整轮结束」，后面 4 个镜像一个都没试。
  ///
  /// **直连是权威**：直连只有 [isTransportFailure]（连不上 / 超时 / TLS）才轮到镜像；
  /// 服务端已经答复的 `STORE_HTTP_404`、`TOO_MANY_REDIRECTS`、以及直连那份内容自己
  /// 解析不出来，换镜像拿到的还是同一份，立即抛出。镜像是公共代理，对存在的资源乱返
  /// 403/404/5xx/HTML 是常态，所以镜像的**任何**失败都只是「换下一个」。全部候选都
  /// 失败时抛**直连**（首候选）的原始错误——碰巧排最后的死镜像的 host-lookup 失败对
  /// 用户毫无诊断价值（与 update_checker 的 TODO-666 一致）。
  ///
  /// 302 每一跳都回到这里，所以 `github.com/.../raw/...` 302 到
  /// `raw.githubusercontent.com` 之后那一跳同样享有回退；非 GitHub 域只有它自己一个候选。
  Future<_Fetched<T>> _get<T>(
    Uri url, {
    required T Function(Uint8List bytes) parse,
    required _FetchBudget budget,
    int maxBytes = mihonStoreMaxBytes,
    String? etag,
    String? lastModified,
    bool allowNotModified = false,
    bool allowInsecure = false,
    int redirectCount = 0,
  }) async {
    Object? directError;
    StackTrace? directStack;
    final List<Uri> candidates = gitHubMirrorCandidates(url);
    for (int index = 0; index < candidates.length; index++) {
      final bool isDirect = index == 0;
      // 总闸：整次公开操作（含索引链上每一跳、全部候选、重定向嵌套）共享同一份
      // [budget]，过点即停不再换镜像。
      if (!isDirect && budget.isExhausted) break;
      try {
        return await _getOnce<T>(
          _validatedUri(
            candidates[index].toString(),
            allowInsecure: allowInsecure,
          ),
          parse: parse,
          budget: budget,
          maxBytes: maxBytes,
          etag: etag,
          lastModified: lastModified,
          allowNotModified: allowNotModified,
          allowInsecure: allowInsecure,
          redirectCount: redirectCount,
        );
      } on Object catch (error, stack) {
        if (isDirect) {
          if (!isTransportFailure(error)) rethrow;
          directError = error;
          directStack = stack;
        }
      }
    }
    Error.throwWithStackTrace(directError!, directStack!);
  }

  Future<_Fetched<T>> _getOnce<T>(
    Uri url, {
    required T Function(Uint8List bytes) parse,
    required _FetchBudget budget,
    required int maxBytes,
    required String? etag,
    required String? lastModified,
    required bool allowNotModified,
    required bool allowInsecure,
    required int redirectCount,
  }) async {
    final http.Request request = http.Request('GET', url);
    request.followRedirects = false;
    if (etag != null && etag.isNotEmpty) {
      request.headers[HttpHeaders.ifNoneMatchHeader] = etag;
    }
    if (lastModified != null && lastModified.isNotEmpty) {
      request.headers[HttpHeaders.ifModifiedSinceHeader] = lastModified;
    }
    final http.StreamedResponse response =
        await _client.send(request).timeout(budget.capped(_kHeadersTimeout));
    if (<int>{
      HttpStatus.movedPermanently,
      HttpStatus.found,
      HttpStatus.seeOther,
      HttpStatus.temporaryRedirect,
      HttpStatus.permanentRedirect,
    }.contains(response.statusCode)) {
      if (redirectCount >= 5) {
        await response.stream.drain<void>();
        throw const MihonRuntimeException(
          'TOO_MANY_REDIRECTS',
          'Extension store redirected too many times',
        );
      }
      final String? location = response.headers[HttpHeaders.locationHeader];
      if (location == null || location.isEmpty) {
        await response.stream.drain<void>();
        throw const MihonRuntimeException(
          'INVALID_REDIRECT',
          'Extension store redirect has no destination',
        );
      }
      final Uri redirected = _validatedUri(
        url.resolve(location).toString(),
        allowInsecure: allowInsecure,
      );
      await response.stream.drain<void>();
      return _get<T>(
        redirected,
        parse: parse,
        budget: budget,
        maxBytes: maxBytes,
        etag: etag,
        lastModified: lastModified,
        allowNotModified: allowNotModified,
        allowInsecure: allowInsecure,
        redirectCount: redirectCount + 1,
      );
    }
    _validatedUri(
      (response.request?.url ?? url).toString(),
      allowInsecure: allowInsecure,
    );
    if (allowNotModified && response.statusCode == HttpStatus.notModified) {
      return _Fetched<T>(
        value: null,
        etag: response.headers[HttpHeaders.etagHeader],
        lastModified: response.headers[HttpHeaders.lastModifiedHeader],
        notModified: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      // 带上地址：同一个 `STORE_HTTP_404` 可能是索引没了、扩展列表没了、或者
      // APK 直链指向的 GitHub release 已被上游删除，不写地址就只能靠猜。
      // 只留 origin+path：release 资产会 302 到带 `sig=` / `jwt=` 的签名地址，
      // query 原样拼进报错文案等于把短期凭证写进 UI 和上传的日志。
      final Uri safeUrl = url.replace(query: '', fragment: '');
      throw MihonRuntimeException(
        'STORE_HTTP_${response.statusCode}',
        'Extension store request failed: HTTP ${response.statusCode} for $safeUrl',
      );
    }
    final int? declared = int.tryParse(
      response.headers[HttpHeaders.contentLengthHeader] ?? '',
    );
    if (declared != null && declared > maxBytes) {
      await response.stream.drain<void>();
      throw MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
      );
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    int length = 0;
    // `Stream.timeout` 计的是**两个事件之间**的间隔：回了 200 就不再发字节的
    // 公共代理会在 [bodyStallTimeout] 后抛 TimeoutException（= 传输失败 =
    // 换下一个候选），而一个慢但一直在传的大文件永远不会被它掐断。
    await for (final List<int> chunk
        in response.stream.timeout(bodyStallTimeout)) {
      length += chunk.length;
      if (length > maxBytes) {
        throw MihonRuntimeException(
          'DOWNLOAD_TOO_LARGE',
          'Download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
        );
      }
      builder.add(chunk);
    }
    return _Fetched<T>(
      value: parse(builder.takeBytes()),
      etag: response.headers[HttpHeaders.etagHeader],
      lastModified: response.headers[HttpHeaders.lastModifiedHeader],
    );
  }

  static Uri _validatedUri(
    String rawUrl, {
    required bool allowInsecure,
  }) {
    // 归一化必须在解析之前：全角句点能骗过 hasAuthority，带着
    // `host%EF%BC%8Ecom` 这样的垃圾域名走到网络层，事后补救抓不到它。
    final Uri? uri = Uri.tryParse(normalizeUrlInput(rawUrl));
    if (uri == null || !uri.hasAuthority) {
      throw const MihonRuntimeException(
        'INVALID_URL',
        'Extension store URL is invalid',
      );
    }
    if (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http')) {
      throw const MihonRuntimeException(
        'INSECURE_URL',
        'Extension stores require HTTPS unless insecure HTTP was explicitly approved',
      );
    }
    return uri;
  }

  static MihonStore _parseLegacyStore(
    Uri indexUrl,
    Map<String, Object?> json,
  ) {
    final Map<String, Object?> meta =
        (json['meta'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
            .cast<String, Object?>();
    final String name = meta['name']?.toString() ?? '';
    if (name.isEmpty) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Legacy store metadata has no name',
      );
    }
    return MihonStore(
      indexUrl: indexUrl.toString(),
      name: name,
      badgeLabel: meta['shortName']?.toString() ?? name,
      signingKey: meta['signingKeyFingerprint']?.toString() ?? '',
      contact: <String, String?>{
        'website': meta['website']?.toString(),
        'discord': null,
      },
      format: MihonStoreFormat.legacy,
      extensionListUrl: null,
    );
  }

  static MihonStore _parseCurrentStoreJson(
    Uri indexUrl,
    Map<String, Object?> json,
  ) {
    final Map<String, Object?> contact =
        (json['contact'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    final MihonStore shell = _validateCurrentStore(MihonStore(
      indexUrl: indexUrl.toString(),
      name: json['name']?.toString() ?? '',
      badgeLabel: json['badgeLabel']?.toString() ?? '',
      signingKey: json['signingKey']?.toString() ?? '',
      contact: <String, String?>{
        'website': contact['website']?.toString(),
        'discord': contact['discord']?.toString(),
      },
      format: MihonStoreFormat.currentJson,
      extensionListUrl: json['extensionListUrl']?.toString(),
    ));
    final Map<String, Object?>? list =
        (json['extensionList'] as Map<Object?, Object?>?)
            ?.cast<String, Object?>();
    final List<MihonAvailableExtension> extensions =
        (list?['extensions'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) => _parseCurrentExtensionJson(
                  shell,
                  indexUrl,
                  item.cast<String, Object?>(),
                ))
            .toList(growable: false);
    return MihonStore(
      indexUrl: shell.indexUrl,
      name: shell.name,
      badgeLabel: shell.badgeLabel,
      signingKey: shell.signingKey,
      contact: shell.contact,
      format: shell.format,
      extensionListUrl: shell.extensionListUrl,
      embeddedExtensions: extensions,
    );
  }

  static MihonAvailableExtension _parseCurrentExtensionJson(
    MihonStore store,
    Uri documentUrl,
    Map<String, Object?> json,
  ) {
    final Map<String, Object?> resources =
        (json['resources'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    final List<MihonAvailableSource> sources =
        (json['sources'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) {
      final Map<String, Object?> source = item.cast<String, Object?>();
      return MihonAvailableSource(
        id: source['id'].toString(),
        name: source['name']?.toString() ?? '',
        language: source['language']?.toString() ?? '',
        baseUrl: source['homeUrl']?.toString() ?? '',
      );
    }).toList(growable: false);
    final Object? warning = json['contentWarning'];
    return MihonAvailableExtension(
      storeUrl: store.indexUrl,
      name: json['name']?.toString() ?? '',
      packageName: json['packageName']?.toString() ?? '',
      apkUrl:
          documentUrl.resolve(resources['apkUrl']?.toString() ?? '').toString(),
      iconUrl: documentUrl
          .resolve(resources['iconUrl']?.toString() ?? '')
          .toString(),
      libVersion: json['extensionLib']?.toString() ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      versionName: json['versionName']?.toString() ?? '',
      language:
          sources.map((MihonAvailableSource s) => s.language).toSet().length ==
                  1
              ? sources.first.language
              : 'all',
      contentWarning: warning is num
          ? warning.toInt()
          : switch (warning?.toString()) {
              'CONTENT_WARNING_SAFE' || 'SAFE' => 1,
              'CONTENT_WARNING_MIXED' || 'MIXED' => 2,
              'CONTENT_WARNING_NSFW' || 'NSFW' => 3,
              _ => 0,
            },
      sources: sources,
    );
  }

  static MihonAvailableExtension _parseLegacyExtension(
    MihonStore store,
    Uri base,
    Map<String, Object?> json,
  ) {
    final String packageName = json['pkg']?.toString() ?? '';
    final String versionName = json['version']?.toString() ?? '';
    final List<MihonAvailableSource> sources =
        (json['sources'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) {
      final Map<String, Object?> source = item.cast<String, Object?>();
      return MihonAvailableSource(
        id: source['id'].toString(),
        name: source['name']?.toString() ?? '',
        language: source['lang']?.toString() ?? '',
        baseUrl: source['baseUrl']?.toString() ?? '',
      );
    }).toList(growable: false);
    final String language = json['lang']?.toString() ?? '';
    return MihonAvailableExtension(
      storeUrl: store.indexUrl,
      name: (json['name']?.toString() ?? '').replaceFirst('Tachiyomi: ', ''),
      packageName: packageName,
      apkUrl: base.resolve('apk/${json['apk']}').toString(),
      iconUrl: base.resolve('icon/$packageName.png').toString(),
      libVersion: versionName.contains('.')
          ? versionName.substring(0, versionName.lastIndexOf('.'))
          : versionName,
      versionCode: (json['code'] as num?)?.toInt() ?? 0,
      versionName: versionName,
      language: language,
      contentWarning: (json['nsfw'] as num?)?.toInt() == 1 ? 3 : 1,
      sources: sources.isNotEmpty
          ? sources
          : <MihonAvailableSource>[
              MihonAvailableSource(
                id: '0',
                name: json['name']?.toString() ?? '',
                language: language,
                baseUrl: '',
              ),
            ],
    );
  }

  static MihonStore _parseCurrentStoreProto(Uri indexUrl, Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String name = '';
    String badgeLabel = '';
    String signingKey = '';
    Map<String, String?> contact = const <String, String?>{};
    String? extensionListUrl;
    Uint8List? extensionList;
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      switch (field.number) {
        case 1:
          name = field.stringValue;
        case 2:
          badgeLabel = field.stringValue;
        case 3:
          signingKey = field.stringValue;
        case 4:
          contact = _parseContactProto(field.bytesValue);
        case 101:
          extensionList = field.bytesValue;
        case 102:
          extensionListUrl = field.stringValue;
      }
    }
    final MihonStore shell = _validateCurrentStore(MihonStore(
      indexUrl: indexUrl.toString(),
      name: name,
      badgeLabel: badgeLabel,
      signingKey: signingKey,
      contact: contact,
      format: MihonStoreFormat.currentProtobuf,
      extensionListUrl: extensionListUrl,
    ));
    return MihonStore(
      indexUrl: shell.indexUrl,
      name: shell.name,
      badgeLabel: shell.badgeLabel,
      signingKey: shell.signingKey,
      contact: shell.contact,
      format: shell.format,
      extensionListUrl: shell.extensionListUrl,
      embeddedExtensions: extensionList == null
          ? const <MihonAvailableExtension>[]
          : _parseExtensionListProto(shell, indexUrl, extensionList),
    );
  }

  static List<MihonAvailableExtension> _parseExtensionListProto(
    MihonStore store,
    Uri documentUrl,
    Uint8List bytes,
  ) {
    final _ProtoReader reader = _ProtoReader(bytes);
    final List<MihonAvailableExtension> result = <MihonAvailableExtension>[];
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      if (field.number == 1) {
        result.add(_parseExtensionProto(store, documentUrl, field.bytesValue));
      }
    }
    return result;
  }

  static MihonAvailableExtension _parseExtensionProto(
    MihonStore store,
    Uri documentUrl,
    Uint8List bytes,
  ) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String name = '';
    String packageName = '';
    String apkUrl = '';
    String iconUrl = '';
    String libVersion = '';
    int versionCode = 0;
    String versionName = '';
    int warning = 0;
    final List<MihonAvailableSource> sources = <MihonAvailableSource>[];
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      switch (field.number) {
        case 1:
          name = field.stringValue;
        case 2:
          packageName = field.stringValue;
        case 3:
          final List<String> resources = _parseResourcesProto(field.bytesValue);
          apkUrl = resources[0];
          iconUrl = resources[1];
        case 4:
          libVersion = field.stringValue;
        case 5:
          versionCode = field.signedInt64Value;
        case 6:
          versionName = field.stringValue;
        case 7:
          warning = field.varintValue;
        case 8:
          sources.add(_parseSourceProto(field.bytesValue));
      }
    }
    final Set<String> languages =
        sources.map((MihonAvailableSource source) => source.language).toSet();
    return MihonAvailableExtension(
      storeUrl: store.indexUrl,
      name: name,
      packageName: packageName,
      apkUrl: documentUrl.resolve(apkUrl).toString(),
      iconUrl: documentUrl.resolve(iconUrl).toString(),
      libVersion: libVersion,
      versionCode: versionCode,
      versionName: versionName,
      language: languages.length == 1 ? languages.first : 'all',
      contentWarning: warning,
      sources: sources,
    );
  }

  static Map<String, String?> _parseContactProto(Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String? website;
    String? discord;
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      if (field.number == 1) website = field.stringValue;
      if (field.number == 2) discord = field.stringValue;
    }
    return <String, String?>{'website': website, 'discord': discord};
  }

  static List<String> _parseResourcesProto(Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    String apk = '';
    String icon = '';
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      if (field.number == 1) apk = field.stringValue;
      if (field.number == 2) icon = field.stringValue;
    }
    return <String>[apk, icon];
  }

  static MihonAvailableSource _parseSourceProto(Uint8List bytes) {
    final _ProtoReader reader = _ProtoReader(bytes);
    int id = 0;
    String name = '';
    String language = '';
    String baseUrl = '';
    while (!reader.isDone) {
      final _ProtoField field = reader.readField();
      switch (field.number) {
        case 1:
          id = field.signedInt64Value;
        case 2:
          name = field.stringValue;
        case 3:
          language = field.stringValue;
        case 4:
          baseUrl = field.stringValue;
      }
    }
    return MihonAvailableSource(
      id: '$id',
      name: name,
      language: language,
      baseUrl: baseUrl,
    );
  }

  static Map<String, Object?> _jsonObject(Uint8List bytes) {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<Object?, Object?>) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Extension store metadata is not a JSON object',
      );
    }
    return decoded.cast<String, Object?>();
  }

  static int _firstNonWhitespace(Uint8List bytes) {
    for (final int byte in bytes) {
      if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
        return byte;
      }
    }
    throw const MihonRuntimeException(
      'EMPTY_STORE',
      'Extension store returned an empty response',
    );
  }

  static MihonStore _validateCurrentStore(MihonStore store) {
    if (store.name.trim().isEmpty ||
        store.badgeLabel.trim().isEmpty ||
        store.signingKey.trim().isEmpty) {
      throw const MihonRuntimeException(
        'INVALID_STORE',
        'Current extension stores require name, badgeLabel, and signingKey',
      );
    }
    return store;
  }

  static Uint8List _decodeGzip(
    Uint8List bytes, {
    required int maxBytes,
  }) {
    Uint8List decoded = bytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      final _LimitedByteSink sink = _LimitedByteSink(maxBytes);
      final ByteConversionSink decoder =
          gzip.decoder.startChunkedConversion(sink);
      try {
        decoder
          ..add(bytes)
          ..close();
        decoded = sink.takeBytes();
      } on MihonRuntimeException {
        rethrow;
      } on Object catch (error) {
        throw MihonRuntimeException(
          'INVALID_GZIP',
          'Extension store returned invalid gzip data',
          cause: error,
        );
      }
    }
    if (decoded.length > maxBytes) {
      throw MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Decoded download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
      );
    }
    return decoded;
  }
}

class _LimitedByteSink extends ByteConversionSink {
  _LimitedByteSink(this.maxBytes);

  final int maxBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;
  bool _closed = false;

  @override
  void add(List<int> chunk) {
    if (_closed) throw StateError('Cannot add bytes after close');
    _length += chunk.length;
    if (_length > maxBytes) {
      throw MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Decoded download exceeds the ${maxBytes ~/ (1024 * 1024)} MiB limit',
      );
    }
    _builder.add(chunk);
  }

  @override
  void close() {
    _closed = true;
  }

  Uint8List takeBytes() {
    if (!_closed) throw StateError('Gzip decoder has not been closed');
    return _builder.takeBytes();
  }
}

/// 一次取数的结果：已解析好的 [value] 加条件请求要回写的校验器。
///
/// [value] 只在 `notModified` 时为 null——`304` 没有响应体可解析。
class _Fetched<T> {
  const _Fetched({
    required this.value,
    this.etag,
    this.lastModified,
    this.notModified = false,
  });

  final T? value;
  final String? etag;
  final String? lastModified;
  final bool notModified;
}

/// 一份索引文档的解析结果：要么是可用的仓库，要么是「跟着走到下一份索引」。
class _StoreDocument {
  const _StoreDocument.store(MihonStore this.store) : nextIndexUrl = null;
  const _StoreDocument.hop(Uri this.nextIndexUrl) : store = null;

  final MihonStore? store;
  final Uri? nextIndexUrl;
}

class _ProtoReader {
  _ProtoReader(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  bool get isDone => _offset >= bytes.length;

  _ProtoField readField() {
    final int tag = _readVarint();
    final int number = tag >> 3;
    final int wireType = tag & 7;
    switch (wireType) {
      case 0:
        return _ProtoField(number, varintValue: _readVarint());
      case 1:
        _skip(8);
        return _ProtoField(number);
      case 2:
        final int length = _readVarint();
        if (length < 0 || _offset + length > bytes.length) {
          throw const MihonRuntimeException(
            'INVALID_PROTOBUF',
            'Truncated protobuf field',
          );
        }
        final Uint8List value =
            Uint8List.sublistView(bytes, _offset, _offset + length);
        _offset += length;
        return _ProtoField(number, bytesValue: value);
      case 5:
        _skip(4);
        return _ProtoField(number);
      default:
        throw MihonRuntimeException(
          'INVALID_PROTOBUF',
          'Unsupported protobuf wire type $wireType',
        );
    }
  }

  int _readVarint() {
    int value = 0;
    int shift = 0;
    while (_offset < bytes.length && shift <= 63) {
      final int byte = bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
    throw const MihonRuntimeException(
      'INVALID_PROTOBUF',
      'Malformed protobuf varint',
    );
  }

  void _skip(int count) {
    if (_offset + count > bytes.length) {
      throw const MihonRuntimeException(
        'INVALID_PROTOBUF',
        'Truncated protobuf field',
      );
    }
    _offset += count;
  }
}

class _ProtoField {
  _ProtoField(
    this.number, {
    this.varintValue = 0,
    Uint8List? bytesValue,
  }) : bytesValue = bytesValue ?? Uint8List(0);

  final int number;
  final int varintValue;
  final Uint8List bytesValue;

  String get stringValue => utf8.decode(bytesValue);

  int get signedInt64Value => varintValue.toSigned(64);
}
