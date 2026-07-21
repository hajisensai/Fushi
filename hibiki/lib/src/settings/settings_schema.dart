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
    // Hibiki 互联从同步分类拆出的独立一级分类（构建函数在 sync_settings_schema
    // 同库，与同步共享私有状态）。
    buildInterconnectDestination(),
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

/// 遍历完整 schema，收集所有带 [VideoPlacement] 的 item，按 group + order 升序
/// 分组（与 [collectReaderItems] 同款；阶段 B 视频面板据此投影渲染）。
Map<VideoGroup, List<SettingsItem>> collectVideoItems(
  SettingsContext context,
) {
  final Map<VideoGroup, List<SettingsItem>> grouped =
      <VideoGroup, List<SettingsItem>>{};
  for (final SettingsDestination destination in buildSettingsSchema(context)) {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        final VideoPlacement? placement = item.video;
        if (placement == null) continue;
        grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
      }
    }
  }
  for (final List<SettingsItem> items in grouped.values) {
    items.sort((SettingsItem a, SettingsItem b) =>
        a.video!.order.compareTo(b.video!.order));
  }
  return grouped;
}

/// 把某个 [VideoGroup] 的 item 包装成一个可被 SettingsRenderer 渲染的 destination。
/// 与 reader 版不同：按 [VideoPlacement.section] 把相邻同名条目并入同一个带标题小节
/// （mpv 组的「画质 / 画面几何 / 色彩均衡」等），复刻旧手写面板的组内分区结构。
SettingsDestination buildVideoGroupDestination(
  SettingsContext context,
  VideoGroup group,
  String title,
) {
  final List<SettingsItem> items =
      collectVideoItems(context)[group] ?? <SettingsItem>[];
  final List<SettingsSection> sections = <SettingsSection>[];
  String? sectionTitle;
  List<SettingsItem> pending = <SettingsItem>[];
  void flush() {
    if (pending.isEmpty) return;
    sections.add(SettingsSection(title: sectionTitle, items: pending));
    pending = <SettingsItem>[];
  }

  for (final SettingsItem item in items) {
    final String? next = item.video!.section;
    if (pending.isNotEmpty && next != sectionTitle) flush();
    sectionTitle = next;
    pending.add(item);
  }
  flush();
  return SettingsDestination(
    id: SettingsDestinationId.videoQuickSettings,
    title: title,
    icon: Icons.tune_outlined,
    sections: sections.isEmpty
        ? <SettingsSection>[const SettingsSection(items: <SettingsItem>[])]
        : sections,
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
      sectionFor(ReaderGroup.layout, t.section_layout),
      sectionFor(ReaderGroup.behavior, t.settings_destination_reading_controls),
      sectionFor(ReaderGroup.lookup, t.settings_destination_lookup),
      sectionFor(ReaderGroup.audiobook, t.section_audiobook),
    ].where((SettingsSection s) => s.items.isNotEmpty).toList(growable: false),
  );
}
