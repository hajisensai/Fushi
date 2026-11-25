import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
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
        SettingsNavigationGroupId.general,
        SettingsNavigationGroupId.learning,
        SettingsNavigationGroupId.connections,
        SettingsNavigationGroupId.data,
        SettingsNavigationGroupId.system,
      ],
    );
    expect(
      groups.expand((SettingsNavigationGroup group) => group.destinations),
      visible,
    );
    expect(groupSettingsDestinations(const <SettingsDestination>[]), isEmpty);
  });

  // 媒体记录只做一件事：把进度记到第三方账号上，所以与其它在线账号同组，
  // 不混在「内容」里。
  test('tracking sits with the other online accounts when enabled', () {
    final List<SettingsDestination> visible = <SettingsDestination>[
      destination(SettingsDestinationId.downloads),
      destination(SettingsDestinationId.services),
      destination(SettingsDestinationId.mediaTracking),
      destination(SettingsDestinationId.localServices),
    ];
    final List<SettingsNavigationGroup> groups = groupSettingsDestinations(
      visible,
    );
    expect(groups.single.id, SettingsNavigationGroupId.connections);
    expect(groups.single.destinations, visible);
    expect(() => groups.single.destinations.clear(), throwsUnsupportedError);
  });

  test('every first-level destination lands in its documented group', () {
    const Map<SettingsNavigationGroupId, List<SettingsDestinationId>> expected =
        <SettingsNavigationGroupId, List<SettingsDestinationId>>{
          SettingsNavigationGroupId.general: <SettingsDestinationId>[
            SettingsDestinationId.general,
            SettingsDestinationId.appearance,
            SettingsDestinationId.navigation,
            SettingsDestinationId.floatingBall,
          ],
          SettingsNavigationGroupId.content: <SettingsDestinationId>[
            SettingsDestinationId.reading,
            SettingsDestinationId.listening,
            SettingsDestinationId.manga,
            SettingsDestinationId.video,
            SettingsDestinationId.music,
            SettingsDestinationId.game,
            SettingsDestinationId.webBrowser,
          ],
          SettingsNavigationGroupId.learning: <SettingsDestinationId>[
            SettingsDestinationId.lookup,
            SettingsDestinationId.cardCreation,
          ],
          SettingsNavigationGroupId.aiModels: <SettingsDestinationId>[
            SettingsDestinationId.ai,
            SettingsDestinationId.models,
          ],
          SettingsNavigationGroupId.connections: <SettingsDestinationId>[
            SettingsDestinationId.downloads,
            SettingsDestinationId.services,
            SettingsDestinationId.mediaTracking,
            SettingsDestinationId.localServices,
          ],
          SettingsNavigationGroupId.data: <SettingsDestinationId>[
            SettingsDestinationId.profiles,
            SettingsDestinationId.syncBackup,
            SettingsDestinationId.interconnect,
            SettingsDestinationId.storage,
          ],
          SettingsNavigationGroupId.system: <SettingsDestinationId>[
            SettingsDestinationId.widgets,
            SettingsDestinationId.system,
          ],
        };
    expected.forEach((
      SettingsNavigationGroupId group,
      List<SettingsDestinationId> ids,
    ) {
      for (final SettingsDestinationId id in ids) {
        expect(settingsNavigationGroupFor(id), group, reason: id.name);
      }
    });
  });
}
