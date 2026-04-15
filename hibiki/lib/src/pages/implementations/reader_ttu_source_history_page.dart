import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_assets_server/local_assets_server.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/utils.dart';

/// A page for [ReaderTtuSource]'s tab body content when selected as a source
/// in the main menu.
class ReaderTtuSourceHistoryPage extends HistoryReaderPage {
  /// Create an instance of this tab page.
  const ReaderTtuSourceHistoryPage({
    super.key,
  });

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      _ReaderTtuSourceHistoryPageState();
}

/// A base class for providing all tabs in the main menu. In large part, this
/// was implemented to define shortcuts for common lengthy methods across UI
/// code.
class _ReaderTtuSourceHistoryPageState<T extends HistoryReaderPage>
    extends HistoryReaderPageState {
  @override
  MediaType get mediaType => mediaSource.mediaType;

  @override
  ReaderTtuSource get mediaSource => ReaderTtuSource.instance;

  final ValueNotifier<int> _tryAgainCountdownNotifier = ValueNotifier(0);
  Timer? _timer;

  @override
  Widget build(BuildContext context) {
    AsyncValue<LocalAssetsServer> server =
        ref.watch(ttuServerProvider(appModel.targetLanguage));

    return server.when(
        data: buildData,
        loading: buildLoading,
        error: (error, stack) {
          if (_tryAgainCountdownNotifier.value == 0) {
            _tryAgainCountdownNotifier.value = 5;
          }

          if (error is SocketException) {
            _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
              _tryAgainCountdownNotifier.value -= 1;
              if (_tryAgainCountdownNotifier.value <= 0) {
                ref.invalidate(ttuServerProvider(appModel.targetLanguage));
                _timer?.cancel();
                _timer = null;
              }
            });

            return Center(
              child: ValueListenableBuilder<int>(
                valueListenable: _tryAgainCountdownNotifier,
                builder: (_, __, ___) => JidoujishoPlaceholderMessage(
                  icon: Icons.lan,
                  message: '${t.server_port_in_use}\n${t.retrying_in.seconds(
                    n: _tryAgainCountdownNotifier.value,
                  )}',
                ),
              ),
            );
          }

          return buildError(
            error: error,
            stack: stack,
            refresh: () {
              ref.invalidate(ttuServerProvider(appModel.targetLanguage));
            },
          );
        });
  }

  Widget buildData(LocalAssetsServer server) {
    AsyncValue<List<MediaItem>> books =
        ref.watch(ttuBooksProvider(appModel.targetLanguage));

    return books.when(
      data: buildBody,
      error: (error, stack) => buildError(
        error: error,
        stack: stack,
        refresh: () {
          ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
        },
      ),
      loading: buildLoading,
    );
  }

  Widget buildBody(List<MediaItem> books) {
    if (books.isEmpty) {
      return buildPlaceholder();
    } else {
      return buildHistory(books);
    }
  }

  /// This is shown as the body when [shouldPlaceholderBeShown] is true.
  @override
  Widget buildPlaceholder() {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: mediaSource.icon,
        message: t.ttu_no_books_added,
      ),
    );
  }

  /// 书架卡片，附加有声书角标。
  @override
  Widget buildMediaItemContent(MediaItem item) {
    final bool hasAudiobook = AudiobookRepository(appModel.database)
            .findByBookUid(item.uniqueKey) !=
        null;

    return Container(
      padding: Spacing.of(context).insets.all.normal,
      child: Stack(
        alignment: Alignment.bottomLeft,
        children: [
          ColoredBox(
            color: Colors.grey.shade800.withOpacity(0.3),
            child: AspectRatio(
              aspectRatio: mediaSource.aspectRatio,
              child: FadeInImage(
                key: UniqueKey(),
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
          ),
          LayoutBuilder(builder: (context, constraints) {
            return Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
              height: constraints.maxHeight * 0.25,
              width: double.maxFinite,
              color: Colors.black.withOpacity(0.6),
              child: Text(
                mediaSource.getDisplayTitleFromMediaItem(item),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
                textAlign: TextAlign.center,
                softWrap: true,
                style: textTheme.bodySmall!.copyWith(
                    color: Colors.white,
                    fontSize: textTheme.bodySmall!.fontSize! * 0.9),
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
            backgroundColor: Colors.white.withOpacity(0.6),
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
            minHeight: 2,
          ),
          if (hasAudiobook)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.headphones,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
