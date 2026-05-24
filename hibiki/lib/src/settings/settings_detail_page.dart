import 'package:flutter/widgets.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

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
    if (isCupertinoPlatform(context)) {
      return const CupertinoSettingsRenderer().buildDetailPage(
        settingsContext: settingsContext,
        destination: widget.destination,
      );
    }
    return const MaterialSettingsRenderer().buildDetailPage(
      settingsContext: settingsContext,
      destination: widget.destination,
    );
  }
}
