import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi_core/fushi_core.dart' show DatabaseSnapshotDeletionResult;

// BUG-4991：「旧版残留」清理在互联 host 运行时被拒——存储页按钮禁用之外，控制通道 `rm`
// 走的 deleteStorageEntry 也是同一道闸。

StorageUsageActions _actions({
  required bool Function() hostRunning,
  required List<String> pruned,
}) => StorageUsageActions(
  booksProvider: () async => const <StorageBookRef>[],
  dictionaryNamesProvider: () async => const <String>[],
  deleteBook: (String _) async => null,
  deleteSrtBook: (String _) async => null,
  deleteDictionary: (String _) async => null,
  deleteDatabaseSnapshots: () async => const DatabaseSnapshotDeletionResult(
    deleted: <String>[],
    failures: <String, String>{},
  ),
  deleteFiles: (List<String> _) async => null,
  pruneInterconnectFileBox: (String dir) async {
    pruned.add(dir);
    return const <String>['Book A'];
  },
  isInterconnectHostRunning: hostRunning,
);

const StorageEntryUsage _legacy = StorageEntryUsage(
  id: StorageUsageService.kInterconnectLegacyEntryId,
  label: 'legacy',
  bytes: 4096,
  paths: <String>['/data/sync-data'],
  kind: StorageEntryKind.interconnectLegacyFileBox,
  itemCount: 1,
);

void main() {
  test('host 运行中：不调清理原语，回报原因', () async {
    final List<String> pruned = <String>[];
    final StorageEntryDeleteOutcome out = await deleteStorageEntry(
      _actions(hostRunning: () => true, pruned: pruned),
      _legacy,
    );
    expect(pruned, isEmpty);
    expect(out.changed, isFalse);
    expect(out.failure, t.storage_entry_interconnect_legacy_host_running);
  });

  test('host 停着：照常清理', () async {
    final List<String> pruned = <String>[];
    final StorageEntryDeleteOutcome out = await deleteStorageEntry(
      _actions(hostRunning: () => false, pruned: pruned),
      _legacy,
    );
    expect(pruned, <String>['/data/sync-data']);
    expect(out.changed, isTrue);
    expect(out.failure, isNull);
  });
}
