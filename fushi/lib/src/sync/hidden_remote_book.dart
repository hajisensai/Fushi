import 'dart:convert';

import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteBookInfo;

/// 书架上「仅从本机移除」的一本远端书（反馈 nvlhtczbro）：只在本机隐藏占位卡，
/// 对端 / 云盘那份不动。找回列表（设置 › 同步 › 已从本机移除的远端书）按
/// [sourceId]（互联再按 [sourceHost]）分组展示，所以除了身份键还记下书名与来源
/// 展示名。
class HiddenRemoteBook {
  const HiddenRemoteBook({
    required this.sourceId,
    required this.remoteId,
    required this.title,
    this.sourceHost,
    this.sourceLabel,
    this.hiddenAt = 0,
  });

  factory HiddenRemoteBook.of({
    required String sourceId,
    required RemoteBookInfo book,
    String? sourceHost,
    String? sourceLabel,
    int? hiddenAt,
  }) => HiddenRemoteBook(
    sourceId: sourceId,
    remoteId: book.downloadId,
    title: book.displayName,
    sourceHost: sourceHost,
    sourceLabel: sourceLabel,
    hiddenAt: hiddenAt ?? DateTime.now().millisecondsSinceEpoch,
  );

  /// 远端来源身份（[RemoteBookClient.remoteLibrarySourceId]）：互联对端与各云盘
  /// 书库互不牵连。
  final String sourceId;

  /// 远端身份键（[RemoteBookInfo.downloadId]，与下载 / 删除同键，BUG-414）。
  final String remoteId;

  /// 互联来源的对端身份（[describeInterconnectHost] 的 `identity`：配对地址行的
  /// hostId，没有就用当时的 base URL）。互联的 [sourceId] 全局只有一个
  /// `interconnect`，不带它的话在 A 机隐藏的书换到 B 机也会被藏、找回列表还会拿 B 的
  /// 书目判 A 的书「远端已不存在」。null = 云盘来源，或升级前记下的旧条目（不分对端）。
  final String? sourceHost;

  /// 隐藏时的显示书名（找回列表用；远端书已不存在时仍能认出是哪本）。
  final String title;

  /// 隐藏时的来源展示名（互联 = 配对时记下的 host 名）；null = 按 [sourceId] 推导。
  final String? sourceLabel;

  final int hiddenAt;

  /// 去重用的键。
  String get key => hiddenRemoteBookKey(
    sourceId: sourceId,
    sourceHost: sourceHost,
    remoteId: remoteId,
  );

  /// 本条是否隐藏 [sourceId] / [sourceHost] 来源上的 [remoteId] 这本书。旧条目
  /// （[sourceHost] 为 null）不分对端，保持升级前的行为。
  bool hides({
    required String sourceId,
    required String? sourceHost,
    required String remoteId,
  }) =>
      this.sourceId == sourceId &&
      this.remoteId == remoteId &&
      (this.sourceHost == null || this.sourceHost == sourceHost);

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'remoteId': remoteId,
    'title': title,
    if (sourceHost != null) 'sourceHost': sourceHost,
    if (sourceLabel != null) 'sourceLabel': sourceLabel,
    'hiddenAt': hiddenAt,
  };

  static HiddenRemoteBook? fromJson(Object? json) {
    // 本 PR 上一版只存键串（`来源身份/编码后的远端身份键`），读进来别丢。
    if (json is String) return _fromLegacyKey(json);
    if (json is! Map) return null;
    final Object? sourceId = json['sourceId'];
    final Object? remoteId = json['remoteId'];
    if (sourceId is! String || remoteId is! String) return null;
    final Object? title = json['title'];
    final Object? host = json['sourceHost'];
    final Object? label = json['sourceLabel'];
    final Object? at = json['hiddenAt'];
    return HiddenRemoteBook(
      sourceId: sourceId,
      remoteId: remoteId,
      title: title is String && title.isNotEmpty ? title : remoteId,
      sourceHost: host is String && host.isNotEmpty ? host : null,
      sourceLabel: label is String && label.isNotEmpty ? label : null,
      hiddenAt: at is int ? at : 0,
    );
  }

  static HiddenRemoteBook? _fromLegacyKey(String key) {
    final int slash = key.lastIndexOf('/');
    if (slash <= 0 || slash == key.length - 1) return null;
    final String remoteId;
    try {
      remoteId = Uri.decodeComponent(key.substring(slash + 1));
    } on ArgumentError {
      return null;
    }
    return HiddenRemoteBook(
      sourceId: key.substring(0, slash),
      remoteId: remoteId,
      title: remoteId,
    );
  }
}

/// 隐藏清单的去重键：来源身份（互联再加对端身份）+ 远端身份键。
String hiddenRemoteBookKey({
  required String sourceId,
  String? sourceHost,
  required String remoteId,
}) {
  final String source = sourceHost == null
      ? sourceId
      : '$sourceId@${Uri.encodeComponent(sourceHost)}';
  return '$source/${Uri.encodeComponent(remoteId)}';
}

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
