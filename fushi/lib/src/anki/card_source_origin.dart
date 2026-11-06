/// 复习卡片的「出处」展示（分期 L3，docs/specs/2026-10-24-cross-media-links.md §4）：
/// 卡片来源链接（[CardSourceLink]）→ 图标 + 「第几集 · 时间 / 第几页」定位串，以及
/// 复习页顶栏「回到出处」按钮取链接的唯一入口。
///
/// 标题（书名 / 番名 / 歌名 / 游戏名）本身就是链接的锚文本（制卡时
/// `AnkiHandlebarRenderer.renderSourceLink` 写进卡面），这里只补锚文本里没有的定位。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show CardSourceKind, CardSourceLink;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

/// 出处种类的图标（与收藏夹来源图标同一组）。
IconData cardSourceKindIcon(CardSourceKind kind) => switch (kind) {
  CardSourceKind.book => FushiIcons.books,
  CardSourceKind.manga => FushiIcons.manga,
  CardSourceKind.video => FushiIcons.video,
  CardSourceKind.game => FushiIcons.games,
  CardSourceKind.music => FushiIcons.music,
};

/// 时间轴位置的显示：`m:ss`，满一小时 `h:mm:ss`。
String formatCardSourceClock(int ms) {
  final int total = (ms < 0 ? 0 : ms) ~/ 1000;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final String s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// 定位串（纯函数）。[playlistEpisodes] 是视频出处所在播放列表的集数——只有多集
/// 播放列表才标「第几集」（单视频的集下标恒 0，标「第 1 集」是错信息）；null =
/// 不知道，按单视频处理。书 / 游戏没有锚文本以外的定位，返回 null。
String? cardSourceLocatorLabel(CardSourceLink link, {int? playlistEpisodes}) {
  switch (link.kind) {
    case CardSourceKind.book:
    case CardSourceKind.game:
      return null;
    case CardSourceKind.manga:
      final int? page = link.pageIndex;
      return page == null ? null : t.card_source_origin_page(n: page + 1);
    case CardSourceKind.music:
      final int? start = link.startMs;
      return start == null ? null : formatCardSourceClock(start);
    case CardSourceKind.video:
      final int? episode = link.episodeIndex;
      final int? start = link.startMs;
      return <String>[
        if (episode != null && (playlistEpisodes ?? 0) >= 2)
          t.card_source_origin_episode(n: episode + 1),
        if (start != null) formatCardSourceClock(start),
      ].join(' · ').ifEmptyNull();
  }
}

/// [cardSourceLocatorLabel] 的查库版：视频出处按本机库里的播放列表定集数；本机没有
/// 该视频时按单视频处理（只给时间）。
Future<String?> resolveCardSourceLocatorLabel(
  FushiDatabase db,
  CardSourceLink link,
) async {
  if (link.kind != CardSourceKind.video) return cardSourceLocatorLabel(link);
  final VideoBookRow? row = await VideoBookRepository(
    db,
  ).getByBookUid(link.uid);
  return cardSourceLocatorLabel(
    link,
    playlistEpisodes: row == null
        ? null
        : playlistEpisodeCount(row.playlistJson),
  );
}

/// 一条笔记的出处链接：按字段顺序取第一个可解析的 `fushi://source` 链接（制卡只写
/// 一个，进 MiscInfo 一类的来源字段）。没有返回 null。
CardSourceLink? cardSourceLinkOfFields(Iterable<String> fieldValues) {
  for (final String html in fieldValues) {
    final CardSourceLink? link = CardSourceLink.fromHtml(html).firstOrNull;
    if (link != null) return link;
  }
  return null;
}

extension on String {
  String? ifEmptyNull() => isEmpty ? null : this;
}

/// 出处定位串（[resolveCardSourceLocatorLabel]，视频要查库定集数）。解析一次、
/// 链接不变不重查；无定位时不占位。
class CardSourceLocatorText extends StatefulWidget {
  const CardSourceLocatorText({
    super.key,
    required this.database,
    required this.link,
    this.style,
  });

  final FushiDatabase database;
  final CardSourceLink link;
  final TextStyle? style;

  @override
  State<CardSourceLocatorText> createState() => _CardSourceLocatorTextState();
}

class _CardSourceLocatorTextState extends State<CardSourceLocatorText> {
  late Future<String?> _label = _resolve();

  Future<String?> _resolve() =>
      resolveCardSourceLocatorLabel(widget.database, widget.link);

  @override
  void didUpdateWidget(CardSourceLocatorText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.toUri() != widget.link.toUri() ||
        !identical(oldWidget.database, widget.database)) {
      _label = _resolve();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _label,
    builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
      final String? label = snapshot.data;
      if (label == null || label.isEmpty) return const SizedBox.shrink();
      return Text(
        label,
        key: const ValueKey<String>('card-source-locator'),
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    },
  );
}
