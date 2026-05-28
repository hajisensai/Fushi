import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for picking a source for a media type.
class MediaSourcePickerDialogPage extends BasePage {
  /// Create an instance of this page.
  const MediaSourcePickerDialogPage({
    required this.mediaType,
    super.key,
  });

  /// What media type is being picked for a source in the dialog.
  final MediaType mediaType;

  @override
  BasePageState createState() => _MediaSourcePickerDialogPageState();
}

class _MediaSourcePickerDialogPageState
    extends BasePageState<MediaSourcePickerDialogPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.change_source,
        leadingIcon: Icons.source_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: buildContent(),
      ),
    );
  }

  Widget buildContent() {
    List<MediaSource> mediaSources =
        appModel.mediaSources[widget.mediaType]!.values.toList();

    return SizedBox(
      width: double.maxFinite,
      child: buildSourceTiles(mediaSources),
    );
  }

  Widget buildSourceTiles(List<MediaSource> mediaSources) {
    return RawScrollbar(
      thumbVisibility: true,
      thickness: 3,
      controller: _scrollController,
      child: ListView.separated(
        controller: _scrollController,
        shrinkWrap: true,
        itemCount: mediaSources.length,
        separatorBuilder: (_, __) => const HibikiDivider(),
        itemBuilder: (context, index) => buildSourceTile(mediaSources[index]),
      ),
    );
  }

  Widget buildSourceTile(MediaSource mediaSource) {
    return KeyedSubtree(
      key: ValueKey(mediaSource.uniqueKey),
      child: HibikiListItem(
        leading: Icon(
          mediaSource.icon,
          color: theme.appBarTheme.foregroundColor,
        ),
        selected: mediaSource.uniqueKey ==
            appModel
                .getCurrentSourceForMediaType(mediaType: widget.mediaType)
                .uniqueKey,
        title: Text(mediaSource.getLocalisedSourceName(appModel)),
        subtitle: Text(mediaSource.getLocalisedDescription(appModel)),
        onTap: () {
          appModel.setCurrentSourceForMediaType(
            mediaType: widget.mediaType,
            mediaSource: mediaSource,
          );
          Navigator.pop(context);
        },
      ),
    );
  }
}
