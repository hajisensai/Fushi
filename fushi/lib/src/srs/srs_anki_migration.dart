/// 「从 Anki 迁移」的逻辑层（UI 见 pages/implementations/srs/srs_anki_migration_page.dart）。
///
/// 两条来源，最后都收敛到 [runSrsAnkiMigration] 这一个函数（以后接后台导入任务只改它）：
/// - [SrsAnkiMigrationFromCollection]：本机 Anki（桌面）/ AnkiDroid（Android 旧默认目录）
///   的用户数据目录里的集合，先拍只读快照（fushi_engine 的 anki_collection_snapshot.dart）；
/// - [SrsAnkiMigrationFromPackage]：用户在 Anki / AnkiDroid / AnkiMobile 里导出的
///   .colpkg / .apkg（所有平台都能走，iOS 只有这一条）。
///
/// 迁移固定用 [kSrsAnkiMigrationOptions]：带排程与复习记录、带牌组预设，其余与 Anki 默认一致。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/srs/srs_media_store.dart';

export 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';

/// 迁移用的导入选项：复习进度（排程 + revlog）与牌组预设都带上；笔记类型不一致时另建一份
/// （不改本机已有的笔记类型），已有笔记「较新时更新」——与 Anki 导入页默认相同。
const SrsAnkiImportOptions kSrsAnkiMigrationOptions = SrsAnkiImportOptions(
  withScheduling: true,
  withDeckConfigs: true,
);

/// 一次迁移的来源。
sealed class SrsAnkiMigrationSource {
  const SrsAnkiMigrationSource();
}

/// 本机集合的快照（调用方负责 [AnkiCollectionSnapshot.discard]）。
final class SrsAnkiMigrationFromCollection extends SrsAnkiMigrationSource {
  const SrsAnkiMigrationFromCollection(this.snapshot);

  final AnkiCollectionSnapshot snapshot;
}

/// 导出的 .colpkg / .apkg 文件。
final class SrsAnkiMigrationFromPackage extends SrsAnkiMigrationSource {
  const SrsAnkiMigrationFromPackage(this.file);

  final File file;
}

/// 执行一次迁移：媒体按内容哈希存进 [media]。抛 [SrsImportException]（如新格式缺排程内核）。
///
/// 这是迁移唯一的执行入口：页面只负责发现 / 确认 / 展示，导入本身只经这里——
/// 改成后台任务时把这一处换成后台 API 即可。
Future<SrsImportReport> runSrsAnkiMigration({
  required SrsDbStore store,
  required SrsMediaStore media,
  required SrsAnkiMigrationSource source,
  SrsAnkiImportOptions options = kSrsAnkiMigrationOptions,
  void Function(double progress)? onProgress,
}) {
  Future<String> storeMedia(String name, Uint8List bytes) =>
      media.store(name, bytes);
  return switch (source) {
    SrsAnkiMigrationFromCollection(:final AnkiCollectionSnapshot snapshot) =>
      importAnkiCollectionSnapshot(
        store: store,
        snapshot: snapshot,
        storeMedia: storeMedia,
        options: options,
        onProgress: onProgress,
      ),
    SrsAnkiMigrationFromPackage(:final File file) => importAnkiPackageFile(
      store: store,
      file: file,
      storeMedia: storeMedia,
      options: options,
      onProgress: onProgress,
    ),
  };
}

/// 这个平台能不能直接扫本机 Anki 数据目录（桌面三端 + Android；iOS 不能）。
bool srsAnkiMigrationCanScan(String os) => switch (os) {
  'windows' || 'macos' || 'linux' || 'android' => true,
  _ => false,
};

/// 当前平台的 Anki 用户数据根。
List<AnkiDataRoot> srsAnkiPlatformRoots() =>
    ankiDataRoots(os: Platform.operatingSystem, env: Platform.environment);
