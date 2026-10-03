/// File-level sharding for the CI unit-test matrix.
///
/// `flutter test --total-shards/--shard-index` is forwarded to package:test,
/// which splits the tests *inside* every suite (`test_core` `_shardSuite`):
/// each shard still compiles and loads all ~3.4k suites, and compile + load is
/// the bulk of a full run. Sharding by file makes every shard compile only its
/// own suites, which is what actually cuts wall time.
library;

/// A parsed `--file-shard=<index>/<total>` value.
class TestFileShard {
  const TestFileShard(this.index, this.total);

  final int index;
  final int total;

  /// Parses `<index>/<total>` (0-based index). Returns null when malformed or
  /// out of range, so the caller can reject it with a usage error.
  static TestFileShard? tryParse(String raw) {
    final List<String> parts = raw.split('/');
    if (parts.length != 2) return null;
    final int? index = int.tryParse(parts[0]);
    final int? total = int.tryParse(parts[1]);
    if (index == null || total == null) return null;
    if (total < 1 || index < 0 || index >= total) return null;
    return TestFileShard(index, total);
  }
}

/// Deterministically partitions [fileWeights] (test file path → weight, e.g.
/// byte size as a cost proxy) into [shard.total] shards and returns the sorted
/// paths of shard [shard.index].
///
/// Longest-processing-time greedy: heaviest file first, each onto the currently
/// lightest shard (ties → lower shard index). Every file lands in exactly one
/// shard, and every shard computes the same assignment from the same input, so
/// the union of all shards is the whole suite with no overlap.
List<String> selectTestFileShard(
  Map<String, int> fileWeights,
  TestFileShard shard,
) {
  final List<MapEntry<String, int>> entries = fileWeights.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final int byWeight = b.value.compareTo(a.value);
      return byWeight != 0 ? byWeight : a.key.compareTo(b.key);
    });
  final List<int> loads = List<int>.filled(shard.total, 0);
  final List<String> selected = <String>[];
  for (final MapEntry<String, int> entry in entries) {
    int target = 0;
    for (int i = 1; i < shard.total; i++) {
      if (loads[i] < loads[target]) target = i;
    }
    loads[target] += entry.value;
    if (target == shard.index) selected.add(entry.key);
  }
  selected.sort();
  return selected;
}
