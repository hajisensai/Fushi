import 'package:flutter/material.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// A default page for a [ReaderMediaSource]'s tab body content when selected
/// as a source in the main menu.
class HistoryReaderPage extends BaseHistoryPage {
  /// Create an instance of this tab page.
  const HistoryReaderPage({
    super.key,
  });

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      HistoryReaderPageState();
}

/// A base class for providing all tabs in the main menu. In large part, this
/// was implemented to define shortcuts for common lengthy methods across UI
/// code.
class HistoryReaderPageState<T extends BaseHistoryPage>
    extends BaseHistoryPageState {
  /// This variable is true when the [buildPlaceholder] should be shown.
  /// For example, if a certain media type does not have any media items to
  /// show in its history.

  /// Each tab in the home page represents a media type.
  @override
  MediaType get mediaType => ReaderMediaType.instance;

  /// Get the active media source for the current media type.
  @override
  MediaSource get mediaSource =>
      appModel.getCurrentSourceForMediaType(mediaType: mediaType);

  @override
  bool get shouldPlaceholderBeShown =>
      appModel.getMediaTypeHistory(mediaType: mediaType).isEmpty;

  @override
  Widget build(BuildContext context) {
    List<MediaItem> items = appModel.getMediaTypeHistory(mediaType: mediaType);

    if (shouldPlaceholderBeShown) {
      return buildPlaceholder();
    } else {
      return buildHistory(items);
    }
  }

  static double _gridExtent(BuildContext context, BoxConstraints constraints) {
    return readerShelfGridExtentForLayout(
      mediaWidth: MediaQuery.sizeOf(context).width,
      contentWidth: constraints.maxWidth,
    );
  }

  /// This is shown as the body when [shouldPlaceholderBeShown] is false.
  @override
  Widget buildHistory(List<MediaItem> items) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return RawScrollbar(
      thumbVisibility: true,
      thickness: 3,
      controller: mediaType.scrollController,
      child: LayoutBuilder(
        builder: (context, constraints) => GridView.builder(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.page * 3,
            tokens.spacing.page,
            tokens.spacing.page,
          ),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _gridExtent(context, constraints),
            childAspectRatio: mediaSource.aspectRatio,
            mainAxisSpacing: tokens.spacing.gap + tokens.spacing.gap / 2,
            crossAxisSpacing: tokens.spacing.gap + tokens.spacing.gap / 2,
          ),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          controller: mediaType.scrollController,
          itemCount: items.length,
          itemBuilder: (context, index) => buildMediaItem(items[index]),
        ),
      ),
    );
  }

  /// Build the widget visually representing the [MediaItem]'s history tile.
  @override
  Widget buildMediaItemContent(MediaItem item) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Stack(
      alignment: Alignment.bottomLeft,
      fit: StackFit.expand,
      children: [
        AspectRatio(
          aspectRatio: mediaSource.aspectRatio,
          child: FadeInImage(
            imageErrorBuilder: (_, __, ___) => const SizedBox.shrink(),
            placeholder: MemoryImage(kTransparentImage),
            image: mediaSource.getDisplayThumbnailFromMediaItem(
              appModel: appModel,
              item: item,
            ),
            alignment: Alignment.topCenter,
            fit: BoxFit.fitHeight,
          ),
        ),
        LayoutBuilder(builder: (context, constraints) {
          return Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
            height: constraints.maxHeight * 0.25,
            width: double.maxFinite,
            color: theme.colorScheme.scrim.withValues(alpha: 0.6),
            child: Text(
              mediaSource.getDisplayTitleFromMediaItem(item),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
              softWrap: true,
              style: tokens.type.metadata.copyWith(
                color: theme.colorScheme.onInverseSurface,
              ),
            ),
          );
        }),
        LinearProgressIndicator(
          value: (item.position / item.duration).isNaN ||
                  (item.position / item.duration) == double.infinity ||
                  (item.position == 0 && item.duration == 0)
              ? 0
              : ((item.position / item.duration) > 0.97)
                  ? 1
                  : (item.position / item.duration),
          backgroundColor:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          color: theme.colorScheme.primary,
          minHeight: 2,
        ),
      ],
    );
  }
}
