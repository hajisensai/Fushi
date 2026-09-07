import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/video_online_services_preferences.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/utils.dart';

/// One reminder shared by the video library's home, series and all sections.
class VideoOnlineServicesBanner extends StatefulWidget {
  const VideoOnlineServicesBanner({
    super.key,
    required this.preferences,
    required this.onRegister,
    required this.onOpenSettings,
  });

  final PreferencesRepository preferences;
  final Future<void> Function() onRegister;
  final Future<void> Function() onOpenSettings;

  @override
  State<VideoOnlineServicesBanner> createState() =>
      _VideoOnlineServicesBannerState();
}

class _VideoOnlineServicesBannerState extends State<VideoOnlineServicesBanner> {
  @override
  void initState() {
    super.initState();
    widget.preferences.addListener(_preferencesChanged);
  }

  @override
  void didUpdateWidget(covariant VideoOnlineServicesBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences) {
      oldWidget.preferences.removeListener(_preferencesChanged);
      widget.preferences.addListener(_preferencesChanged);
    }
  }

  @override
  void dispose() {
    widget.preferences.removeListener(_preferencesChanged);
    super.dispose();
  }

  void _preferencesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _dismiss() async {
    await dismissVideoOnlineServicesReminder(widget.preferences);
    if (mounted) setState(() {});
  }

  Future<void> _openSettings() async {
    await widget.onOpenSettings();
    if (mounted) setState(() {});
  }

  Future<void> _openOverview() async {
    await widget.onRegister();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!shouldShowVideoOnlineServicesReminder(widget.preferences)) {
      return const SizedBox.shrink();
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: FushiCard(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
            vertical: tokens.spacing.rowVertical,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.video_online_services_setup_title,
                  style: Theme.of(context).textTheme.titleSmall),
              SizedBox(height: tokens.spacing.gap),
              Text(t.video_online_services_setup_description),
              SizedBox(height: tokens.spacing.gap),
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  TextButton.icon(
                    onPressed: _openOverview,
                    icon: const Icon(Icons.info_outline),
                    label: Text(t.video_online_services_setup_register),
                  ),
                  FilledButton.tonal(
                    onPressed: _openSettings,
                    child: Text(t.video_online_services_setup_settings),
                  ),
                  TextButton(
                    onPressed: _dismiss,
                    child: Text(t.video_online_services_setup_dismiss),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
