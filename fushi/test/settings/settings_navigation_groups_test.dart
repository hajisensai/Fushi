import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';

SettingsDestination destination(SettingsDestinationId id) =>
    SettingsDestination(
      id: id,
      title: id.name,
      icon: Icons.settings,
      sections: const <SettingsSection>[],
    );

void main() {
  test('hidden modules do not leave empty headings or change peer order', () {
    final List<SettingsDestination> visible = <SettingsDestination>[
      destination(SettingsDestinationId.appearance),
      destination(SettingsDestinationId.lookup),
      destination(SettingsDestinationId.cardCreation),
      destination(SettingsDestinationId.downloads),
      destination(SettingsDestinationId.storage),
      destination(SettingsDestinationId.system),
    ];
    final List<SettingsNavigationGroup> groups = groupSettingsDestinations(
      visible,
    );
    expect(
      groups.map((SettingsNavigationGroup group) => group.id),
      <SettingsNavigationGroupId>[
        SettingsNavigationGroupId.interface,
        SettingsNavigationGroupId.learning,
        SettingsNavigationGroupId.connections,
        SettingsNavigationGroupId.data,
        SettingsNavigationGroupId.app,
      ],
    );
    expect(
      groups.expand((SettingsNavigationGroup group) => group.destinations),
      visible,
    );
    expect(groupSettingsDestinations(const <SettingsDestination>[]), isEmpty);
  });

  test('tracking stays with content when enabled', () {
    final List<SettingsDestination> visible = <SettingsDestination>[
      destination(SettingsDestinationId.reading),
      destination(SettingsDestinationId.manga),
      destination(SettingsDestinationId.video),
      destination(SettingsDestinationId.game),
      destination(SettingsDestinationId.mediaTracking),
    ];
    final List<SettingsNavigationGroup> groups = groupSettingsDestinations(
      visible,
    );
    expect(groups.single.id, SettingsNavigationGroupId.content);
    expect(groups.single.destinations, visible);
    expect(() => groups.single.destinations.clear(), throwsUnsupportedError);
  });
}
