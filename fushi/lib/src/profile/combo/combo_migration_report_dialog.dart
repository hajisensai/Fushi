/// 组合迁移报告（拍板台 design-combo-node-split 阶段 3，设计 §3.3 第 5 条）：首次启动提示
/// 一次（[maybeShowComboMigrationNotice]，首页首帧串行弹框之一），配置管理页可重看
/// （[showComboMigrationReportDialog]）。
///
/// 报告内容由迁移时算好存进本机偏好（`ComboMigrationReport`），这里只呈现：各组合单独设置
/// 了哪些项、语言与媒体类型都绑了时生效顺序变化影响到的项、在绑定层不生效的拆分、复习库结论。
library;

import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 首页首帧调用：迁移写下的报告还没提示过就弹一次（标记先清再弹，见
/// [ProfileRepository.takePendingComboMigrationReport]）。
Future<void> maybeShowComboMigrationNotice({
  required BuildContext context,
  required ProfileRepository repository,
}) async {
  final ComboMigrationReport? report = await repository
      .takePendingComboMigrationReport();
  if (report == null || !context.mounted) return;
  await showComboMigrationReportDialog(context, report);
}

/// 叶子 id → 界面名。树上新增叶子必须在这里加名字（`combo_migration_report_dialog_test`
/// 逐个叶子查）；不认识的 id（更新版本写的报告）原样显示。
String comboLeafLabel(String leafId) => switch (leafId) {
  FushiComboNode.miningTarget => t.profile_combo_leaf_mining_target,
  FushiComboNode.miningDeck => t.profile_combo_leaf_mining_deck,
  FushiComboNode.miningNoteType => t.profile_combo_leaf_mining_note_type,
  FushiComboNode.miningTagsDupes => t.profile_combo_leaf_mining_tags_dupes,
  FushiComboNode.miningCardContent => t.profile_combo_leaf_mining_card_content,
  FushiComboNode.appearanceTheme => t.profile_combo_leaf_appearance_theme,
  FushiComboNode.appearanceFonts => t.profile_combo_leaf_appearance_fonts,
  FushiComboNode.appearanceReaderStyle =>
    t.profile_combo_leaf_appearance_reader_style,
  FushiComboNode.appearanceSubtitles =>
    t.profile_combo_leaf_appearance_subtitles,
  FushiComboNode.dictionary => t.profile_combo_leaf_dictionary,
  FushiComboNode.inputShortcuts => t.profile_combo_leaf_input_shortcuts,
  FushiComboNode.srsLibrary => t.profile_combo_leaf_srs_library,
  FushiComboNode.other => t.profile_combo_leaf_other,
  _ => leafId,
};

String _scopeLabel(ComboScope scope) => switch (scope) {
  ComboScope.work => t.profile_combo_scope_work,
  ComboScope.mediaType => t.profile_combo_scope_media_type,
  ComboScope.language => t.profile_combo_scope_language,
  ComboScope.defaults => scope.name,
};

String _mediaTypeLabel(String dbValue) =>
    switch (ProfileMediaKind.tryParse(dbValue)) {
      ProfileMediaKind.epub => t.profile_media_epub,
      ProfileMediaKind.srtbook => t.profile_media_srtbook,
      ProfileMediaKind.audiobook => t.profile_media_audiobook,
      ProfileMediaKind.lyrics => t.profile_media_lyrics,
      ProfileMediaKind.video => t.profile_media_video,
      ProfileMediaKind.manga => t.profile_media_manga,
      ProfileMediaKind.game => t.profile_media_game,
      ProfileMediaKind.browser => t.profile_media_browser,
      null => dbValue,
    };

String _leaves(List<String> ids) =>
    ids.map(comboLeafLabel).join(t.profile_combo_migration_list_separator);

/// 报告弹框本体。
Future<void> showComboMigrationReportDialog(
  BuildContext context,
  ComboMigrationReport report,
) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog(
    key: const ValueKey<String>('combo_migration_report'),
    icon: const FushiIcon(Icons.account_tree_outlined),
    title: Text(t.profile_combo_migration_title),
    content: SingleChildScrollView(
      child: FushiEntranceScope(
        child: ComboMigrationReportBody(report: report),
      ),
    ),
    actions: <Widget>[
      FushiTextButton(
        key: const ValueKey<String>('combo_migration_report_ok'),
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(t.dialog_ok),
      ),
    ],
  ),
);

/// 报告正文（弹框与测试共用）：每段错峰进场。
class ComboMigrationReportBody extends StatelessWidget {
  const ComboMigrationReportBody({required this.report, super.key});

  final ComboMigrationReport report;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<Widget> blocks = <Widget>[
      Text(t.profile_combo_migration_intro(name: report.defaultName)),
      if (report.combos.isNotEmpty)
        _Section(
          title: t.profile_combo_migration_splits_title,
          lines: <String>[
            for (final ComboMigrationEntry e in report.combos)
              t.profile_combo_migration_split_item(
                name: e.name,
                items: e.splitLeaves.isEmpty
                    ? t.profile_combo_migration_inherits_all
                    : _leaves(e.splitLeaves),
              ),
          ],
          titleStyle: text.titleSmall,
        ),
      if (report.conflicts.isNotEmpty)
        _Section(
          title: t.profile_combo_migration_conflicts_title,
          lines: <String>[
            for (final ComboBindingConflict c in report.conflicts)
              t.profile_combo_migration_conflict_item(
                language: c.languageTag,
                mediaType: _mediaTypeLabel(c.mediaType),
                items: _leaves(c.leaves),
                mediaProfile: c.mediaTypeProfile,
                languageProfile: c.languageProfile,
              ),
          ],
          titleStyle: text.titleSmall,
        ),
      if (report.ignored.isNotEmpty)
        _Section(
          title: t.profile_combo_migration_ignored_title,
          lines: <String>[
            for (final ComboIgnoredSplitEntry e in report.ignored)
              t.profile_combo_migration_ignored_item(
                profile: e.profile,
                count: '${e.bindings}',
                scope: _scopeLabel(e.scope),
                items: _leaves(e.leaves),
              ),
          ],
          titleStyle: text.titleSmall,
        ),
      if (report.srs case final ComboSrsLibraryDecision srs)
        _Section(
          title: t.profile_combo_leaf_srs_library,
          lines: <String>[
            t.profile_combo_migration_srs_shared(name: srs.sharedProfile),
            if (srs.ownProfiles.isNotEmpty)
              t.profile_combo_migration_srs_own(
                names: srs.ownProfiles.join(
                  t.profile_combo_migration_list_separator,
                ),
              ),
          ],
          titleStyle: text.titleSmall,
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < blocks.length; i++)
          FushiStaggeredEntrance(
            index: i,
            child: Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
              child: blocks[i],
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.lines,
    required this.titleStyle,
  });

  final String title;
  final List<String> lines;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(title, style: titleStyle),
      const SizedBox(height: 4),
      for (final String line in lines)
        Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $line')),
    ],
  );
}
