/// 牌组设置：名称、每日上限、目标记忆率、学习 / 重学步长、复习音频（自动播放 / 重播含问题）；「高级」默认收起：排程算法、
/// 自动优化（上次优化时间与 log loss、「立即优化」「恢复默认参数」）、最大间隔、参数继承与
/// 「立即重排整组」。
///
/// 只写真正改动过的键（与物化视图逐项比较），没碰过的设置不产生修改记录——否则
/// 每打开保存一次就在同步里多一批与默认值相同的记录，还会无谓地和别的设备冲突。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_optimizer.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_optimization_scheduler.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rwkv_panel.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 步长输入（「1 10」/「1, 10」，单位分钟）→ 列表；有解析不了的项返回 null。
List<double>? parseSrsSteps(String text) {
  final List<String> parts = text
      .split(RegExp(r'[\s,，、]+'))
      .where((String s) => s.isNotEmpty)
      .toList();
  // 留空 = 不用步长（直接进复习）。
  if (parts.isEmpty) return const <double>[];
  final List<double> out = <double>[];
  for (final String p in parts) {
    final double? v = double.tryParse(p);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

String _formatSteps(List<double> steps) => steps
    .map((double s) => s == s.roundToDouble() ? '${s.round()}' : '$s')
    .join(' ');

String _two(int v) => v.toString().padLeft(2, '0');

/// 「上次优化」的时刻（本地时区，`yyyy-MM-dd HH:mm`）。
String srsFormatOptimizedAt(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  return '${d.year}-${_two(d.month)}-${_two(d.day)} '
      '${_two(d.hour)}:${_two(d.minute)}';
}

String _algorithmLabel(SrsAlgorithm a) => switch (a) {
  SrsAlgorithm.fsrs7 => 'FSRS-7',
  SrsAlgorithm.fsrs6 => 'FSRS-6',
  SrsAlgorithm.rwkv => 'RWKV',
};

class SrsDeckSettingsPage extends ConsumerStatefulWidget {
  const SrsDeckSettingsPage({super.key, required this.deckId});

  final String deckId;

  @override
  ConsumerState<SrsDeckSettingsPage> createState() =>
      _SrsDeckSettingsPageState();
}

class _SrsDeckSettingsPageState extends ConsumerState<SrsDeckSettingsPage> {
  SrsDbStore? _store;
  SrsDeckView? _deck;
  SrsDeckView? _owner;
  bool _hasParent = false;

  /// 子树里自己管参数（own）的后代牌组：「子牌组都继承这里」要改的那些。
  List<String> _ownDescendants = const <String>[];
  bool _loading = true;
  bool _saving = false;
  bool _optimizing = false;
  Object? _error;

  /// 本牌组上「被另一台设备覆盖」的设置键。
  Set<String> _conflictKeys = const <String>{};

  final TextEditingController _name = TextEditingController();
  final TextEditingController _newPerDay = TextEditingController();
  final TextEditingController _reviewsPerDay = TextEditingController();
  final TextEditingController _learnSteps = TextEditingController();
  final TextEditingController _relearnSteps = TextEditingController();
  final TextEditingController _maxInterval = TextEditingController();
  final TextEditingController _rwkvMinReviews = TextEditingController();
  final TextEditingController _rwkvRepeatReviews = TextEditingController();
  final TextEditingController _rwkvRepeatSeconds = TextEditingController();
  final TextEditingController _rwkvRefreshEvery = TextEditingController();
  final TextEditingController _newLoadBudget = TextEditingController();
  final TextEditingController _newLoadBoost = TextEditingController();
  bool _newLoadAuto = true;
  bool _rwkvIgnoreLimit = false;
  double _retention = 0.8;
  SrsAlgorithm _algorithm = srsDefaultAlgorithm;
  bool _autoOptimize = true;
  bool _ownParams = true;
  bool _autoplayAudio = true;
  bool _replayQuestionAudio = true;
  SrsNewCardOrder _newCardOrder = SrsNewCardOrder.frequency;

  String? _learnError;
  String? _relearnError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _newPerDay,
      _reviewsPerDay,
      _learnSteps,
      _relearnSteps,
      _maxInterval,
      _rwkvMinReviews,
      _rwkvRepeatReviews,
      _rwkvRepeatSeconds,
      _rwkvRefreshEvery,
      _newLoadBudget,
      _newLoadBoost,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final SrsDeckTree tree = await store.deckTree();
      final SrsDeckView? deck = tree[widget.deckId];
      if (deck == null) throw StateError('deck ${widget.deckId} not found');
      final Set<String> conflictKeys = <String>{
        for (final (SrsEntityKind kind, String id, SrsRegister reg)
            in await store.syncConflicts())
          if (kind == SrsEntityKind.deck && id == widget.deckId) reg.key,
      };
      if (!mounted) return;
      setState(() {
        _store = store;
        _deck = deck;
        _owner = tree.paramsOwner(deck.id);
        _hasParent = tree.parentOf(deck.id) != null;
        _ownDescendants = <String>[
          for (final String id in tree.subtree(deck.id).skip(1))
            if (tree[id]!.ownParams) id,
        ];
        _conflictKeys = conflictKeys;
        _name.text = deck.name;
        _newPerDay.text = '${deck.newPerDay}';
        _reviewsPerDay.text = '${deck.reviewsPerDay}';
        _learnSteps.text = _formatSteps(deck.learnSteps);
        _relearnSteps.text = _formatSteps(deck.relearnSteps);
        _maxInterval.text = '${deck.maxIntervalDays}';
        _retention = deck.desiredRetention.clamp(0.7, 0.97);
        _algorithm = deck.localAlgorithm;
        _autoOptimize = deck.autoOptimize;
        _ownParams = deck.ownParams;
        _autoplayAudio = deck.autoplayAudio;
        _replayQuestionAudio = deck.replayQuestionAudio;
        _newCardOrder = deck.newCardOrder;
        _rwkvMinReviews.text = '${deck.rwkvQueue.minReviewsPerDay}';
        _rwkvRepeatReviews.text = '${deck.rwkvQueue.repeatMinReviews}';
        _rwkvRepeatSeconds.text = '${deck.rwkvQueue.repeatMinSeconds}';
        _rwkvRefreshEvery.text = '${deck.rwkvQueue.refreshEvery}';
        _rwkvIgnoreLimit = deck.rwkvQueue.ignoreReviewLimit;
        _newLoadAuto = deck.newCardPlan.autoLoad;
        _newLoadBudget.text = '${deck.newCardPlan.budgetPercent}';
        _newLoadBoost.text = '${deck.newCardPlan.boostPercent}';
        _loading = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDeckSettingsPage.load', e, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  /// 输入框里的 RWKV 排队设置；空 / 非数字的项沿用 [current]，越界的夹到合法范围。
  SrsRwkvQueueSettings _rwkvQueue(SrsRwkvQueueSettings current) =>
      SrsRwkvQueueSettings.fromValue(<String, Object?>{
        'minReviews':
            int.tryParse(_rwkvMinReviews.text.trim()) ??
            current.minReviewsPerDay,
        'repeatReviews':
            int.tryParse(_rwkvRepeatReviews.text.trim()) ??
            current.repeatMinReviews,
        'repeatSeconds':
            int.tryParse(_rwkvRepeatSeconds.text.trim()) ??
            current.repeatMinSeconds,
        'refreshEvery':
            int.tryParse(_rwkvRefreshEvery.text.trim()) ?? current.refreshEvery,
        'ignoreLimit': _rwkvIgnoreLimit,
      });

  /// 输入框里的新卡计划；空 / 非数字的项沿用 [current]，越界的夹到合法范围。
  SrsNewCardPlan _newCardPlan(
    SrsNewCardPlan current,
  ) => SrsNewCardPlan.fromValue(<String, Object?>{
    'auto': _newLoadAuto,
    'budget': int.tryParse(_newLoadBudget.text.trim()) ?? current.budgetPercent,
    'boost': int.tryParse(_newLoadBoost.text.trim()) ?? current.boostPercent,
  });

  /// 与物化视图逐项比较，只收改动过的键。步长不合法返回 null（并标出错误）。
  Map<String, Object?>? _changes() {
    final SrsDeckView deck = _deck!;
    final Map<String, Object?> out = <String, Object?>{};
    final String name = _name.text.trim();
    if (name.isNotEmpty && !name.contains('::') && name != deck.name) {
      out[SrsFieldKeys.name] = name;
    }
    final int newPerDay =
        int.tryParse(_newPerDay.text.trim()) ?? deck.newPerDay;
    final int reviewsPerDay =
        int.tryParse(_reviewsPerDay.text.trim()) ?? deck.reviewsPerDay;
    if (newPerDay != deck.newPerDay || reviewsPerDay != deck.reviewsPerDay) {
      out[SrsFieldKeys.deckLimits] = <String, Object?>{
        'new': newPerDay.clamp(0, 9999),
        'review': reviewsPerDay.clamp(0, 99999),
      };
    }
    // 新卡计划与每日上限一样是牌组自己的值（不随参数继承）。
    final SrsNewCardPlan plan = _newCardPlan(deck.newCardPlan);
    if (plan != deck.newCardPlan) {
      out[SrsFieldKeys.deckNewPlan] = plan.toValue();
    }
    final List<double>? learn = parseSrsSteps(_learnSteps.text);
    final List<double>? relearn = parseSrsSteps(_relearnSteps.text);
    _learnError = learn == null || !srsValidateSteps(learn)
        ? t.srs_settings_steps_invalid
        : null;
    _relearnError = relearn == null || !srsValidateSteps(relearn)
        ? t.srs_settings_steps_invalid
        : null;
    if (_learnError != null || _relearnError != null) return null;
    if (_formatSteps(learn!) != _formatSteps(deck.learnSteps) ||
        _formatSteps(relearn!) != _formatSteps(deck.relearnSteps)) {
      out[SrsFieldKeys.deckSteps] = <String, Object?>{
        'learn': learn,
        'relearn': relearn,
      };
    }
    final int maxInterval =
        int.tryParse(_maxInterval.text.trim()) ?? deck.maxIntervalDays;
    if (maxInterval != deck.maxIntervalDays) {
      out[SrsFieldKeys.deckMaxInterval] = maxInterval.clamp(1, 36500);
    }
    if (_hasParent && _ownParams != deck.ownParams) {
      out[SrsFieldKeys.deckParamsMode] = _ownParams ? 'own' : 'inherit';
    }
    // 算法 / 记忆率 / 自动优化只在本牌组自己管参数时可改（继承时由上级决定）。
    if (_ownParams || !_hasParent) {
      if ((_retention - deck.desiredRetention).abs() > 1e-9) {
        out[SrsFieldKeys.deckRetention] = double.parse(
          _retention.toStringAsFixed(2),
        );
      }
      if (_algorithm.wire != deck.algorithmWire) {
        out[SrsFieldKeys.deckAlgorithm] = <String, Object?>{
          'alg': _algorithm.wire,
          'auto': false,
        };
      }
      if (_autoOptimize != deck.autoOptimize) {
        out[SrsFieldKeys.deckAutoOptimize] = _autoOptimize;
      }
      // 音频两项与记忆率同一条继承（Anki 里它们同属一个预设）。
      if (_autoplayAudio != deck.autoplayAudio) {
        out[SrsFieldKeys.deckAutoplay] = _autoplayAudio;
      }
      if (_replayQuestionAudio != deck.replayQuestionAudio) {
        out[SrsFieldKeys.deckReplayQuestion] = _replayQuestionAudio;
      }
      if (_newCardOrder != deck.newCardOrder) {
        out[SrsFieldKeys.deckNewOrder] = _newCardOrder.wire;
      }
      final SrsRwkvQueueSettings queue = _rwkvQueue(deck.rwkvQueue);
      if (queue != deck.rwkvQueue) {
        out[SrsFieldKeys.deckRwkvQueue] = queue.toValue();
      }
    }
    return out;
  }

  Future<void> _save() async {
    final SrsDbStore? store = _store;
    if (store == null || _deck == null || _saving) return;
    final Map<String, Object?>? changes = _changes();
    if (changes == null) {
      setState(() {});
      return;
    }
    setState(() => _saving = true);
    try {
      if (changes.isNotEmpty) {
        await store.editFields(SrsEntityKind.deck, widget.deckId, changes);
      }
      if (!mounted) return;
      bumpSrsRevision(ref);
      FushiToast.show(
        msg: t.srs_settings_saved,
        severity: ToastSeverity.success,
      );
      await Navigator.of(context).maybePop();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDeckSettingsPage.save', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rescheduleAll() async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_settings_reschedule,
      message: t.srs_settings_reschedule_confirm,
      confirmLabel: t.srs_settings_reschedule,
      cancelLabel: t.cancel,
      icon: FushiIcons.schedule,
    );
    if (!ok || !mounted) return;
    final int n = await store.rescheduleDeck(widget.deckId);
    if (!mounted) return;
    bumpSrsRevision(ref);
    FushiToast.show(msg: t.srs_settings_rescheduled(n: n));
  }

  /// 「子牌组都继承这里」：把子树里所有「单独设置」的后代一次改成「继承上级」，之后改这里的
  /// 记忆率 / 算法 / 自动优化就对整棵子树生效（Anki 导入的子牌组常各带一份预设，逐个改太累）。
  /// 后代自己的步长与每日上限不动。
  Future<void> _childrenInherit() async {
    final SrsDbStore? store = _store;
    final List<String> targets = _ownDescendants;
    if (store == null || targets.isEmpty) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_settings_children_inherit(n: targets.length),
      message: t.srs_settings_children_inherit_confirm(n: targets.length),
      confirmLabel: t.srs_settings_children_inherit(n: targets.length),
      cancelLabel: t.cancel,
      icon: FushiIcons.merge,
    );
    if (!ok || !mounted) return;
    await store.writeEdits(<SrsEditSpec>[
      for (final String id in targets)
        SrsEditSpec(
          SrsEntityKind.deck,
          id,
          SrsFieldKeys.deckParamsMode,
          'inherit',
        ),
    ]);
    if (!mounted) return;
    bumpSrsRevision(ref);
    FushiToast.show(
      msg: t.srs_settings_children_inherit_done(n: targets.length),
      severity: ToastSeverity.success,
    );
    await _load();
  }

  /// 「立即优化」：只跑本牌组所属的参数组；跳过样本门槛与触发基线（用户显式要求），
  /// 新参数在同一份数据上不比当前好就不采用（与自动优化同一条采用判据）。
  Future<void> _optimizeNow() async {
    final SrsAppRuntime? runtime = ref.read(srsAppRuntimeProvider);
    if (runtime == null || _optimizing) return;
    setState(() => _optimizing = true);
    try {
      final SrsOptimizationRound? round = await runtime.optimizer.runNow(
        onlyDeckId: widget.deckId,
        force: true,
      );
      if (!mounted) return;
      if (round == null) {
        FushiToast.show(msg: t.srs_engine_unavailable);
      } else if (round.applied.isEmpty) {
        FushiToast.show(msg: t.srs_settings_optimize_not_enough);
      } else if (round.applied.any((SrsOptimizationResult r) => r.adopted)) {
        FushiToast.show(
          msg: t.srs_settings_optimize_done,
          severity: ToastSeverity.success,
        );
      } else {
        FushiToast.show(msg: t.srs_settings_optimize_kept);
      }
      bumpSrsRevision(ref);
      await _load();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDeckSettingsPage.optimize', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _optimizing = false);
    }
  }

  /// 「恢复默认参数」：清掉当前算法的参数组，触发基线重置为「此刻 + 当前有效复习条数」。
  Future<void> _resetParams() async {
    final SrsDbStore? store = _store;
    final SrsDeckView? owner = _owner;
    if (store == null || owner == null) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_settings_reset_params,
      message: t.srs_settings_reset_params_confirm,
      confirmLabel: t.srs_settings_reset_params,
      cancelLabel: t.cancel,
      icon: FushiIcons.restart,
    );
    if (!ok || !mounted) return;
    try {
      final SrsOptimizationInput? input = await srsPrepareOptimization(
        store,
        owner.id,
      );
      await srsResetParams(
        store,
        owner.id,
        owner.localAlgorithm,
        reviewCount: input?.reviewCount ?? 0,
      );
      if (!mounted) return;
      bumpSrsRevision(ref);
      FushiToast.show(
        msg: t.srs_settings_reset_params_done,
        severity: ToastSeverity.success,
      );
      await _load();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsDeckSettingsPage.resetParams', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    }
  }

  /// 参数组状态（上次优化时间与 log loss）+ 两个按钮。
  List<Widget> _optimizationSection(BuildContext context) {
    final SrsDeckView? owner = _owner;
    if (owner == null) return const <Widget>[];
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsParamSet? set = owner.paramSetFor(owner.localAlgorithm);
    final int? at = set?.optimizedAt;
    final double? loss = set?.logLoss;
    final bool canOptimize =
        !_optimizing &&
        (_store?.canSchedule ?? false) &&
        ref.watch(srsAppRuntimeProvider) != null;
    return <Widget>[
      Text(
        at == null
            ? t.srs_settings_optimize_never
            : t.srs_settings_optimize_last(
                time: srsFormatOptimizedAt(at),
                loss: loss == null ? '—' : loss.toStringAsFixed(4),
              ),
        key: const ValueKey<String>('srs-settings-optimize-status'),
        style: context.fushiType.bodySmall,
      ),
      SizedBox(height: tokens.spacing.gap),
      Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          FushiOutlinedButton.icon(
            key: const ValueKey<String>('srs-settings-optimize-now'),
            onPressed: canOptimize
                ? () => srsRunLogged('SrsDeckSettings.optimize', _optimizeNow)
                : null,
            icon: _optimizing
                ? const SizedBox.square(
                    dimension: 18,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  )
                : const FushiIcon(FushiIcons.modelTraining),
            label: Text(
              _optimizing
                  ? t.srs_settings_optimize_running
                  : t.srs_settings_optimize_now,
            ),
          ),
          FushiOutlinedButton.icon(
            key: const ValueKey<String>('srs-settings-reset-params'),
            onPressed: _optimizing || set == null
                ? null
                : () => srsRunLogged('SrsDeckSettings.reset', _resetParams),
            icon: const FushiIcon(FushiIcons.restart),
            label: Text(t.srs_settings_reset_params),
          ),
        ],
      ),
    ];
  }

  FushiToolbarItem get _saveItem => FushiToolbarItem(
    key: const ValueKey<String>('srs_settings_save'),
    icon: FushiIcons.save,
    label: t.srs_settings_save,
    onPressed: _saving || _deck == null ? null : () => unawaited(_save()),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final String title = t.srs_deck_settings;
    return FushiPageScaffold(
      title: title,
      subtitle: _deck?.name,
      header: apple ? null : _buildTopBar(context, title),
      actions: apple
          ? <Widget>[
              FushiIconButton(
                key: _saveItem.key,
                icon: _saveItem.icon,
                tooltip: _saveItem.label,
                enabled: _saveItem.onPressed != null,
                onTap: _saveItem.onPressed,
              ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context, String title) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: title,
        subtitle: _deck?.name ?? '',
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_saveItem],
        ],
      ),
    );
  }

  /// 这项设置被另一台设备的修改替换了：项旁一行提示。
  Widget? _conflictNote(BuildContext context, String key) {
    if (!_conflictKeys.contains(key)) return null;
    return Text(
      t.srs_settings_conflict_replaced,
      style: context.fushiType.labelMedium.copyWith(
        color: Theme.of(context).colorScheme.error,
      ),
    );
  }

  Widget _numberField(
    TextEditingController controller,
    String label, {
    String? helper,
    Key? key,
  }) => FushiTextField(
    key: key,
    controller: controller,
    labelText: label,
    helperText: helper,
    keyboardType: TextInputType.number,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
    ],
  );

  /// RWKV-Instant 的排队设置（上游 kuma3 的 RWKV 牌组选项）。
  Widget _rwkvQueueSection(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      key: const ValueKey<String>('srs-settings-rwkv-queue'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap * 1.5,
      children: <Widget>[
        Text(t.srs_settings_rwkv_queue, style: tokens.type.sectionLabel),
        Text(
          t.srs_settings_rwkv_steps_note,
          style: context.fushiType.bodySmall,
        ),
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('srs-settings-rwkv-ignore-limit'),
          title: t.srs_settings_rwkv_ignore_limit,
          subtitle: t.srs_settings_rwkv_ignore_limit_hint,
          value: _rwkvIgnoreLimit,
          onChanged: (bool v) => setState(() => _rwkvIgnoreLimit = v),
        ),
        _numberField(
          _rwkvMinReviews,
          t.srs_settings_rwkv_min_reviews,
          helper: t.srs_settings_rwkv_min_reviews_hint,
          key: const ValueKey<String>('srs-settings-rwkv-min-reviews'),
        ),
        _numberField(
          _rwkvRefreshEvery,
          t.srs_settings_rwkv_refresh_every,
          helper: t.srs_settings_rwkv_refresh_every_hint,
          key: const ValueKey<String>('srs-settings-rwkv-refresh-every'),
        ),
        Text(
          t.srs_settings_rwkv_repeat,
          style: context.fushiType.titleSmallEmphasized,
        ),
        _numberField(
          _rwkvRepeatReviews,
          t.srs_settings_rwkv_repeat_reviews,
          key: const ValueKey<String>('srs-settings-rwkv-repeat-reviews'),
        ),
        _numberField(
          _rwkvRepeatSeconds,
          t.srs_settings_rwkv_repeat_seconds,
          helper: t.srs_settings_rwkv_repeat_hint,
          key: const ValueKey<String>('srs-settings-rwkv-repeat-seconds'),
        ),
        ?_conflictNote(context, SrsFieldKeys.deckRwkvQueue),
      ],
    );
  }

  Widget _group(BuildContext context, List<Widget?> children) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap * 1.5,
        children: children.whereType<Widget>().toList(),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final SrsDeckView? deck = _deck;
    if (_error != null || deck == null) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: _error == null ? null : '$_error',
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool ownsParams = _ownParams || !_hasParent;
    // 宽窗（手机横屏 / 桌面）：左栏基础项（名字、每日上限、保留率、学习步骤），
    // 右栏高级项且默认展开——横屏只有 ~400 高，右栏不必再点开一层才看得见。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = srsUsesTwoPane(constraints);
        return SrsAdaptiveSections(
          sections: <SrsSection>[
            for (final Widget w in _basicGroups(context, ownsParams))
              SrsSection(w),
            SrsSection(
              pane: SrsPane.secondary,
              FushiCard(
                padding: EdgeInsets.zero,
                child: FushiExpansionTile(
                  key: const ValueKey<String>('srs-settings-advanced'),
                  leading: const FushiIcon(FushiIcons.settingsGear),
                  title: Text(t.srs_settings_advanced),
                  initiallyExpanded: wide,
                  maintainState: true,
                  childrenPadding: EdgeInsets.fromLTRB(
                    tokens.spacing.card,
                    0,
                    tokens.spacing.card,
                    tokens.spacing.card,
                  ),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildAdvanced(context, deck, ownsParams),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _basicGroups(BuildContext context, bool ownsParams) {
    return <Widget>[
      _group(context, <Widget?>[
        FushiTextField(
          key: const ValueKey<String>('srs-settings-name'),
          controller: _name,
          labelText: t.srs_deck_name,
        ),
        _conflictNote(context, SrsFieldKeys.name),
      ]),
      _group(context, <Widget?>[
        _numberField(
          _newPerDay,
          t.srs_settings_new_per_day,
          helper: t.srs_settings_new_per_day_hint,
          key: const ValueKey<String>('srs-settings-new'),
        ),
        _numberField(
          _reviewsPerDay,
          t.srs_settings_reviews_per_day,
          key: const ValueKey<String>('srs-settings-review'),
        ),
        _conflictNote(context, SrsFieldKeys.deckLimits),
      ]),
      _group(context, <Widget?>[
        if (ownsParams) ...<Widget?>[
          Text(
            t.srs_settings_retention_value(p: (_retention * 100).round()),
            style: context.fushiType.titleSmallEmphasized,
          ),
          FushiSlider(
            key: const ValueKey<String>('srs-settings-retention'),
            value: _retention,
            min: 0.7,
            max: 0.97,
            divisions: 27,
            label: '${(_retention * 100).round()}%',
            onChanged: (double v) => setState(() => _retention = v),
          ),
          Text(
            t.srs_settings_retention_hint,
            style: context.fushiType.bodySmall,
          ),
          _conflictNote(context, SrsFieldKeys.deckRetention),
        ] else
          Text(
            t.srs_settings_inherited_from(name: _owner?.name ?? ''),
            style: context.fushiType.bodyMedium,
          ),
      ]),
      _group(context, <Widget?>[
        Text(
          t.srs_settings_audio,
          style: context.fushiType.titleSmallEmphasized,
        ),
        if (ownsParams) ...<Widget?>[
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-settings-autoplay-audio'),
            title: t.srs_settings_autoplay_audio,
            subtitle: t.srs_settings_autoplay_audio_hint,
            value: _autoplayAudio,
            onChanged: (bool v) => setState(() => _autoplayAudio = v),
          ),
          _conflictNote(context, SrsFieldKeys.deckAutoplay),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-settings-replay-question-audio'),
            title: t.srs_settings_replay_question_audio,
            subtitle: t.srs_settings_replay_question_audio_hint,
            value: _replayQuestionAudio,
            onChanged: (bool v) => setState(() => _replayQuestionAudio = v),
          ),
          _conflictNote(context, SrsFieldKeys.deckReplayQuestion),
        ] else
          Text(
            t.srs_settings_inherited_from(name: _owner?.name ?? ''),
            style: context.fushiType.bodyMedium,
          ),
      ]),
      _group(context, <Widget?>[
        FushiTextField(
          key: const ValueKey<String>('srs-settings-learn-steps'),
          controller: _learnSteps,
          labelText: t.srs_settings_learn_steps,
          helperText:
              '${t.srs_settings_steps_hint}\n${t.srs_settings_steps_empty_hint}',
          errorText: _learnError,
        ),
        FushiTextField(
          key: const ValueKey<String>('srs-settings-relearn-steps'),
          controller: _relearnSteps,
          labelText: t.srs_settings_relearn_steps,
          helperText:
              '${t.srs_settings_steps_hint}\n${t.srs_settings_steps_empty_hint}',
          errorText: _relearnError,
        ),
        _conflictNote(context, SrsFieldKeys.deckSteps),
      ]),
      // 新卡顺序与记忆率同一条继承（只看 own 祖先，见 [SrsDeckView.newCardOrder]）。
      _group(context, <Widget?>[
        if (ownsParams) ...<Widget?>[
          AdaptiveSettingsSegmentedRow<SrsNewCardOrder>(
            key: const ValueKey<String>('srs-settings-new-order'),
            title: t.srs_settings_new_order,
            subtitle: switch (_newCardOrder) {
              SrsNewCardOrder.frequency =>
                t.srs_settings_new_order_frequency_hint,
              SrsNewCardOrder.position =>
                t.srs_settings_new_order_position_hint,
            },
            segments: <ButtonSegment<SrsNewCardOrder>>[
              ButtonSegment<SrsNewCardOrder>(
                value: SrsNewCardOrder.frequency,
                label: Text(t.srs_settings_new_order_frequency),
              ),
              ButtonSegment<SrsNewCardOrder>(
                value: SrsNewCardOrder.position,
                label: Text(t.srs_settings_new_order_position),
              ),
            ],
            selected: _newCardOrder,
            onChanged: (SrsNewCardOrder v) => setState(() => _newCardOrder = v),
          ),
          _conflictNote(context, SrsFieldKeys.deckNewOrder),
        ] else
          Text(
            t.srs_settings_inherited_from(name: _owner?.name ?? ''),
            style: context.fushiType.bodyMedium,
          ),
      ]),
      // 新卡计划与每日上限一样是牌组自己的值（不随继承），放在新卡顺序之后。
      _group(context, <Widget?>[
        Text(
          t.srs_settings_new_plan,
          style: context.fushiType.titleSmallEmphasized,
        ),
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('srs-settings-new-load-auto'),
          title: t.srs_settings_new_load_auto,
          subtitle: t.srs_settings_new_load_auto_hint,
          value: _newLoadAuto,
          onChanged: (bool v) => setState(() => _newLoadAuto = v),
        ),
        if (_newLoadAuto) ...<Widget?>[
          _numberField(
            _newLoadBudget,
            t.srs_settings_new_load_budget,
            helper: t.srs_settings_new_load_budget_hint,
            key: const ValueKey<String>('srs-settings-new-load-budget'),
          ),
          _numberField(
            _newLoadBoost,
            t.srs_settings_new_load_boost,
            helper: t.srs_settings_new_load_boost_hint,
            key: const ValueKey<String>('srs-settings-new-load-boost'),
          ),
        ],
        _conflictNote(context, SrsFieldKeys.deckNewPlan),
      ]),
    ];
  }

  List<Widget> _buildAdvanced(
    BuildContext context,
    SrsDeckView deck,
    bool ownsParams,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget gap = SizedBox(height: tokens.spacing.gap * 1.5);
    final List<Widget> out = <Widget>[];
    void add(Widget? w) {
      if (w == null) return;
      if (out.isNotEmpty) out.add(gap);
      out.add(w);
    }

    if (_hasParent) {
      add(Text(t.srs_settings_params_mode, style: tokens.type.sectionLabel));
      out.add(SizedBox(height: tokens.spacing.gap));
      out.add(
        FushiSegmentedButton<bool>(
          key: const ValueKey<String>('srs-settings-params-mode'),
          showSelectedIcon: false,
          segments: <ButtonSegment<bool>>[
            ButtonSegment<bool>(
              value: false,
              label: Text(t.srs_settings_params_inherit),
            ),
            ButtonSegment<bool>(
              value: true,
              label: Text(t.srs_settings_params_own),
            ),
          ],
          selected: <bool>{_ownParams},
          onSelectionChanged: (Set<bool> v) =>
              setState(() => _ownParams = v.first),
        ),
      );
      add(_conflictNote(context, SrsFieldKeys.deckParamsMode));
    }
    if (_ownDescendants.isNotEmpty) {
      add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiOutlinedButton.icon(
              key: const ValueKey<String>('srs-settings-children-inherit'),
              onPressed: () => srsRunLogged(
                'SrsDeckSettings.childrenInherit',
                _childrenInherit,
              ),
              icon: const FushiIcon(FushiIcons.merge),
              label: Text(
                t.srs_settings_children_inherit(n: _ownDescendants.length),
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.srs_settings_children_inherit_hint,
              style: context.fushiType.bodySmall,
            ),
          ],
        ),
      );
    }
    if (ownsParams) {
      add(Text(t.srs_settings_algorithm, style: tokens.type.sectionLabel));
      out.add(SizedBox(height: tokens.spacing.gap));
      out.add(
        FushiSegmentedButton<SrsAlgorithm>(
          key: const ValueKey<String>('srs-settings-algorithm'),
          showSelectedIcon: false,
          segments: <ButtonSegment<SrsAlgorithm>>[
            // 默认算法（srsDefaultAlgorithm）排第一并标「推荐」，FSRS-7 次之。
            ButtonSegment<SrsAlgorithm>(
              value: SrsAlgorithm.rwkv,
              label: Text(t.srs_settings_algorithm_rwkv_recommended),
            ),
            ButtonSegment<SrsAlgorithm>(
              value: SrsAlgorithm.fsrs7,
              label: Text(_algorithmLabel(SrsAlgorithm.fsrs7)),
            ),
            ButtonSegment<SrsAlgorithm>(
              value: SrsAlgorithm.fsrs6,
              label: Text(_algorithmLabel(SrsAlgorithm.fsrs6)),
            ),
          ],
          selected: <SrsAlgorithm>{_algorithm},
          onSelectionChanged: (Set<SrsAlgorithm> v) =>
              setState(() => _algorithm = v.first),
        ),
      );
      if (deck.algorithmUnknownLocally) {
        add(
          Text(
            t.srs_settings_algorithm_unknown(
              alg: _algorithmLabel(deck.localAlgorithm),
            ),
            style: context.fushiType.bodySmall.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        );
      }
      add(
        Text(t.srs_settings_algorithm_hint, style: context.fushiType.bodySmall),
      );
      if (_algorithm == SrsAlgorithm.rwkv) {
        add(const SrsRwkvPanel(key: ValueKey<String>('srs-settings-rwkv')));
        add(_rwkvQueueSection(context));
      }
      add(_conflictNote(context, SrsFieldKeys.deckAlgorithm));
      add(
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('srs-settings-auto-optimize'),
          title: t.srs_settings_auto_optimize,
          // RWKV 牌组优化的是影子记忆状态（FSRS-7）的参数（srsPrepareOptimization），要写明它管
          // 什么，否则看着像「RWKV 还得手动点优化」。
          subtitle: _algorithm.usesRwkv
              ? t.srs_settings_auto_optimize_rwkv_hint
              : t.srs_settings_auto_optimize_hint,
          value: _autoOptimize,
          onChanged: (bool v) => setState(() => _autoOptimize = v),
        ),
      );
      add(_conflictNote(context, SrsFieldKeys.deckAutoOptimize));
      final List<Widget> optimization = _optimizationSection(context);
      if (optimization.isNotEmpty) {
        add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: optimization,
          ),
        );
      }
    }
    add(
      _numberField(
        _maxInterval,
        t.srs_settings_max_interval,
        helper: t.srs_settings_max_interval_hint,
        key: const ValueKey<String>('srs-settings-max-interval'),
      ),
    );
    add(_conflictNote(context, SrsFieldKeys.deckMaxInterval));
    add(
      FushiOutlinedButton.icon(
        key: const ValueKey<String>('srs-settings-reschedule'),
        onPressed: _store?.canSchedule ?? false
            ? () => srsRunLogged('SrsDeckSettings.reschedule', _rescheduleAll)
            : null,
        icon: const FushiIcon(FushiIcons.schedule),
        label: Text(t.srs_settings_reschedule),
      ),
    );
    return out;
  }
}
