/// 远端书来源的对端身份：互联对端用配对时记下的 hostId（没有就用地址），其它来源无身份。
///
/// 从 hidden_remote_books.dart 拆出：那边的 [resolveShelfRemoteBookClient] 要 import
/// 云盘远端书客户端（经同步编排连到 AppModel），只想要「对端是谁」的有声书版本记录
/// （remote_audiobook_revision_store.dart）会因此被拖进 import 大环（import_cycle_guard）。
library;

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart'
    show kInterconnectRemoteLibrarySourceId;
import 'package:fushi/src/sync/sync_repository.dart';

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
