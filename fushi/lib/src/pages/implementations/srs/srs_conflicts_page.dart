/// 复习的同步冲突：两台设备同时改了同一项设置 / 卡片标志时，后写的生效、被覆盖的
/// 留在这里，逐条「改回」（写被覆盖的值）或「确认」（写当前值）；另列出内容类
/// 待裁决的笔记（字段并发修改），点开进编辑页处理；以及同步 v2 扣住的删除（一台设备删了、
/// 另一台同时还在改 / 复习 / 移动它：删除先不生效、条目照常可见，等这里选「删除」或「保留」，
/// docs/specs/2026-10-25-srs-sync-v2-design.md §5.3）；以及疑似重复的笔记（两台设备各自制了同一个词，§5.4），
/// 用户选「合并」才合并（复习历史并入保留的那条），选「不是重复」就不再提示。
///
/// 每一边都显示是哪台设备（「<名称>（Fushi X.Y）」，srs/srs_device_view.dart）、什么时候改的；文本值画出差异；
/// 每条给默认推荐并写明理由（设置类：修改时间更晚的一边；扣住的删除：保留——另一边还有复习 / 修改，保留不丢数据），
/// 同类冲突（同一种实体的同一项 / 同一种删除冲突）可以一次都按这个选。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/pages/implementations/srs/srs_value_diff.dart';
import 'package:fushi/src/srs/srs_device_view.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/srs/srs_navigation.dart';

/// 同步 v2 扣住的一次删除（内核 `sync2_conflicts` 的一行）。
class _HeldDelete {
  const _HeldDelete({
    required this.id,
    required this.kind,
    required this.by,
    required this.others,
    required this.at,
    required this.label,
  });

  final String id;

  /// `delete_edit` / `delete_review` / `delete_move`。
  final String kind;

  /// 删除它的设备。
  final String by;

  /// 与删除并发的修改条数。
  final int others;
  final int at;
  final String label;
}

/// 冲突页的一条（标志 / 设置类）。
class _Conflict {
  const _Conflict({
    required this.kind,
    required this.entityId,
    required this.register,
    required this.entityLabel,
    this.valueLabels = const <String, String>{},
  });

  final SrsEntityKind kind;
  final String entityId;
  final SrsRegister register;

  /// 牌组名 / 卡片所属笔记的排序字段。
  final String entityLabel;

  /// 值是 ID 时的人读名（笔记的「笔记类型」冲突：类型 ID → 类型名）。
  final Map<String, String> valueLabels;

  String formatValue(Object? v) =>
      (v is String ? valueLabels[v] : null) ?? srsFormatValue(v);

  SrsFieldEdit get winner => register.winner!;
  SrsFieldEdit get loser => register.visibleLosers.first;

  /// 「同类」：同一种实体的同一项设置。
  String get group => '${kind.wire}/${register.key}';

  /// 推荐保留修改时间更晚的一边（一般就是当前生效的；时钟不准时可能是被替换的那边）。
  bool get recommendRevert => loser.hlc.physical > winner.hlc.physical;
}

class SrsConflictsPage extends ConsumerStatefulWidget {
  const SrsConflictsPage({super.key});

  @override
  ConsumerState<SrsConflictsPage> createState() => _SrsConflictsPageState();
}

class _SrsConflictsPageState extends ConsumerState<SrsConflictsPage> {
  bool _loading = true;
  List<_Conflict> _conflicts = const <_Conflict>[];
  List<SrsNoteCacheRow> _pending = const <SrsNoteCacheRow>[];
  List<_HeldDelete> _held = const <_HeldDelete>[];
  List<SrsDuplicateGroup> _duplicates = const <SrsDuplicateGroup>[];
  SrsDeviceDirectory _devices = SrsDeviceDirectory.empty;

  /// 勾了「同类都按这个选」的组（[_Conflict.group] / 扣住删除的 `held/<kind>`）。
  final Set<String> _applySame = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsDeckTree tree = await store.deckTree();
    final List<_Conflict> conflicts = <_Conflict>[];
    Map<String, String>? typeNames;
    for (final (SrsEntityKind kind, String id, SrsRegister reg)
        in await store.syncConflicts()) {
      String label = id;
      switch (kind) {
        case SrsEntityKind.deck:
          label = tree[id] == null ? id : tree.fullName(id);
        case SrsEntityKind.card:
          // 卡片按它所属笔记的第一个字段认（与浏览页的排序字段同口径）。
          final SrsCardDetail? d = await store.cardDetail(id);
          final SrsFieldDef? first = d?.noteType.fields.firstOrNull;
          if (d != null && first != null) {
            final String text = d.note
                .field(first.id)
                .replaceAll(RegExp(r'<[^>]+>'), '')
                .trim();
            if (text.isNotEmpty) label = text;
          }
        case SrsEntityKind.profile:
          label = t.srs_conflict_profile;
        case SrsEntityKind.noteType:
          label = (await store.noteType(id))?.name ?? id;
        case SrsEntityKind.note:
          // 笔记按它的第一个字段认；「笔记类型」冲突的值显示类型名。
          final SrsNoteView? n = await store.note(id);
          final SrsNoteTypeView? nt = n == null
              ? null
              : await store.noteType(n.noteTypeId);
          final SrsFieldDef? first = nt?.fields.firstOrNull;
          if (n != null && first != null) {
            final String text = n
                .field(first.id)
                .replaceAll(RegExp(r'<[^>]+>'), '')
                .trim();
            if (text.isNotEmpty) label = text;
          }
          if (reg.key == SrsFieldKeys.noteType) {
            typeNames ??= <String, String>{
              for (final SrsNoteTypeView v in await store.noteTypes())
                v.id: v.name,
            };
          }
      }
      conflicts.add(
        _Conflict(
          kind: kind,
          entityId: id,
          register: reg,
          entityLabel: label,
          valueLabels: reg.key == SrsFieldKeys.noteType
              ? typeNames ?? const <String, String>{}
              : const <String, String>{},
        ),
      );
    }
    final List<SrsNoteCacheRow> pending = await store.notesPendingDecision();
    final List<_HeldDelete> held = <_HeldDelete>[];
    for (final Map<String, Object?> c in await store.sync2Conflicts()) {
      held.add(
        _HeldDelete(
          id: c['id'] as String? ?? '',
          kind: c['kind'] as String? ?? '',
          by: c['by'] as String? ?? '',
          others: (c['others'] as num?)?.toInt() ?? 0,
          at: (c['at'] as num?)?.toInt() ?? 0,
          label: await _entityLabel(
            store,
            tree,
            SrsEntityKind.tryParse(c['entityKind'] as String?),
            c['entity'] as String? ?? '',
          ),
        ),
      );
    }
    final List<SrsDuplicateGroup> duplicates = await store
        .duplicateNoteGroups();
    final SrsDeviceDirectory devices = await srsLoadDeviceDirectory(store);
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _conflicts = conflicts;
      _pending = pending;
      _held = held;
      _duplicates = duplicates;
      _loading = false;
    });
  }

  /// 冲突里实体的人读名：牌组全名 / 笔记（卡片按所属笔记）的第一个字段 / 笔记类型名。
  Future<String> _entityLabel(
    SrsDbStore store,
    SrsDeckTree tree,
    SrsEntityKind? kind,
    String id,
  ) async {
    String firstField(SrsNoteView? n, SrsNoteTypeView? nt) {
      final SrsFieldDef? first = nt?.fields.firstOrNull;
      if (n == null || first == null) return '';
      return n.field(first.id).replaceAll(RegExp(r'<[^>]+>'), '').trim();
    }

    switch (kind) {
      case SrsEntityKind.deck:
        return tree[id] == null ? id : tree.fullName(id);
      case SrsEntityKind.card:
        final SrsCardDetail? d = await store.cardDetail(id);
        final String text = firstField(d?.note, d?.noteType);
        return text.isEmpty ? id : text;
      case SrsEntityKind.note:
        final SrsNoteView? n = await store.note(id);
        final String text = firstField(
          n,
          n == null ? null : await store.noteType(n.noteTypeId),
        );
        return text.isEmpty ? id : text;
      case SrsEntityKind.noteType:
        return (await store.noteType(id))?.name ?? id;
      case SrsEntityKind.profile:
        return t.srs_conflict_profile;
      case null:
        return id;
    }
  }

  /// 写入者的显示名：本机 / 「<名称>（Fushi X.Y）」/ 认不出给前 8 位 ID。
  String _who(String writerId) => _devices.label(
    writerId,
    selfLabel: t.srs_timeline_this_device,
    fallback: srsShortDevice(writerId),
    formatTime: (DateTime x) => srsTimeLabel(context, x),
  );

  static String _heldGroup(_HeldDelete c) => 'held/${c.kind}';

  int _sameCount(String group) => group.startsWith('held/')
      ? _held.where((_HeldDelete h) => _heldGroup(h) == group).length
      : _conflicts.where((_Conflict c) => c.group == group).length;

  void _toggleSame(String group, bool on) =>
      setState(() => on ? _applySame.add(group) : _applySame.remove(group));

  void _toastMany(int n) {
    if (n > 1) {
      FushiToast.show(
        msg: t.srs_conflict_resolved_many(n: n),
        severity: ToastSeverity.success,
      );
    }
  }

  Future<void> _resolveHeld(_HeldDelete c, {required bool delete}) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final String group = _heldGroup(c);
    final List<_HeldDelete> targets = _applySame.contains(group)
        ? _held.where((_HeldDelete h) => _heldGroup(h) == group).toList()
        : <_HeldDelete>[c];
    for (final _HeldDelete h in targets) {
      await store.sync2Resolve(h.id, delete: delete);
    }
    _applySame.remove(group);
    _toastMany(targets.length);
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  Future<void> _mergeDuplicates(SrsDuplicateGroup g, String keepId) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsMergeReport r = await store.mergeNotes(
      keepId: keepId,
      absorbIds: <String>[
        for (final String id in g.noteIds)
          if (id != keepId) id,
      ],
    );
    FushiToast.show(
      msg: t.srs_duplicates_merged(n: r.linkedCards),
      severity: ToastSeverity.success,
    );
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  Future<void> _dismissDuplicates(SrsDuplicateGroup g) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.dismissDuplicates(g.noteIds);
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  Future<void> _resolve(_Conflict c, {required bool revert}) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final List<_Conflict> targets = _applySame.contains(c.group)
        ? _conflicts.where((_Conflict x) => x.group == c.group).toList()
        : <_Conflict>[c];
    for (final _Conflict x in targets) {
      await store.resolveConflict(
        x.kind,
        x.entityId,
        x.register.key,
        revert ? x.loser.value : x.winner.value,
      );
    }
    _applySame.remove(c.group);
    _toastMany(targets.length);
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  Future<void> _confirmAll() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    for (final _Conflict c in _conflicts) {
      await store.resolveConflict(
        c.kind,
        c.entityId,
        c.register.key,
        c.winner.value,
      );
    }
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  Future<void> _openNote(SrsNoteCacheRow row) async {
    await srsPushPage<void>(context, (_) => SrsNoteEditorPage(noteId: row.id));
    if (mounted) await _reload();
  }

  FushiToolbarItem get _confirmAllItem => FushiToolbarItem(
    key: const ValueKey<String>('srs_conflicts_confirm_all'),
    icon: FushiIcons.checklist,
    label: t.srs_conflict_confirm_all,
    onPressed: _conflicts.isEmpty
        ? null
        : () => srsRunLogged('SrsConflicts.confirmAll', _confirmAll),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_conflicts_title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              FushiIconButton(
                key: _confirmAllItem.key,
                icon: _confirmAllItem.icon,
                tooltip: _confirmAllItem.label,
                enabled: _confirmAllItem.onPressed != null,
                onTap: _confirmAllItem.onPressed,
              ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context) {
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
        title: t.srs_conflicts_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_confirmAllItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    if (_conflicts.isEmpty &&
        _pending.isEmpty &&
        _held.isEmpty &&
        _duplicates.isEmpty) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.success,
            message: t.srs_conflicts_empty,
            detail: t.srs_conflicts_empty_hint,
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> items = <Widget>[
      if (_held.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_conflicts_deletions),
        for (final _HeldDelete c in _held)
          _HeldDeleteCard(
            key: ValueKey<String>('srs-held-${c.id}'),
            conflict: c,
            who: _who,
            sameCount: _sameCount(_heldGroup(c)),
            applySame: _applySame.contains(_heldGroup(c)),
            onApplySameChanged: (bool on) => _toggleSame(_heldGroup(c), on),
            onDelete: () => srsRunLogged(
              'SrsConflicts.applyDelete',
              () => _resolveHeld(c, delete: true),
            ),
            onKeep: () => srsRunLogged(
              'SrsConflicts.keep',
              () => _resolveHeld(c, delete: false),
            ),
          ),
      ],
      if (_duplicates.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_duplicates_title),
        for (final SrsDuplicateGroup g in _duplicates)
          _DuplicateCard(
            key: ValueKey<String>('srs-dup-${g.noteIds.join('-')}'),
            group: g,
            onMerge: (String keepId) => srsRunLogged(
              'SrsConflicts.merge',
              () => _mergeDuplicates(g, keepId),
            ),
            onDismiss: () => srsRunLogged(
              'SrsConflicts.notDuplicate',
              () => _dismissDuplicates(g),
            ),
          ),
      ],
      if (_pending.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_conflicts_pending_notes),
        for (int i = 0; i < _pending.length; i++)
          FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('srs-pending-${_pending[i].id}'),
              index: i,
              count: _pending.length,
              onTap: () => srsRunLogged(
                'SrsConflicts.openNote',
                () => _openNote(_pending[i]),
              ),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(
                  FushiIcons.warning,
                  tone: FushiCardTone.error,
                ),
                title: Text(
                  _pending[i].sortField.isEmpty ? '—' : _pending[i].sortField,
                ),
                subtitle: Text(
                  _pending[i].deletedAt != null
                      ? t.srs_note_delete_conflict
                      : t.srs_note_field_conflict,
                ),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          ),
      ],
      if (_conflicts.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_conflicts_settings),
        for (final _Conflict c in _conflicts)
          _ConflictCard(
            key: ValueKey<String>('srs-conflict-${c.register.winner!.id}'),
            conflict: c,
            who: _who,
            sameCount: _sameCount(c.group),
            applySame: _applySame.contains(c.group),
            onApplySameChanged: (bool on) => _toggleSame(c.group, on),
            onRevert: () => srsRunLogged(
              'SrsConflicts.revert',
              () => _resolve(c, revert: true),
            ),
            onConfirm: () => srsRunLogged(
              'SrsConflicts.confirm',
              () => _resolve(c, revert: false),
            ),
          ),
      ],
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
        itemCount: items.length,
        separatorBuilder: (BuildContext context, int index) =>
            items[index] is FushiPressScale &&
                items[index + 1] is FushiPressScale
            ? const SizedBox.shrink()
            : SizedBox(height: tokens.spacing.gap * 1.5),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

/// 一组疑似重复的笔记：点一行选「保留这条」（默认复习最多的那条），「合并」把其余并进来。
class _DuplicateCard extends StatefulWidget {
  const _DuplicateCard({
    super.key,
    required this.group,
    required this.onMerge,
    required this.onDismiss,
  });

  final SrsDuplicateGroup group;
  final void Function(String keepId) onMerge;
  final VoidCallback onDismiss;

  @override
  State<_DuplicateCard> createState() => _DuplicateCardState();
}

class _DuplicateCardState extends State<_DuplicateCard> {
  late String _keep = widget.group.noteIds.first;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsDuplicateGroup g = widget.group;
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(t.srs_duplicates_hint, style: context.fushiType.bodySmall),
          for (int i = 0; i < g.noteIds.length; i++)
            FushiPressScale(
              child: FushiGroupedListItem(
                key: ValueKey<String>('srs-dup-row-${g.noteIds[i]}'),
                index: i,
                count: g.noteIds.length,
                onTap: () => setState(() => _keep = g.noteIds[i]),
                child: FushiListItem(
                  leading: FushiListLeadingIcon(
                    _keep == g.noteIds[i]
                        ? FushiIcons.check
                        : FushiIcons.ankiCard,
                    tone: _keep == g.noteIds[i]
                        ? FushiCardTone.primary
                        : FushiCardTone.neutral,
                  ),
                  title: Text(
                    (g.sortFields[g.noteIds[i]] ?? '').isEmpty
                        ? '—'
                        : g.sortFields[g.noteIds[i]]!,
                  ),
                  subtitle: Text(
                    <String>[
                      t.srs_duplicates_reviews(n: g.reviews[g.noteIds[i]] ?? 0),
                      if (_keep == g.noteIds[i]) t.srs_duplicates_keep,
                    ].join(' · '),
                  ),
                ),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiOutlinedButton.icon(
                key: const ValueKey<String>('srs-dup-dismiss'),
                onPressed: widget.onDismiss,
                icon: const FushiIcon(FushiIcons.close),
                label: Text(t.srs_duplicates_dismiss),
              ),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('srs-dup-merge'),
                onPressed: () => widget.onMerge(_keep),
                icon: const FushiIcon(FushiIcons.check),
                label: Text(t.srs_duplicates_merge),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 推荐一行：「推荐：<选择>」+ 理由。
class _Recommendation extends StatelessWidget {
  const _Recommendation({required this.choice, required this.reason});

  final String choice;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color accent = Theme.of(context).colorScheme.primary;
    return Row(
      key: const ValueKey<String>('srs-conflict-recommendation'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        FushiIcon(FushiIcons.lightbulb, size: 18, color: accent),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: t.srs_conflict_recommended(choice: choice),
                  style: context.fushiType.bodyMedium.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text: ' · $reason',
                  style: context.fushiType.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 「同类 n 条冲突都按这个选」（只在同类不止一条时出现）。
class _ApplySame extends StatelessWidget {
  const _ApplySame({
    required this.count,
    required this.value,
    required this.onChanged,
    required this.groupKey,
  });

  final int count;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String groupKey;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return FushiCheckboxListTile(
      key: ValueKey<String>('srs-conflict-apply-same-$groupKey'),
      value: value,
      onChanged: (bool? v) => onChanged(v ?? false),
      contentPadding: EdgeInsets.zero,
      title: Text(
        t.srs_conflict_apply_same(n: count),
        style: context.fushiType.bodyMedium,
      ),
    );
  }
}

/// 冲突一边：标签、值、哪台设备什么时候改的；推荐的一边描边强调。
class _ConflictSide extends StatelessWidget {
  const _ConflictSide({
    required this.label,
    required this.value,
    required this.from,
    required this.recommended,
  });

  final String label;
  final String value;
  final String from;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      padding: EdgeInsets.all(tokens.spacing.gap),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(tokens.spacing.gap),
        border: Border.all(
          color: recommended ? cs.primary : cs.outlineVariant,
          width: recommended ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap / 4,
        children: <Widget>[
          Text(label, style: tokens.type.sectionLabel),
          Text(
            value,
            style: context.fushiType.bodyLarge,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          Text(from, style: context.fushiType.bodySmall),
        ],
      ),
    );
  }
}

class _HeldDeleteCard extends StatelessWidget {
  const _HeldDeleteCard({
    super.key,
    required this.conflict,
    required this.who,
    required this.sameCount,
    required this.applySame,
    required this.onApplySameChanged,
    required this.onDelete,
    required this.onKeep,
  });

  final _HeldDelete conflict;
  final String Function(String writerId) who;
  final int sameCount;
  final bool applySame;
  final ValueChanged<bool> onApplySameChanged;
  final VoidCallback onDelete;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String what = switch (conflict.kind) {
      'delete_review' => t.srs_conflict_deleted_while_reviewed(
        n: conflict.others,
      ),
      'delete_move' => t.srs_conflict_deleted_while_moved,
      _ => t.srs_conflict_deleted_while_edited(n: conflict.others),
    };
    // 推荐保留：另一边还有复习 / 修改，保留不丢；保留之后仍可再删，删了却回不来。
    final String reason = switch (conflict.kind) {
      'delete_review' => t.srs_conflict_reason_keep_reviews(n: conflict.others),
      'delete_move' => t.srs_conflict_reason_keep_move,
      _ => t.srs_conflict_reason_keep_edits(n: conflict.others),
    };
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(conflict.label, style: context.fushiType.titleSmallEmphasized),
          Text(what, style: context.fushiType.bodyMedium),
          Text(
            t.srs_conflict_side_from(
              device: who(conflict.by),
              time: srsFormatMoment(conflict.at),
            ),
            style: context.fushiType.bodySmall,
          ),
          _Recommendation(choice: t.srs_conflict_keep, reason: reason),
          _ApplySame(
            count: sameCount,
            value: applySame,
            onChanged: onApplySameChanged,
            groupKey: conflict.kind,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiPressScale(
                child: FushiOutlinedButton.icon(
                  key: const ValueKey<String>('srs-held-delete'),
                  onPressed: onDelete,
                  icon: const FushiIcon(FushiIcons.delete),
                  label: Text(t.srs_conflict_apply_delete),
                ),
              ),
              FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('srs-held-keep'),
                  onPressed: onKeep,
                  icon: const FushiIcon(FushiIcons.check),
                  label: Text(t.srs_conflict_keep),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    super.key,
    required this.conflict,
    required this.who,
    required this.sameCount,
    required this.applySame,
    required this.onApplySameChanged,
    required this.onRevert,
    required this.onConfirm,
  });

  final _Conflict conflict;
  final String Function(String writerId) who;
  final int sameCount;
  final bool applySame;
  final ValueChanged<bool> onApplySameChanged;
  final VoidCallback onRevert;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldEdit winner = conflict.winner;
    final SrsFieldEdit loser = conflict.loser;
    final bool revert = conflict.recommendRevert;
    final String key = srsFieldKeyLabel(conflict.kind, conflict.register.key);
    final String current = conflict.formatValue(winner.value);
    final String replaced = conflict.formatValue(loser.value);
    String from(SrsFieldEdit e) => t.srs_conflict_side_from(
      device: who(e.dot.writerId),
      time: srsFormatMoment(e.hlc.physical),
    );
    // 推荐的一边是实心按钮，另一边描边。
    Widget button({
      required String id,
      required bool primary,
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
    }) => FushiPressScale(
      child: primary
          ? FushiFilledButton.tonalIcon(
              key: ValueKey<String>(id),
              onPressed: onPressed,
              icon: FushiIcon(icon),
              label: Text(label),
            )
          : FushiOutlinedButton.icon(
              key: ValueKey<String>(id),
              onPressed: onPressed,
              icon: FushiIcon(icon),
              label: Text(label),
            ),
    );
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            '${conflict.entityLabel} · $key',
            style: context.fushiType.titleSmallEmphasized,
          ),
          _ConflictSide(
            label: t.srs_conflict_current,
            value: current,
            from: from(winner),
            recommended: !revert,
          ),
          _ConflictSide(
            label: t.srs_conflict_replaced,
            value: replaced,
            from: from(loser),
            recommended: revert,
          ),
          SrsValueDiff(from: replaced, to: current),
          _Recommendation(
            choice: revert ? t.srs_conflict_replaced : t.srs_conflict_current,
            reason: t.srs_conflict_reason_later,
          ),
          _ApplySame(
            count: sameCount,
            value: applySame,
            onChanged: onApplySameChanged,
            groupKey: conflict.group,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              button(
                id: 'srs-conflict-revert',
                primary: revert,
                icon: FushiIcons.undo,
                label: t.srs_conflict_revert,
                onPressed: onRevert,
              ),
              button(
                id: 'srs-conflict-confirm',
                primary: !revert,
                icon: FushiIcons.check,
                label: t.srs_conflict_confirm,
                onPressed: onConfirm,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
