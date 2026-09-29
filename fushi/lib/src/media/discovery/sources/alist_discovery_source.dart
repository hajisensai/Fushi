/// AList v3 站点的发现源 adapter：标准 `/api/fs/list`（目录浏览）、
/// `/api/fs/search`（关键词搜索，站点开了索引才可用）、`/api/fs/get`
/// （下载时延迟取 `raw_url` 直链——签名临期，列表阶段取了也会过期）。
///
/// 一个实例 = 一个 AList 站；内置 alist.erogame.space，用户加任意站 = 再
/// 注册一个实例。匿名访问；站点要求登录时可给 [username]/[password]，
/// 首次请求前换 token（`/api/auth/login`），token 失效重登一次。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/alist/alist_api_client.dart';
import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';

/// 用户自配站点的源 id 前缀（内置站是 `alist-erogame`，同前缀不同 id 空间：
/// 自配 id 由 UI 生成为 `site-<微秒>`，不会与内置站撞名）。
const String kAListSourceIdPrefix = 'alist-';

String alistSourceIdFor(String configId) => '$kAListSourceIdPrefix$configId';

class AListDiscoverySource extends MediaDiscoverySource {
  AListDiscoverySource({
    required this.id,
    required this.displayName,
    required String baseUrl,
    required Iterable<DiscoveryMediaKind> kinds,
    this.priority = 20,
    this.username,
    this.password,
    this.isUserConfigured = false,
    http.Client? client,
  })  : _kinds = Set<DiscoveryMediaKind>.unmodifiable(kinds),
        _api = AListApiClient(
          baseUrl: baseUrl,
          providerId: id,
          username: username,
          password: password,
          client: client,
        );

  /// 由用户自配站点建源：id 从配置派生、域按用户声明、空账号 = 游客访问。
  /// 自配站排在内置源之后（priority 30），与 OPDS 自配源同档。
  AListDiscoverySource.fromConfig(
    AListSiteConfig config, {
    http.Client? client,
  }) : this(
          id: alistSourceIdFor(config.id),
          displayName: config.displayName,
          baseUrl: config.origin,
          kinds: config.kinds,
          priority: 30,
          username: config.username.trim().isEmpty ? null : config.username,
          password: config.password,
          isUserConfigured: true,
          client: client,
        );

  @override
  final String id;

  @override
  final String displayName;

  @override
  final int priority;

  @override
  final bool isUserConfigured;

  final String? username;
  final String? password;

  final Set<DiscoveryMediaKind> _kinds;

  /// 信封校验 / token / 401 重登都在这里（与媒体库 `alist` 来源共用）。
  final AListApiClient _api;

  /// search 结果路径相对 `fs/list` 命名空间多出来的前缀，已归一：无前缀时为空串。
  ///
  /// BUG-1771：AList 的 `/api/fs/search` 返回的 `parent` 在**用户根命名空间**里
  /// （erogame.space 的 guest 是 `/guest`），而 `/api/fs/list` 与 `/api/fs/get`
  /// 收的是**相对该根**的路径。原样把 search 的 `parent` 当路径用，站点对每一条
  /// 都回 `object not found` —— 搜索结果里的目录一个都打不开、文件一个都下不了。
  /// 实测：`/guest/其他/…/Leaf/WHITE ALBUM2` → 500 object not found；
  /// 剥掉 `/guest` 后 → 200，`fs/get` 拿到真实 `raw_url`。
  /// null = 还没推断出结论（下次继续试）；`''` = 推断过、和搜索结果同命名空间、
  /// 无需剥；`'/guest'` = 推断过、要剥这一段。
  ///
  /// 刻意用可空而不是「`''` + 一个 _basePathProbed 布尔」：那样 `''` 同时背着
  /// 「没推断」和「推断出无需剥」两个意思，两份状态一旦不同步就会出现「一次探测
  /// 失败即永久放弃」——而失败恰恰是最该重试的情形。合成一份就没有这个边界。
  String? _basePath;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: _kinds,
        supportsBrowse: true,
        supportsPaging: true,
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    final String path = request.path ?? '/';
    final AListPage result = await _api.list(
      path,
      page: request.page,
      perPage: request.pageSize,
    );
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final AListEntry entry in result.entries)
              _entryFrom(entry, parent: path, kind: request.kind),
          ],
          page: request.page,
          hasMore: request.page * request.pageSize < result.total,
        ),
      ],
    );
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    final AListPage result = await _api.search(
      request.query!.trim(),
      page: request.page,
      perPage: request.pageSize,
    );
    // 先拿本次结果里的 parent 当样本反推命名空间前缀，再逐条转换（BUG-1771）。
    // 推断失败只是不剥前缀，不影响本次搜索返回。
    await _ensureBasePath(<String>[
      for (final AListEntry entry in result.entries)
        if (entry.parent case final String parent) parent,
    ]);
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final AListEntry entry in result.entries)
              _entryFrom(
                entry,
                parent: _stripBasePath(entry.parent ?? '/'),
                kind: request.kind,
              ),
          ],
          page: request.page,
          hasMore: request.page * request.pageSize < result.total,
        ),
      ],
    );
  }

  /// 下载时经 `/api/fs/get` 取带签名的 `raw_url`。
  @override
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    final AListFileLink link = await _api.getFile(item.id);
    return DiscoveryHttpPayload(
      url: link.rawUrl,
      fileName: link.name,
      sizeBytes: link.sizeBytes,
    );
  }

  DiscoveryEntry _entryFrom(
    AListEntry entry, {
    required String parent,
    required DiscoveryMediaKind kind,
  }) {
    final String name = entry.name;
    final String fullPath = parent == '/' ? '/$name' : '$parent/$name';
    if (entry.isDir) {
      return DiscoveryFolder(sourceId: id, title: name, path: fullPath);
    }
    final String? modified = entry.modified;
    return DiscoveryResourceItem(
      sourceId: id,
      id: fullPath,
      title: name,
      kind: kind,
      payloadKind: DiscoveryPayloadKind.httpFile,
      // payload 留空 → 下载时 resolvePayload 取临期直链。
      sizeBytes: entry.sizeBytes,
      dateText: modified != null && modified.length >= 10
          ? modified.substring(0, 10)
          : modified,
    );
  }

  /// 反推 search 命名空间相对 `fs/list` 命名空间多出来的前缀。
  ///
  /// 判据只用**本来就必须能用**的 `fs/list '/'`：真实根下的第一层名字一定会出现在
  /// search 的 `parent` 里，它**之前**的那一段就是前缀。例如根是 `[其他, 年份合集]`、
  /// parent 是 `/guest/其他/…`，`其他` 落在第 2 段，于是前缀 = `/guest`。
  ///
  /// 为什么不问 `/api/me`（它直接给 `base_path`）：本机实测 alist.erogame.space 的
  /// `/api/me` **直连 3/3 连接超时**，而同一时刻 `fs/list` / `fs/search` /
  /// `/api/public/settings` / 首页都正常。拿一个可能连不上的端点当前置依赖，
  /// 结果是每次首搜先白等一个连接超时，然后照样拿不到前缀——比不做还差。
  /// 这里改成只依赖已有链路，且推断失败就退回「不剥前缀」的老行为。
  Future<void> _ensureBasePath(Iterable<String> sampleParents) async {
    if (_basePath != null) return;
    final List<String> samples = sampleParents
        .where((String p) => p.startsWith('/') && p.length > 1)
        .toList(growable: false);
    if (samples.isEmpty) return; // 没样本，下次再推
    // 注意：这里不做任何「已尝试」标记。下面每条不产生结论的出口（根目录列不出、
    // 样本一个都对不上、网络异常）都必须让 _basePath 保持 null，否则本会话再也
    // 不会重推，而搜索结果的目录会一直打不开。只有两个 return 才算有结论。
    try {
      final AListPage root = await _api.list('/', perPage: 200);
      final Set<String> rootNames = <String>{
        for (final AListEntry entry in root.entries) entry.name,
      };
      if (rootNames.isEmpty) return;
      for (final String parent in samples) {
        final List<String> segments = parent
            .split('/')
            .where((String s) => s.isNotEmpty)
            .toList(growable: false);
        final int hit = segments.indexWhere(rootNames.contains);
        if (hit < 0) continue; // 这条对不上，看下一条
        if (hit == 0) {
          _basePath = ''; // 已经在同一命名空间，无需剥
          return;
        }
        _basePath = '/${segments.take(hit).join('/')}';
        return;
      }
    } catch (_) {
      // 根目录列不出来（站点只开搜索、网络抖动、信封变形）：拿不到前缀而已，
      // 不是源不可用——本次搜索照常返回，只是路径保持原样。
    }
  }

  /// 把 search 返回的、带 [_basePath] 前缀的路径转成 `fs/list`/`fs/get` 能用的路径。
  /// 不带该前缀的路径原样返回（站点未启用用户根，或已是相对路径）。
  String _stripBasePath(String path) {
    final String base = _basePath ?? '';
    if (base.isEmpty) return path;
    if (path == base) return '/';
    if (path.startsWith('$base/')) {
      final String rest = path.substring(base.length);
      return rest.isEmpty ? '/' : rest;
    }
    return path;
  }

  @override
  void close() => _api.close();
}
