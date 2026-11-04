import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart'
    show syncFolderIdEmbedsLegacyRoot;
import 'package:fushi/src/sync/hidden_remote_book.dart';

/// [hidden] 里是否有条目隐藏了这本远端书（书架过滤占位卡用）。
bool isRemoteBookHidden(
  List<HiddenRemoteBook> hidden, {
  required String sourceId,
  required String? sourceHost,
  required String remoteId,
}) => hidden.any(
  (HiddenRemoteBook h) =>
      h.hides(sourceId: sourceId, sourceHost: sourceHost, remoteId: remoteId),
);

/// 当前互联对端的身份与展示名。
///
/// `identity`：与 [baseUrl] 对得上的配对地址行的 hostId（同一台 host 的多条地址共用
/// 一个），没有就用 [baseUrl] 本身；[baseUrl] 为 null 时也是 null。
/// `label`：配对时记下的对端名，没有就用地址的主机名。
({String? identity, String label}) describeInterconnectHost(
  List<FushiClientUrl> urls,
  String? baseUrl,
) {
  String? hostId;
  String? name;
  if (baseUrl != null) {
    for (final FushiClientUrl url in urls) {
      if (url.url != baseUrl) continue;
      final String? id = url.hostId?.trim();
      final String? n = url.deviceName?.trim();
      if (hostId == null && id != null && id.isNotEmpty) hostId = id;
      if (name == null && n != null && n.isNotEmpty) name = n;
    }
  }
  final String? host = baseUrl == null ? null : Uri.tryParse(baseUrl)?.host;
  return (
    identity: hostId ?? baseUrl,
    label: name ?? ((host == null || host.isEmpty) ? (baseUrl ?? '?') : host),
  );
}

/// [client] 是互联对端时它的身份（见 [describeInterconnectHost]），否则 null。
Future<String?> remoteBookSourceHost(
  FushiDatabase database,
  RemoteBookClient client,
) async {
  if (client.remoteLibrarySourceId != kInterconnectRemoteLibrarySourceId ||
      client is! InterconnectSyncBackend) {
    return null;
  }
  final List<FushiClientUrl> urls = await SyncRepository(
    database,
  ).getFushiClientUrls();
  return describeInterconnectHost(urls, client.resolvedHostBaseUrl).identity;
}

/// 书架当前的远端书来源：互联开启且鉴权成功 → 互联对端；否则云盘备份后端；都没有
/// → null。书架与「已从本机移除的远端书」列表共用这一条判定。
///
/// [createRootFolder] = false 给只读查询用（「已从本机移除的远端书」列表核对书还在
/// 不在）：云盘同步根只用本会话已解析过的 / 上次同步落盘的那个，一个都没有就返回
/// null，**不**去远端建目录、也不跑旧根改名迁移（BUG-3245：以前光是打开设置页就会
/// 在用户云盘上建出同步根）。
Future<RemoteBookClient?> resolveShelfRemoteBookClient(
  FushiDatabase database, {
  bool createRootFolder = true,
}) async {
  final SyncRepository syncRepo = SyncRepository(database);
  if (await syncRepo.isInterconnectEnabled()) {
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    if (await backend.restoreAuth(syncRepo)) return backend;
  }
  // 云备份通道被用户关掉时不回落到云盘（与同步通道枚举同一判据）。
  if (!await syncRepo.isCloudSyncEnabled()) return null;
  final SyncBackendType type = await syncRepo.getBackendType();
  final SyncBackend backend = resolveSyncBackend(type);
  if (!await backend.restoreAuth(syncRepo)) return null;
  final String? rootFolderId = createRootFolder
      ? await backend.findOrCreateRootFolder()
      : await _knownRootFolderId(syncRepo, backend);
  if (rootFolderId == null) return null;
  return CloudRemoteBookClient(
    backend: backend,
    backendType: type,
    rootFolderId: rootFolderId,
    database: database,
  );
}

/// 不碰远端就知道的同步根：本会话已解析过的，或上次同步落盘的（嵌着改名前旧根名的
/// 陈旧路径不算，与 `SyncFolderCache.restoreCache` 同一口径）。
Future<String?> _knownRootFolderId(
  SyncRepository syncRepo,
  SyncBackend backend,
) async {
  final String? cached = backend.cachedRootFolderId;
  if (cached != null) return cached;
  final String? persisted = await syncRepo.getRootFolderId(
    syncChannelScopeOf(backend),
  );
  if (persisted == null || syncFolderIdEmbedsLegacyRoot(persisted)) {
    return null;
  }
  return persisted;
}
