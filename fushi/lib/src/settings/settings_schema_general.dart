/// 「通用」一级分类：不属于任何一种内容、每个人都会碰到的日常偏好——语言、
/// 键盘与手柄、学习计时的口径、性能与新手上手。
///
/// 这里只做装配：每一项都留在它原来的 schema 文件里（那里有它依赖的私有
/// helper），以顶层 builder 导出，本文件按分区排好。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_music.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

SettingsDestination buildGeneralDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.general,
    title: t.settings_section_general,
    summary: t.settings_general_summary,
    icon: FushiIcons.settings,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'general.section.language',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_general_section_language,
        items: <SettingsItem>[
          buildInterfaceLanguageItem(),
          buildDefaultContentLanguageItem(),
        ],
      ),
      SettingsSection(
        id: 'general.section.input',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_general_section_input,
        items: <SettingsItem>[
          buildKeyboardShortcutsItem(),
          buildFocusNavigationItem(),
          buildControllerLookupStyleItem(),
        ],
      ),
      // 学习时长怎么算是跨媒介的同一套口径（空闲判定对小说 / PDF / 漫画 / 视频都
      // 生效，听歌是否计入也进同一份统计），所以从各自的阅读 / 音乐页提到这里；
      // 计时器、字数等读数的显示开关仍留在各阅读界面。
      SettingsSection(
        id: 'general.section.study_clock',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_general_section_study_clock,
        footer: t.settings_general_study_clock_footer,
        items: <SettingsItem>[
          ...buildStudyClockItems(),
          buildMusicListeningCountsAsStudyItem(),
        ],
      ),
      SettingsSection(
        id: 'general.section.performance',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_general_section_performance,
        // 「推荐包下载」行随 controller 的阶段实时显隐：本分组自己订阅 stage，
        // 不靠宿主页整页重建（小内存模式那一行恒可见，满足 liveListenable 的前提）。
        liveListenable: (SettingsContext settingsContext) =>
            settingsContext.appModel.recommendedPackDownloadController.stage,
        items: <SettingsItem>[
          buildLowMemoryModeItem(),
          buildOnboardingWizardItem(),
          buildRecommendedPackDownloadItem(),
          ...buildSteamShortcutItems(),
        ],
      ),
    ],
  );
}
