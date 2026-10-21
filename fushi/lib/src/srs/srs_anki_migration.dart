/// 「从 Anki 迁移」的逻辑层（UI 见 pages/implementations/srs/srs_anki_migration_page.dart）。
///
/// 两条来源，最后都收敛到 [runSrsAnkiMigration] 这一个函数（以后接后台导入任务只改它）：
/// - [SrsAnkiMigrationFromCollection]：本机 Anki（桌面）/ AnkiDroid（Android 旧默认目录）
///   的用户数据目录里的集合，先拍只读快照（fushi_engine 的 anki_collection_snapshot.dart）；
/// - [SrsAnkiMigrationFromPackage]：用户在 Anki / AnkiDroid / AnkiMobile 里导出的
///   .colpkg / .apkg（所有平台都能走，iOS 只有这一条）。
///
/// 选项由「迁移设置」页（srs_anki_migration_setup_page.dart）逐项给用户选：学习进度、排程算法
/// （RWKV / FSRS）、导入后是否把旧 Lapis 迁到 Fushi 卡片等，记在
/// [kSrsAnkiMigrationSettingsPrefKey]；没选过时取 [kSrsAnkiMigrationOptions]。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';

import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';

/// 迁移用的导入选项：复习进度（排程 + revlog）与牌组预设都带上；笔记类型不一致时另建一份
/// （不改本机已有的笔记类型），已有笔记「较新时更新」——与 Anki 导入页默认相同。
const SrsAnkiImportOptions kSrsAnkiMigrationOptions = SrsAnkiImportOptions(
  withScheduling: true,
  withDeckConfigs: true,
);

/// 「迁移设置」页的全部选择：导入选项 + 导入后是否把旧 Lapis 迁到 Fushi 卡片。
class SrsAnkiMigrationSettings {
  const SrsAnkiMigrationSettings({
    this.options = kSrsAnkiMigrationOptions,
    this.convertLapis = true,
    this.renameLapisDecks = true,
  });

  final SrsAnkiImportOptions options;

  /// 导入结束后在同一个后台任务里把本机全部旧 Lapis 笔记（含这次导入的）迁到 Fushi 卡片，
  /// 并补迁以前遗漏的字段（[SrsLegacyLapisMigrationOps]）。默认开：从 Anki 带 Lapis 过来就是
  /// 要用 Fushi 卡片；设置页写明了它做什么、迁不过去的字段怎么处理，不想要可以关。
  final bool convertLapis;

  /// [convertLapis] 开着时，再把名字里带 Lapis 的牌组改成 Fushi Card
  /// （[SrsLegacyLapisMigrationOps.renameLapisDecks]）。[convertLapis] 关着时不生效。
  final bool renameLapisDecks;

  SrsAnkiMigrationSettings copyWith({
    SrsAnkiImportOptions? options,
    bool? convertLapis,
    bool? renameLapisDecks,
  }) => SrsAnkiMigrationSettings(
    options: options ?? this.options,
    convertLapis: convertLapis ?? this.convertLapis,
    renameLapisDecks: renameLapisDecks ?? this.renameLapisDecks,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'options': options.toJson(),
    'convertLapis': convertLapis,
    'renameLapisDecks': renameLapisDecks,
  };

  /// 缺项 / 坏值回落到默认值。
  static SrsAnkiMigrationSettings fromJson(Map<String, Object?> json) {
    const SrsAnkiMigrationSettings d = SrsAnkiMigrationSettings();
    final Object? options = json['options'];
    final Object? convert = json['convertLapis'];
    final Object? renameDecks = json['renameLapisDecks'];
    return SrsAnkiMigrationSettings(
      options: options is Map
          ? SrsAnkiImportOptions.fromJson(options.cast<String, Object?>())
          : d.options,
      convertLapis: convert is bool ? convert : d.convertLapis,
      renameLapisDecks: renameDecks is bool ? renameDecks : d.renameLapisDecks,
    );
  }
}

/// 偏好键：上次「迁移设置」页的选择（String，[SrsAnkiMigrationSettings.toJson] 的 JSON）。
///
/// 与「导入 Anki 包」对话框的 `srs_import_anki_options` 分开：两边默认值本来就不同（迁移默认
/// 带排程与预设，导入别人分享的包一般不带）。
const String kSrsAnkiMigrationSettingsPrefKey = 'srs_anki_migration_settings';

SrsAnkiMigrationSettings readSrsAnkiMigrationSettings(PrefStore prefs) {
  final Object? raw = prefs.getPref(
    kSrsAnkiMigrationSettingsPrefKey,
    defaultValue: '',
  );
  if (raw is! String || raw.isEmpty) return const SrsAnkiMigrationSettings();
  try {
    final Object? json = jsonDecode(raw);
    if (json is Map) {
      return SrsAnkiMigrationSettings.fromJson(json.cast<String, Object?>());
    }
  } on FormatException {
    // 坏值：按默认值处理，下次确认时覆盖。
  }
  return const SrsAnkiMigrationSettings();
}

Future<void> writeSrsAnkiMigrationSettings(
  PrefStore prefs,
  SrsAnkiMigrationSettings settings,
) => prefs.setPref(
  kSrsAnkiMigrationSettingsPrefKey,
  jsonEncode(settings.toJson()),
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
///
/// [settings] 的 [SrsAnkiMigrationSettings.convertLapis] 开着时，导入落库后在同一个任务里把旧
/// Lapis 迁到 Fushi 卡片（[srsConvertLegacyLapisAfterImport]），不依赖迁移页还开着。
Future<SrsImportReport> runSrsAnkiMigration({
  required SrsDbStore store,
  required SrsMediaStore media,
  required SrsAnkiMigrationSource source,
  SrsAnkiMigrationSettings settings = const SrsAnkiMigrationSettings(),
  void Function(double progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  final SrsImportReport report = await _importMigrationSource(
    store: store,
    media: media,
    source: source,
    options: settings.options,
    onProgress: onProgress,
    shouldStop: shouldStop,
  );
  if (settings.convertLapis) {
    await srsConvertLegacyLapisAfterImport(
      store,
      report,
      renameDecks: settings.renameLapisDecks,
    );
  }
  return report;
}

/// 迁移后的「旧 Lapis → Fushi 卡片」：逐个变体迁移（换类型 + 补迁，原牌组不动），再补迁以前
/// 迁移遗漏的字段。每个变体各自一个事务（[SrsLegacyLapisMigrationOps.migrateLegacyLapis]），失败的
/// 那个整体不落库、仍是旧 Lapis。[renameDecks] 时最后把名字带 Lapis 的牌组改成 Fushi Card。导入本身已经落库，所以这一步失败不让整个任务失败，而是记日志并在
/// 报告里写明（[SrsImportReport.lapisMigrationFailed]），用户可以去笔记类型页重试。
Future<void> srsConvertLegacyLapisAfterImport(
  SrsDbStore store,
  SrsImportReport report, {
  bool renameDecks = false,
}) async {
  try {
    for (final SrsLegacyLapisSource source
        in await store.legacyLapisSources()) {
      report.lapisNotesMigrated += await store.migrateLegacyLapis(
        source.type.id,
      );
    }
    report.lapisNotesMigrated += await store.applyLapisBackfill();
    if (renameDecks) report.lapisDecksRenamed = await store.renameLapisDecks();
  } catch (e, stack) {
    ErrorLogService.instance.log('SrsAnkiMigration.convertLapis', e, stack);
    report.lapisMigrationFailed = true;
  }
}

Future<SrsImportReport> _importMigrationSource({
  required SrsDbStore store,
  required SrsMediaStore media,
  required SrsAnkiMigrationSource source,
  required SrsAnkiImportOptions options,
  void Function(double progress)? onProgress,
  bool Function()? shouldStop,
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
        shouldStop: shouldStop,
      ),
    SrsAnkiMigrationFromPackage(:final File file) => importAnkiPackageFile(
      store: store,
      file: file,
      storeMedia: storeMedia,
      options: options,
      onProgress: onProgress,
      shouldStop: shouldStop,
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
