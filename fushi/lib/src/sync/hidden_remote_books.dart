import 'dart:convert';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteBookInfo;
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 书架上「仅从本机移除」的一本远端书（反馈 nvlhtczbro）：只在本机隐藏占位卡，
/// 对端 / 云盘那份不动。找回列表（设置 › 同步 › 已从本机移除的远端书）按
/// [sourceId] 分组展示，所以除了身份键还记下书名与来源展示名。
class HiddenRemoteBook {
  const HiddenRemoteBook({
    required this.sourceId,
    required this.remoteId,
    required this.title,
    this.sourceLabel,
    this.hiddenAt = 0,
  });

  factory HiddenRemoteBook.of({
    required String sourceId,
    required RemoteBookInfo book,
    String? sourceLabel,
    int? hiddenAt,
  }) => HiddenRemoteBook(
    sourceId: sourceId,
    remoteId: book.downloadId,
    title: book.displayName,
    sourceLabel: sourceLabel,
    hiddenAt: hiddenAt ?? DateTime.now().millisecondsSinceEpoch,
  );

  /// 远端来源身份（[RemoteBookClient.remoteLibrarySourceId]）：互联对端与各云盘
  /// 书库互不牵连。
  final String sourceId;

  /// 远端身份键（[RemoteBookInfo.downloadId]，与下载 / 删除同键，BUG-414）。
  final String remoteId;

  /// 隐藏时的显示书名（找回列表用；远端书已不存在时仍能认出是哪本）。
  final String title;

  /// 隐藏时的来源展示名（互联 = 配对时记下的 host 名）；null = 按 [sourceId] 推导。
  final String? sourceLabel;

  final int hiddenAt;

  /// 去重 / 过滤用的键。
  String get key => hiddenRemoteBookKey(sourceId: sourceId, remoteId: remoteId);

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'remoteId': remoteId,
    'title': title,
    if (sourceLabel != null) 'sourceLabel': sourceLabel,
    'hiddenAt': hiddenAt,
  };

  static HiddenRemoteBook? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? sourceId = json['sourceId'];
    final Object? remoteId = json['remoteId'];
    if (sourceId is! String || remoteId is! String) return null;
    final Object? title = json['title'];
    final Object? label = json['sourceLabel'];
    final Object? at = json['hiddenAt'];
    return HiddenRemoteBook(
      sourceId: sourceId,
      remoteId: remoteId,
      title: title is String && title.isNotEmpty ? title : remoteId,
      sourceLabel: label is String && label.isNotEmpty ? label : null,
      hiddenAt: at is int ? at : 0,
    );
  }
}

/// 隐藏清单的键：来源身份 + 远端身份键。
String hiddenRemoteBookKey({
  required String sourceId,
  required String remoteId,
}) => '$sourceId/${Uri.encodeComponent(remoteId)}';

/// 解析偏好里的隐藏清单（JSON 数组）；坏值按空清单处理，同键只留第一条。
List<HiddenRemoteBook> decodeHiddenRemoteBooks(String? raw) {
  if (raw == null || raw.isEmpty) return const <HiddenRemoteBook>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <HiddenRemoteBook>[];
  }
  if (decoded is! List) return const <HiddenRemoteBook>[];
  final Set<String> seen = <String>{};
  return <HiddenRemoteBook>[
    for (final Object? e in decoded)
      if (HiddenRemoteBook.fromJson(e) case final HiddenRemoteBook book
          when seen.add(book.key))
        book,
  ];
}

String encodeHiddenRemoteBooks(List<HiddenRemoteBook> books) =>
    jsonEncode(<Map<String, Object?>>[
      for (final HiddenRemoteBook book in books) book.toJson(),
    ]);

/// 书架当前的远端书来源：互联开启且鉴权成功 → 互联对端；否则云盘备份后端；都没有
/// → null。书架与「已从本机移除的远端书」列表共用这一条判定。
Future<RemoteBookClient?> resolveShelfRemoteBookClient(
  FushiDatabase database,
) async {
  final SyncRepository syncRepo = SyncRepository(database);
  if (await syncRepo.isInterconnectEnabled()) {
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    if (await backend.restoreAuth(syncRepo)) return backend;
  }
  final SyncBackendType type = await syncRepo.getBackendType();
  final SyncBackend backend = resolveSyncBackend(type);
  if (!await backend.restoreAuth(syncRepo)) return null;
  final String rootFolderId = await backend.findOrCreateRootFolder();
  return CloudRemoteBookClient(
    backend: backend,
    backendType: type,
    rootFolderId: rootFolderId,
  );
}
