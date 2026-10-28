/// 牌组设置的物化视图、牌组树与参数继承。
library;

import 'dart:math' as math;

import 'algorithm.dart';
import 'entities.dart';
import 'field_edit.dart';
import 'scheduler.dart';

/// 新卡出卡顺序（牌组设置 [SrsFieldKeys.deckNewOrder]）。
enum SrsNewCardOrder {
  /// 按卡上的词频名次（笔记类型的词频序字段，见 [SrsNoteTypeView.frequencyField]）升序：常用词先出。
  /// 名次随笔记同步，每台设备读到同一个数，出卡顺序一致；没有名次的卡排在后面、按 [position] 的规则。
  frequency('frequency'),

  /// 按新卡位置（手动「按词频重排新卡」/ Anki 导入写的 `newPos`），没排过的按添加先后。
  position('position');

  const SrsNewCardOrder(this.wire);

  final String wire;

  /// 缺省与不认识的值（更新版本加的新顺序）都按 [frequency]。
  static SrsNewCardOrder fromWire(String? wire) {
    for (final SrsNewCardOrder o in values) {
      if (o.wire == wire) return o;
    }
    return frequency;
  }
}

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

/// RWKV-Instant 的排队设置（[SrsFieldKeys.deckRwkvQueue]），默认值 = 上游 kuma3 默认。
class SrsRwkvQueueSettings {
  const SrsRwkvQueueSettings({
    this.minReviewsPerDay = 0,
    this.repeatMinReviews = 5,
    this.repeatMinSeconds = 30,
    this.refreshEvery = 1,
  });

  /// 每天最少复习数：今天在这个牌组复习过的卡不到这个数时，从回忆率高于目标保留率（本不该出）
  /// 的复习卡里按回忆率从低到高补足。0 = 不启用。
  final int minReviewsPerDay;

  /// 同日重复：今天答过的卡，之后这组牌组里别的卡至少要有这么多次作答才再出。
  final int repeatMinReviews;

  /// 同日重复：今天答过的卡，距上次作答至少这么多秒才再出。
  final int repeatMinSeconds;

  /// 每答几题整表刷新一次 RWKV 分数（上游 JSchoreels/anki「Update the RWKV queue every」，
  /// 默认 1 = 每题）。数的是模型状态真正推进的次数（作答与撤回），刷新在后台跑、下一次排队
  /// 生效（`SrsRwkvService`）。调大能减少复习时 RWKV 的计算，代价是队列在两次刷新之间用的是
  /// 较旧的估计。最小 1。
  final int refreshEvery;

  static const int maxMinReviewsPerDay = 9999;
  static const int maxRepeatMinReviews = 999;
  static const int maxRepeatMinSeconds = 86400;
  static const int maxRefreshEvery = 10000;

  /// 缺项 / 坏值回落到默认值，越界的夹到合法范围。
  static SrsRwkvQueueSettings fromValue(Object? v) {
    const SrsRwkvQueueSettings d = SrsRwkvQueueSettings();
    if (v is! Map) return d;
    int read(String key, int fallback, int max) => switch (v[key]) {
      final int n => n.clamp(0, max),
      _ => fallback,
    };
    return SrsRwkvQueueSettings(
      minReviewsPerDay: read(
        'minReviews',
        d.minReviewsPerDay,
        maxMinReviewsPerDay,
      ),
      repeatMinReviews: read(
        'repeatReviews',
        d.repeatMinReviews,
        maxRepeatMinReviews,
      ),
      repeatMinSeconds: read(
        'repeatSeconds',
        d.repeatMinSeconds,
        maxRepeatMinSeconds,
      ),
      refreshEvery: math.max(
        1,
        read('refreshEvery', d.refreshEvery, maxRefreshEvery),
      ),
    );
  }

  Map<String, Object?> toValue() => <String, Object?>{
    'minReviews': minReviewsPerDay,
    'repeatReviews': repeatMinReviews,
    'repeatSeconds': repeatMinSeconds,
    'refreshEvery': refreshEvery,
  };

  @override
  bool operator ==(Object other) =>
      other is SrsRwkvQueueSettings &&
      other.minReviewsPerDay == minReviewsPerDay &&
      other.repeatMinReviews == repeatMinReviews &&
      other.repeatMinSeconds == repeatMinSeconds &&
      other.refreshEvery == refreshEvery;

  @override
  int get hashCode => Object.hash(
    minReviewsPerDay,
    repeatMinReviews,
    repeatMinSeconds,
    refreshEvery,
  );
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
    this.rwkvQueue = const SrsRwkvQueueSettings(),
    this.newCardOrder = SrsNewCardOrder.frequency,
    required this.optimizeBaselineAt,
    required this.optimizeBaselineCount,
    required this.deletedAt,
    required this.builtinKey,
    required this.createdAt,
    required this.edits,
    this.collapsed = false,
    this.position,
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

  /// 同级里的手动排序位（[SrsFieldKeys.deckPosition]）；null = 没排过。
  final double? position;

  /// 同级排序：有位置的按位置在前，其余按名字；最后按 id 定序（全确定性，各端一致）。
  static int compareSiblings(SrsDeckView a, SrsDeckView b) {
    final double pa = a.position ?? double.infinity;
    final double pb = b.position ?? double.infinity;
    if (pa != pb) return pa.compareTo(pb);
    final int byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }

  /// 复习时自动播放卡面音频（Anki「自动播放音频」）。只看 own 祖先上的值
  /// （[SrsDeckTree.paramsOwner]）。
  final bool autoplayAudio;

  /// 答案面重播时先播问题音频（Anki 默认；false = 「重播答案时跳过问题」）。
  /// 只看 own 祖先上的值。
  final bool replayQuestionAudio;

  /// RWKV-Instant 排队设置。只看 own 祖先上的值（[SrsDeckTree.paramsOwner]）。
  final SrsRwkvQueueSettings rwkvQueue;

  /// 新卡出卡顺序。只看 own 祖先上的值（[SrsDeckTree.paramsOwner]）。
  final SrsNewCardOrder newCardOrder;
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

  SrsParamSet? paramSetFor(SrsAlgorithm a) => switch (a.memoryAlgorithm) {
    SrsAlgorithm.fsrs6 => fsrs6,
    SrsAlgorithm.fsrs7 || SrsAlgorithm.rwkv => fsrs7,
  };
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

  /// 卡片的有效牌组：[deckId] 不在本树里（牌组在别的设备删了、或卡片的移动先于牌组同步到）
  /// 时归到 [fallback]（默认牌组）。排程配置、浏览页 / 统计页的牌组名与 `deck:` 搜索共用
  /// 这一判据（BUG-3617），不要各写一份。
  String effectiveDeckOf(String deckId, {required String fallback}) =>
      _byId.containsKey(deckId) ? deckId : fallback;

  /// [effectiveDeckOf] 的全名；连 [fallback] 也不在树里时为空串。
  String effectiveDeckNameOf(String deckId, {required String fallback}) {
    final String id = effectiveDeckOf(deckId, fallback: fallback);
    return _byId.containsKey(id) ? fullName(id) : '';
  }

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
        : (defaultsOf?.call(alg.memoryAlgorithm) ?? const <double>[]);
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
