/// 因果上下文：dotted version vector（第六轮审查第 1、2 条）。
///
/// 修订版 8 的 ctx 是「本机 cursor 已应用的批次前缀」的版本向量，有两个洞：
/// 1. 批次只含本机改动、不转发，没有因果投递保证，支配关系不能传递（A 写 a；B 见 a 后写 b；
///    C 只读了 B 没读 A 就写 c —— c 的 ctx[A]=0 支配不了 a，不同端会留下不同的集合）。
/// 2. vv 装不下「不连续的 dot」：退役 / 恢复备份后由新化身重新发布的旧事件 dot 仍属旧 writer，
///    任何人的 cursor[旧 writer] 都到不了它们，这些记录永远不被支配；改回 / 确认要覆盖具体 dot 也表达不了。
///
/// 改法：上下文 = 连续前缀 vv + 额外 dot 集合（cloud），按**已应用的记录**统计（不按已读的批次），
/// 并且取**因果闭包**：应用一条记录时，把它的 dot 和它自己的 ctx 一起并进本机上下文。
/// 这样「b 的作者看见过 a」⇔「b.ctx 含 a.dot」，而 c.ctx ⊇ b.ctx ∪ {b.dot}，支配可以传递，
/// 丢掉被支配的记录是安全的。
library;

import 'dart:collection';

/// 一个 dot = (writerId, 该写入者的修改序号，从 1 起连续)。
class SrsDot implements Comparable<SrsDot> {
  const SrsDot(this.writerId, this.seq);

  final String writerId;
  final int seq;

  @override
  int compareTo(SrsDot other) {
    final int w = writerId.compareTo(other.writerId);
    return w != 0 ? w : seq.compareTo(other.seq);
  }

  @override
  bool operator ==(Object other) =>
      other is SrsDot && other.writerId == writerId && other.seq == seq;

  @override
  int get hashCode => Object.hash(writerId, seq);

  @override
  String toString() => '$writerId:$seq';
}

/// 不可变的因果上下文。
class SrsCausalContext {
  SrsCausalContext._(this._vv, this._cloud);

  /// 空上下文。
  factory SrsCausalContext.empty() => SrsCausalContext._(
    const <String, int>{},
    const <String, SplayTreeSet<int>>{},
  );

  /// 规范化构造：cloud 里能并进连续前缀的部分并进去。
  factory SrsCausalContext.of({
    Map<String, int> vv = const <String, int>{},
    Map<String, Iterable<int>> cloud = const <String, Iterable<int>>{},
  }) {
    final Map<String, int> v = <String, int>{
      for (final MapEntry<String, int> e in vv.entries)
        if (e.value > 0) e.key: e.value,
    };
    final Map<String, SplayTreeSet<int>> c = <String, SplayTreeSet<int>>{};
    for (final MapEntry<String, Iterable<int>> e in cloud.entries) {
      final SplayTreeSet<int> set = SplayTreeSet<int>.of(
        e.value.where((int s) => s > (v[e.key] ?? 0)),
      );
      if (set.isNotEmpty) c[e.key] = set;
    }
    _compactAll(v, c);
    return SrsCausalContext._(
      Map<String, int>.unmodifiable(v),
      Map<String, SplayTreeSet<int>>.unmodifiable(c),
    );
  }

  final Map<String, int> _vv;
  final Map<String, SplayTreeSet<int>> _cloud;

  Map<String, int> get vv => _vv;

  Map<String, List<int>> get cloud => <String, List<int>>{
    for (final MapEntry<String, SplayTreeSet<int>> e in _cloud.entries)
      e.key: e.value.toList(growable: false),
  };

  bool get isEmpty => _vv.isEmpty && _cloud.isEmpty;

  static void _compactAll(
    Map<String, int> v,
    Map<String, SplayTreeSet<int>> c,
  ) {
    for (final String w in c.keys.toList()) {
      final SplayTreeSet<int> set = c[w]!;
      int top = v[w] ?? 0;
      while (set.isNotEmpty && set.first <= top + 1) {
        final int s = set.first;
        set.remove(s);
        if (s == top + 1) top = s;
      }
      if (top > 0) v[w] = top;
      if (set.isEmpty) c.remove(w);
    }
  }

  bool contains(SrsDot dot) {
    if (dot.seq <= (_vv[dot.writerId] ?? 0)) return true;
    return _cloud[dot.writerId]?.contains(dot.seq) ?? false;
  }

  /// 本上下文是否覆盖 [other] 的全部 dot。
  bool covers(SrsCausalContext other) {
    for (final MapEntry<String, int> e in other._vv.entries) {
      final int mine = _vv[e.key] ?? 0;
      if (mine >= e.value) continue;
      final SplayTreeSet<int>? set = _cloud[e.key];
      for (int s = mine + 1; s <= e.value; s++) {
        if (set == null || !set.contains(s)) return false;
      }
    }
    for (final MapEntry<String, SplayTreeSet<int>> e in other._cloud.entries) {
      for (final int s in e.value) {
        if (!contains(SrsDot(e.key, s))) return false;
      }
    }
    return true;
  }

  SrsCausalContext add(SrsDot dot) {
    if (contains(dot)) return this;
    final Map<String, int> v = Map<String, int>.of(_vv);
    final Map<String, SplayTreeSet<int>> c = <String, SplayTreeSet<int>>{
      for (final MapEntry<String, SplayTreeSet<int>> e in _cloud.entries)
        e.key: SplayTreeSet<int>.of(e.value),
    };
    (c[dot.writerId] ??= SplayTreeSet<int>()).add(dot.seq);
    _compactAll(v, c);
    return SrsCausalContext._(
      Map<String, int>.unmodifiable(v),
      Map<String, SplayTreeSet<int>>.unmodifiable(c),
    );
  }

  SrsCausalContext merge(SrsCausalContext other) {
    if (other.isEmpty || covers(other)) return this;
    if (isEmpty) return other;
    final Map<String, int> v = Map<String, int>.of(_vv);
    for (final MapEntry<String, int> e in other._vv.entries) {
      if ((v[e.key] ?? 0) < e.value) v[e.key] = e.value;
    }
    final Map<String, SplayTreeSet<int>> c = <String, SplayTreeSet<int>>{};
    void addCloud(Map<String, SplayTreeSet<int>> from) {
      for (final MapEntry<String, SplayTreeSet<int>> e in from.entries) {
        final int top = v[e.key] ?? 0;
        for (final int s in e.value) {
          if (s > top) (c[e.key] ??= SplayTreeSet<int>()).add(s);
        }
      }
    }

    addCloud(_cloud);
    addCloud(other._cloud);
    _compactAll(v, c);
    return SrsCausalContext._(
      Map<String, int>.unmodifiable(v),
      Map<String, SplayTreeSet<int>>.unmodifiable(c),
    );
  }

  /// 规范 JSON：writer 按字典序，cloud 升序。相同上下文逐字节相同。
  Map<String, Object?> toJson() {
    final List<String> vk = _vv.keys.toList()..sort();
    final List<String> ck = _cloud.keys.toList()..sort();
    return <String, Object?>{
      'vv': <String, int>{for (final String k in vk) k: _vv[k]!},
      if (ck.isNotEmpty)
        'cloud': <String, List<int>>{
          for (final String k in ck) k: _cloud[k]!.toList(growable: false),
        },
    };
  }

  static SrsCausalContext fromJson(Object? json) {
    if (json is! Map) return SrsCausalContext.empty();
    final Map<String, int> vv = <String, int>{};
    final Object? rawVv = json['vv'];
    if (rawVv is Map) {
      for (final MapEntry<Object?, Object?> e in rawVv.entries) {
        final Object? v = e.value;
        if (e.key is String && v is int) vv[e.key! as String] = v;
      }
    }
    final Map<String, List<int>> cloud = <String, List<int>>{};
    final Object? rawCloud = json['cloud'];
    if (rawCloud is Map) {
      for (final MapEntry<Object?, Object?> e in rawCloud.entries) {
        final Object? v = e.value;
        if (e.key is String && v is List) {
          cloud[e.key! as String] = v.whereType<int>().toList();
        }
      }
    }
    return SrsCausalContext.of(vv: vv, cloud: cloud);
  }

  @override
  bool operator ==(Object other) =>
      other is SrsCausalContext && covers(other) && other.covers(this);

  @override
  int get hashCode => Object.hashAllUnordered(_vv.entries.map((e) => e.key));

  @override
  String toString() => 'Ctx${toJson()}';
}
