import 'package:flutter/material.dart';
import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

SettingsDestination buildMediaTrackingDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.mediaTracking,
    // 「功能模块」门控：关掉本模块 = 整条分类不渲染 / 不进搜索索引 / 主从详情不可选
    // （三条渲染路径共用 isVisible）。归属表见 module_registry.dart，别在此另写判据。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.mediaTracking,
      c.appModel.moduleVisibility,
    ),
    title: t.settings_destination_tracking,
    summary: t.media_tracking_summary,
    icon: Icons.auto_awesome_motion_outlined,
    sections: const <SettingsSection>[],
    body: (SettingsContext settingsContext) => MediaTrackingSettingsBody(
      appModel: settingsContext.appModel,
    ),
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'media_tracking.account',
        title: t.media_tracking_account,
        subtitle: t.media_tracking_access_token_hint,
      ),
      SettingsBodySearchEntry(
        id: 'media_tracking.mappings',
        title: t.media_tracking_mappings,
        subtitle: t.media_tracking_summary,
      ),
    ],
  );
}
