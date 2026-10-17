/// 牌组设置的物化视图、牌组树与参数继承。
library;

import 'algorithm.dart';
import 'entities.dart';
import 'field_edit.dart';
import 'scheduler.dart';

/// 一种算法的参数组（整体一个字段键，按铁律 H 设置类合并）。
class SrsParamSet {
  const SrsParamSet({
    required this.params,
    this.algorithmRev,
    this.optimizedAt,
    this.trainCount = 0,
    this.logLoss,
  });

  final List<double> params;
  final String? algorithmRev;
  final int? optimizedAt;
  final int trainCount;
  final double? logLoss;

  Map<String, Object?> toValue() => <String, Object?>{
    'params': params,
    if (algorithmRev != null) 'rev': algorithmRev,
    if (optimizedAt != null) 'at': optimizedAt,
    'n': trainCount,
    if (logLoss != null) 'logLoss': logLoss,
  };

  static SrsParamSet? fromValue(Object? v) {
    if (v is! Map) return null;
    final Object? p = v['params'];
    return SrsParamSet(
      params: p is List
          ? p.whereType<num>().map((num x) => x.toDouble()).toList()
          : const <double>[],
      algorithmRev: v['rev'] as String?,
      optimizedAt: v['at'] as int?,
      trainCount: (v['n'] as int?) ?? 0,
      logLoss: (v['logLoss'] as num?)?.toDouble(),
    );
  }
}

/// 物化后的牌组。
class SrsDeckView {
  SrsDeckView({
    required this.id,
    required this.name,
    required this.parentId,
    required this.ownParams,
    required this.newPerDay,
    required this.reviewsPerDay,
    required this.learnSteps,
    required this.relearnSteps,
    required this.desiredRetention,
    required this.algorithmWire,
    required this.algorithmAuto,
    required this.fsrs6,
    required this.fsrs7,
    required this.autoOptimize,
    required this.maxIntervalDays,
    this.autoplayAudio = true,
    this.replayQuestionAudio = true,
    required this.optimizeBaselineAt,
    required this.optimizeBaselineCount,
    required this.deletedAt,
    required this.builtinKey,
    required this.createdAt,
    required this.edits,
    this.collapsed = false,
  });

  static const List<double> defaultLearnSteps = <double>[1, 10];
  static const List<double> defaultRelearnSteps = <double>[10];

  final String id;
  final String name;
  final String? parentId;

  /// paramsMode = own（顶层恒为 own）。
  final bool ownParams;
  final int newPerDay;
  final int reviewsPerDay;
  final List<double> learnSteps;
  final List<double> relearnSteps;
  final double desiredRetention;

  /// 可能是本机不认识的值（原样保留、不改写）。
  final String algorithmWire;
  final bool algorithmAuto;
  final SrsParamSet? fsrs6;
  final SrsParamSet? fsrs7;
  final bool autoOptimize;
  final int maxIntervalDays;

  /// 牌组列表里收起了子牌组（缺省 = 展开，与 Anki 一致）。
  final bool collapsed;

  /// 复习时自动播放卡面音频（Anki「自动播放音频」）。只看 own 祖先上的值
  /// （[SrsDeckTree.paramsOwner]）。
  final bool autoplayAudio;

  /// 答案面重播时先播问题音频（Anki 默认；false = 「重播答案时跳过问题」）。
  /// 只看 own 祖先上的值。
  final bool replayQuestionAudio;
  final int? optimizeBaselineAt;
  final int? optimizeBaselineCount;
  final int? deletedAt;
  final String? builtinKey;
  final int createdAt;
  final SrsEntityEdits edits;

  SrsAlgorithm get localAlgorithm => resolveLocalAlgorithm(algorithmWire);

  /// 本机不认识的算法（旧版 app 收到新算法）：设置里显示「此牌组的算法来自更新版本，本机暂用 X」。
  bool get algorithmUnknownLocally =>
      SrsAlgorithm.tryParse(algorithmWire) == null;

  SrsParamSet? paramSetFor(SrsAlgorithm a) => switch (a) {
    SrsAlgorithm.fsrs6 => fsrs6,
    SrsAlgorithm.fsrs7 => fsrs7,
  };

  static SrsDeckView materialize(SrsEntityRecord record, SrsEntityEdits edits) {
    final Object? limits = edits.value(SrsFieldKeys.deckLimits);
    final Object? steps = edits.value(SrsFieldKeys.deckSteps);
    final Object? alg = edits.value(SrsFieldKeys.deckAlgorithm);
    final Object? baseline = edits.value(SrsFieldKeys.deckOptimizeBaseline);
    List<double> listOf(Object? v, List<double> fallback) => v is List
        ? srsSanitizeSteps(
            v.whereType<num>().map((num x) => x.toDouble()).toList(),
            fallback,
          )
        : fallback;
    final String? parent = edits.value(SrsFieldKeys.deckParent) as String?;
    return SrsDeckView(
      id: record.id,
      name: (edits.value(SrsFieldKeys.name) as String?) ?? 'Default',
      parentId: parent,
      ownParams:
          parent == null || edits.value(SrsFieldKeys.deckParamsMode) == 'own',
      newPerDay: limits is Map ? (limits['new'] as int?) ?? 20 : 20,
      reviewsPerDay: limits is Map ? (limits['review'] as int?) ?? 200 : 200,
      learnSteps: listOf(
        steps is Map ? steps['learn'] : null,
        defaultLearnSteps,
      ),
      relearnSteps: listOf(
        steps is Map ? steps['relearn'] : null,
        defaultRelearnSteps,
      ),
      desiredRetention:
          ((edits.value(SrsFieldKeys.deckRetention) as num?) ?? 0.8).toDouble(),
      algorithmWire: alg is Map
          ? (alg['alg'] as String?) ?? srsDefaultAlgorithm.wire
          : srsDefaultAlgorithm.wire,
      algorithmAuto: alg is Map ? alg['auto'] != false : true,
      fsrs6: SrsParamSet.fromValue(edits.value(SrsFieldKeys.deckFsrs6Params)),
      fsrs7: SrsParamSet.fromValue(edits.value(SrsFieldKeys.deckFsrs7Params)),
      autoOptimize: edits.value(SrsFieldKeys.deckAutoOptimize) != false,
      maxIntervalDays:
          (edits.value(SrsFieldKeys.deckMaxInterval) as int?) ?? 36500,
      collapsed: edits.value(SrsFieldKeys.deckCollapsed) == true,
      autoplayAudio: edits.value(SrsFieldKeys.deckAutoplay) != false,
      replayQuestionAudio:
          edits.value(SrsFieldKeys.deckReplayQuestion) != false,
      optimizeBaselineAt: baseline is Map ? baseline['at'] as int? : null,
      optimizeBaselineCount: baseline is Map ? baseline['n'] as int? : null,
      deletedAt: edits.deletedAt,
      builtinKey: record.payload['builtin'] as String?,
      createdAt: record.createdAt,
      edits: edits,
    );
  }
}

/// 牌组树：父子关系、成环打破、参数继承。
class SrsDeckTree {
  SrsDeckTree(Iterable<SrsDeckView> decks)
    : _byId = <String, SrsDeckView>{
        for (final SrsDeckView d in decks)
          if (d.deletedAt == null) d.id: d,
      } {
    _resolveParents();
  }

  final Map<String, SrsDeckView> _byId;
  final Map<String, String?> _parent = <String, String?>{};

  /// 因成环被视为顶层的牌组（进同步冲突记录）。
  final Set<String> cycleBroken = <String>{};

  Iterable<SrsDeckView> get decks => _byId.values;

  SrsDeckView? operator [](String id) => _byId[id];

  /// 成环（两端并发把 A 挪到 B 下、B 挪到 A 下）时，环上 deckId 字典序最小的那个视为顶层，确定性打破。
  void _resolveParents() {
    for (final SrsDeckView d in _byId.values) {
      final String? p = d.parentId;
      _parent[d.id] = (p != null && _byId.containsKey(p)) ? p : null;
    }
    for (final String start in _byId.keys.toList()..sort()) {
      final List<String> path = <String>[];
      final Set<String> seen = <String>{};
      String? cur = start;
      while (cur != null && !seen.contains(cur)) {
        seen.add(cur);
        path.add(cur);
        cur = _parent[cur];
      }
      if (cur != null) {
        final int at = path.indexOf(cur);
        final List<String> cycle = path.sublist(at)..sort();
        _parent[cycle.first] = null;
        cycleBroken.add(cycle.first);
      }
    }
  }

  String? parentOf(String id) => _parent[id];

  /// 「父::子」全名。
  String fullName(String id) {
    final List<String> parts = <String>[];
    String? cur = id;
    int guard = 0;
    while (cur != null && guard++ < 64) {
      parts.insert(0, _byId[cur]?.name ?? '?');
      cur = _parent[cur];
    }
    return parts.join('::');
  }

  /// 子树（含自己）。
  List<String> subtree(String id) {
    final List<String> out = <String>[id];
    for (int i = 0; i < out.length; i++) {
      for (final String c in _byId.keys) {
        if (_parent[c] == out[i]) out.add(c);
      }
    }
    return out;
  }

  /// 参数继承：最近一个 own 祖先（顶层恒为 own）。
  SrsDeckView paramsOwner(String id) {
    String? cur = id;
    int guard = 0;
    while (cur != null && guard++ < 64) {
      final SrsDeckView d = _byId[cur]!;
      if (d.ownParams || _parent[cur] == null) return d;
      cur = _parent[cur];
    }
    return _byId[id]!;
  }

  /// own 牌组的优化训练范围：整棵子树里 inherit 的后代，遇到 own 的后代就停（那棵归它自己）。
  List<String> paramsScope(String ownerId) {
    final List<String> out = <String>[ownerId];
    for (int i = 0; i < out.length; i++) {
      for (final String c in _byId.keys) {
        if (_parent[c] == out[i] && !_byId[c]!.ownParams) out.add(c);
      }
    }
    return out;
  }

  /// 某牌组复习时实际用的排程配置：步长 / 上限是自己的，算法 / 参数 / 记忆率来自 own 祖先。
  SrsSchedulingConfig schedulingConfig(
    String id, {
    List<double> Function(SrsAlgorithm algorithm)? defaultsOf,
  }) {
    final SrsDeckView self = _byId[id]!;
    final SrsDeckView owner = paramsOwner(id);
    final SrsAlgorithm alg = owner.localAlgorithm;
    final SrsParamSet? set = owner.paramSetFor(alg);
    final List<double> params =
        (set != null && set.params.length == alg.paramCount)
        ? set.params
        : (defaultsOf?.call(alg) ?? const <double>[]);
    return SrsSchedulingConfig(
      learnStepsMinutes: self.learnSteps,
      relearnStepsMinutes: self.relearnSteps,
      desiredRetention: owner.desiredRetention,
      maxIntervalDays: self.maxIntervalDays,
      algorithm: alg,
      params: params,
    );
  }
}
