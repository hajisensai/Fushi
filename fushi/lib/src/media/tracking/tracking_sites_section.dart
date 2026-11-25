import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:material_ui/material_ui.dart';

/// Which site gets which media type: one switch per site and type, grouped by
/// Fushi section (Anime, Manga, Books). Defaults come from each provider
/// (AniList → anime; MangaBaka → manga and books); the user can change them.
class TrackingSitesSection extends StatefulWidget {
  const TrackingSitesSection({required this.service, super.key});

  final MediaTrackingService service;

  @override
  State<TrackingSitesSection> createState() => _TrackingSitesSectionState();
}

class _TrackingSitesSectionState extends State<TrackingSitesSection> {
  MediaTrackingService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.statusRevision.addListener(_changed);
  }

  @override
  void dispose() {
    _service.statusRevision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<TrackingProvider> providers = _service.providers.all;
    return AdaptiveSettingsSection(
      title: t.media_tracking_sites_title,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.media_tracking_sites_choose_hint,
          titleMaxLines: 4,
          icon: FushiIcons.info,
          showIcon: true,
        ),
        for (final TrackingKind kind in const <TrackingKind>[
          TrackingKind.anime,
          TrackingKind.manga,
          TrackingKind.novel,
          TrackingKind.game,
        ])
          for (final TrackingProvider provider in providers)
            if (provider.capabilities.acceptsKind(kind))
              AdaptiveSettingsSwitchRow(
                title:
                    '${trackingKindLabel(kind.value)} · ${provider.displayName}',
                subtitle: provider.isConfigured
                    ? null
                    : t.media_tracking_sites_not_connected,
                value:
                    provider.isConfigured &&
                    _service.isKindEnabled(provider.id, kind),
                onChanged: provider.isConfigured
                    ? (bool value) =>
                          _service.setKindEnabled(provider.id, kind, value)
                    : null,
              ),
      ],
    );
  }
}
