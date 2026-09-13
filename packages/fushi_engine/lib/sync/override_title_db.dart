/// 只写 DB 的书名覆盖采纳（无头服务端用）。
///
/// app 侧 `MediaSource.adoptOverrideTitleIfNewer` 还要写穿内存偏好缓存与收敛
/// BUG-1317 旧键；服务端没有内存缓存，也没有旧键存量（库从零建），所以只剩
/// LWW 一步：`setPrefIfNewer`（严格更新才覆盖、平局保留本机、无行则采纳）。
/// 键的拼法与 `override_title_lookup.dart` 读侧同源。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_pref_keys.dart';

Future<bool> adoptOverrideTitleInDb(
  FushiDatabase db, {
  required String bookKey,
  required String title,
  required int updatedAt,
}) {
  if (bookKey.isEmpty || title.isEmpty) return Future<bool>.value(false);
  final String key = dbSourcePrefKey(
    kReaderSourcePersistedKey,
    overrideTitleKeyFor(readerBookMediaIdentifierFor(bookKey)),
  );
  return db.setPrefIfNewer(key, PrefCodec.encode(title), updatedAt: updatedAt);
}
