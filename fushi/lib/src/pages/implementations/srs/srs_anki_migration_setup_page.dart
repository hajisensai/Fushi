/// 「从 Anki 迁移」的设置页：选好集合 / 文件之后、真正开始之前，把会发生什么和能选的
/// 一页列全，取代以前只报数量的确认框（那时排程算法、Lapis 模板一概不问，迁完才在报告里
/// 说「已改用 RWKV」，Lapis 提示也只在迁移页还开着时才弹）。
///
/// - 来源概况与警告（Anki 还开着等）；
/// - 学习进度：排程与复习记录 / 牌组预设 / FSRS 参数；
/// - 排程算法：RWKV / FSRS 二选一，各自写明后果；
/// - 卡片模板：导入后把旧 Lapis 迁到 Fushi 卡片（同一个后台任务里做，不依赖本页）；
/// - 更新（折叠）：合并笔记模板、更新笔记 / 笔记模板；
/// - 开始前请知悉：合并不替换、删过的笔记会恢复、后台进行、怎么撤回。
///
/// 返回用户确认的 [SrsAnkiMigrationSettings]；返回 null = 取消。选择记在偏好里，下次沿用。
library;

import 'dart:async';

import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_anki_migration.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开设置页；确认返回选择，取消返回 null。
Future<SrsAnkiMigrationSettings?> openSrsAnkiMigrationSetupPage(
  BuildContext context, {
  required String sourceName,
  required String summary,
  required SrsAnkiMigrationSettings initial,
  bool sourceProbablyOpen = false,
}) => Navigator.of(context).push<SrsAnkiMigrationSettings>(
  adaptivePageRoute<SrsAnkiMigrationSettings>(
    context: context,
    builder: (_) => SrsAnkiMigrationSetupPage(
      sourceName: sourceName,
      summary: summary,
      initial: initial,
      sourceProbablyOpen: sourceProbablyOpen,
    ),
  ),
);

class SrsAnkiMigrationSetupPage extends StatefulWidget {
  const SrsAnkiMigrationSetupPage({
    super.key,
    required this.sourceName,
    required this.summary,
    required this.initial,
    this.sourceProbablyOpen = false,
  });

  /// profile 名或文件名（页标题「迁移「…」？」）。
  final String sourceName;

  /// 来源概况（笔记 / 卡片 / 复习数，或文件说明）。
  final String summary;
  final SrsAnkiMigrationSettings initial;

  /// 来源集合可能正被 Anki 打开（快照里有未合并的 WAL）。
  final bool sourceProbablyOpen;

  @override
  State<SrsAnkiMigrationSetupPage> createState() =>
      _SrsAnkiMigrationSetupPageState();
}

class _SrsAnkiMigrationSetupPageState extends State<SrsAnkiMigrationSetupPage> {
  late SrsAnkiMigrationSettings _settings = widget.initial;

  SrsAnkiImportOptions get _o => _settings.options;

  void _setOptions(SrsAnkiImportOptions next) =>
      setState(() => _settings = _settings.copyWith(options: next));

  void _start() => Navigator.of(context).pop(_settings);

  String _conditionLabel(SrsImportUpdateCondition c) => switch (c) {
    SrsImportUpdateCondition.ifNewer => t.srs_import_update_if_newer,
    SrsImportUpdateCondition.always => t.srs_import_update_always,
    SrsImportUpdateCondition.never => t.srs_import_update_never,
  };

  List<AdaptiveSettingsPickerOption<SrsImportUpdateCondition>>
  get _conditionOptions =>
      <AdaptiveSettingsPickerOption<SrsImportUpdateCondition>>[
        for (final SrsImportUpdateCondition c
            in SrsImportUpdateCondition.values)
          AdaptiveSettingsPickerOption<SrsImportUpdateCondition>(
            value: c,
            label: _conditionLabel(c),
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_anki_migrate_setup_title,
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
        title: t.srs_anki_migrate_setup_title,
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

  Widget _gap(FushiDesignTokens tokens) => SizedBox(height: tokens.spacing.gap);

  Widget _section(FushiDesignTokens tokens, Widget child) => Padding(
    padding: EdgeInsets.only(top: tokens.spacing.section),
    child: child,
  );

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool narrow = MediaQuery.sizeOf(context).width < 600;
    final List<Widget> items = <Widget>[
      Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
        child: Text(
          t.srs_anki_migrate_confirm_title(name: widget.sourceName),
          style: text.titleMedium,
        ),
      ),
      _gap(tokens),
      FushiInlineNotice(
        key: const ValueKey<String>('srs-anki-setup-summary'),
        icon: FushiIcons.importFile,
        message: widget.summary,
      ),
      if (widget.sourceProbablyOpen) ...<Widget>[
        _gap(tokens),
        FushiInlineNotice(
          key: const ValueKey<String>('srs-anki-setup-open'),
          severity: FushiNoticeSeverity.warning,
          message: t.srs_anki_migrate_open_warning,
        ),
      ],
      _section(
        tokens,
        AdaptiveSettingsSection(
          title: t.srs_anki_migrate_setup_section_progress,
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('srs-anki-setup-scheduling'),
              title: t.srs_import_with_scheduling,
              subtitle: t.srs_import_with_scheduling_help,
              value: _o.withScheduling,
              onChanged: (bool v) =>
                  _setOptions(_o.copyWith(withScheduling: v)),
            ),
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('srs-anki-setup-deck-configs'),
              title: t.srs_import_with_deck_configs,
              subtitle: t.srs_import_with_deck_configs_help,
              value: _o.withDeckConfigs,
              onChanged: (bool v) =>
                  _setOptions(_o.copyWith(withDeckConfigs: v)),
            ),
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('srs-anki-setup-fsrs-params'),
              title: t.srs_import_with_fsrs_params,
              subtitle: t.srs_import_with_fsrs_params_help,
              value: _o.withFsrsParams,
              onChanged: (bool v) =>
                  _setOptions(_o.copyWith(withFsrsParams: v)),
            ),
          ],
        ),
      ),
      _section(
        tokens,
        AdaptiveSettingsSection(
          title: t.srs_anki_migrate_setup_section_algorithm,
          children: <Widget>[
            AdaptiveSettingsSegmentedRow<bool>(
              key: const ValueKey<String>('srs-anki-setup-algorithm'),
              title: t.srs_anki_migrate_setup_algorithm,
              subtitle: _o.useRwkv
                  ? t.srs_anki_migrate_setup_algorithm_rwkv_desc
                  : t.srs_anki_migrate_setup_algorithm_fsrs_desc,
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('RWKV')),
                ButtonSegment<bool>(value: false, label: Text('FSRS')),
              ],
              selected: _o.useRwkv,
              onChanged: (bool v) => _setOptions(_o.copyWith(useRwkv: v)),
            ),
          ],
        ),
      ),
      _section(
        tokens,
        AdaptiveSettingsSection(
          title: t.srs_anki_migrate_setup_section_templates,
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('srs-anki-setup-convert-lapis'),
              title: t.srs_anki_migrate_setup_convert_lapis,
              subtitle: t.srs_anki_migrate_setup_convert_lapis_desc,
              value: _settings.convertLapis,
              onChanged: (bool v) => setState(
                () => _settings = _settings.copyWith(convertLapis: v),
              ),
            ),
          ],
        ),
      ),
      _section(
        tokens,
        AdaptiveSettingsSection(
          key: const ValueKey<String>('srs-anki-setup-updates'),
          title: t.srs_import_section_updates,
          titlePlacement: SettingsSectionTitlePlacement.inside,
          collapsible: true,
          initiallyExpanded: false,
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              title: t.srs_import_merge_notetypes,
              subtitle: t.srs_import_merge_notetypes_help,
              value: _o.mergeNoteTypes,
              onChanged: (bool v) =>
                  _setOptions(_o.copyWith(mergeNoteTypes: v)),
            ),
            AdaptiveSettingsPickerRow<SrsImportUpdateCondition>(
              title: t.srs_import_update_notes,
              subtitle: t.srs_import_update_notes_help,
              options: _conditionOptions,
              selected: _o.updateNotes,
              materialWidth: 160,
              controlBelow: narrow,
              onChanged: (SrsImportUpdateCondition c) =>
                  _setOptions(_o.copyWith(updateNotes: c)),
            ),
            AdaptiveSettingsPickerRow<SrsImportUpdateCondition>(
              title: t.srs_import_update_notetypes,
              subtitle: t.srs_import_update_notetypes_help,
              options: _conditionOptions,
              selected: _o.updateNoteTypes,
              materialWidth: 160,
              controlBelow: narrow,
              onChanged: (SrsImportUpdateCondition c) =>
                  _setOptions(_o.copyWith(updateNoteTypes: c)),
            ),
          ],
        ),
      ),
      _section(
        tokens,
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
          child: Text(
            t.srs_anki_migrate_setup_section_notices,
            style: text.titleSmall,
          ),
        ),
      ),
      _gap(tokens),
      for (final (String key, IconData icon, String message)
          in <(String, IconData, String)>[
            ('merge', FushiIcons.merge, t.srs_anki_migrate_setup_notice_merge),
            (
              'restore',
              FushiIcons.history,
              t.srs_anki_migrate_setup_notice_restore,
            ),
            (
              'background',
              FushiIcons.schedule,
              t.srs_anki_migrate_setup_notice_background,
            ),
            (
              'backup',
              FushiIcons.backup,
              t.srs_anki_migrate_setup_notice_backup,
            ),
          ]) ...<Widget>[
        FushiInlineNotice(
          key: ValueKey<String>('srs-anki-setup-notice-$key'),
          icon: icon,
          message: message,
        ),
        _gap(tokens),
      ],
      _section(
        tokens,
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiFilledButton(
            key: const ValueKey<String>('srs-anki-setup-start'),
            autofocus: true,
            onPressed: _start,
            child: Text(t.srs_anki_migrate_start),
          ),
        ),
      ),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
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
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}
