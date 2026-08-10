import 'package:fushi/src/media/media_source.dart'
    show MediaSource, dbSourcePrefKey;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource, kReaderSourcePersistedKey;
import 'package:fushi_core/fushi_core.dart';

/// 一本书的显示名覆盖（用户改的名字）+ 它的 LWW 毫秒戳。
///
/// 戳来自 `preferences.updated_at`（v84 / BUG-1502）。**0 =「时刻未知」**：v84
/// 迁移前就改好、之后没再动过的存量行。收到 0 的一方按 LWW 平局处理（保留本机）。
typedef OverrideTitleEntry = ({String title, int updatedAt});

/// 全库「bookKey → 显示名 + 戳」的**唯一查询实现**。
///
/// 互联的两个方向都要读它，各写一份必然漂：
///  - host 下发书清单（`AppModelLibraryHostService.listBooks` 填
///    `RemoteBookInfo.displayTitle` / `displayTitleAt`，BUG-1488 + BUG-1502）；
///  - client 推书给 host（`SyncOrchestrator._syncBooksContentLive` 填
///    `putRemoteBook` 的两个 header，BUG-1503）。
///
/// 一趟全表扫（偏好表本就整表加载进各源的内存缓存），按 `override_title://`
/// 命名空间前缀过滤。清除改名写的是 **null 值行**而不是删行，所以解出来非 String
/// 即「无 override」，必须跳过——否则会把「清掉的名字」当成一次改名发出去。
Future<Map<String, OverrideTitleEntry>> readOverrideTitlesByBookKey(
  FushiDatabase db,
) async {
  final String prefix = dbSourcePrefKey(
    kReaderSourcePersistedKey,
    MediaSource.overrideTitleKeyFor(ReaderFushiSource.mediaIdentifierFor('')),
  );
  final Map<String, OverrideTitleEntry> out = <String, OverrideTitleEntry>{};
  for (final PreferenceRow row in await db.getAllPrefRows()) {
    if (!row.key.startsWith(prefix)) continue;
    final String bookKey = row.key.substring(prefix.length);
    if (bookKey.isEmpty) continue;
    final Object? decoded = PrefCodec.decodeUntyped(row.value);
    if (decoded is! String || decoded.isEmpty) continue;
    out[bookKey] = (title: decoded, updatedAt: row.updatedAt);
  }
  return out;
}
