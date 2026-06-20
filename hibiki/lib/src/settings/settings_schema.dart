import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_appearance.dart';
import 'package:hibiki/src/settings/settings_schema_card_creation.dart';
import 'package:hibiki/src/settings/settings_schema_listening.dart';
import 'package:hibiki/src/settings/settings_schema_lookup.dart';
import 'package:hibiki/src/settings/settings_schema_profiles.dart';
import 'package:hibiki/src/settings/settings_schema_reading.dart';
import 'package:hibiki/src/settings/settings_schema_system.dart';
import 'package:hibiki/src/settings/settings_schema_video.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/utils.dart';

List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    buildAppearanceDestination(),
    buildProfilesDestination(),
    buildReadingDestination(),
    buildLookupDestination(),
    buildCardCreationDestination(),
    buildVideoDestination(),
    buildListeningDestination(),
    buildSyncBackupDestination(),
    buildSystemDestination(),
  ];
}

/// 遍历完整 schema，收集所有带 [ReaderPlacement] 的 item，按 group + order 升序分组。
Map<ReaderGroup, List<SettingsItem>> collectReaderItems(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      <ReaderGroup, List<SettingsItem>>{};
  for (final SettingsDestination destination in buildSettingsSchema(context)) {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        final ReaderPlacement? placement = item.reader;
        if (placement == null) continue;
        grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
      }
    }
  }
  for (final List<SettingsItem> items in grouped.values) {
    items.sort((SettingsItem a, SettingsItem b) =>
        a.reader!.order.compareTo(b.reader!.order));
  }
  return grouped;
}

/// 把某个 [ReaderGroup] 的 item 包装成一个可被 SettingsRenderer 渲染的 destination。
SettingsDestination buildReaderGroupDestination(
  SettingsContext context,
  ReaderGroup group,
  String title,
) {
  final List<SettingsItem> items =
      collectReaderItems(context)[group] ?? <SettingsItem>[];
  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: title,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[SettingsSection(items: items)],
  );
}

SettingsDestination buildReaderQuickSettingsDestination(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      collectReaderItems(context);
  SettingsSection sectionFor(ReaderGroup group, String title) {
    return SettingsSection(
      title: title,
      items: grouped[group] ?? <SettingsItem>[],
    );
  }

  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      sectionFor(ReaderGroup.appearance, t.settings_destination_appearance),
      sectionFor(ReaderGroup.layout, t.section_layout),
      sectionFor(ReaderGroup.behavior, t.settings_destination_reading_controls),
      sectionFor(ReaderGroup.lookup, t.settings_destination_lookup),
      sectionFor(ReaderGroup.audiobook, t.section_audiobook),
    ].where((SettingsSection s) => s.items.isNotEmpty).toList(growable: false),
  );
}
