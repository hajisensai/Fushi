import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/utils.dart';

class SettingsHomePage extends BasePage {
  const SettingsHomePage({
    super.key,
    this.embedded = false,
  });

  final bool embedded;

  @override
  BasePageState<SettingsHomePage> createState() => _SettingsHomePageState();
}

class _SettingsHomePageState extends BasePageState<SettingsHomePage> {
  SettingsDestinationId _selectedDestinationId =
      SettingsDestinationId.readingDisplay;

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );
    final List<SettingsDestination> destinations = buildSettingsSchema(
      settingsContext,
    )
        .where((SettingsDestination destination) =>
            destination.isVisible(settingsContext))
        .toList(growable: false);
    if (!destinations.any(
      (SettingsDestination destination) =>
          destination.id == _selectedDestinationId,
    )) {
      _selectedDestinationId = destinations.first.id;
    }
    final SettingsRenderer renderer = isCupertinoPlatform(context)
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();

    return DesktopContentLayout(
      kind: DesktopContentKind.settings,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth >= 720) {
            return _buildWideLayout(
              settingsContext: settingsContext,
              renderer: renderer,
              destinations: destinations,
            );
          }
          return renderer.buildHomePage(
            settingsContext: settingsContext,
            destinations: destinations,
            selectedDestinationId: _selectedDestinationId,
            onDestinationSelected: _selectDestination,
            embedded: widget.embedded,
          );
        },
      ),
    );
  }

  Widget _buildWideLayout({
    required SettingsContext settingsContext,
    required SettingsRenderer renderer,
    required List<SettingsDestination> destinations,
  }) {
    final SettingsDestination selected = destinations.firstWhere(
      (SettingsDestination destination) =>
          destination.id == _selectedDestinationId,
    );
    final bool cupertino = isCupertinoPlatform(context);
    final Color dividerColor = cupertino
        ? CupertinoColors.separator.resolveFrom(context)
        : Theme.of(context).colorScheme.outlineVariant;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 280,
          child: renderer.buildDestinationList(
            settingsContext: settingsContext,
            destinations: destinations,
            selectedDestinationId: _selectedDestinationId,
            onDestinationSelected: _selectDestination,
            pushRoutes: false, // master-detail keeps selection in-pane.
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: dividerColor),
        Expanded(
          child: renderer.buildDetailContent(
            settingsContext: settingsContext,
            destination: selected,
          ),
        ),
      ],
    );
  }

  void _selectDestination(SettingsDestinationId id) {
    setState(() => _selectedDestinationId = id);
  }
}
