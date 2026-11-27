import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_schema_manga.dart'
    show buildMangaToolbarLayoutDestination;
import 'package:fushi/src/settings/settings_schema_reading.dart'
    show buildReaderStatusBarDestination, buildReaderToolbarLayoutDestination;
import 'package:fushi/src/settings/settings_schema_video.dart'
    show buildVideoControlLayoutSettingsDestination;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 某一级分类的模块此刻是否开着（模块关掉时它的布局入口一起藏起来）。
SettingsVisibility _moduleVisible(SettingsDestinationId id) =>
    (SettingsContext c) =>
        isSettingsDestinationVisible(id, c.appModel.moduleVisibility);

/// 「外观 › 自定义布局」：各模块拖放布局编辑器的集中入口（反馈 JONk4qmF8V，维护者
/// 2026-11-25「这些自定义的 ui 拆出来放到某个地方统一管理」）。
///
/// 每一项链到的子页与各模块设置页里的入口是**同一个** destination（同一份 item、
/// 同一个编辑器），这里只是集中目录，不存第二份状态。编辑器本身全部是泛型
/// `ControlLayoutEditor`（拖放 / 键盘手柄搬运 / 两套设计系统）。
SettingsDestination buildCustomLayoutsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_custom_layouts_title,
    summary: t.settings_custom_layouts_hint,
    icon: FushiIcons.dashboardCustomize,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'appearance.custom_layouts.section.novel',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_custom_layouts_section_novel,
        visible: _moduleVisible(SettingsDestinationId.reading),
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.custom_layouts.reader_toolbar',
            title: t.reader_control_editor_title,
            subtitle: t.settings_custom_layouts_reader_toolbar_hint,
            icon: FushiIcons.dashboardCustomize,
            child: buildReaderToolbarLayoutDestination,
          ),
          SettingsNavigationItem(
            id: 'appearance.custom_layouts.reader_status_bar',
            title: t.reader_status_bar_title,
            subtitle: t.reader_status_bar_subtitle,
            icon: FushiIcons.viewAgenda,
            child: buildReaderStatusBarDestination,
          ),
        ],
      ),
      SettingsSection(
        id: 'appearance.custom_layouts.section.manga',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_custom_layouts_section_manga,
        visible: _moduleVisible(SettingsDestinationId.manga),
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.custom_layouts.manga_toolbar',
            title: t.manga_reader_control_layout,
            subtitle: t.settings_custom_layouts_manga_toolbar_hint,
            icon: FushiIcons.dashboardCustomize,
            child: buildMangaToolbarLayoutDestination,
          ),
        ],
      ),
      SettingsSection(
        id: 'appearance.custom_layouts.section.video',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_custom_layouts_section_video,
        visible: _moduleVisible(SettingsDestinationId.video),
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.custom_layouts.video_controls',
            title: t.settings_custom_layouts_video_controls,
            subtitle: t.settings_custom_layouts_video_controls_hint,
            icon: FushiIcons.dashboardCustomize,
            child: buildVideoControlLayoutSettingsDestination,
          ),
        ],
      ),
    ],
  );
}
