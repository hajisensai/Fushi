/// 「同步差异对比」对话框在控制通道上的等价操作（`fushi_cli sync compare` /
/// `sync compare-apply`）。
///
/// 与对话框同一条链路：后端 = [resolveSyncCompareBackend]（同步真正会跑的第一条
/// 认证通过的通道），差异 = [loadSyncCompareData]，默认选择 =
/// [defaultSyncCompareChoices]，应用 = [applySyncCompareChoices]；远端独有书的
/// 「下载」= [downloadSyncCompareRemoteOnly]。对话框是「看一眼再点应用」，这里每次
/// 调用都重新拉一次差异再按给定选择应用——不会拿过时的列表去写。
///
/// 条目 id：本机有的书 = 它的 bookKey；远端独有的 = `remote:<书名>`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart'
    show runExclusiveWithSync;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart' show SyncDirection;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';

/// 条目 id（见库注释）。
String syncCompareEntryId(SyncCompareEntry entry) =>
    entry.bookKey ?? 'remote:${entry.title}';

String _status(SyncCompareEntry e) {
  if (e.bookKey == null) {
    return e.isDownloadableRemoteOnly ? 'remote_only' : 'remote_orphan';
  }
  if (e.hasConflict) return 'conflict';
  if (e.isSynced) return 'synced';
  return switch (e.autoDirection) {
    SyncDirection.exportToTtu => e.hasRemote ? 'local_newer' : 'local_only',
    SyncDirection.importFromTtu => 'remote_newer',
    _ => 'synced',
  };
}

String _choiceToken(SyncChoice choice) => switch (choice) {
  SyncChoice.skip => 'skip',
  SyncChoice.useLocal => 'local',
  SyncChoice.useRemote => 'remote',
};

SyncChoice _parseChoice(String raw, String where) => switch (raw.trim()) {
  'local' => SyncChoice.useLocal,
  'remote' => SyncChoice.useRemote,
  'skip' => SyncChoice.skip,
  _ => throw ArgumentError('$where 取 local / remote / skip，收到「$raw」'),
};

Map<String, Object?> _entryJson(SyncCompareEntry e, SyncChoice choice) =>
    <String, Object?>{
      'id': syncCompareEntryId(e),
      'title': e.title,
      'status': _status(e),
      'default': _choiceToken(choice),
      if (e.localProgress != null) 'localProgress': e.localProgress,
      if (e.localUpdatedAt != null) 'localUpdatedAt': e.localUpdatedAt,
      if (e.remoteProgress != null) 'remoteProgress': e.remoteProgress,
      if (e.remoteUpdatedAt != null) 'remoteUpdatedAt': e.remoteUpdatedAt,
      if (e.localPage != null) 'localPage': e.localPage,
      if (e.remotePage != null) 'remotePage': e.remotePage,
      if (e.pageCount != null) 'pageCount': e.pageCount,
      if (e.localStatsCount != null) 'localStats': e.localStatsCount,
      if (e.remoteStatsCount != null) 'remoteStats': e.remoteStatsCount,
    };

Future<SyncBackend> _requireBackend(AppModel appModel) async {
  final SyncBackend? backend = await resolveSyncCompareBackend(
    SyncRepository(appModel.database),
  );
  if (backend == null) {
    throw StateError('没有可用的同步目标（先配置云同步或互联）');
  }
  return backend;
}

/// `sync compare`：列出差异（书 + 词典）与各自的默认选择。
Future<Map<String, Object?>> listSyncCompareForCli(AppModel appModel) async {
  final SyncBackend backend = await _requireBackend(appModel);
  final ({List<SyncCompareEntry> books, List<SyncDictEntry> dicts}) data =
      await loadSyncCompareData(appModel.database, backend);
  final Map<String, SyncChoice> defaults = defaultSyncCompareChoices(
    data.books,
  );
  return <String, Object?>{
    'backend': backend.runtimeType.toString(),
    'books': <Map<String, Object?>>[
      for (final SyncCompareEntry e in data.books)
        _entryJson(e, defaults[e.title] ?? SyncChoice.skip),
    ],
    'dictionaries': <Map<String, Object?>>[
      for (final SyncDictEntry d in data.dicts)
        <String, Object?>{
          'name': d.name,
          'title': d.shownName,
          'local': d.hasLocal,
          'remote': d.hasRemote,
        },
    ],
  };
}

/// 把 [itemsJson]（`{"<id>": "local|remote|skip", …}`）解析成 id → 选择。
Map<String, SyncChoice> parseSyncCompareItems(String? itemsJson) {
  if (itemsJson == null || itemsJson.trim().isEmpty) {
    return const <String, SyncChoice>{};
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(itemsJson);
  } on FormatException {
    throw const FormatException(
      'items 必须是 JSON 对象：{"<id>":"local|remote|skip"}',
    );
  }
  if (decoded is! Map) {
    throw const FormatException(
      'items 必须是 JSON 对象：{"<id>":"local|remote|skip"}',
    );
  }
  return <String, SyncChoice>{
    for (final MapEntry<Object?, Object?> e in decoded.entries)
      '${e.key}': _parseChoice('${e.value}', 'items 里「${e.key}」'),
  };
}

/// 一次 compare-apply 要做的事（[resolveSyncCompareCliPlan] 的结果）。
class SyncCompareCliPlan {
  const SyncCompareCliPlan({
    required this.choices,
    required this.books,
    required this.downloads,
  });

  /// 书名 → 选择（[applySyncCompareChoices] 按书名取）。
  final Map<String, SyncChoice> choices;

  /// 要按选择同步的本机书。
  final List<SyncCompareEntry> books;

  /// 要下载的远端独有书。
  final List<SyncCompareEntry> downloads;
}

/// 把 `--keep` / `--item` 解析成计划（纯函数）。[keep]：没点名的书怎么处理——
/// `auto`（缺省，= 对话框的默认选择）/ `local` / `remote` / `skip`。远端独有的书只在
/// 被点名为 `remote` 时下载（对话框里它也只有行内「下载」，不进批量）。
SyncCompareCliPlan resolveSyncCompareCliPlan(
  List<SyncCompareEntry> entries, {
  String? keep,
  Map<String, SyncChoice> items = const <String, SyncChoice>{},
}) {
  final String keepMode = (keep ?? 'auto').trim();
  final SyncChoice? keepChoice = keepMode == 'auto'
      ? null
      : _parseChoice(keepMode, 'keep');
  final Set<String> ids = <String>{
    for (final SyncCompareEntry e in entries) syncCompareEntryId(e),
  };
  for (final String id in items.keys) {
    if (!ids.contains(id)) {
      throw ArgumentError('没有差异项「$id」（先 sync compare 看 id）');
    }
  }
  final Map<String, SyncChoice> choices = defaultSyncCompareChoices(entries);
  final List<SyncCompareEntry> books = <SyncCompareEntry>[];
  final List<SyncCompareEntry> downloads = <SyncCompareEntry>[];
  for (final SyncCompareEntry e in entries) {
    final String id = syncCompareEntryId(e);
    if (e.bookKey == null) {
      final SyncChoice? pick = items[id];
      if (pick == SyncChoice.useLocal) {
        throw ArgumentError('「${e.title}」只在远端有，不能保留本地（用 remote 下载，或 skip）');
      }
      if (pick == SyncChoice.useRemote) {
        if (!e.isDownloadableRemoteOnly) {
          throw ArgumentError('「${e.title}」在远端只剩同步元数据、没有可下载的内容');
        }
        downloads.add(e);
      }
      continue;
    }
    // 两端已一致的书 --keep 不管（应用了也是空转）；要动它得逐条点名。
    final SyncChoice choice =
        items[id] ?? (e.isSynced ? null : keepChoice) ?? choices[e.title]!;
    choices[e.title] = choice;
    if (choice != SyncChoice.skip) books.add(e);
  }
  return SyncCompareCliPlan(
    choices: choices,
    books: books,
    downloads: downloads,
  );
}

/// `sync compare-apply`：重新拉差异，按 [resolveSyncCompareCliPlan] 的计划应用。
Future<Map<String, Object?>> applySyncCompareForCli(
  AppModel appModel, {
  String? keep,
  String? itemsJson,
}) async {
  final Map<String, SyncChoice> items = parseSyncCompareItems(itemsJson);
  final SyncBackend backend = await _requireBackend(appModel);
  final ({List<SyncCompareEntry> books, List<SyncDictEntry> dicts}) data =
      await loadSyncCompareData(appModel.database, backend);
  final SyncCompareCliPlan plan = resolveSyncCompareCliPlan(
    data.books,
    keep: keep,
    items: items,
  );
  final Map<String, SyncChoice> choices = plan.choices;
  final List<SyncCompareEntry> books = plan.books;
  final List<SyncCompareEntry> downloads = plan.downloads;

  final Directory tempDir = Directory.systemTemp;
  final SyncCompareApplyResult result = await applySyncCompareChoices(
    db: appModel.database,
    backend: backend,
    actionable: books,
    choices: choices,
    tempDir: tempDir,
  );
  final List<String> downloaded = <String>[];
  final List<String> skippedDuplicates = <String>[];
  final List<String> downloadErrors = <String>[];
  for (final SyncCompareEntry e in downloads) {
    try {
      final bool imported = await runExclusiveWithSync(
        () => downloadSyncCompareRemoteOnly(
          db: appModel.database,
          backend: backend,
          entry: e,
          tempDir: tempDir,
          audioDatabaseRoot: Directory(
            p.join(appModel.appDirectory.path, 'audiobooks'),
          ),
        ),
      );
      if (imported) downloaded.add(e.title);
    } on DuplicateImportCancelledException {
      skippedDuplicates.add(e.title);
    } catch (err) {
      downloadErrors.add('${e.title}: $err');
    }
  }
  return <String, Object?>{
    'applied': result.applied,
    'chosen': <Map<String, Object?>>[
      for (final SyncCompareEntry e in books)
        <String, Object?>{
          'id': syncCompareEntryId(e),
          'title': e.title,
          'keep': _choiceToken(choices[e.title]!),
        },
    ],
    if (result.errors.isNotEmpty) 'errors': result.errors,
    if (downloaded.isNotEmpty) 'downloaded': downloaded,
    if (skippedDuplicates.isNotEmpty) 'alreadyLocal': skippedDuplicates,
    if (downloadErrors.isNotEmpty) 'downloadErrors': downloadErrors,
  };
}
