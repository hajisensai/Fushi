import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/metadata/music_scrape_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart';

/// 音乐控制通道测试共用的假件与种子数据（`ctl_music_routes_test` /
/// `op_undo_music_test`）。

/// 可编排的播放器：队列 / 下标 / 播放状态都是真状态，语义照 [MusicPlayerEngine]。
class FakeMusicPlayer implements MusicCtlPlayer {
  List<MusicPlayItem> _queue = <MusicPlayItem>[];
  int _index = 0;
  bool playing = false;
  MusicQueueContext? lastContext;
  bool? lastShuffle;

  @override
  List<MusicPlayItem> get queue => List<MusicPlayItem>.unmodifiable(_queue);

  @override
  MusicPlayItem? get current =>
      _index < _queue.length && _queue.isNotEmpty ? _queue[_index] : null;

  @override
  bool get isPlaying => playing;

  @override
  Duration get position => const Duration(seconds: 12);

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Future<void> playQueue(
    List<MusicPlayItem> items, {
    int startIndex = 0,
    MusicQueueContext context = MusicQueueContext.mixed,
    bool shuffle = false,
  }) async {
    if (items.isEmpty) return;
    _queue = List<MusicPlayItem>.of(items);
    _index = startIndex.clamp(0, items.length - 1);
    lastContext = context;
    lastShuffle = shuffle;
    playing = true;
  }

  @override
  Future<void> play() async {
    if (current != null) playing = true;
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> skipNext() async {
    if (_index + 1 >= _queue.length) return;
    _index++;
    playing = true;
  }

  @override
  Future<void> skipPrevious() async {
    if (_index == 0) return;
    _index--;
    playing = true;
  }

  @override
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    playing = true;
  }
}

/// 假识别：单曲直接写一行结论；整库按 [gate] 放行、逐首报进度、遵守取消。
class FakeMusicScraper {
  FakeMusicScraper(this.db);

  final FushiDatabase db;
  final List<({String uid, String? manual})> calls =
      <({String uid, String? manual})>[];
  Completer<void> gate = Completer<void>();
  int libraryRuns = 0;

  Future<MusicScrapeOutcome> scrapeTrack(
    String trackUid, {
    String? manualRecordingId,
  }) async {
    calls.add((uid: trackUid, manual: manualRecordingId));
    await db.writeMusicScrapeResult(
      meta: MusicScrapeMetaCompanion.insert(
        trackUid: trackUid,
        status: MusicScrapeStatus.matched,
        method: Value<String?>(
          manualRecordingId == null ? 'acoustid' : 'manual',
        ),
        mbRecordingId: Value<String?>(
          manualRecordingId ?? '11111111-1111-1111-1111-111111111111',
        ),
        scraperVersion: kMusicScraperVersion,
        scrapedAt: 1000 + calls.length,
      ),
    );
    return const MusicScrapeOutcome(status: MusicScrapeStatus.matched);
  }

  Future<MusicLibraryScrapeReport> scrapeLibrary({
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    libraryRuns++;
    final MusicLibraryScrapeReport report = MusicLibraryScrapeReport()
      ..total = 3;
    onProgress?.call(0, 3);
    await gate.future;
    for (int i = 0; i < 3; i++) {
      if (cancelled?.call() ?? false) break;
      report.matched++;
      onProgress?.call(i + 1, 3);
    }
    return report;
  }

  MusicCtlScraper get port =>
      MusicCtlScraper(scrapeTrack: scrapeTrack, scrapeLibrary: scrapeLibrary);
}

/// 曲库种子：两张专辑、四首歌、两位艺人、一个歌单、一首带候选的识别结论。
Future<void> seedMusicLibrary(FushiDatabase db) async {
  Future<void> album(String uid, String title, String artist) => db
      .into(db.musicAlbums)
      .insert(
        MusicAlbumsCompanion.insert(
          albumUid: uid,
          title: title,
          albumArtistCredit: Value<String?>(artist),
          addedAt: 1,
          updatedAt: 1,
        ),
      );
  Future<void> track(
    String uid,
    String title,
    String albumUid,
    int no,
    String artistUid,
    String artist,
  ) async {
    await db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: uid,
            path: '/music/$uid.flac',
            title: title,
            artistCredit: Value<String?>(artist),
            albumUid: Value<String?>(albumUid),
            trackNo: Value<int?>(no),
            durationMs: const Value<int?>(180000),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
    await db
        .into(db.musicTrackCredits)
        .insert(
          MusicTrackCreditsCompanion.insert(
            trackUid: uid,
            artistUid: artistUid,
            role: 'artist',
            creditName: artist,
          ),
        );
  }

  await db
      .into(db.musicArtists)
      .insert(
        MusicArtistsCompanion.insert(
          artistUid: 'ar-yoasobi',
          name: 'YOASOBI',
          addedAt: 1,
        ),
      );
  await db
      .into(db.musicArtists)
      .insert(
        MusicArtistsCompanion.insert(
          artistUid: 'ar-aimer',
          name: 'Aimer',
          addedAt: 1,
        ),
      );
  await album('al-1', 'THE BOOK', 'YOASOBI');
  await album('al-2', 'Walpurgis', 'Aimer');
  await track('t-2', 'あの夢をなぞって', 'al-1', 2, 'ar-yoasobi', 'YOASOBI');
  await track('t-1', '夜に駆ける', 'al-1', 1, 'ar-yoasobi', 'YOASOBI');
  await track('t-3', '残響散歌', 'al-2', 1, 'ar-aimer', 'Aimer');
  await track('t-4', 'Walpurgis', 'al-2', 2, 'ar-aimer', 'Aimer');
  await db
      .into(db.musicPlaylists)
      .insert(
        MusicPlaylistsCompanion.insert(
          playlistUid: 'pl-1',
          name: 'Drive',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await db.writeMusicScrapeResult(
    meta: MusicScrapeMetaCompanion.insert(
      trackUid: 't-3',
      status: MusicScrapeStatus.unmatched,
      candidatesJson: const Value<String?>(
        '[{"id":"22222222-2222-2222-2222-222222222222","title":"残響散歌",'
        '"artist":"Aimer","release":"残響散歌","date":"2022"}]',
      ),
      scraperVersion: kMusicScraperVersion,
      scrapedAt: 500,
    ),
  );
}
