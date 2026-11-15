/// Tells the user when media tracking linked a title by itself (T1 F9, the
/// user's option B): automatic linking stays as it is, and each new link is
/// announced once in the app's snackbar, with a button to the Tracking page.
/// Links made while a notice is up join it (one notice with a count), so the
/// catch-up after start never shows a row of snackbars.
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

/// The notice text for [links] (in the order they were made): one title
/// names its site entries; several say how many titles.
String trackingAutoLinkNoticeText(List<TrackingAutoLink> links) {
  final Set<String> titles = <String>{
    for (final TrackingAutoLink link in links)
      '${link.mapping.mediaType}|${link.mapping.mediaKey}',
  };
  if (titles.length > 1) {
    return t.media_tracking_auto_link_many(n: titles.length);
  }
  final List<String> entries = <String>[
    for (final TrackingAutoLink link in links)
      t.media_tracking_auto_link_entry(
        entry: link.mapping.subjectName,
        site: link.siteName,
      ),
  ];
  return t.media_tracking_auto_link_one(
    title: links.first.mapping.mediaTitle,
    entries: entries.join(', '),
  );
}

/// Listens to [MediaTrackingService.autoLinks] for the app's lifetime and
/// shows the notices through [messenger].
final class TrackingAutoLinkNotices {
  TrackingAutoLinkNotices({
    required Stream<TrackingAutoLink> links,
    required GlobalKey<ScaffoldMessengerState> messenger,
    required this.onReview,
  }) : _messenger = messenger {
    _subscription = links.listen(_onLink);
  }

  final GlobalKey<ScaffoldMessengerState> _messenger;

  /// Opens the Tracking page (the notice's button).
  final VoidCallback onReview;

  late final StreamSubscription<TrackingAutoLink> _subscription;

  /// Links of the notice on screen (or waiting for a messenger).
  final ValueNotifier<List<TrackingAutoLink>> _shown =
      ValueNotifier<List<TrackingAutoLink>>(const <TrackingAutoLink>[]);
  bool _visible = false;

  void _onLink(TrackingAutoLink link) {
    _shown.value = <TrackingAutoLink>[..._shown.value, link];
    if (_visible) return;
    final ScaffoldMessengerState? messenger = _messenger.currentState;
    if (messenger == null) return;
    _visible = true;
    messenger
        .showSnackBar(
          FushiSnackBar(
            key: const ValueKey<String>('tracking-auto-link-notice'),
            content: ValueListenableBuilder<List<TrackingAutoLink>>(
              valueListenable: _shown,
              builder: (_, List<TrackingAutoLink> links, _) =>
                  Text(trackingAutoLinkNoticeText(links)),
            ),
            persist: false,
            action: SnackBarAction(
              label: t.media_tracking_auto_link_review,
              onPressed: onReview,
            ),
          ),
        )
        .closed
        .then((_) {
          _visible = false;
          _shown.value = const <TrackingAutoLink>[];
        });
  }

  void dispose() {
    unawaited(_subscription.cancel());
    _shown.dispose();
  }
}
