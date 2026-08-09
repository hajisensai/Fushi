import 'package:flutter/material.dart';
import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

SettingsDestination buildMediaTrackingDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.mediaTracking,
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
