/// The signed-in account's watched anime on a tracking site, read from the
/// site (not mirrored locally): the built-in Bangumi's collection API, or a
/// tracking plugin's `trackingList` (the bundled Bangumi plugin included).
/// Opened from the Media tracking settings page (the Bangumi block, or a
/// plugin's row in "Tracking plugins").
library;

import 'dart:async';

import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show TrackingKind;
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows [TrackingWatchedDialog] for site [providerId]; a row opens the
/// subject's page in the browser when the site's addresses are known
/// ([MediaTrackingService.subjectPageUrl]).
Future<void> showTrackingWatchedDialog(
  BuildContext context,
  MediaTrackingService service, {
  required String providerId,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => TrackingWatchedDialog(
    service: service,
    providerId: providerId,
    onOpenSubject: (Uri url) =>
        launchUrl(url, mode: LaunchMode.externalApplication),
  ),
);

class TrackingWatchedDialog extends StatefulWidget {
  const TrackingWatchedDialog({
    super.key,
    required this.service,
    required this.providerId,
    required this.onOpenSubject,
  });

  final MediaTrackingService service;
  final String providerId;
  final Future<void> Function(Uri url) onOpenSubject;

  @override
  State<TrackingWatchedDialog> createState() => TrackingWatchedDialogState();
}

class TrackingWatchedDialogState extends State<TrackingWatchedDialog> {
  late final Future<List<TrackingWatchedItem>> _watched = widget.service
      .loadWatchedAnime(providerId: widget.providerId);

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Row(
        children: <Widget>[
          const FushiIcon(FushiIcons.visibility),
          const SizedBox(width: 12),
          Expanded(child: Text(t.media_tracking_watched_title)),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: FutureBuilder<List<TrackingWatchedItem>>(
          future: _watched,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<TrackingWatchedItem>> snapshot,
              ) {
                // 加载 / 失败 / 空走统一占位件（MD3 中性块 / Apple 大图标灰字），
                // 不再是裸菊花与裸文字。
                if (snapshot.connectionState != ConnectionState.done) {
                  return const FushiLoadingView();
                }
                if (snapshot.hasError) {
                  return Center(
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.error,
                      message: t.media_tracking_watched_load_failed(
                        error: snapshot.error!,
                      ),
                    ),
                  );
                }
                final List<TrackingWatchedItem> watched =
                    snapshot.data ?? const <TrackingWatchedItem>[];
                if (watched.isEmpty) {
                  return Center(
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.visibility,
                      message: t.media_tracking_watched_empty,
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: watched.length,
                  separatorBuilder: (_, __) =>
                      const FushiDividerControl(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final TrackingWatchedItem item = watched[index];
                    final String? coverUrl = item.coverUrl;
                    final Uri? url = widget.service.subjectPageUrl(
                      widget.providerId,
                      item.subjectId,
                      TrackingKind.anime,
                    );
                    return FushiListItem(
                      padding: EdgeInsets.zero,
                      titleMaxLines: 2,
                      leading: SizedBox(
                        width: 42,
                        height: 56,
                        child: coverUrl == null
                            ? const FushiIcon(FushiIcons.video)
                            : ClipRRect(
                                borderRadius: FushiBorderRadius.chip,
                                child: Image(
                                  image: AppHttpImage(coverUrl),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const FushiIcon(FushiIcons.brokenImage),
                                ),
                              ),
                      ),
                      title: Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        t.media_tracking_watched_progress(n: item.progress),
                      ),
                      trailing: url == null
                          ? null
                          : FushiTooltip(
                              message: t.media_tracking_open_subject,
                              child: const FushiIcon(
                                FushiIcons.openInNew,
                                size: 18,
                              ),
                            ),
                      onTap: url == null
                          ? null
                          : () => unawaited(widget.onOpenSubject(url)),
                    );
                  },
                );
              },
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.media_tracking_close),
        ),
      ],
    );
  }
}
