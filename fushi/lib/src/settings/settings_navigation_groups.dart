import 'package:flutter/widgets.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';

/// 一级导航分组固定展开，分区内部的展开策略与此无关。
enum SettingsNavigationGroupId {
  general,
  content,
  learning,
  aiModels,
  connections,
  data,
  system;

  String title(BuildContext context) => switch (this) {
    general => context.t.settings_group_general,
    content => context.t.settings_group_content,
    learning => context.t.settings_group_learning,
    aiModels => context.t.settings_group_ai_models,
    connections => context.t.settings_group_connections,
    data => context.t.settings_group_data,
    system => context.t.settings_group_system,
  };
}

class SettingsNavigationGroup {
  SettingsNavigationGroup(this.id, Iterable<SettingsDestination> destinations)
    : destinations = List<SettingsDestination>.unmodifiable(destinations);

  final SettingsNavigationGroupId id;
  final List<SettingsDestination> destinations;
}

SettingsNavigationGroupId settingsNavigationGroupFor(
  SettingsDestinationId id,
) => switch (id) {
  SettingsDestinationId.general ||
  SettingsDestinationId.appearance ||
  SettingsDestinationId.navigation ||
  SettingsDestinationId.floatingBall => SettingsNavigationGroupId.general,
  SettingsDestinationId.reading ||
  SettingsDestinationId.listening ||
  SettingsDestinationId.manga ||
  SettingsDestinationId.video ||
  SettingsDestinationId.music ||
  SettingsDestinationId.game ||
  SettingsDestinationId.webBrowser => SettingsNavigationGroupId.content,
  SettingsDestinationId.lookup ||
  SettingsDestinationId.cardCreation => SettingsNavigationGroupId.learning,
  SettingsDestinationId.ai ||
  SettingsDestinationId.models => SettingsNavigationGroupId.aiModels,
  // 媒体记录只做一件事：把进度记到第三方账号上，所以与其它在线账号放在一组。
  SettingsDestinationId.downloads ||
  SettingsDestinationId.services ||
  SettingsDestinationId.mediaTracking ||
  SettingsDestinationId.localServices => SettingsNavigationGroupId.connections,
  SettingsDestinationId.profiles ||
  SettingsDestinationId.syncBackup ||
  SettingsDestinationId.interconnect ||
  SettingsDestinationId.storage => SettingsNavigationGroupId.data,
  SettingsDestinationId.system ||
  SettingsDestinationId.widgets ||
  SettingsDestinationId.readerQuickSettings ||
  SettingsDestinationId.videoQuickSettings ||
  SettingsDestinationId.appIcon ||
  SettingsDestinationId.shortcuts => SettingsNavigationGroupId.system,
};

/// 接收经过平台和模块门控后的列表，保留 schema 组内顺序，不生成空标题。
List<SettingsNavigationGroup> groupSettingsDestinations(
  List<SettingsDestination> destinations,
) {
  return <SettingsNavigationGroup>[
    for (final SettingsNavigationGroupId id in SettingsNavigationGroupId.values)
      if (destinations.any(
        (SettingsDestination destination) =>
            settingsNavigationGroupFor(destination.id) == id,
      ))
        SettingsNavigationGroup(
          id,
          destinations.where(
            (SettingsDestination destination) =>
                settingsNavigationGroupFor(destination.id) == id,
          ),
        ),
  ];
}
