import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

MusicScannedTrack _track(
  String uid, {
  String path = '/m/a.flac',
  String? album = 'Album',
  String? albumUid = 'al',
  String? cover,
  bool embedded = false,
  int? start,
}) => MusicScannedTrack(
  path: path,
  trackUid: uid,
  cueStartMs: start,
  cueEndMs: null,
  durationMs: 1000,
  codec: 'flac',
  sampleRate: 96000,
  bitDepth: 24,
  channels: 2,
  bitrateKbps: 3000,
  isLossless: true,
  title: 'title-$uid',
  titleSort: null,
  artistCredit: 'X',
  albumTitle: album,
  albumTitleSort: null,
  albumArtist: 'X',
  albumUid: albumUid,
  discNo: 1,
  discTotal: 1,
  trackNo: 1,
  year: 2020,
  releaseDate: '2020',
  genre: null,
  catalogNo: null,
  rgTrackGain: -6,
  rgTrackPeak: 0.9,
  rgAlbumGain: -5,
  rgAlbumPeak: 0.95,
  mbRecordingId: null,
  mbWorkId: null,
  mbReleaseId: null,
  mbReleaseGroupId: null,
  fileMtimeMs: 10,
  fileSize: 20,
  hasEmbeddedCover: embedded,
  folderCoverPath: cover,
  cueSheetPath: null,
  credits: const <MusicScanCredit>[
    MusicScanCredit(role: 'artist', name: 'X', artistUid: 'ax'),
    MusicScanCredit(role: 'album_artist', name: 'X', artistUid: 'ax'),
  ],
);

/// 按顺序把预设批次喂给扫描器，并记下扫描器传来的已知文件清单。
class _ScriptedScanner {
  _ScriptedScanner(this.batches);

  final List<List<MusicScanRecord>> batches;
  Map<String, ({int mtimeMs, int size})>? lastKnown;

  Stream<MusicScanBatch> call(
    String root, {
    bool recursive = true,
    Map<String, ({int mtimeMs, int size})> known =
        const <String, ({int mtimeMs, int size})>{},
  }) async* {
    lastKnown = known;
    for (int i = 0; i < batches.length; i++) {
      yield MusicScanBatch(done: i == batches.length - 1, records: batches[i]);
    }
  }
}

String _fixtureRoot() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory c = Directory(
      '${dir.path}/native/fushi_music/tests/fixtures/library',
    );
    if (c.existsSync()) return c.path;
    dir = dir.parent;
  }
  throw StateError('fixtures not found');
}

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('批次换算：同专辑封面取第一个有的；没封面不写封面列', () {
    final MusicScanBatchWrite w = musicScanBatchWriteOf(
      <MusicScannedTrack>[
        _track('t1'),
        _track('t2', cover: '/m/cover.jpg', embedded: true),
        _track('t3'),
      ],
      sourceId: 1,
      now: 5,
    );
    expect(w.tracks, hasLength(3));
    expect(w.albums, hasLength(1));
    expect(w.albums.single.coverPath.value, '/m/cover.jpg');
    expect(w.albums.single.coverTrackUid.value, 't2');
    expect(w.artists, hasLength(1));
    expect(w.credits, hasLength(6));
    final MusicScanBatchWrite none = musicScanBatchWriteOf(
      <MusicScannedTrack>[_track('t9')],
      sourceId: 1,
      now: 5,
    );
    expect(none.albums.single.coverPath.present, isFalse);
  });

  test('重扫：没变的文件经 unchanged 保留（含 CUE 多首），消失的软删', () async {
    final _ScriptedScanner first = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        _track('a1', path: '/m/a.flac'),
        _track('c1', path: '/m/cue.flac', start: 0),
      ],
      <MusicScanRecord>[
        _track('c2', path: '/m/cue.flac', start: 1000),
        _track('gone', path: '/m/gone.flac'),
      ],
    ]);
    final MusicScanSummary s1 = await MusicLibraryScanner(
      db,
      scanner: first.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(s1.trackCount, 4);
    expect(s1.parsedTrackCount, 4);
    expect(first.lastKnown, isEmpty);

    final _ScriptedScanner second = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        const MusicScanUnchanged('/m/a.flac'),
        const MusicScanUnchanged('/m/cue.flac'),
        const MusicScanError('/m/bad.ape', 'corrupt'),
      ],
    ]);
    final MusicScanSummary s2 = await MusicLibraryScanner(
      db,
      scanner: second.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(second.lastKnown?.keys.toSet(), <String>{
      '/m/a.flac',
      '/m/cue.flac',
      '/m/gone.flac',
    });
    expect(second.lastKnown?['/m/a.flac'], (mtimeMs: 10, size: 20));
    expect(s2.trackCount, 3);
    expect(s2.removedTrackCount, 1);
    expect(s2.errorSummary, contains('/m/bad.ape'));
    expect(
      (await db.listMusicTracks()).map((MusicTrackRow t) => t.trackUid).toSet(),
      <String>{'a1', 'c1', 'c2'},
    );
  });

  test('真原生库扫样本库入库：CUE 拆轨 + 专辑聚合（硬依赖，缺库判红）', () async {
    final MusicScanSummary s = await MusicLibraryScanner(
      db,
    ).scanSource(sourceId: 7, rootPath: _fixtureRoot());
    expect(s.errors, isEmpty);
    expect(s.trackCount, 11);
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    final MusicAlbumRow cueAlbum = snap.albums.firstWhere(
      (MusicAlbumRow a) => a.title == 'キュー盤',
    );
    final List<MusicTrackRow> cue = snap.tracksOfAlbum(cueAlbum.albumUid);
    expect(cue.map((MusicTrackRow t) => t.title), <String>[
      '夜に駆ける',
      '二曲目',
      '三曲目',
    ]);
    expect(cue.map((MusicTrackRow t) => t.cueStartMs), <int?>[0, 1000, 2000]);
    final MusicAlbumRow albumA = snap.albums.firstWhere(
      (MusicAlbumRow a) => a.title == 'Album A',
    );
    expect(albumA.coverPath, endsWith('cover.png'));
    expect(snap.tracksOfAlbum(albumA.albumUid), hasLength(2));

    // 第二遍：文件都没动 → 全部走 unchanged，一首都不重解析，也不软删。
    final MusicScanSummary again = await MusicLibraryScanner(
      db,
    ).scanSource(sourceId: 7, rootPath: _fixtureRoot());
    expect(again.parsedTrackCount, 0);
    expect(again.removedTrackCount, 0);
    expect(again.trackCount, 11);
  });

  test('格式徽章', () {
    expect(
      musicFormatBadge(
        codec: 'flac',
        isLossless: true,
        sampleRate: 96000,
        bitDepth: 24,
      ),
      'FLAC 24/96',
    );
    expect(
      musicFormatBadge(
        codec: 'flac',
        isLossless: true,
        sampleRate: 44100,
        bitDepth: 16,
      ),
      'FLAC 16/44.1',
    );
    expect(
      musicFormatBadge(codec: 'dsd', isLossless: true, sampleRate: 2822400),
      'DSD64',
    );
    expect(
      musicFormatBadge(codec: 'mp3', isLossless: false, bitrateKbps: 320),
      'MP3 320k',
    );
    expect(
      musicIsHiRes(
        codec: 'flac',
        isLossless: true,
        sampleRate: 48000,
        bitDepth: 24,
      ),
      isTrue,
    );
    expect(
      musicIsHiRes(
        codec: 'flac',
        isLossless: true,
        sampleRate: 44100,
        bitDepth: 16,
      ),
      isFalse,
    );
    expect(
      musicIsHiRes(codec: 'aac', isLossless: false, sampleRate: 96000),
      isFalse,
    );
  });
}
