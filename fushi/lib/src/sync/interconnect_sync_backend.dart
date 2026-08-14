import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/misc/resumable_downloader.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_backend_file_trio_mixin.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/tls/fushi_pinning_http.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

/// Probes whether a single Hibiki server URL is reachable with [token].
/// Returns true if reachable, false on connectivity failure/timeout, and
/// throws [SyncAuthError] if the server rejects the token.
typedef FushiProbe = Future<bool> Function(String url, String token);

/// TODO-961 M1: 按顺序探测 [candidates]（跳过 disabled），返回第一个可达的
/// [FushiClientUrl]（而非裸 URL），让调用方能取到该地址的钉扎指纹（https 走 pinned
/// client）。指纹是地址身份的一部分，故必须随选中地址一起流出。
///
/// BUG-1550：每个候选用**自己那份**凭据（[FushiClientUrl.token]，为空回落
/// [fallbackToken]）。因此一个候选的 [SyncAuthError] 不再株连其余候选——它只说明
/// 「这台的 token 过期/被吊销了」，换下一台继续探。全部候选都试完仍无可达者时：
/// 只要出现过鉴权拒绝就抛 [SyncAuthError]（让 UI 说「凭据被拒，请重新配对」），
/// 否则抛可重试的 [SyncBackendError]。
///
/// 升级前的行为（单一全局 token、第一台 401 即整体失败）在**只有一台对端**时逐字
/// 不变：唯一候选 401 → 循环结束 → 抛 SyncAuthError，与旧的立即 rethrow 等效。
Future<FushiClientUrl> resolveReachableFushiCandidate(
  List<FushiClientUrl> candidates,
  String fallbackToken,
  FushiProbe probe,
) async {
  SyncAuthError? authError;
  for (final FushiClientUrl candidate in candidates) {
    if (!candidate.enabled) continue;
    final String? token = interconnectTokenFor(candidate, fallbackToken);
    if (token == null) continue;
    final String? fp = candidate.fingerprintSha256;
    try {
      // https 端点（带指纹）的可达性必须用 pinned client 探测——裸 [probe] 会因自签
      // TLS 握手失败把它误判不可达。明文 http（无指纹）仍走可注入的 [probe] 测试缝。
      final bool reachable = (fp != null && fp.isNotEmpty)
          ? await _pinnedReachabilityProbe(candidate.url, token, fp)
          : await probe(candidate.url, token);
      if (reachable) return candidate;
    } on SyncAuthError catch (e) {
      // 这台拒了我的凭据 —— 记下原因，继续问下一台。
      authError = e;
    }
  }
  if (authError != null) throw authError;
  throw SyncBackendError(
    'No reachable Fushi server address',
    isRetryable: true,
  );
}

/// TODO-961 M1: https 候选地址的固定 pinned 可达性探测（不经可注入的测试缝，因为
/// 它必须真正建立 pinned TLS 连接才有意义）。语义同 [_defaultFushiProbe]：可达 →
/// true，鉴权失败 → 抛 [SyncAuthError]（BUG-1550 起由调用方记下并继续问下一台，
/// 不再株连其余地址），其余失败 → false。
Future<bool> _pinnedReachabilityProbe(
    String url, String token, String fingerprint) async {
  WebDavOps? ops;
  try {
    ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
      connectionTimeout: InterconnectSyncBackend.probeTimeout,
      pinnedFingerprint: fingerprint,
    );
    await ops.testConnection().timeout(InterconnectSyncBackend.probeTimeout);
    return true;
  } on SyncAuthError {
    rethrow;
  } catch (e) {
    debugPrint('[fushi-client] pinned probe failed for $url: $e');
    return false;
  } finally {
    ops?.close(force: true);
  }
}

/// Default probe: a short-timeout WebDAV connection test. Connectivity
/// failures and timeouts map to `false` (unreachable); a rejected token
/// surfaces as [SyncAuthError] so the resolver can tell "this peer revoked my
/// credential" apart from "this address is down" (BUG-1550: it moves on to the
/// next candidate either way, and only reports auth failure if none worked).
Future<bool> _defaultFushiProbe(String url, String token) async {
  WebDavOps? ops;
  try {
    ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
      // Bound the socket connect itself (WebDavOps defaults to 60s); the outer
      // .timeout only bounds the awaited future, not the underlying connect.
      connectionTimeout: InterconnectSyncBackend.probeTimeout,
    );
    await ops.testConnection().timeout(InterconnectSyncBackend.probeTimeout);
    return true;
  } on SyncAuthError {
    rethrow;
  } catch (e) {
    // Unreachable, timed out, or the server returned an error — skip this
    // address, but log why so a running-but-erroring server is distinguishable
    // from "down" (HBK-AUDIT-166).
    debugPrint('[fushi-client] probe failed for $url: $e');
    return false;
  } finally {
    // force: abort any connect still in flight when we timed out, so an
    // unreachable address never leaks a socket lingering up to 60s.
    ops?.close(force: true);
  }
}

/// Sync backend for connecting to another Hibiki instance's embedded server.
///
/// Uses the WebDAV protocol (same as [WebDavSyncBackend]) but stores
/// credentials in dedicated keys to avoid collision with the user's
/// standalone WebDAV config.
class InterconnectSyncBackend extends SyncBackend
    with SyncFolderCache, SyncBackendFileTrioMixin, SyncAssetStoreDefaults
    implements
        RemoteBookClient,
        RemoteVideoClient,
        RemoteVideoDelaySync,
        RemoteCoverFetcher {
  InterconnectSyncBackend._({FushiProbe? probe})
      : _probe = probe ?? _defaultFushiProbe;
  static final InterconnectSyncBackend instance = InterconnectSyncBackend._();

  /// Test seam: inject a fake reachability probe.
  @visibleForTesting
  InterconnectSyncBackend.withProbe(FushiProbe probe) : _probe = probe;

  /// How long to wait for a single address probe before treating it as
  /// unreachable and trying the next candidate. Short so LAN-first failover
  /// to WAN is quick when you are away from home.
  static const Duration probeTimeout = Duration(seconds: 2);

  /// BUG-1567：小型请求（清单 / 进度 / 断点 / streamurl / 封面 / 服务配置 / 删除等
  /// 非流式端点）的整体超时，分别封顶「发出请求到收到响应头」（[_sendBounded]）与
  /// 「读取响应体」（[_readBodyBounded]）两个阶段。此前只有 videos / activity 清单有
  /// 封顶（旧 listTimeout），其余端点在 host 接受 TCP 连接后停摆时 future 永久悬挂
  /// ——远端库页无限转圈，且挂死的请求还占住 [RemoteLibraryCache] 的 in-flight 槽。
  ///
  /// 15s 沿用旧 listTimeout 的量级（探测已由 2s 的 [probeTimeout] 把关，正常请求给宽
  /// 松余量）。整体超时同时覆盖底层 socket connect（整体 ≤ 连接阶段），无需再单调
  /// WebDavOps 的 connectionTimeout。**不适用**于大文件传输：下载走
  /// [ResumableDownloader] 的 firstByte/stall 超时；流式上传（epub / 视频 / 词典包
  /// PUT）body 发送时长与文件大小成正比、host 侧收尾（词典导入等）可能分钟级，
  /// 固定值封顶会砍断合法慢传输，维持原语义。
  ///
  /// 实例可变仅供测试注入短超时（生产代码不得改写）。
  @visibleForTesting
  Duration requestTimeout = const Duration(seconds: 15);

  /// BUG-1567：把 [req] 发出并在 [requestTimeout] 内等到响应头；超时则中止请求
  /// （释放底层连接）并抛 [TimeoutException]，让挂死 host 降级为可重试失败。
  Future<HttpClientResponse> _sendBounded(HttpClientRequest req) {
    return req.close().timeout(requestTimeout, onTimeout: () {
      req.abort();
      throw TimeoutException(
        'interconnect request timed out after $requestTimeout',
        requestTimeout,
      );
    });
  }

  /// BUG-1567：在 [requestTimeout] 内读完 [res] 的 UTF-8 响应体（响应头到了但
  /// body 断流的对称封顶），超时抛 [TimeoutException]。
  Future<String> _readBodyBounded(HttpClientResponse res) =>
      res.transform(utf8.decoder).join().timeout(requestTimeout);

  /// 下载健壮性（弱网，TODO-819 续）超时：
  /// - [downloadStallTimeout]：数据流两个 chunk 之间的最大空闲。超过即判定连接卡死并
  ///   中断（[ResumableDownloader] 保留 .part 可续传），而不是干等到 OS 级 TCP 超时
  ///   （弱网下可能几分钟像卡死）。给得比常规请求宽松，容忍慢但活着的链路。
  /// - [videoFirstByteTimeout]：视频是稳定磁盘文件、host 无需打包，首字节应很快。
  /// - [packageFirstByteTimeout]：书/有声书/词典包下载——host 要先导出临时包再流式，
  ///   首字节（=打包耗时）可能较慢，给足打包余量，远比视频宽松。
  static const Duration downloadStallTimeout = Duration(seconds: 45);
  static const Duration videoFirstByteTimeout = Duration(seconds: 30);
  static const Duration packageFirstByteTimeout = Duration(minutes: 5);

  final FushiProbe _probe;
  List<FushiClientUrl> _candidates = const <FushiClientUrl>[];
  String? _token;
  bool _sessionResolved = false;

  /// 上一次 [_loadConfig] 读到的配置身份（见 [_sessionSignature]）。BUG-1183：用它
  /// 判断 `restoreAuth` 是否真需要作废已解析的地址。null = 还没读过配置。
  String? _configSignature;

  /// 远端清单缓存里的来源身份（BUG-1202）：互联对端 live 库。
  ///
  /// 不随「当前是哪一台对端」变化——本类是单例，换对端由
  /// [sessionIdentityRevision] 驱动 `invalidateAll()`，那是唯一权威判据。这个 id
  /// 只回答「这份清单是问互联要的，不是问云盘要的」。
  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  /// 对端身份（地址集合 / 钉扎指纹 / 令牌）真的变了时自增。
  ///
  /// BUG-1180：远端**清单缓存**必须跟着作废，否则换对端后 TTL 内还会拿上一台 host 的
  /// 清单渲染（点下载还会向新 host 要一个它根本没有的条目）。
  ///
  /// 为什么挂在这里而不是各个「改配置」的 UI 调用点——改对端的入口有四处
  /// （设置页 `_persistUrls` / `_saveToken`、局域网配对的两处 token 落库），而
  /// [_sessionSignature] 的比对已经是**唯一**权威的「对端身份变了」判据，且
  /// [restoreAuth] 是所有远端读取的必经前置。挂在这里 = 四个入口加任何将来新增的
  /// 入口全部自动覆盖，不依赖每个调用点记得手动失效（这正是本 bug 的成因）。
  final ValueNotifier<int> sessionIdentityRevision = ValueNotifier<int>(0);

  WebDavOps? _ops;
  // TODO-961 M1: 当前选中地址的钉扎指纹（https 走 pinned client；http=null）。
  String? _activeFingerprint;

  /// BUG-1550：当前 [_ops] 里烧进 Basic 头的那份凭据。[WebDavOps] 只留 auth header、
  /// 不回吐口令，故在此镜像一份，用于判断「换了一台对端 = 要重建 ops」。
  String? _activeToken;

  // 文件夹缓存收敛进 [SyncFolderCache] mixin；路径式定位符覆写归一化钩子保持
  // 「缓存的 folderId 必以 `/` 结尾」不变量（BUG-845）。
  @override
  String normalizeFolderId(String id) => ensureFolderIdTrailingSlash(id);

  /// Test seam: force address resolution without performing a folder op.
  @visibleForTesting
  Future<void> ensureResolved() => _ensureResolved();

  /// Test seam: the base URL the session has settled on.
  @visibleForTesting
  String? get activeBaseUrl => _ops?.baseUrl;

  /// BUG-891：当前选中 host 的 TOFU 钉扎证书 SHA-256 指纹（`aa:bb:..`），供制卡把它
  /// 下发给 ffmpeg 的 `-tls_pin_sha256` 以按指纹接受自签流。http 主机 / 未解析 = null。
  String? get activeFingerprintSha256 => _activeFingerprint;

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async => _ops != null;

  @override
  Future<String?> get currentEmail async => 'hibiki';

  Future<void> _loadConfig(SyncRepository repo) async {
    final List<FushiClientUrl> candidates = (await repo.getFushiClientUrls())
        .where((FushiClientUrl u) => u.enabled)
        .toList();
    final String? token = await repo.getFushiClientToken();
    // BUG-1183：这里原本无条件 `_sessionResolved = false`，而 [restoreAuth] 又是每个
    // 消费方（书架 / 视频页 / 首页 dashboard）取 client 的必经之路，且本类是**单例**。
    // 净效果：每切一次页面就把已经探明可达的地址作废一次，下一次网络操作要重跑
    // [resolveReachableFushiCandidate] 的全候选串行探测（https 候选还要各做一次带
    // 指纹钉扎的 TLS 握手），三个页面之间还互相踩。
    //
    // 会话该不该重来，取决于**配置是否真的变了**——地址集合、启用状态、钉扎指纹、
    // 令牌。没变就保留已解析地址；变了才作废。地址失联的换路由径由 [clearCache]
    // 负责（SyncManager 重试前调用），与本处正交、不受影响。
    final String signature = _sessionSignature(candidates, token);
    if (signature != _configSignature) {
      _configSignature = signature;
      _sessionResolved = false;
      // BUG-1180：身份变了 = 远端清单缓存里的东西属于**上一个**对端，必须作废。
      // 监听者同步收到通知，所以本次 restoreAuth 返回时缓存已经是空的，紧随其后的
      // 那次 read() 必然重新向新对端取数。
      sessionIdentityRevision.value++;
    }
    _candidates = candidates;
    _token = token;
  }

  /// 会话身份指纹：只包含影响「该连哪个地址、用什么凭据」的字段。`deviceName`
  /// 是纯展示名，改它不该触发全候选重探测，故不进签名。
  ///
  /// BUG-1550：每候选自带的 token 也进签名——重新配对某一台只改那一行的凭据，
  /// 全局键可能一字未动，不入签名就检测不到「对端身份变了」，已解析会话会带着
  /// 旧凭据继续用。
  static String _sessionSignature(
    List<FushiClientUrl> candidates,
    String? token,
  ) {
    // 换行做分隔符：URL 与指纹里都不可能出现裸换行，不会拼出歧义签名。
    final StringBuffer buffer = StringBuffer(token ?? '');
    for (final FushiClientUrl candidate in candidates) {
      buffer
        ..write('\n')
        ..write(candidate.url)
        ..write('\n')
        ..write(candidate.fingerprintSha256 ?? '')
        ..write('\n')
        ..write(candidate.token ?? '');
    }
    return buffer.toString();
  }

  /// Builds a provisional [WebDavOps] on the first well-formed candidate so
  /// [isAuthenticated] reflects "configured". The actually-reachable address
  /// is chosen later by [_ensureResolved] on the first network operation.
  void _buildProvisionalOps() {
    _ops?.close();
    _ops = null;
    _activeToken = null;
    for (final FushiClientUrl candidate in _candidates) {
      // BUG-1550：凭据按候选取（自带优先、回落全局），两者都空就跳过这一条。
      final String? token = interconnectTokenFor(candidate, _token);
      if (token == null) continue;
      try {
        _ops = WebDavOps(
          baseUrl: WebDavOps.normalizeUrl(candidate.url),
          username: 'hibiki',
          password: token,
          pinnedFingerprint: candidate.fingerprintSha256,
        );
        _activeFingerprint = candidate.fingerprintSha256;
        // 与 [_ensureResolved] 的判据保持同一真相：暂定句柄用的是哪份凭据必须记下，
        // 否则解析阶段会把「凭据没变」误判成「换了一台」而白白 clearCache()。
        _activeToken = token;
        return;
      } on SyncBackendError {
        continue; // malformed URL — keep looking for a usable handle
      }
    }
  }

  /// Probes the candidate addresses (in order) and settles the session on the
  /// first reachable one. Switching addresses rebuilds [_ops] and clears the
  /// folder cache, whose paths embed the previous base URL.
  Future<void> _ensureResolved() async {
    if (_sessionResolved) return;
    if (!_hasAnyCredential) {
      throw SyncAuthError('Fushi server credentials not configured');
    }
    final FushiClientUrl chosen =
        await resolveReachableFushiCandidate(_candidates, _token ?? '', _probe);
    // BUG-1550：连接用的是**选中那台**的凭据（自带优先），不再是唯一全局 token。
    // resolveReachableFushiCandidate 已保证选中的候选必有可用凭据。
    final String token = interconnectTokenFor(chosen, _token)!;
    final String normalized = WebDavOps.normalizeUrl(chosen.url);
    if (_ops == null ||
        _ops!.baseUrl != normalized ||
        _activeToken != token ||
        _activeFingerprint != chosen.fingerprintSha256) {
      _ops?.close();
      _ops = WebDavOps(
        baseUrl: normalized,
        username: 'hibiki',
        password: token,
        pinnedFingerprint: chosen.fingerprintSha256,
      );
      _activeFingerprint = chosen.fingerprintSha256;
      _activeToken = token;
      clearCache();
    }
    _sessionResolved = true;
  }

  /// BUG-1550：是否至少有一个已启用候选拿得出凭据（自带 token 或全局回落）。
  /// 取代旧的「全局 token 非空」判据——per-peer token 时代全局键可能为空，而各
  /// 地址行上仍有各自有效的凭据。
  bool get _hasAnyCredential => _candidates
      .any((FushiClientUrl u) => interconnectTokenFor(u, _token) != null);

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    await _loadConfig(repo);
    if (_candidates.isEmpty || !_hasAnyCredential) {
      throw SyncAuthError('Fushi server credentials not configured');
    }
    // Probes + selects a reachable address (or throws), confirming the token
    // is accepted by the server.
    await _ensureResolved();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _ops?.close();
    _ops = null;
    _candidates = const <FushiClientUrl>[];
    _token = null;
    _sessionResolved = false;
    // 登出后配置身份归零，下次 restoreAuth 必然重探测（BUG-1183）。
    _configSignature = null;
    await repo.setFushiClientUrls(const <FushiClientUrl>[]);
    // Also wipe the legacy single-url key, else getFushiClientUrls would
    // migrate it back on the next read.
    // ignore: deprecated_member_use_from_same_package
    await repo.setFushiClientUrl(null);
    await repo.setFushiClientToken(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    await _loadConfig(repo);
    if (_candidates.isEmpty || !_hasAnyCredential) {
      _ops?.close();
      _ops = null;
      _sessionResolved = false;
      return false;
    }
    // BUG-1559：已经探明可达的会话不得被重建成「候选[0]」。
    //
    // [_loadConfig] 已经拿配置签名判完「会话该不该重来」（BUG-1183）：配置真变了
    // 就会把 [_sessionResolved] 置 false。可旧实现不管那个判决，无条件跑
    // [_buildProvisionalOps]，把 [_ops] / [_activeFingerprint] / [_activeToken] 打回第一个
    // 格式合法的候选——而 [_sessionResolved] 仍是 true，[_ensureResolved] 直接 return。
    // 净效果：切一次页面，会话就从「探明可达的那台」静默地滑回候选[0]（常常
    // 是一条当前不可达的旧地址），且因为已标「已解析」而**永不重探**，往后每一次
    // 请求都打到错地址。故会话已解析且句柄还在时，原封不动地保留它。
    if (_sessionResolved && _ops != null) return true;
    _buildProvisionalOps();
    return _ops != null;
  }

  @override
  Future<void> refreshAuth() async {}

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    await _ensureResolved();
    if (rootFolderIdCache != null) return rootFolderIdCache!;

    final path = '${_ops!.baseUrl}/$kSyncRootFolderName/';
    await _ops!.ensureCollection(path);
    rootFolderIdCache = path;
    return path;
  }

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async {
    final entries = await _ops!.propfindChildren(rootFolderId);
    return entries
        .where((e) => e.isCollection && e.href != rootFolderId)
        .map((e) => SyncFileRef(id: e.href, name: e.displayName))
        .toList();
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final sanitized = requireBookFolderName(bookTitle);

    if (folderIdCache.containsKey(sanitized)) {
      // Normalize a possibly slash-less cached href on return (BUG-845).
      return ensureFolderIdTrailingSlash(folderIdCache[sanitized]!);
    }

    final path = '$rootFolderId${Uri.encodeComponent(sanitized)}/';
    await _ops!.ensureCollection(path);
    folderIdCache[sanitized] = path;

    final Uint8List? coverData = await readCoverData?.call();
    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverPath = '${path}cover_1_6.${format.extension}';
        final existing = await _ops!.headFile(coverPath);
        if (!existing) {
          await _ops!.putBytes(coverPath, coverData, format.mimeType);
        }
      } catch (e) {
        debugPrint('[fushi-client] cover upload failed: $e');
      }
    }

    return path;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final entries = await _ops!.propfindChildren(folderId);
    final files = entries
        .where((e) => !e.isCollection && e.href != folderId)
        .map((e) => SyncFileRef(id: e.href, name: e.displayName))
        .toList();

    // HBK-AUDIT-085: route through the single canonical matcher in sync_utils.
    return SyncFileTrio(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }

  // get{Progress,Stats,AudioBook}File 三件套由 SyncBackendFileTrioMixin 提供；
  // 这里只给出 hibiki client 的下载原语（size-capped GET + jsonDecode，见
  // WebDavOps.downloadJson）。读取不经 _ensureResolved（沿用原实现，直接用 _ops!）。
  @override
  Future<Object?> readJsonById(String fileId) => _ops!.downloadJson(fileId);

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _ops!.uploadJson(folderId, fileName, progress.toJson());
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName = statisticsFileName(stats);
    await _ops!
        .uploadJson(folderId, fileName, stats.map((s) => s.toJson()).toList());
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _ops!.uploadJson(folderId, fileName, audioBook.toJson());
  }

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final length = await file.length();
    final request = await _ops!.buildRequest('PUT', path);
    request.headers.set('Content-Type', WebDavOps.guessContentType(fileName));
    request.headers.set('Content-Length', '$length');
    int bytesUploaded = 0;
    await request.addStream(file.openRead().map((chunk) {
      bytesUploaded += chunk.length;
      onProgress?.call(length > 0 ? bytesUploaded / length : 0);
      return chunk;
    }));
    final response = await request.close();
    await response.drain<void>();
    _ops!.checkStatus(response.statusCode, 'PUT $path');
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    // Range 续传（视频 TODO-819 同款范式推广到库包下载：epub/词典/有声书/本地
    // 音频）。旧实现是裸 GET，中断即删截断文件、下次从 0——大词典/有声书包在
    // 抖动 Wi-Fi 上反复整包重下。host 包端点现带 ETag + If-Range（导出缓存保证
    // TTL 内字节稳定）；ResumableDownloader 把 ETag 经 `.part.etag` 侧车持久化，
    // 续传时以 If-Range 携带——host 字节换代则收 200 全量重写，绝不拼错字节。
    // 旧 host 无 Range 支持时同样收 200 → 丢弃旧 part 从 0，零兼容破坏。
    final File partFile = File('${destination.path}.part');
    final File etagFile = File('${destination.path}.part.etag');
    await destination.parent.create(recursive: true);
    String? storedEtag;
    try {
      if (partFile.existsSync() && etagFile.existsSync()) {
        storedEtag = etagFile.readAsStringSync();
      }
    } catch (_) {
      // 侧车读不出：当无验证器处理（host 端会因缺 If-Range 而整包 200，安全）。
    }
    final ResumableDownloader downloader = ResumableDownloader(
      url: fileId,
      destination: destination,
      partFile: partFile,
      resumeState: ResumableDownloadState(etag: storedEtag),
      // 弱网停顿超时：流内空闲超 downloadStallTimeout 即中断保 part 可续；打包型
      // 包端点首字节（=打包耗时）给足 packageFirstByteTimeout 余量。
      firstByteTimeout: packageFirstByteTimeout,
      bodyTimeout: downloadStallTimeout,
      open: (Uri uri, Map<String, String> headers) async {
        final HttpClientRequest req =
            await _ops!.buildRequest('GET', uri.toString());
        for (final MapEntry<String, String> entry in headers.entries) {
          req.headers.set(entry.key, entry.value);
        }
        final HttpClientResponse res = await req.close();
        // 保留原错误契约：401/403 → SyncAuthError、404 → 可重试 SyncBackendError
        // （上层认证/重试流依赖这些类型）。416 放行给 ResumableDownloader——那是
        // 它「丢弃旧 part 从 0 重来」的合法信号。
        if (res.statusCode >= 400 && res.statusCode != 416) {
          await res.drain<void>().catchError((_) {});
          _ops!.checkStatus(res.statusCode, 'GET $fileId');
        }
        final Map<String, String> responseHeaders = <String, String>{};
        res.headers.forEach((String name, List<String> values) {
          if (values.isNotEmpty) responseHeaders[name] = values.join(',');
        });
        return ResumableDownloadResponse(
          statusCode: res.statusCode,
          headers: responseHeaders,
          stream: res,
        );
      },
      onMeta: (ResumableDownloadMetaInfo meta) {
        // 把本次响应的 ETag 落侧车，供中断后下次进程的 If-Range 使用。
        try {
          final String? etag = meta.etag;
          if (etag != null && etag.isNotEmpty) {
            etagFile.writeAsStringSync(etag);
          } else if (etagFile.existsSync()) {
            etagFile.deleteSync();
          }
        } catch (_) {
          // best-effort：侧车写失败只损失续传能力，不影响本次下载。
        }
      },
      onProgress: (int received, int? total) {
        if (total != null && total > 0) onProgress?.call(received / total);
      },
    );
    try {
      await downloader.download();
    } finally {
      // 成功后清侧车；失败保留（与 .part 配对供续传）。
      if (!partFile.existsSync()) {
        try {
          if (etagFile.existsSync()) etagFile.deleteSync();
        } catch (_) {
          // best-effort
        }
      }
    }
  }

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final exists = await _ops!.headFile(path);
    if (!exists) return null;
    return SyncFileRef(id: path, name: fileName);
  }

  // ── Cache ─────────────────────────────────────────────────────────

  // restoreCache / cachedRootFolderId / cachedFolderIds / cacheBookFolderIds
  // / evictFolderId 收敛进 [SyncFolderCache] mixin；本后端覆写 [normalizeFolderId]
  // 保持尾斜杠规范化（BUG-845，见类顶部）。
  @override
  void clearCache() {
    super.clearCache();
    // Re-probe the candidate addresses on the next op. SyncManager calls
    // clearCache() before retrying a retryable failure; if the resolved
    // address just went down, the retry must be free to fail over to the next
    // one (HBK-AUDIT-157). The folder cache is cleared by super.clearCache(), so
    // switching addresses is safe — no stale base-URL-coupled paths survive.
    _sessionResolved = false;
  }

  // ── SyncAssetStore ────────────────────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) async {
    await _ensureResolved();
    final root = '${_ops!.baseUrl}/$kSyncRootFolderName/';
    final path = '$root${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    await _ensureResolved();
    final path = '$parentId${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    await _ensureResolved();
    final entries = await _ops!.propfindChildren(namespaceId);
    return entries
        .where((e) => e.href != namespaceId)
        .map((e) => AssetEntry(
              id: e.href,
              name: _stripTrailingSlash(e.displayName),
              isFolder: e.isCollection,
            ))
        .toList();
  }

  // interconnect must settle on a reachable host before any per-asset op, so the
  // base [putAsset]/[getAsset] defaults await this readiness hook. The path-style
  // findAsset override and the folder-op methods below still call
  // [_ensureResolved] directly (same idempotent gate, unchanged from before).
  @override
  Future<void> ensureAssetReady() => _ensureResolved();

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    await _ensureResolved();
    final path = '$namespaceId${Uri.encodeComponent(name)}';
    if (!await _ops!.headFile(path)) return null;
    return AssetEntry(id: path, name: name);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    await _ensureResolved();
    return _ops!.downloadJson(assetId);
  }

  @override
  Future<void> putJsonAsset(
      String namespaceId, String name, Object? json) async {
    await _ensureResolved();
    await _ops!.uploadJson(namespaceId, name, json);
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    await _ensureResolved();
    // 服务端 _handleDelete 对目录 recursive 删、对文件单删；同一原语。
    // WebDavOps.deleteFile 已把服务端 404/已删除当作成功（幂等）；其它错误
    // （网络/权限/协议）必须自然抛出，否则 UI 会把真实失败误报为「已删除」。
    await _ops!.deleteFile(id);
  }

  static String _stripTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  // ── Live library (interconnect-only) ──────────────────────────────
  // host 升级为「库感知」后，client 直读对端实时词典，彻底不经 __dictionaries__。
  // 无旧设备，互联恒走 live（无能力探测）；分流由 orchestrator 按后端类型判定。

  /// host 根 origin（folder 路径是 `${_apiBase}/$kSyncRootFolderName/`，
  /// 故 /api 端点在 `${_apiBase}/api/...`）。
  String get _apiBase => _ops!.baseUrl;

  /// Pulls the host-owned service configuration over the pinned HTTPS session.
  /// Old hosts return 404 and are treated as not supporting the capability.
  /// HTTP/shared-token sessions are rejected by the server rather than silently
  /// downgrading API keys to plaintext transport.
  Future<InterconnectServiceConfigSnapshot?> getRemoteServiceConfig() async {
    await _ensureResolved();
    // 明文会话上这个端点**必然**是 403（host 侧 `HTTPS required for service
    // config`），因为 API key 不允许降级到明文传输——这是有意的拒绝，不是故障。
    // 而 TLS 默认是关的（`SyncRepository.getServerTlsEnabled()` 默认 false，存量
    // host 一律保持明文），照样发请求只会让每一轮同步都收到一条
    // `SyncAuthError: Authentication failed`，把「同步完成」永久挂上「N 项失败」，
    // 并且把用户引去反复重配 token——而 token 根本没问题（BUG-1311）。
    //
    // 答案本地就已知，别问。返回 null 与「旧 host 404」「host 关掉了该能力 404」
    // 归一到同一条「对端不提供此能力」语义，和 host 自己在 /api/capabilities 上
    // 广播的 `serviceConfig: _securityContext != null && ...` 逐字一致。
    if (Uri.tryParse(_apiBase)?.scheme != 'https') return null;
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/interconnect/service-config',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode >= 400) {
      // BUG-1323：host 对这个端点的拒绝是**有理由的**（明文 → `HTTPS required for
      // service config`；未配对 → `Paired-device token required`）。把响应体读出来
      // 当拒绝原因传下去，否则用户只会看到一句与事实不符的「登录已过期」。
      // 只在错误路径读——成功路径下面那行还要拿完整 body 解 JSON。
      _ops!.checkStatus(
        res.statusCode,
        'GET /api/interconnect/service-config',
        serverReason: await readSyncErrorBody(res),
      );
    }
    final String body = await _readBodyBounded(res);
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Invalid service config response');
    }
    return InterconnectServiceConfigSnapshot.fromJson(
      decoded.cast<String, Object?>(),
    );
  }

  /// TODO-1235（TODO-961 回归）：把对端封面拉成字节，复用互联其余流量同一条钉扎
  /// 通路——[_ops.buildRequest] 对 https 用 pinned client（证书指纹相等才接受自签），
  /// 对明文 http 用裸 client（老路径字节不变），并补 Basic auth。[coverUrl] 由 host
  /// 依 client 实际请求地址回填（scheme/host 与已解析地址一致），故指纹钉扎匹配。
  /// 非 2xx / 握手失败 / 网络异常抛出，由 [RemoteCoverImage] 转占位图。
  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest('GET', coverUrl);
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      await res.drain<void>();
      throw SyncBackendError('GET cover -> ${res.statusCode}');
    }
    // BUG-1567：封面字节读取同样封顶——header 到了但 body 停摆时不再永久悬挂。
    return consolidateHttpClientResponseBytes(res).timeout(requestTimeout);
  }

  /// 列出对端 host 当前实时词典清单（直打 `/api/library/dictionaries`）。
  /// 互联「列清单」端点的共同骨架：解析会话 → GET → 逐条 fromJson（TODO-2120）。
  ///
  /// 五个域此前各抄一份 12 行的同构代码。**降级必须逐域按现状显式传入**，
  /// 不能图省事统一给所有域打开：
  /// - [degradeOn404]：只有 videos / activity 这类**后加的**端点才降级——老 host 没有
  ///   它们，降级成空表是为了「不因老 server 缺端点让整页占位卡消失或转圈」。词典 /
  ///   书 / 本地音频 / 有声书是最老的端点，假定必然存在；给它们也加降级，会把「host
  ///   把库服务关了（404 Library service off）」从可见错误变成静默空列表——那是真实的
  ///   行为回归，不是「更健壮」。
  /// - 超时（BUG-1567）：所有域统一走 [requestTimeout] 封顶。此前只有 videos /
  ///   activity 有（旧 listTimeout），其余域在 host 停摆时永久转圈。
  Future<List<T>> _listRemote<T>(
    String path,
    T Function(Map<String, Object?> json) parse, {
    bool degradeOn404 = false,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase$path');
    final HttpClientResponse res = await _sendBounded(req);
    if (degradeOn404 && res.statusCode == 404) {
      await res.drain<void>();
      return <T>[];
    }
    if (res.statusCode >= 400) {
      // BUG-1323：错误路径把服务端给的原因带上（成功路径下面才读完整 body）。
      _ops!.checkStatus(
        res.statusCode,
        'GET $path',
        serverReason: await readSyncErrorBody(res),
      );
    }
    final String body = await _readBodyBounded(res);
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    return <T>[
      for (final dynamic e in arr) parse((e as Map).cast<String, Object?>()),
    ];
  }

  Future<List<RemoteDictionaryInfo>> listRemoteDictionaries() =>
      _listRemote('/api/library/dictionaries', RemoteDictionaryInfo.fromJson);

  /// 从对端 host 下载名为 [name] 的词典包到 [destination] 文件。
  Future<void> getRemoteDictionary(
    String name,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId: '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
      destination: destination,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file]（.fushidict 包）推送到对端 host，导入名为 [name] 的词典。
  Future<void> putRemoteDictionary(
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/dictionaries/$name');
  }

  /// 通知对端 host 删除名为 [name] 的词典。
  Future<void> deleteRemoteDictionary(String name) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
    );
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'DELETE /api/library/dictionaries/$name');
  }

  // ── Live books (interconnect-only) ────────────────────────────────
  // 与 live dictionaries 对称：直打 /api/library/books，不经 WebDAV 暂存。

  /// 互联（局域网对端设备）：书架远端分区用「互联 / 对端设备」文案。
  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  /// 列出对端 host 当前书库清单（直打 `/api/library/books`）。
  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() =>
      _listRemote('/api/library/books', RemoteBookInfo.fromJson);

  /// 从对端 host 下载书名为 [title] 的 EPUB 到 [destination] 文件。
  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId: '$_apiBase/api/library/books/${Uri.encodeComponent(title)}',
      destination: destination,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file]（.epub）推送到对端 host，导入书名为 [title] 的书。
  ///
  /// [displayTitle] / [displayTitleAt] 是本机用户给这本书改的名字及其 LWW 毫秒戳
  /// （BUG-1503）。body 是**裸 .epub 字节流**，没有 sidecar 也没有 multipart，所以
  /// 元数据走自定义 header —— 与本类视频推送的 `X-Hibiki-Video-Title` 同一套先例
  /// （header 只收 ASCII，日文书名必须 [Uri.encodeComponent]）。
  ///
  /// additive：没改过名就一个 header 都不发，旧 host 对未知 header 一律静默忽略
  /// （`_serveAssetPackage` 的 PUT 分支从头到尾只读 body），所以对旧 host 零影响、
  /// 不需要任何版本协商。
  Future<void> putRemoteBook(
    String title,
    File file, {
    String? displayTitle,
    int displayTitleAt = 0,
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/books/${Uri.encodeComponent(title)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/epub+zip');
    req.headers.set('Content-Length', '$length');
    if (displayTitle != null &&
        displayTitle.isNotEmpty &&
        displayTitle != title) {
      req.headers.set(
        kBookDisplayTitleHeader,
        Uri.encodeComponent(displayTitle),
      );
      if (displayTitleAt > 0) {
        req.headers.set(kBookDisplayTitleAtHeader, '$displayTitleAt');
      }
    }
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/books/$title');
  }

  /// 通知对端 host 删除书名为 [title] 的书。
  Future<void> deleteRemoteBook(String title) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/books/${Uri.encodeComponent(title)}',
    );
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'DELETE /api/library/books/$title');
  }

  /// 读 host 端书 [bookKey] 的阅读进度（TODO-767）。host 返回 404（该书无记录）或
  /// 网络异常时返回 [RemoteBookProgress.empty]，让调用方退回本地 `reader_positions`
  /// （离线 / 旧 host 无端点不致崩溃）。
  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/books/${Uri.encodeComponent(bookKey)}/progress',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return RemoteBookProgress.empty;
    }
    _ops!.checkStatus(
        res.statusCode, 'GET /api/library/books/$bookKey/progress');
    final String body = await _readBodyBounded(res);
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return RemoteBookProgress.fromJson(json.cast<String, Object?>());
  }

  /// 向 host 上报书 [bookKey] 的本端阅读进度（TODO-767）。host 端取较新时间戳决定
  /// 是否覆盖（落 host 自己的 reader_positions）。
  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/books/${Uri.encodeComponent(bookKey)}/progress',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(jsonEncode(progress.toJson())));
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'PUT /api/library/books/$bookKey/progress');
  }

  // ── 聚合（统计 + 收藏，TODO-1056 phase C）────────────────────────────────────

  /// 拉取 host 端聚合快照原始 JSON（TODO-1056 phase C）。老 host 无该端点返回 404
  /// 时优雅降级返回 null（调用方跳过聚合步骤，与 [remoteBookProgress] 的 404 降级
  /// 同纪律）——绝不因老 server 缺端点崩溃。返回的是未解码 Map，快照 decode 由上层
  /// orchestrator 用 AggregateSnapshot.fromJson 处理，本 backend 只搬运 JSON。
  Future<Map<String, dynamic>?> getRemoteAggregate() async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/aggregate',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return null; // 老 host 无聚合端点：降级跳过，不崩。
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/library/aggregate');
    final String body = await _readBodyBounded(res);
    final dynamic decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null; // 非对象返回体：当作空快照处理（上层 fromJson 也会降级）。
  }

  /// 向 host 上报（已在 client 端与 host 并集合并的）聚合快照 JSON（TODO-1056
  /// phase C）。host 端用 MAX / 并集 upsert 折叠进自己 DB（幂等）。[json] 是
  /// AggregateSnapshot.toJson() 的结果，本 backend 只负责 PUT 搬运。
  Future<void> putRemoteAggregate(Object? json) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/aggregate',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(jsonEncode(json)));
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/aggregate');
  }

  // ── Live collections (interconnect-only) ──────────────────────────
  // 合集双向同步（多端库联合视图 §2.3 任务5.3）：直打 /api/library/collections，
  // 不经 WebDAV 文件箱伪装的 __collections__ 资产（互联资产层是 live 端点适配，语义
  // 不同）。读-合并-写：GET host 清单 → 引擎合并 → 应用本地 → POST 合并后清单。

  /// GET 对端 host 当前合集清单（读）。老 host 无该端点返回 404 时优雅降级返回 null
  /// （调用方跳过整个合集同步步骤，绝不因老 server 缺端点崩溃，与 [getRemoteAggregate]
  /// 的 404 降级同纪律）。返回的清单已按 [CollectionManifest.fromJson] 解码。
  Future<CollectionManifest?> getRemoteCollectionManifest() async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/collections',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return null; // 老 host 无合集端点：降级跳过，不崩。
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/library/collections');
    final String body = await _readBodyBounded(res);
    return CollectionManifest.fromJson(jsonDecode(body));
  }

  /// POST 本端合并后清单到对端 host（写），host 并入自己 DB（成员并集 + 墓碑防复活 +
  /// 手动序 LWW）并返回其合并结果。返回体供调用方核对/调试；互联读-合并-写的收敛
  /// 已在 client 端 GET+merge 阶段完成，本方法只负责把结果推给 host 落库。
  Future<CollectionManifest> putRemoteCollectionManifest(
    CollectionManifest manifest,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'POST',
      '$_apiBase/api/library/collections',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(manifest.canonicalJson()));
    final HttpClientResponse res = await _sendBounded(req);
    _ops!.checkStatus(res.statusCode, 'POST /api/library/collections');
    final String body = await _readBodyBounded(res);
    return CollectionManifest.fromJson(jsonDecode(body));
  }

  /// GET 对端 host 当前删除墓碑清单（显式确认式删除传播，host→client 消费方向）。
  /// 老 host 无 `/api/tombstones` 端点返回 404 时优雅降级返回 null（调用方跳过删除墓碑
  /// 消费，绝不因老 server 缺端点崩溃，与 [getRemoteCollectionManifest] 同纪律）。
  /// 返回体是 JSON 数组，逐条 [parseDeletionTombstoneJson] 解码；非法条目安全跳过。
  Future<List<({String mediaType, String itemKey, int deletedAt})>?>
      getRemoteDeletionTombstones() async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/tombstones',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return null; // 老 host 无删除墓碑端点：降级跳过，不崩。
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/tombstones');
    final String body = await _readBodyBounded(res);
    final Object? decoded = jsonDecode(body);
    final List<({String mediaType, String itemKey, int deletedAt})> out =
        <({String mediaType, String itemKey, int deletedAt})>[];
    if (decoded is List) {
      for (final Object? e in decoded) {
        final parsed = parseDeletionTombstoneJson(e);
        if (parsed != null) out.add(parsed);
      }
    }
    return out;
  }

  // ── Live local audio (interconnect-only) ──────────────────────────
  // 与 live books 对称：直打 /api/library/localaudio，不经 WebDAV 暂存。

  /// 列出对端 host 当前本地音频来源清单（直打 `/api/library/localaudio`）。
  Future<List<RemoteLocalAudioInfo>> listRemoteLocalAudio() =>
      _listRemote('/api/library/localaudio', RemoteLocalAudioInfo.fromJson);

  /// 从对端 host 下载 displayName 为 [displayName] 的本地音频库到 [dest] 文件。
  Future<void> getRemoteLocalAudio(
    String displayName,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId:
          '$_apiBase/api/library/localaudio/${Uri.encodeComponent(displayName)}',
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file] 推送到对端 host，导入 displayName 为 [displayName] 的本地音频来源。
  Future<void> putRemoteLocalAudio(
    String displayName,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/localaudio/${Uri.encodeComponent(displayName)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'PUT /api/library/localaudio/$displayName');
  }

  /// 通知对端 host 删除 displayName 为 [displayName] 的本地音频来源。
  Future<void> deleteRemoteLocalAudio(String displayName) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/localaudio/${Uri.encodeComponent(displayName)}',
    );
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'DELETE /api/library/localaudio/$displayName');
  }

  // ── Live audiobooks (interconnect-only) ───────────────────────────
  // 与 live books 对称：直打 /api/library/audiobooks，不经 WebDAV 暂存。

  /// 列出对端 host 当前有声书清单（直打 `/api/library/audiobooks`）。
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() =>
      _listRemote('/api/library/audiobooks', RemoteAudiobookInfo.fromJson);

  /// 从对端 host 下载 bookKey 为 [bookKey] 的有声书到 [dest] 文件。
  Future<void> getRemoteAudiobook(
    String bookKey,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId:
          '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}',
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file] 推送到对端 host，导入 bookKey 为 [bookKey] 的有声书。
  Future<void> putRemoteAudiobook(
    String bookKey,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/audiobooks/$bookKey');
  }

  /// 通知对端 host 删除 bookKey 为 [bookKey] 的有声书。
  Future<void> deleteRemoteAudiobook(String bookKey) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}',
    );
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!
        .checkStatus(res.statusCode, 'DELETE /api/library/audiobooks/$bookKey');
  }

  /// 读 host 端有声书 [bookKey] 的播放断点（BUG-471）。host 返回 404（有声书不存在）
  /// 或网络异常时返回 (0, 0)，让调用方退回本地 prefs（离线/旧 host 无端点不致崩溃）。
  Future<({int positionMs, int updatedAtMs})> remoteAudiobookPosition(
    String bookKey,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}/position',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return (positionMs: 0, updatedAtMs: 0);
    }
    _ops!.checkStatus(
        res.statusCode, 'GET /api/library/audiobooks/$bookKey/position');
    final String body = await _readBodyBounded(res);
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return (
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 向 host 上报有声书 [bookKey] 的本端播放断点（BUG-471）。host 端取较新时间戳决定
  /// 是否覆盖。旧 peer 无此端点经 checkStatus 抛错由调用方逐项容错降级。
  Future<void> putRemoteAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}/position',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(jsonEncode(<String, Object?>{
      'positionMs': positionMs,
      'positionUpdatedAtMs': updatedAtMs,
    })));
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'PUT /api/library/audiobooks/$bookKey/position');
  }

  /// 读 host 端有声书 [identity] 的调轴（互联完整支持批次）。404（旧 host 无端点 /
  /// 有声书不存在）返回 (0, 0)，与 [remoteAudiobookPosition] 同款降级。
  Future<({int delayMs, int updatedAtMs})> remoteAudiobookDelay(
    String identity,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(identity)}/delay',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return (delayMs: 0, updatedAtMs: 0);
    }
    _ops!.checkStatus(
        res.statusCode, 'GET /api/library/audiobooks/$identity/delay');
    final String body = await _readBodyBounded(res);
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return (
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['delayUpdatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 向 host 上报有声书 [identity] 的调轴。host「严格较新时间戳者胜」；旧 host 无
  /// 端点经 checkStatus 抛错由调用方 best-effort 容错。
  Future<void> putRemoteAudiobookDelay(
    String identity,
    int delayMs,
    int updatedAtMs,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(identity)}/delay',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(jsonEncode(<String, Object?>{
      'delayMs': delayMs,
      'delayUpdatedAtMs': updatedAtMs,
    })));
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'PUT /api/library/audiobooks/$identity/delay');
  }

  // ── Remote videos (interconnect-only, read-only) ─────────────────────────
  // 视频只远程观看/可选下载，不参与双向同步。Host 的 /stream 端点使用短时
  // token URL，media_kit 可直接播放，不依赖自定义 HTTP header。

  /// 列出对端 host 当前视频清单（直打 `/api/library/videos`）。老 host 无该端点返回
  /// 404 时优雅降级返回空表（与 [getRemoteAggregate] / [getRemoteCollectionManifest]
  /// 的 404 降级同纪律——绝不因老 server 缺端点抛异常让整页占位卡消失/转圈）。请求
  /// 用 [requestTimeout] 封顶，防止 host 接受连接后卡住响应导致视频页无限等待。
  /// 拉取 host 最近活动事件（新首页 Activity 面板互联数据源；display-only）。
  /// 老 host 无此端点（404）降级空列表；坏条目逐条跳过不拖垮整表。
  Future<List<RemoteActivityEvent>> listRemoteActivity(
      {int limit = 100}) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!
        .buildRequest('GET', '$_apiBase/api/library/activity?limit=$limit');
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return const <RemoteActivityEvent>[]; // 老 host 无活动端点：降级空表。
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/library/activity');
    final String body = await _readBodyBounded(res);
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    final List<RemoteActivityEvent> events = <RemoteActivityEvent>[];
    for (final dynamic e in arr) {
      if (e is! Map) continue;
      final RemoteActivityEvent event =
          RemoteActivityEvent.fromJson(e.cast<String, Object?>());
      // 坏条目（缺核心字段）跳过：混排展示要求类型/标题/时刻齐全。
      if (event.eventType.isEmpty ||
          event.title.isEmpty ||
          event.timestampMs <= 0) {
        continue;
      }
      events.add(event);
    }
    return events;
  }

  @override

  /// 老 host 无视频端点 → 404 降级空表（不崩不转圈）；清单可能很慢，故超时封顶。
  Future<List<RemoteVideoInfo>> listRemoteVideos() => _listRemote(
        '/api/library/videos',
        RemoteVideoInfo.fromJson,
        degradeOn404: true,
      );

  /// 把本地视频 [file] 上传到对端 host，注册成 bookUid 为 [id] 的视频（client→host，
  /// syncVideoFiles 开关驱动的 live push）。[title] 与原始文件名经 URL-encode 走 header
  /// （HTTP header 只收 ASCII，日文标题/文件名必须编码）。流式发送、不整块读进内存
  /// （视频 GB 级），进度经 [onProgress] 上报。
  Future<void> putRemoteVideo(
    String id,
    File file, {
    required String title,
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}',
    );
    final int length = await file.length();
    final String baseName = file.path.split(RegExp(r'[/\\]')).last;
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    req.headers.set('X-Hibiki-Video-Title', Uri.encodeComponent(title));
    req.headers.set('X-Hibiki-Video-Filename', Uri.encodeComponent(baseName));
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/videos/$id');
  }

  /// 通知对端 host 删除 bookUid 为 [id] 的视频（远端视频卡长按删除 / 「从所有设备
  /// 删除」的墓碑推送）。
  ///
  /// 返回 true = host 已删除；false = 该 host 不支持视频删除（旧版本 app 无此端点，
  /// 或 host 库服务未实现 `VideoDeletionHost`，两者都表现为 404/405）。调用方据此
  /// 区分「删成了」与「对端不支持」——后者不该报错给用户、也不该标记墓碑已发布，
  /// 留待 host 升级后下次同步重试。其余失败照常抛（[WebDavOps.checkStatus]），
  /// 与 [putRemoteVideoSubtitle] 的旧 host 降级同款。
  Future<bool> deleteRemoteVideo(String id) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}',
    );
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    if (res.statusCode == 404 || res.statusCode == 405) return false;
    _ops!.checkStatus(res.statusCode, 'DELETE /api/library/videos/$id');
    return true;
  }

  /// 把视频 [id] 的一个外挂字幕 sidecar [file] 推给 host（BUG-964，随
  /// [putRemoteVideo] 的 live push 一起走）。[suffix] 是相对视频 stem 的字幕后缀
  /// （`.srt` / `.ja.srt` …，host 端按自己的视频文件名 stem + suffix 落盘）。
  ///
  /// 返回 true = host 已接收；false = 老 host 无此端点（404/405），调用方据此
  /// 停止本轮后续字幕推送并提示升级 host（与合集端点缺失同纪律）。其余失败
  /// 照常抛（[WebDavOps.checkStatus]）。
  Future<bool> putRemoteVideoSubtitle(
    String id,
    File file, {
    required String suffix,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/subtitle',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    req.headers.set('X-Hibiki-Subtitle-Suffix', Uri.encodeComponent(suffix));
    await req.addStream(file.openRead());
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    if (res.statusCode == 404 || res.statusCode == 405) return false;
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/videos/$id/subtitle');
    return true;
  }

  /// 向 host 换取可直接播放的视频 stream URL。
  ///
  /// 返回的 [RemoteVideoStreamUrls.streamUrl] 已携带短时 token；播放器不需要
  /// Authorization 头。字幕 URL（若存在）仍是普通受 Basic 鉴权的 API URL，UI
  /// 可先用 [getRemoteVideoSubtitle] 下载到本地后交给现有字幕加载逻辑。
  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    await _ensureResolved();
    final String encodedId = _encodeVideoId(id);
    final String query = episodeIndex > 0 ? '?episode=$episodeIndex' : '';
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/videos/$encodedId/streamurl$query',
    );
    final HttpClientResponse res = await _sendBounded(req);
    _ops!.checkStatus(res.statusCode, 'GET /api/library/videos/$id/streamurl');
    final String body = await _readBodyBounded(res);
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return RemoteVideoStreamUrls.fromJson(json);
  }

  /// media_kit 兼容接口：当前协议走 token URL，因此无需额外 HTTP headers。
  Map<String, String> remoteVideoAuthHeaders() => const <String, String>{};

  /// 下载对端视频外挂字幕到 [dest]。
  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final Map<String, String> query = <String, String>{
      if (embeddedStreamIndex != null)
        'embeddedStreamIndex': '$embeddedStreamIndex',
      if (episodeIndex > 0) 'episode': '$episodeIndex',
    };
    final Uri uri = Uri.parse(
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/subtitle',
    ).replace(queryParameters: query.isEmpty ? null : query);
    await downloadContentFile(
      fileId: uri.toString(),
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// BUG-1004：请求 host 在其**本地**裁出视频 [id] 的 `[startMs,endMs)` 段音频（mining 句子
  /// 音频），经已鉴权/钉扎的 [downloadContentFile] 通道落到 [dest]。host 用本地文件裁、不经
  /// 网络/TLS，从根上绕开「移动端 client ffmpeg 打不开 host 自签 https / token 流」的整类失败
  /// （BUG-891 残余缺口）。[audioChannels]/[audioBitrate] 对齐制卡压缩档，使 host 裁出的片段与
  /// 本地路径同规格；[audioStreamIndex]/[audioStreamCount] 选多音轨视频里用户当前听的轨。
  ///
  /// 老 host 无 `clipaudio` 端点 → 该子路径 GET 落 host 兜底 → 404 → [downloadContentFile]
  /// 抛可重试 `SyncBackendError`；调用方 catch 后回退直连 ffmpeg 抽取（Never break userspace）。
  Future<void> getRemoteVideoAudioClip(
    String id,
    File dest, {
    required int startMs,
    required int endMs,
    int episodeIndex = 0,
    int? audioStreamIndex,
    int? audioStreamCount,
    int audioChannels = 1,
    String audioBitrate = '64k',
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final Map<String, String> query = <String, String>{
      'startMs': '$startMs',
      'endMs': '$endMs',
      if (episodeIndex > 0) 'episode': '$episodeIndex',
      if (audioStreamIndex != null) 'audioStreamIndex': '$audioStreamIndex',
      if (audioStreamCount != null) 'audioStreamCount': '$audioStreamCount',
      'ac': '$audioChannels',
      'bitrate': audioBitrate,
    };
    final Uri uri = Uri.parse(
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/clipaudio',
    ).replace(queryParameters: query);
    await downloadContentFile(
      fileId: uri.toString(),
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// 整段下载对端视频到 [dest]（用于 UI 的「下载到本机」）。
  ///
  /// 下载走 host 签发的 token stream URL，避免依赖播放器/header 兼容性；失败时
  /// 复用 [downloadContentFile] 同款清理语义，不留下截断文件。
  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    final RemoteVideoStreamUrls urls = await remoteVideoStreamUrls(id);
    // 根因修复（TODO-819）：旧实现是裸 GET 无 Range，中断即整包删、
    // 下次从 0。host /stream 已支持 Range（serveFileWithRange → 206），故改走通用
    // ResumableDownloader：Range + 同目录 .part + 中断保留 part 可续传。LAN 单源
    // 不分片（单连接 Range 已足够，避免共享出口限流）。
    final File partFile = File('${dest.path}.part');
    await dest.parent.create(recursive: true);
    // TODO-961 M1: https 端点（_activeFingerprint 非空）走 pinned client；明文 http
    // 用裸 client（行为零变化）。stream token URL 自带鉴权，无需额外头。
    final String? fp = _activeFingerprint;
    final HttpClient client = fp != null && fp.isNotEmpty
        ? createPinnedHttpClient(expectedFingerprint: fp)
        : HttpClient();
    try {
      final ResumableDownloader downloader = ResumableDownloader(
        url: urls.streamUrl,
        destination: dest,
        partFile: partFile,
        open: (Uri uri, Map<String, String> headers) =>
            _openResumableRequest(client, uri, headers),
        // 弱网停顿超时：稳定视频文件首字节快（videoFirstByteTimeout），流内空闲超
        // downloadStallTimeout 即中断保 part 可续，不再无限等卡死连接。
        firstByteTimeout: videoFirstByteTimeout,
        bodyTimeout: downloadStallTimeout,
        onProgress: (int received, int? total) {
          if (total != null && total > 0) {
            onProgress?.call(received / total);
          }
        },
      );
      await downloader.download();
    } finally {
      client.close(force: true);
    }
  }

  /// ResumableDownloader 的注入缝：用 [client] 发一次带 [headers]（含 Range/If-Range）
  /// 的 GET，包成 [ResumableDownloadResponse]。token stream URL 自带鉴权，无需额外头。
  Future<ResumableDownloadResponse> _openResumableRequest(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest request = await client.openUrl('GET', uri);
    for (final MapEntry<String, String> entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final HttpClientResponse response = await request.close();
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      if (values.isNotEmpty) responseHeaders[name] = values.join(',');
    });
    return ResumableDownloadResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      stream: response,
    );
  }

  /// 读 host 端视频 [id] 的播放断点（TODO-653）。host 返回 404（视频不存在）或网络
  /// 异常时返回 (0, 0)，让调用方退回本地 prefs（离线/旧 host 不致崩溃）。
  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    await _ensureResolved();
    final String query = episodeIndex > 0 ? '?episode=$episodeIndex' : '';
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/position$query',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return (positionMs: 0, updatedAtMs: 0);
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/library/videos/$id/position');
    final String body = await _readBodyBounded(res);
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return (
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 向 host 上报视频 [id] 的本端播放断点（TODO-653）。host 端取较新时间戳决定覆盖。
  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    await _ensureResolved();
    final String query = episodeIndex > 0 ? '?episode=$episodeIndex' : '';
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/position$query',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(jsonEncode(<String, Object?>{
      'positionMs': positionMs,
      'positionUpdatedAtMs': updatedAtMs,
    })));
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/videos/$id/position');
  }

  /// 读 host 端视频 [id] 的字幕调轴（[RemoteVideoDelaySync]）。host 返回 404
  /// （旧 host 无端点 / 视频不存在）或网络异常时由调用方兜底——这里对 404 返回
  /// (0, 0)，与 [remoteVideoPosition] 同款降级。
  @override
  Future<({int delayMs, int updatedAtMs})> remoteVideoDelay(String id) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/delay',
    );
    final HttpClientResponse res = await _sendBounded(req);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return (delayMs: 0, updatedAtMs: 0);
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/library/videos/$id/delay');
    final String body = await _readBodyBounded(res);
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return (
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['delayUpdatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 向 host 上报视频 [id] 的字幕调轴（[RemoteVideoDelaySync]）。host 端「严格较新
  /// 时间戳者胜」决定覆盖；旧 host 无端点 → 404 经 checkStatus 抛，调用方 best-effort
  /// 捕获（本地 prefs 已持久化）。
  @override
  Future<void> putRemoteVideoDelay(
    String id,
    int delayMs,
    int updatedAtMs,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/delay',
    );
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.add(utf8.encode(jsonEncode(<String, Object?>{
      'delayMs': delayMs,
      'delayUpdatedAtMs': updatedAtMs,
    })));
    final HttpClientResponse res = await _sendBounded(req);
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/videos/$id/delay');
  }

  static String _encodeVideoId(String id) =>
      id.split('/').map(Uri.encodeComponent).join('/');

  // ── Test connection ───────────────────────────────────────────────

  /// 测试单个互联地址是否可用。[fingerprint] 是该地址 TOFU 钉扎的自签证书 SHA-256
  /// 指纹（https 端点必带，明文 http 为 null）。**必须**随地址一起传入：新版 host 默认
  /// 开 TLS（applyFirstHostingTlsDefault），刚配对的地址就是 https + 自签证书；不带
  /// 指纹的裸 WebDavOps 会在自签 TLS 握手处失败，把「其实能连」的 host 误报成
  /// 连接失败（TODO-1330 / BUG：测试连接对已配对 https host 恒失败）。指纹非空 →
  /// pinned client（仅接受指纹相等的自签证书）；null → 明文 http 老路径不变。
  Future<void> testConnection({
    required String url,
    required String token,
    String? fingerprint,
  }) async {
    final ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
      pinnedFingerprint: fingerprint,
    );
    try {
      await ops.testConnection();
    } finally {
      ops.close();
    }
  }
}
