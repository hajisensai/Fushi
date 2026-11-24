part of '../srs_deck_list_page.dart';

// Apple（Cupertino）复习首页的横幅：一律 TipKit 内联提示外观（拍板点 3）——与分组卡
// 同一枚 secondaryGroupedBackground 实色面、左侧强调色单色图标、标题 + 正文、下面
// 一排 plain 文字按钮（主选项加粗）。「每日上限改按作答次数计」不带 ✕：必须选一个
// 才算处理完（与 M3E 一致）；Lapis 迁移提醒的「不再提醒」本身就是关闭项。
// 后台导入任务条（[SrsImportTasksBar]，FushiCard 已有 Apple 分组面）与清除出错提示
// （[SrsScrubErrorNotice]）照用公共件，位置不变（列表最前）。

/// TipKit 提示里的一个文字动作。
@immutable
class _AppleSrsTipAction {
  const _AppleSrsTipAction({
    required this.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final Key key;
  final String label;
  final VoidCallback? onPressed;

  /// 默认项（semibold）。
  final bool primary;
}

/// TipKit 式内联提示卡。
class _AppleSrsTip extends StatelessWidget {
  const _AppleSrsTip({
    super.key,
    required this.icon,
    required this.body,
    this.title,
    this.tint,
    this.actions = const <_AppleSrsTipAction>[],
  });

  final IconData icon;
  final String? title;
  final String body;

  /// 图标色；null = 强调色（引擎不可用这类警示传 destructive）。
  final Color? tint;
  final List<_AppleSrsTipAction> actions;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle titleStyle = (text.titleMedium ?? const TextStyle())
        .copyWith(
          fontSize: (m.desktop ? 13 : 17) * s,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          height: 1.25,
          color: apple.label,
        );
    final TextStyle bodyStyle = (text.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: (m.desktop ? 12 : 15) * s,
      letterSpacing: 0,
      height: 1.35,
      color: apple.secondaryLabel,
    );
    final TextStyle actionStyle = (text.labelLarge ?? const TextStyle())
        .copyWith(
          fontSize: (m.desktop ? 13 : 17) * s,
          letterSpacing: 0,
          color: apple.accent,
        );
    final String? heading = title;
    return FushiAppleGroupSurface(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          (m.desktop ? 12 : 16) * s,
          (m.desktop ? 12 : 16) * s,
          (m.desktop ? 12 : 16) * s,
          actions.isEmpty ? (m.desktop ? 12 : 16) * s : (m.desktop ? 4 : 6) * s,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: (m.desktop ? 10 : 14) * s,
          children: <Widget>[
            FushiIcon(
              icon,
              size: (m.desktop ? 22 : 30) * s,
              color: tint ?? apple.accent,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 4 * s,
                children: <Widget>[
                  if (heading != null) Text(heading, style: titleStyle),
                  Text(body, style: bodyStyle),
                  if (actions.isNotEmpty)
                    Wrap(
                      spacing: (m.desktop ? 4 : 8) * s,
                      children: <Widget>[
                        for (final _AppleSrsTipAction a in actions)
                          FushiPressScale(
                            child: FushiPlainButton(
                              key: a.key,
                              onPressed: a.onPressed,
                              semanticLabel: a.label,
                              borderRadius: BorderRadius.circular(8 * s),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: m.desktop ? 28 * s : 44,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 4 * s,
                                  ),
                                  child: Align(
                                    widthFactor: 1,
                                    child: Text(
                                      a.label,
                                      style: actionStyle.copyWith(
                                        fontWeight: a.primary
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Apple 档的横幅列表（与 M3E [_srsDeckBanners] 同参、同 key、同位置：根层列表最前）。
List<Widget> _appleSrsDeckBanners(
  BuildContext context, {
  required SrsDeckListData data,
  required bool showImportTasks,
  required int lapisPending,
  required bool joinProvisional,
  required VoidCallback onMigrateLapis,
  required VoidCallback onDismissLapisReminder,
  required VoidCallback onStarterPacks,
  required VoidCallback onAddFirst,
  required int legacyLimitUnitDecks,
  required VoidCallback onKeepLegacyLimitCards,
  required VoidCallback onAcceptLimitAnswers,
}) {
  final FushiAppleColors apple = appleColorsOf(context);
  return <Widget>[
    if (showImportTasks)
      const SrsImportTasksBar(key: ValueKey<String>('srs-import-tasks')),
    if (legacyLimitUnitDecks > 0)
      _AppleSrsTip(
        key: const ValueKey<String>('srs-limit-unit-notice'),
        icon: FushiIcons.info,
        title: t.srs_limit_unit_notice_title,
        body: t.srs_limit_unit_notice_body(n: legacyLimitUnitDecks),
        actions: <_AppleSrsTipAction>[
          _AppleSrsTipAction(
            key: const ValueKey<String>('srs-limit-unit-keep-cards'),
            label: t.srs_limit_unit_notice_keep_cards,
            onPressed: onKeepLegacyLimitCards,
          ),
          _AppleSrsTipAction(
            key: const ValueKey<String>('srs-limit-unit-accept'),
            label: t.srs_limit_unit_notice_accept,
            onPressed: onAcceptLimitAnswers,
            primary: true,
          ),
        ],
      ),
    if (lapisPending > 0)
      _AppleSrsTip(
        key: const ValueKey<String>('srs-lapis-migration-reminder'),
        icon: FushiIcons.swap,
        title: t.srs_lapis_migration_reminder_title,
        body: t.srs_lapis_migration_entry_summary(n: lapisPending),
        actions: <_AppleSrsTipAction>[
          _AppleSrsTipAction(
            key: const ValueKey<String>('srs-lapis-migration-reminder-dismiss'),
            label: t.srs_lapis_migration_reminder_dismiss,
            onPressed: onDismissLapisReminder,
          ),
          _AppleSrsTipAction(
            key: const ValueKey<String>('srs-lapis-migration-reminder-open'),
            label: t.srs_lapis_migration_migrate,
            onPressed: onMigrateLapis,
            primary: true,
          ),
        ],
      ),
    if (joinProvisional)
      _AppleSrsTip(
        key: const ValueKey<String>('srs-join-provisional'),
        icon: FushiIcons.cloudSync,
        body: t.srs_sync_join_provisional_hint,
      ),
    if (!data.store.canSchedule)
      _AppleSrsTip(
        key: const ValueKey<String>('srs-engine-missing'),
        icon: FushiIcons.warning,
        tint: apple.destructive,
        body: t.srs_engine_unavailable,
      ),
    if (data.totalCards == 0)
      _AppleSrsTip(
        key: const ValueKey<String>('srs-empty'),
        icon: FushiIcons.ankiCard,
        title: t.srs_empty_title,
        body: t.srs_empty_body,
        actions: <_AppleSrsTipAction>[
          _AppleSrsTipAction(
            key: const ValueKey<String>('srs-starter-packs'),
            label: t.srs_starter_title,
            onPressed: onStarterPacks,
          ),
          _AppleSrsTipAction(
            key: const ValueKey<String>('srs-add-first'),
            label: t.srs_empty_action,
            onPressed: onAddFirst,
            primary: true,
          ),
        ],
      ),
  ];
}
