/// 复习的同步冲突：两台设备同时改了同一项设置 / 卡片标志时，后写的生效、被覆盖的
/// 留在这里，逐条「改回」（写被覆盖的值）或「确认」（写当前值）；另列出内容类
/// 待裁决的笔记（字段并发修改 / 删除与并发修改），点开进编辑页处理。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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
    if (!mounted) return;
    setState(() {
      _conflicts = conflicts;
      _pending = pending;
      _loading = false;
    });
  }

  Future<void> _resolve(_Conflict c, {required bool revert}) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.resolveConflict(
      c.kind,
      c.entityId,
      c.register.key,
      revert ? c.loser.value : c.winner.value,
    );
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
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsNoteEditorPage(noteId: row.id),
      ),
    );
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
    if (_conflicts.isEmpty && _pending.isEmpty) {
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

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    super.key,
    required this.conflict,
    required this.onRevert,
    required this.onConfirm,
  });

  final _Conflict conflict;
  final VoidCallback onRevert;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldEdit winner = conflict.winner;
    final SrsFieldEdit loser = conflict.loser;
    final String key = srsFieldKeyLabel(conflict.kind, conflict.register.key);
    Widget side(String label, SrsFieldEdit e) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: tokens.type.sectionLabel),
        Text(
          conflict.formatValue(e.value),
          style: context.fushiType.bodyLarge,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          t.srs_conflict_from(
            device: srsShortDevice(e.dot.writerId),
            time: srsFormatMoment(e.hlc.physical),
          ),
          style: context.fushiType.bodySmall,
        ),
      ],
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
          side(t.srs_conflict_current, winner),
          side(t.srs_conflict_replaced, loser),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiOutlinedButton.icon(
                key: const ValueKey<String>('srs-conflict-revert'),
                onPressed: onRevert,
                icon: const FushiIcon(FushiIcons.undo),
                label: Text(t.srs_conflict_revert),
              ),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('srs-conflict-confirm'),
                onPressed: onConfirm,
                icon: const FushiIcon(FushiIcons.check),
                label: Text(t.srs_conflict_confirm),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
