/// 「迁移旧 Lapis 到新模板」：列出全部受支持的旧 Lapis 变体（内置 Lapis、从 Anki 导入 /
/// 改过名的 Lapis），逐个预演（字段按语义的映射、继承复习历史 / 不再出现的卡、迁不过去的字段）
/// 后一键迁到 Fushi 卡片；另列出旧版迁移遗漏、可从迁移前的字段补回的笔记，一键补迁。
///
/// 逻辑全在 `packages/fushi_engine/lib/srs/srs_legacy_lapis_migration.dart`；本页只做预演展示
/// 与确认。入口：[openSrsLegacyLapisMigrationPage]（笔记类型页、Anki 一键迁移结果页共用）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开「迁移旧 Lapis 到新模板」页；页面关掉后返回。需要 [context] 在 [ProviderScope] 之下。
///
/// 供笔记类型页与 Anki 一键迁移的结果页调用（迁移 / 补迁都在页内确认后才写入）。
Future<void> openSrsLegacyLapisMigrationPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const SrsLegacyLapisMigrationPage(),
      ),
    );

/// 变体识别依据 → 文案。
String srsLapisVariantKindLabel(SrsLapisVariantKind kind) => switch (kind) {
  SrsLapisVariantKind.builtinLapis => t.srs_lapis_migration_kind_builtin,
  SrsLapisVariantKind.namedLapis => t.srs_lapis_migration_kind_named,
  SrsLapisVariantKind.lapisFields => t.srs_lapis_migration_kind_fields,
};

class SrsLegacyLapisMigrationPage extends ConsumerStatefulWidget {
  const SrsLegacyLapisMigrationPage({super.key});

  @override
  ConsumerState<SrsLegacyLapisMigrationPage> createState() =>
      _SrsLegacyLapisMigrationPageState();
}

class _SrsLegacyLapisMigrationPageState
    extends ConsumerState<SrsLegacyLapisMigrationPage> {
  bool _loading = true;
  bool _busy = false;
  SrsNoteTypeView? _fushiCard;
  List<SrsLegacyLapisMigrationPreview> _previews =
      const <SrsLegacyLapisMigrationPreview>[];
  SrsLapisBackfillPreview? _backfill;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) return;
      final SrsNoteTypeView? fushi = await store.noteType(
        store.fushiCardNoteTypeId,
      );
      final List<SrsLegacyLapisMigrationPreview> previews =
          <SrsLegacyLapisMigrationPreview>[
            for (final SrsLegacyLapisSource s
                in await store.legacyLapisSources())
              await store.previewLegacyLapisMigration(s.type.id),
          ];
      final SrsLapisBackfillPreview backfill = await store
          .previewLapisBackfill();
      if (!mounted) return;
      setState(() {
        _fushiCard = fushi;
        _previews = previews;
        _backfill = backfill;
        _loading = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsLegacyLapisMigration.load', e, stack);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _write(
    String where,
    Future<String> Function(SrsDbStore store) body,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final String done = await body(store);
      if (!mounted) return;
      bumpSrsRevision(ref);
      FushiToast.show(msg: done, severity: ToastSeverity.success);
    } catch (e, stack) {
      ErrorLogService.instance.log(where, e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<void> _migrate(SrsLegacyLapisMigrationPreview p) async {
    final int n = p.source.noteIds.length;
    final int dropped = p.change.droppedCards;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_lapis_migration_title,
      message:
          '${t.srs_lapis_migration_confirm(n: n, name: p.source.type.name)}\n'
          '${t.srs_lapis_migration_cards(linked: p.change.linkedCards, dropped: dropped)}',
      confirmLabel: t.srs_lapis_migration_migrate,
      cancelLabel: t.cancel,
      icon: FushiIcons.swap,
      destructive: dropped > 0,
    );
    if (!ok || !mounted) return;
    await _write('SrsLegacyLapisMigration.migrate', (SrsDbStore store) async {
      final int migrated = await store.migrateLegacyLapis(p.source.type.id);
      return t.srs_migrate_fushi_done(n: migrated);
    });
  }

  Future<void> _adjust(SrsLegacyLapisMigrationPreview p) async {
    final SrsDbStore? store = await readSrsStore(ref);
    final SrsNoteTypeView? fushi = _fushiCard;
    if (store == null || fushi == null || !mounted) return;
    final bool changed = await showSrsChangeNoteTypeFlow(
      context,
      p.source.noteIds,
      initialTargetId: fushi.id,
      initialFieldMap: Map<String, String?>.of(p.fields.fieldMap),
      initialTemplateMap: srsLapisTemplateMap(p.source.type, fushi),
    );
    if (changed && mounted) await _reload();
  }

  Future<void> _applyBackfill(SrsLapisBackfillPreview p) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_lapis_migration_backfill_title,
      message: t.srs_lapis_migration_backfill_summary(n: p.notes),
      confirmLabel: t.srs_lapis_migration_backfill_action,
      cancelLabel: t.cancel,
      icon: FushiIcons.restoreBackup,
    );
    if (!ok || !mounted) return;
    await _write('SrsLegacyLapisMigration.backfill', (SrsDbStore store) async {
      final int n = await store.applyLapisBackfill();
      return t.srs_lapis_migration_backfill_done(n: n);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_lapis_migration_title,
      header: apple ? null : _buildTopBar(context),
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
        title: t.srs_lapis_migration_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final Widget child;
    if (_loading) {
      child = const SafeArea(
        key: ValueKey<String>('srs-lapis-migration-loading'),
        bottom: false,
        child: FushiLoadingView(),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey<String>('srs-lapis-migration-content'),
        child: _buildSections(context),
      );
    }
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      child: child,
    );
  }

  Widget _buildSections(BuildContext context) {
    final SrsLapisBackfillPreview? backfill = _backfill;
    final bool hasBackfill = backfill != null && backfill.notes > 0;
    final List<SrsSection> sections = <SrsSection>[
      SrsSection(_introCard(context)),
      if (_previews.isEmpty && !hasBackfill)
        SrsSection(
          Center(
            child: FushiPlaceholderMessage(
              key: const ValueKey<String>('srs-lapis-migration-nothing'),
              icon: FushiIcons.check,
              message: t.srs_lapis_migration_nothing,
            ),
          ),
        ),
      if (hasBackfill) SrsSection(_backfillCard(context, backfill)),
      for (final SrsLegacyLapisMigrationPreview p in _previews)
        SrsSection(pane: SrsPane.secondary, _sourceCard(context, p)),
    ];
    return SrsAdaptiveSections(
      sections: sections,
      primaryFlex: 2,
      secondaryFlex: 3,
    );
  }

  Widget _introCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      key: const ValueKey<String>('srs-lapis-migration-intro'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap * 1.5,
        children: <Widget>[
          const FushiIcon(FushiIcons.info),
          Expanded(child: Text(t.srs_lapis_migration_intro)),
        ],
      ),
    );
  }

  Widget _note(
    BuildContext context,
    String text, {
    Key? key,
    bool error = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap / 2,
        tokens.spacing.card,
        tokens.spacing.gap / 2,
      ),
      child: Text(
        text,
        key: key,
        style: context.fushiType.bodySmall.copyWith(
          color: error ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    );
  }

  Widget _buttons(BuildContext context, List<Widget> children) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final Widget c in children) FushiPressScale(child: c),
        ],
      ),
    );
  }

  Widget _sourceCard(BuildContext context, SrsLegacyLapisMigrationPreview p) {
    final String id = p.source.type.id;
    final List<String> lost = <String>[
      for (final MapEntry<SrsFieldDef, int> e in p.lostFieldNotes.entries)
        '${e.key.name} (${e.value})',
    ];
    return FushiCard(
      key: ValueKey<String>('srs-lapis-migration-source-$id'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiListItem(
            leading: const FushiListLeadingIcon(
              FushiIcons.ankiCard,
              tone: FushiCardTone.primary,
            ),
            title: Text(p.source.type.name),
            subtitle: SrsMetaLine(<String>[
              srsLapisVariantKindLabel(p.source.kind),
              t.srs_lapis_migration_notes(n: p.source.noteIds.length),
            ]),
          ),
          for (final SrsLapisFieldMapping r in p.fields.rows)
            FushiListItem(
              key: ValueKey<String>(
                'srs-lapis-migration-row-$id-${r.target.name}',
              ),
              density: FushiListDensity.compact,
              title: Text(r.target.name),
              subtitle: Text(
                r.source == null
                    ? '← ${t.srs_lapis_migration_left_empty}'
                    : r.match == SrsLapisFieldMatch.alias
                    ? '← ${r.source!.name} · ${t.srs_lapis_migration_by_synonym}'
                    : '← ${r.source!.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _note(
            context,
            t.srs_lapis_migration_cards(
              linked: p.change.linkedCards,
              dropped: p.change.droppedCards,
            ),
            error: p.change.droppedCards > 0,
          ),
          if (p.fallbackFills > 0)
            _note(context, t.srs_lapis_migration_fallback(n: p.fallbackFills)),
          if (lost.isNotEmpty)
            _note(
              context,
              t.srs_lapis_migration_lost(fields: lost.join('、')),
              key: ValueKey<String>('srs-lapis-migration-lost-$id'),
              error: true,
            ),
          _buttons(context, <Widget>[
            FushiOutlinedButton.icon(
              key: ValueKey<String>('srs-lapis-migration-adjust-$id'),
              onPressed: _busy
                  ? null
                  : () => srsRunLogged(
                      'SrsLegacyLapisMigration.adjust',
                      () => _adjust(p),
                    ),
              icon: const FushiIcon(FushiIcons.textFields),
              label: Text(t.srs_migrate_fushi_adjust),
            ),
            FushiFilledButton.tonalIcon(
              key: ValueKey<String>('srs-lapis-migration-migrate-$id'),
              onPressed: _busy
                  ? null
                  : () => srsRunLogged(
                      'SrsLegacyLapisMigration.migrate',
                      () => _migrate(p),
                    ),
              icon: const FushiIcon(FushiIcons.swap),
              label: Text(t.srs_lapis_migration_migrate),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _backfillCard(BuildContext context, SrsLapisBackfillPreview p) {
    final Map<String, String> names = <String, String>{
      for (final SrsFieldDef f in _fushiCard?.fields ?? const <SrsFieldDef>[])
        f.id: f.name,
    };
    final List<String> counts = <String>[
      for (final MapEntry<String, int> e in p.fieldCounts.entries)
        '${names[e.key] ?? e.key} (${e.value})',
    ];
    return FushiCard(
      key: const ValueKey<String>('srs-lapis-migration-backfill'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiListItem(
            leading: const FushiListLeadingIcon(FushiIcons.restoreBackup),
            title: Text(t.srs_lapis_migration_backfill_title),
            subtitle: Text(t.srs_lapis_migration_backfill_summary(n: p.notes)),
          ),
          _note(context, counts.join('、')),
          _buttons(context, <Widget>[
            FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('srs-lapis-migration-backfill-apply'),
              onPressed: _busy
                  ? null
                  : () => srsRunLogged(
                      'SrsLegacyLapisMigration.backfill',
                      () => _applyBackfill(p),
                    ),
              icon: const FushiIcon(FushiIcons.restoreBackup),
              label: Text(t.srs_lapis_migration_backfill_action),
            ),
          ]),
        ],
      ),
    );
  }
}
