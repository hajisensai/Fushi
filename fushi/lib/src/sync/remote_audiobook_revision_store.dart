/// 「从互联对端下载的有声书是哪一版」的读写，以及**唯一**的记录入口
/// [recordRemoteAudiobookPackageDownload]：书架手动下载 / 重新下载、同步 sweep 自动
/// 补拉、同步对比页补拉，整包下载导入成功后都经它记一次。
///
/// 只读写数据库里的偏好行（同 `DeletePromptPreferenceStore`），不经
/// `PreferencesRepository` 的内存缓存：同步编排没有那个实例，绕开它写 DB 会让缓存
/// 读到旧值。
library;

import 'dart:io';

import 'package:fushi/src/sync/hidden_remote_books.dart'
    show remoteBookSourceHost;
import 'package:fushi/src/sync/remote_audiobook_revision.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/sync/sync_asset_package_service.dart'
    show SyncAssetPackageService;

/// 设备本地偏好 [kInterconnectAudiobookRevisionsPrefKey] 的读写。
class RemoteAudiobookRevisionStore {
  const RemoteAudiobookRevisionStore(this._db);

  final FushiDatabase _db;

  Future<Map<String, RemoteAudiobookRevisionRecord>> load() async =>
      decodeRemoteAudiobookRevisions(
        await _db.getPref(kInterconnectAudiobookRevisionsPrefKey) ?? '',
      );

  /// 记下（[record] 非空）或删掉（null）本机身份键 [key] 的下载版本。
  ///
  /// 整张表是一个偏好值，书架下载与同步 sweep 可能同时记不同的书：读改写放进一个
  /// 数据库事务（drift 在唯一写连接上串行化事务，内层 `setPref` 并入这个事务），
  /// 两次写不会互相覆盖。
  Future<void> put(String key, RemoteAudiobookRevisionRecord? record) =>
      _db.transaction(() async {
        final Map<String, RemoteAudiobookRevisionRecord> next =
            Map<String, RemoteAudiobookRevisionRecord>.of(await load());
        if (record == null) {
          next.remove(key);
        } else {
          next[key] = record;
        }
        await _db.setPref(
          kInterconnectAudiobookRevisionsPrefKey,
          encodeRemoteAudiobookRevisions(next),
        );
      });
}

/// 下载记录里的「来源」：来源种类 + 互联对端身份（[remoteBookSourceHost]）。互联的
/// 来源 id 对所有对端都是同一个常量，换配对另一台 host 后同一本书的内容版本天然
/// 不同（路径不同），只按来源 id 比会误报「有更新」。
Future<String> remoteAudiobookRevisionSource(
  FushiDatabase db,
  RemoteBookClient client,
) async =>
    '${client.remoteLibrarySourceId}|'
    '${await remoteBookSourceHost(db, client) ?? ''}';

/// 一次**整包**有声书下载导入成功后，记下本机拿到的是 host 哪一版内容。
///
/// 版本取自包本身（[package] 的 manifest `contentRevision`，host 打包时算的），不取
/// 书架缓存的清单：清单在 TTL 内可能比包旧。旧 host 打的包没有版本 → 不记（之后也就
/// 不提示）。只更新字幕的重新拉取**不**调这里：它没换音频，记下 host 当前版本会把
/// 「host 也换了音频」藏起来。
///
/// 记录失败不让已成功的下载变失败：记进错误日志，书只是少一次「有更新」提示。
Future<void> recordRemoteAudiobookPackageDownload({
  required FushiDatabase db,
  required RemoteBookClient client,
  required String key,
  required File package,
}) async {
  try {
    final String? revision =
        await SyncAssetPackageService.readAudioPackageContentRevision(package);
    if (revision == null) return;
    await RemoteAudiobookRevisionStore(db).put(
      key,
      RemoteAudiobookRevisionRecord(
        sourceId: await remoteAudiobookRevisionSource(db, client),
        revision: revision,
      ),
    );
  } catch (e, stack) {
    ErrorLogService.instance.log(
      'recordRemoteAudiobookPackageDownload',
      e,
      stack,
    );
  }
}
