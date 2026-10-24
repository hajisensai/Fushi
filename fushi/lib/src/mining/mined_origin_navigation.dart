/// 「回到出处」（docs/specs/2026-10-24-cross-media-links.md §4，分期 L3）里书 / 视频
/// 以外三种出处的落地：漫画页、游戏、音乐片段。
///
/// 收藏夹的制卡历史行与复习卡片的来源链接（[CardSourceLink]）共用这三个出口，
/// 不各写一份：
/// - 漫画 → 漫画阅读器开到那一页（[MangaFushiSource.buildChapterLaunchPage]）；
/// - 游戏 → 游戏详情页（统计 tab 带会话历史）。台词本身只活在文本钩子的会话内存
///   里、游戏没在跑时没有可定位的「那一行」，所以只能做到打开游戏；
/// - 音乐 → 以该曲为单曲队列播放并 seek 到歌词行起点（播放原音频片段）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 出处在本机找不到时的统一提示（与卡片来源回看同一句）。
void _toastOriginMissing() {
  FushiToast.show(msg: t.card_source_review_media_missing);
}

/// 漫画出处：开到 [pageIndex]（null = 按保存位置恢复）。书已不在库 / 不是漫画时提示。
Future<bool> openMangaOriginAtPage({
  required WidgetRef ref,
  required String bookKey,
  required int? pageIndex,
}) async {
  final AppModel app = ref.read(appProvider);
  final MediaItem? item = await ReaderFushiSource.instance.mediaItemForBookKey(
    bookKey,
  );
  if (item == null ||
      item.mediaSourceIdentifier != MangaFushiSource.kUniqueKey) {
    _toastOriginMissing();
    return false;
  }
  await app.openMedia(
    ref: ref,
    mediaSource: item.getMediaSource(appModel: app),
    item: item,
    // 回到出处是临时浏览，不进「最近打开」流。
    recordHistory: false,
    waitUntilClosed: false,
    launchPageBuilder: () => MangaFushiSource.instance.buildChapterLaunchPage(
      item: item,
      initialPage: pageIndex,
    ),
  );
  return true;
}

/// 游戏出处：打开游戏详情页（[GalgameDetailPage]，统计 tab = 会话历史）。
Future<bool> openGameOrigin({
  required NavigatorState navigator,
  required FushiDatabase db,
  required String gameId,
}) async {
  final GalgameRow? game = await db.getGalgame(gameId);
  if (game == null) {
    _toastOriginMissing();
    return false;
  }
  if (!navigator.mounted) return false;
  unawaited(
    navigator.push<void>(
      adaptivePageRoute<void>(
        context: navigator.context,
        builder: (_) => GalgameDetailPage(gameId: gameId, initialTab: 0),
      ),
    ),
  );
  return true;
}

/// 音乐出处：以该曲为单曲队列开播，seek 到 [positionMs]（曲目时间轴，CUE 虚拟曲目
/// 也是曲内偏移）。曲目已不在库时提示。
Future<bool> playMusicOriginClip({
  required AppModel app,
  required String trackUid,
  required int positionMs,
}) async {
  final FushiDatabase db = app.database;
  final MusicTrackRow? track = await db.getMusicTrack(trackUid);
  if (track == null) {
    _toastOriginMissing();
    return false;
  }
  final String? albumUid = track.albumUid;
  final MusicAlbumRow? album = albumUid == null
      ? null
      : await db.getMusicAlbum(albumUid);
  final MusicPlayerEngine engine = app.musicSession.engine;
  final MusicPlayItem item = musicPlayItemOf(track, album: album);
  await engine.playQueue(<MusicPlayItem>[item]);
  await engine.seek(Duration(milliseconds: positionMs < 0 ? 0 : positionMs));
  return true;
}
