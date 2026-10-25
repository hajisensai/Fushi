/// 「我库里的例句」点击 → 回到出处。复用作品图谱 L3「回到出处」的落地出口
/// （`mined_origin_navigation.dart` 的游戏 / 音乐出口、收藏夹同款的书锚点与视频起点解析），
/// 不另写一套：
/// - 书 → 阅读器开到那一章、按学习单位锚点（`charAnchor`）对齐那一句，临时浏览不覆盖
///   真实阅读进度；
/// - 视频 → 播放页从那条字幕起播（播放列表带集号）；
/// - 音乐 → 单曲队列开播并 seek 到那一行；
/// - 游戏 → 游戏详情页（台词没有可重放的「那一行」，与 L3 同一限制）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/mining/mined_origin_navigation.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show resolveVideoFavoriteOpenTarget;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart' show Bookmark, SentenceSourceKind;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

/// 语料来源 → 制卡来源（两个域各自的枚举；语料没有漫画 / 有声书 / 歌词模式）。
SentenceSourceKind sentenceSourceKindOfCorpus(CorpusSourceKind kind) =>
    switch (kind) {
      CorpusSourceKind.book => SentenceSourceKind.book,
      CorpusSourceKind.video => SentenceSourceKind.video,
      CorpusSourceKind.music => SentenceSourceKind.music,
      CorpusSourceKind.game => SentenceSourceKind.game,
    };

/// 语料来源所属的功能模块：模块被用户关掉时不显示该组、也不跳过去。
ModuleId moduleOfCorpusKind(CorpusSourceKind kind) => switch (kind) {
  CorpusSourceKind.book => ModuleId.books,
  CorpusSourceKind.video => ModuleId.video,
  CorpusSourceKind.music => ModuleId.music,
  CorpusSourceKind.game => ModuleId.games,
};

/// 打开一条例句的出处。找不到出处时给统一提示并返回 false。
Future<bool> openCorpusHitOrigin({
  required WidgetRef ref,
  required CorpusHit hit,
}) async {
  final AppModel app = ref.read(appProvider);
  final NavigatorState? navigator = app.navigatorKey.currentState;
  if (navigator == null || app.isMigrationReadonly) return false;
  if (!app.moduleVisibility.isEnabled(moduleOfCorpusKind(hit.kind))) {
    return false;
  }
  switch (hit.kind) {
    case CorpusSourceKind.book:
      return _openBookSentence(ref: ref, app: app, hit: hit);
    case CorpusSourceKind.video:
      return _openVideoSentence(app: app, navigator: navigator, hit: hit);
    case CorpusSourceKind.music:
      return playMusicOriginClip(
        app: app,
        trackUid: hit.key,
        positionMs: hit.pos,
      );
    case CorpusSourceKind.game:
      return openGameOrigin(
        navigator: navigator,
        db: app.database,
        gameId: hit.key,
      );
  }
}

Future<bool> _openBookSentence({
  required WidgetRef ref,
  required AppModel app,
  required CorpusHit hit,
}) async {
  final MediaItem? item = await ReaderFushiSource.instance.mediaItemForBookKey(
    hit.key,
  );
  if (item == null) {
    FushiToast.show(msg: t.card_source_review_media_missing);
    return false;
  }
  // 与收藏句 / 制卡历史跳回原文同一形态（collections_page `_openBook`，BUG-459 / 461）：
  // 章内学习单位锚点走 charAnchor，句长一并透传让整句对齐进可见区，preserveSavedPosition
  // 让这次临时浏览不覆盖用户真实阅读进度。
  final Bookmark bookmark = Bookmark(
    sectionIndex: hit.section,
    normCharOffset: 0,
    charAnchor: hit.pos,
    charAnchorLength: hit.len,
    preserveSavedPosition: true,
    label: '',
    createdAt: DateTime.now(),
  );
  unawaited(
    app.openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: app),
      item: item,
      initialBookmarkJump: bookmark,
      recordHistory: false,
      waitUntilClosed: false,
    ),
  );
  return true;
}

Future<bool> _openVideoSentence({
  required AppModel app,
  required NavigatorState navigator,
  required CorpusHit hit,
}) async {
  final VideoBookRepository repo = VideoBookRepository(app.database);
  final VideoBookRow? row = await repo.getByBookUid(hit.key);
  if (row == null) {
    FushiToast.show(msg: t.card_source_review_media_missing);
    return false;
  }
  final ({int? episodeIndex, int? startMs}) target =
      resolveVideoFavoriteOpenTarget(
        row: row,
        favoriteSectionIndex: hit.section,
        favoriteStartMs: hit.pos,
      );
  // 属于某 playlist 合集时带上主合集 id（BUG-1067：否则系列级音轨 / 字幕调轴记忆被跳过）。
  final Map<String, int> primaryByEntry = await app.database
      .getPrimaryCollectionIdByEntry();
  final int? playlistCollectionId =
      primaryByEntry[MediaKind.video.compositeKey(row.bookUid)];
  if (!navigator.mounted) return false;
  unawaited(
    navigator.push<void>(
      adaptivePageRoute<void>(
        context: navigator.context,
        builder: (_) => VideoFushiPage.neutralized(
          bookUid: row.bookUid,
          repo: repo,
          playlistCollectionId: playlistCollectionId,
          initialCueStartMs: target.startMs,
          initialEpisodeIndex: target.episodeIndex,
          initialSubtitleListVisible: true,
        ),
      ),
    ),
  );
  return true;
}
