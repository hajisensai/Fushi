import 'dart:io' show Platform;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart'
    show buildCardCreationDestination;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 「设置 › 主屏幕小组件」（仅 Android）：小组件读的每日目标、默认隐私，以及怎么添加
/// 小组件、复习小组件跟哪个应用。小组件本身的数据都来自 app（见
/// `docs/agent/android-widgets.md`），这里只放有真实效果的设置：
/// - 每日目标 → 「目标」小组件（`WidgetSnapshotSource` 读同一批 AppModel 偏好）；
/// - 隐私 → 快照 `privacy` 默认值，每个小组件还能在自己的配置页里覆盖。
SettingsDestination buildWidgetsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.widgets,
    title: t.widget_settings_title,
    summary: t.widget_settings_summary,
    icon: FushiIcons.widgets,
    visible: (SettingsContext c) => Platform.isAndroid,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'widgets.section.howto',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.widget_settings_section_howto,
        items: <SettingsItem>[
          SettingsStatusItem(
            id: 'widgets.howto',
            title: t.widget_settings_howto_title,
            subtitle: t.widget_settings_howto_body,
            icon: FushiIcons.info,
          ),
        ],
      ),
      SettingsSection(
        id: 'widgets.section.goals',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.widget_settings_section_goals,
        footer: t.widget_settings_goals_footer,
        items: <SettingsItem>[
          _goalItem(
            id: 'widgets.goal_total_minutes',
            title: t.widget_settings_goal_total,
            unit: t.widget_settings_unit_minutes,
            max: 24 * 60,
            value: (SettingsContext c) => c.appModel.studyGoalDailyMinutes,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setStudyGoalDailyMinutes(v),
          ),
          _goalItem(
            id: 'widgets.goal_reading_minutes',
            title: t.widget_settings_goal_reading,
            unit: t.widget_settings_unit_minutes,
            max: 24 * 60,
            value: (SettingsContext c) =>
                c.appModel.studyGoalDailyReadingMinutes,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setStudyGoalDailyReadingMinutes(v),
          ),
          _goalItem(
            id: 'widgets.goal_listening_minutes',
            title: t.widget_settings_goal_listening,
            unit: t.widget_settings_unit_minutes,
            max: 24 * 60,
            value: (SettingsContext c) =>
                c.appModel.studyGoalDailyListeningMinutes,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setStudyGoalDailyListeningMinutes(v),
          ),
          _goalItem(
            id: 'widgets.goal_video_minutes',
            title: t.widget_settings_goal_video,
            unit: t.widget_settings_unit_minutes,
            max: 24 * 60,
            value: (SettingsContext c) => c.appModel.studyGoalDailyVideoMinutes,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setStudyGoalDailyVideoMinutes(v),
          ),
          _goalItem(
            id: 'widgets.goal_reviews',
            title: t.widget_settings_goal_reviews,
            unit: t.widget_settings_unit_cards,
            max: 1000000,
            value: (SettingsContext c) => c.appModel.srsGoalDailyReviews,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setSrsGoalDailyReviews(v),
          ),
          _goalItem(
            id: 'widgets.goal_mined_cards',
            title: t.widget_settings_goal_mined,
            unit: t.widget_settings_unit_cards,
            max: 1000000,
            value: (SettingsContext c) => c.appModel.miningGoalDailyCards,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setMiningGoalDailyCards(v),
          ),
          // 与统计页 / 首页同一个目标（`readingGoalDailyChars`），这里只是多一个入口。
          _goalItem(
            id: 'widgets.goal_chars',
            title: t.widget_settings_goal_chars,
            unit: t.stat_goal_unit_chars,
            max: 1000000,
            value: (SettingsContext c) => c.appModel.readingGoalDailyChars,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setReadingGoalDailyChars(v),
          ),
        ],
      ),
      SettingsSection(
        id: 'widgets.section.privacy',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.widget_settings_section_privacy,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'widgets.hide_titles',
            title: t.widget_settings_hide_titles,
            subtitle: t.widget_settings_hide_titles_hint,
            icon: FushiIcons.visibilityOff,
            defaultValue: false,
            value: (SettingsContext c) => c.appModel.widgetPrivacyHideTitles,
            onChanged: (SettingsContext c, bool v) async {
              await c.appModel.setWidgetPrivacyHideTitles(v);
              c.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'widgets.hide_definitions',
            title: t.widget_settings_hide_definitions,
            subtitle: t.widget_settings_hide_definitions_hint,
            icon: FushiIcons.visibilityOff,
            defaultValue: false,
            value: (SettingsContext c) =>
                c.appModel.widgetPrivacyHideDefinitions,
            onChanged: (SettingsContext c, bool v) async {
              await c.appModel.setWidgetPrivacyHideDefinitions(v);
              c.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'widgets.hide_profile',
            title: t.widget_settings_hide_profile,
            subtitle: t.widget_settings_hide_profile_hint,
            icon: FushiIcons.visibilityOff,
            defaultValue: false,
            value: (SettingsContext c) => c.appModel.widgetPrivacyHideProfile,
            onChanged: (SettingsContext c, bool v) async {
              await c.appModel.setWidgetPrivacyHideProfile(v);
              c.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        id: 'widgets.section.review',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.widget_settings_section_review,
        items: <SettingsItem>[
          // 复习小组件没有自己的开关：跟「制卡」里的卡片去向（Fushi 复习 / AnkiDroid）走。
          SettingsStatusItem(
            id: 'widgets.review_provider',
            title: t.widget_settings_review_title,
            subtitle: t.widget_settings_review_hint,
            icon: FushiIcons.ankiCard,
            actionLabel: t.widget_settings_review_action,
            onAction: (SettingsContext c) async {
              await pushSettingsPage(
                c,
                (_) => SettingsDetailPage(
                  destination: buildCardCreationDestination(),
                ),
              );
            },
          ),
        ],
      ),
    ],
  );
}

SettingsNumberItem _goalItem({
  required String id,
  required String title,
  required String unit,
  required int max,
  required int Function(SettingsContext) value,
  required Future<void> Function(SettingsContext, int) onChanged,
}) {
  return SettingsNumberItem(
    id: id,
    title: title,
    icon: FushiIcons.flag,
    integer: true,
    min: 0,
    max: max,
    suffixText: unit,
    value: value,
    resetValue: (SettingsContext c) => 0,
    onChanged: (SettingsContext c, num v) async {
      await onChanged(c, v.toInt());
      c.refresh();
    },
  );
}
