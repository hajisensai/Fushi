import 'dart:math';

import 'package:just_audio/just_audio.dart';

/// 有声书 / TTS 朗读建多源播放列表的唯一入口：带 [LinearShuffleOrder]。
///
/// BUG-4957：just_audio 的 [ConcatenatingAudioSource] 构造时调用
/// `shuffleOrder.insert(0, children.length)`，默认的 [DefaultShuffleOrder] 对每个
/// 新下标做一次随机位置的 `List.insert`，整体 O(n²)。TTS 朗读每句一个源，长篇小说
/// 动辄十几万句，构造这一步就在主线程（Android 上 Flutter 合并平台 / UI 线程）上
/// 算十几秒，触摸 5 秒无响应即 ANR。
ConcatenatingAudioSource concatenateAudiobookSources(
  List<AudioSource> children,
) {
  return ConcatenatingAudioSource(
    children: children,
    shuffleOrder: LinearShuffleOrder(),
  );
}

/// 与 [DefaultShuffleOrder] 同语义（随机插入位置、[shuffle] 时把当前项放在队首），
/// 但 [insert] / [removeRange] 都是 O(n + count) 的单趟重建，而不是逐个 `insert`。
///
/// [insert] 的分布与默认实现一致：新下标在合并后的列表里占据一个均匀随机的位置子集，
/// 彼此之间的相对顺序也是均匀随机的，原有下标保持相对顺序。
class LinearShuffleOrder extends ShuffleOrder {
  /// [random] 只给测试注入确定性种子；默认 [Random]。
  LinearShuffleOrder({Random? random}) : _random = random ?? Random();

  final Random _random;

  List<int> _indices = <int>[];

  @override
  List<int> get indices => _indices;

  @override
  void shuffle({int? initialIndex}) {
    if (_indices.length <= 1) return;
    _indices.shuffle(_random);
    if (initialIndex == null) return;
    final int swapPos = _indices.indexOf(initialIndex);
    if (swapPos <= 0) return;
    _indices[swapPos] = _indices[0];
    _indices[0] = initialIndex;
  }

  @override
  void insert(int index, int count) {
    if (count <= 0) return;
    final List<int> old = _indices;
    final int total = old.length + count;
    // 新下标先打乱相对顺序，再用选择抽样（Knuth Algorithm S）把它们均匀地
    // 散到合并后的 total 个位置里；原有下标 >= index 的整体后移 count。
    final List<int> fresh = List<int>.generate(count, (int i) => index + i)
      ..shuffle(_random);
    final List<int> merged = List<int>.filled(total, 0);
    int freshLeft = count;
    int oldPos = 0;
    int freshPos = 0;
    for (int slot = 0; slot < total; slot++) {
      final int slotsLeft = total - slot;
      if (freshLeft > 0 && _random.nextInt(slotsLeft) < freshLeft) {
        merged[slot] = fresh[freshPos++];
        freshLeft--;
      } else {
        final int v = old[oldPos++];
        merged[slot] = v >= index ? v + count : v;
      }
    }
    _indices = merged;
  }

  @override
  void removeRange(int start, int end) {
    final int count = end - start;
    if (count <= 0) return;
    final List<int> kept = <int>[];
    for (final int v in _indices) {
      if (v >= start && v < end) continue;
      kept.add(v >= end ? v - count : v);
    }
    _indices = kept;
  }

  @override
  void clear() {
    _indices = <int>[];
  }
}
