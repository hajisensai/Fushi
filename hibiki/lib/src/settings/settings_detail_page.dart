import 'package:flutter/widgets.dart';
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

/// Renders [destination] through the active platform's settings detail shell
/// (Material → [HibikiPageScaffold] + 24px padding + [AdaptiveSettingsSection];
/// Cupertino → grouped sliver list). This is the SAME chrome the master-detail
/// renderer uses, so any pushed settings sub-page built on top of it is visually
/// indistinguishable from a real schema destination — no scaffold/padding/card
/// drift between the unified detail pane and the pages it links to.
///
/// Used by the pushed sub-pages that are not first-class schema destinations
/// (shortcut bindings, app-icon picker): they synthesise a [SettingsDestination]
/// (usually with a `body` escape hatch carrying their custom content) and call
/// this, instead of hand-rolling their own scaffold.
Widget buildSettingsDetailShell({
  required BuildContext context,
  required SettingsContext settingsContext,
  required SettingsDestination destination,
}) {
  final SettingsRenderer renderer = isCupertinoPlatform(context)
      ? const CupertinoSettingsRenderer()
      : const MaterialSettingsRenderer();
  return renderer.buildDetailPage(
    settingsContext: settingsContext,
    destination: destination,
  );
}

class SettingsDetailPage extends BasePage {
  const SettingsDetailPage({
    required this.destination,
    super.key,
  });

  final SettingsDestination destination;

  @override
  BasePageState<SettingsDetailPage> createState() => _SettingsDetailPageState();
}

class _SettingsDetailPageState extends BasePageState<SettingsDetailPage> {
  @override
  void initState() {
    super.initState();
    ErrorLogService.instance.addListener(_onLogChanged);
    DebugLogService.instance.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    ErrorLogService.instance.removeListener(_onLogChanged);
    DebugLogService.instance.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
  }

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
    final SettingsDestination destination = _freshDestination(settingsContext);
    if (isCupertinoPlatform(context)) {
      return const CupertinoSettingsRenderer().buildDetailPage(
        settingsContext: settingsContext,
        destination: destination,
      );
    }
    return const MaterialSettingsRenderer().buildDetailPage(
      settingsContext: settingsContext,
      destination: destination,
    );
  }

  SettingsDestination _freshDestination(SettingsContext settingsContext) {
    for (final SettingsDestination destination
        in buildSettingsSchema(settingsContext)) {
      if (destination.id == widget.destination.id) return destination;
    }
    return widget.destination;
  }
}
