/// 从互联对端下载的有声书「下载时是哪个内容版本」：本机记下 host 清单里的
/// `RemoteAudiobookInfo.contentRevision`，之后清单里的值不同 = host 上换过音频 /
/// 字幕，书架提示「有更新」、可重新下载。
///
/// 存在一个设备本地偏好（`interconnect_audiobook_revisions`，JSON）里：互联下载没有
/// 落库的下载记录（`InterconnectDownloadManager` 的任务只在内存里），而加列是跨端
/// schema 迁移。键是本机身份：EPUB 有声书按本机 bookKey，纯字幕书按 uid
/// （[remoteAudiobookRevisionKeyForBook] / [remoteAudiobookRevisionKeyForSrt]）。
library;

import 'dart:convert';

/// 一条下载记录：从哪个来源下的（来源种类 + 互联对端身份，书架页拼好传进来）、
/// 当时 host 报的内容版本。
class RemoteAudiobookRevisionRecord {
  const RemoteAudiobookRevisionRecord({
    required this.sourceId,
    required this.revision,
  });

  final String sourceId;
  final String revision;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': sourceId,
    'rev': revision,
  };

  static RemoteAudiobookRevisionRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? source = raw['source'];
    final Object? rev = raw['rev'];
    if (source is! String || rev is! String) return null;
    if (source.isEmpty || rev.isEmpty) return null;
    return RemoteAudiobookRevisionRecord(sourceId: source, revision: rev);
  }
}

/// EPUB 有声书（本机 bookKey）的记录键。
String remoteAudiobookRevisionKeyForBook(String localBookKey) =>
    'book:$localBookKey';

/// 纯字幕书（uid）的记录键。
String remoteAudiobookRevisionKeyForSrt(String uid) => 'srt:$uid';

/// 解码偏好里的 JSON；空串 / 坏 JSON / 坏条目一律跳过（不抛）。
Map<String, RemoteAudiobookRevisionRecord> decodeRemoteAudiobookRevisions(
  String raw,
) {
  if (raw.isEmpty) return const <String, RemoteAudiobookRevisionRecord>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <String, RemoteAudiobookRevisionRecord>{};
  }
  if (decoded is! Map) return const <String, RemoteAudiobookRevisionRecord>{};
  return <String, RemoteAudiobookRevisionRecord>{
    for (final MapEntry<Object?, Object?> e in decoded.entries)
      if (e.key case final String key)
        if (RemoteAudiobookRevisionRecord.fromJson(e.value)
            case final RemoteAudiobookRevisionRecord record)
          key: record,
  };
}

/// [decodeRemoteAudiobookRevisions] 的逆；空表编码成空串（偏好被删掉）。
String encodeRemoteAudiobookRevisions(
  Map<String, RemoteAudiobookRevisionRecord> records,
) => records.isEmpty
    ? ''
    : jsonEncode(<String, Object?>{
        for (final MapEntry<String, RemoteAudiobookRevisionRecord> e
            in records.entries)
          e.key: e.value.toJson(),
      });

/// host 上的内容是否比本机下载的那一份新：只有「本机记过、来源相同、host 报了版本、
/// 两者不同」才算。没记过（这项功能之前下的书、本机自己导入的书）、换了来源、
/// 旧 host 不报版本，一律不提示——不知道就不说。
bool remoteAudiobookUpdateAvailable({
  required RemoteAudiobookRevisionRecord? stored,
  required String sourceId,
  required String? remoteRevision,
}) =>
    stored != null &&
    remoteRevision != null &&
    remoteRevision.isNotEmpty &&
    stored.sourceId == sourceId &&
    stored.revision != remoteRevision;

/// 书架上哪些本机有声书该提示「对端有更新」，返回记录键集合。
///
/// [bookRefetch]：本机 bookKey → 对端身份（EPUB 有声书的「重新拉取」候选）；
/// [srtRefetchUids]：本机已有、对端也有的纯字幕书 uid（身份就是 uid）；
/// [remoteRevisions]：对端清单里 身份 → `contentRevision`。
Set<String> remoteAudiobookUpdateKeys({
  required Map<String, String> bookRefetch,
  required Iterable<String> srtRefetchUids,
  required Map<String, String> remoteRevisions,
  required Map<String, RemoteAudiobookRevisionRecord> stored,
  required String sourceId,
}) {
  final Set<String> out = <String>{};
  void check(String key, String identity) {
    if (remoteAudiobookUpdateAvailable(
      stored: stored[key],
      sourceId: sourceId,
      remoteRevision: remoteRevisions[identity],
    )) {
      out.add(key);
    }
  }

  for (final MapEntry<String, String> e in bookRefetch.entries) {
    check(remoteAudiobookRevisionKeyForBook(e.key), e.value);
  }
  for (final String uid in srtRefetchUids) {
    check(remoteAudiobookRevisionKeyForSrt(uid), uid);
  }
  return out;
}
