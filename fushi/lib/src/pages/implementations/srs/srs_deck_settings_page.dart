/// 牌组设置：名称、每日上限、目标记忆率、学习 / 重学步长；「高级」默认收起：排程算法、
/// 自动优化、最大间隔、参数继承与「立即重排整组」。
///
/// 只写真正改动过的键（与物化视图逐项比较），没碰过的设置不产生修改记录——否则
/// 每打开保存一次就在同步里多一批与默认值相同的记录，还会无谓地和别的设备冲突。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 步长输入（「1 10」/「1, 10」，单位分钟）→ 列表；有解析不了的项返回 null。
List<double>? parseSrsSteps(String text) {
  final List<String> parts = text
      .split(RegExp(r'[\s,，、]+'))
      .where((String s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
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

String _algorithmLabel(SrsAlgorithm a) => switch (a) {
  SrsAlgorithm.fsrs7 => 'FSRS-7',
  SrsAlgorithm.fsrs6 => 'FSRS-6',
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
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  /// 本牌组上「被另一台设备覆盖」的设置键。
  Set<String> _conflictKeys = const <String>{};

  final TextEditingController _name = TextEditingController();
  final TextEditingController _newPerDay = TextEditingController();
  final TextEditingController _reviewsPerDay = TextEditingController();
  final TextEditingController _learnSteps = TextEditingController();
  final TextEditingController _relearnSteps = TextEditingController();
  final TextEditingController _maxInterval = TextEditingController();
  double _retention = 0.8;
  SrsAlgorithm _algorithm = srsDefaultAlgorithm;
  bool _autoOptimize = true;
  bool _ownParams = true;

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
    final List<Widget> sections = <Widget>[
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
        FushiTextField(
          key: const ValueKey<String>('srs-settings-learn-steps'),
          controller: _learnSteps,
          labelText: t.srs_settings_learn_steps,
          helperText: t.srs_settings_steps_hint,
          errorText: _learnError,
        ),
        FushiTextField(
          key: const ValueKey<String>('srs-settings-relearn-steps'),
          controller: _relearnSteps,
          labelText: t.srs_settings_relearn_steps,
          helperText: t.srs_settings_steps_hint,
          errorText: _relearnError,
        ),
        _conflictNote(context, SrsFieldKeys.deckSteps),
      ]),
      FushiCard(
        padding: EdgeInsets.zero,
        child: FushiExpansionTile(
          key: const ValueKey<String>('srs-settings-advanced'),
          leading: const FushiIcon(FushiIcons.settingsGear),
          title: Text(t.srs_settings_advanced),
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
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(height: tokens.spacing.gap * 1.5),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index],
        ),
      ),
    );
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
    if (ownsParams) {
      add(Text(t.srs_settings_algorithm, style: tokens.type.sectionLabel));
      out.add(SizedBox(height: tokens.spacing.gap));
      out.add(
        FushiSegmentedButton<SrsAlgorithm>(
          key: const ValueKey<String>('srs-settings-algorithm'),
          showSelectedIcon: false,
          segments: <ButtonSegment<SrsAlgorithm>>[
            ButtonSegment<SrsAlgorithm>(
              value: SrsAlgorithm.fsrs7,
              label: Text(t.srs_settings_algorithm_fsrs7),
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
      add(_conflictNote(context, SrsFieldKeys.deckAlgorithm));
      add(
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('srs-settings-auto-optimize'),
          title: t.srs_settings_auto_optimize,
          subtitle: t.srs_settings_auto_optimize_hint,
          value: _autoOptimize,
          onChanged: (bool v) => setState(() => _autoOptimize = v),
        ),
      );
      add(_conflictNote(context, SrsFieldKeys.deckAutoOptimize));
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
