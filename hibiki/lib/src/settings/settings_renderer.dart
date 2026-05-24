import 'package:flutter/widgets.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';

abstract class SettingsRenderer {
  Widget buildHomePage({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool embedded = false,
  });

  Widget buildDestinationList({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool pushRoutes = true,
  });

  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  });

  Widget buildDetailContent({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  });
}
