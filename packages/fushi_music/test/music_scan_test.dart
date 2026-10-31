import 'dart:io';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 经真原生库扫 native/fushi_music/tests/fixtures/library（与 Rust 侧 golden 同一份样本）。
/// 原生库是硬依赖：找不到库这里判红（FushiMusicUnavailableError），不 skip。
String _fixtureRoot() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory candidate = Directory(
      '${dir.path}/native/fushi_music/tests/fixtures/library',
    );
    if (candidate.existsSync()) return candidate.path;
    dir = dir.parent;
  }
  throw StateError('fixtures not found from ${Directory.current.path}');
}

String _rel(String root, String path) =>
    path.replaceAll('\\', '/').substring(root.replaceAll('\\', '/').length + 1);

void main() {
  late String root;
  setUpAll(() => root = _fixtureRoot());

  List<MusicScannedTrack> tracksOf(Iterable<MusicScanBatch> batches) =>
      <MusicScannedTrack>[
        for (final MusicScanBatch b in batches)
          ...b.records.whereType<MusicScannedTrack>(),
      ];

  test('同步会话：解码出与 Rust golden 一致的曲目集合', () {
    final MusicScanSession s = MusicScanSession.open(root);
    final List<MusicScanBatch> batches = <MusicScanBatch>[];
    try {
      while (true) {
        final MusicScanBatch b = s.next(maxRecords: 3);
        expect(b.records.length, lessThanOrEqualTo(3));
        batches.add(b);
        if (b.done) break;
      }
    } finally {
      s.close();
    }
    final List<MusicScannedTrack> tracks = tracksOf(batches);
    expect(
      batches
          .expand((MusicScanBatch b) => b.records)
          .whereType<MusicScanError>(),
      isEmpty,
    );
    expect(tracks.map((MusicScannedTrack t) => _rel(root, t.path)), <String>[
      'Album A/01 First Song.flac',
      'Album A/02 Second Song.mp3',
      'Cue Album/full.flac',
      'Cue Album/full.flac',
      'Cue Album/full.flac',
      'Embedded/image.flac',
      'Embedded/image.flac',
      'Formats/alac.m4a',
      'Formats/dsd.dsf',
      'Formats/tta.tta',
      'Formats/wavpack.wv',
    ]);

    final MusicScannedTrack first = tracks.first;
    expect(first.title, 'First Song');
    expect(first.codec, 'flac');
    expect(first.isLossless, isTrue);
    expect(first.bitDepth, 16);
    expect(first.rgTrackGain, -7.25);
    expect(first.rgAlbumGain, -6.5);
    expect(first.year, 2019);
    expect(first.folderCoverPath, isNotNull);
    expect(
      first.credits.map((MusicScanCredit c) => '${c.role}:${c.name}'),
      <String>['artist:Singer X', 'album_artist:Singer X', 'composer:Writer Y'],
    );
    expect(tracks[1].albumUid, first.albumUid, reason: '同专辑艺人 + 专辑名 = 同一张专辑');

    final List<MusicScannedTrack> cue = tracks.sublist(2, 5);
    expect(cue.map((MusicScannedTrack t) => t.title), <String>[
      '夜に駆ける',
      '二曲目',
      '三曲目',
    ], reason: 'Shift_JIS CUE 解码');
    expect(
      cue.map((MusicScannedTrack t) => (t.cueStartMs, t.cueEndMs)),
      <(int?, int?)>[(0, 1000), (1000, 2000), (2000, null)],
    );
    expect(cue[2].artistCredit, 'Guest');
    expect(cue[0].cueSheetPath, endsWith('full.cue'));

    expect(tracks[7].codec, 'alac');
    expect(tracks[8].codec, 'dsd');
    expect(tracks[8].sampleRate, 2822400);
    expect(tracks[10].codec, 'wavpack');
    expect(
      tracks.map((MusicScannedTrack t) => t.trackUid).toSet(),
      hasLength(tracks.length),
    );
  });

  test('已知且没变的文件只回 unchanged（CUE 整轨一条）', () {
    final MusicScanSession s = MusicScanSession.open(root);
    final List<MusicScannedTrack> first = <MusicScannedTrack>[];
    try {
      while (true) {
        final MusicScanBatch b = s.next();
        first.addAll(b.records.whereType<MusicScannedTrack>());
        if (b.done) break;
      }
    } finally {
      s.close();
    }
    final MusicScannedTrack cue = first.firstWhere(
      (MusicScannedTrack t) => t.cueStartMs != null && t.cueSheetPath != null,
    );
    final MusicScanSession again = MusicScanSession.open(
      root,
      known: <String, ({int mtimeMs, int size})>{
        cue.path: (mtimeMs: cue.fileMtimeMs, size: cue.fileSize),
      },
    );
    final List<MusicScanRecord> records = <MusicScanRecord>[];
    try {
      while (true) {
        final MusicScanBatch b = again.next();
        records.addAll(b.records);
        if (b.done) break;
      }
    } finally {
      again.close();
    }
    expect(
      records.whereType<MusicScanUnchanged>().map(
        (MusicScanUnchanged u) => u.path,
      ),
      <String>[cue.path],
    );
    expect(records.whereType<MusicScannedTrack>(), hasLength(first.length - 3));
  });

  test('后台 isolate 流与同步会话产出相同', () async {
    final List<MusicScanBatch> batches = await scanMusicRoot(
      root,
      maxRecords: 4,
    ).toList();
    expect(batches.last.done, isTrue);
    expect(tracksOf(batches), hasLength(11));
  });

  test('根不存在：流以 MusicScanRootError 结束', () async {
    await expectLater(
      scanMusicRoot('$root/no-such-dir').toList(),
      throwsA(isA<MusicScanRootError>()),
    );
    expect(
      () => MusicScanSession.open('$root/no-such-dir'),
      throwsA(isA<MusicScanRootError>()),
    );
  });

  test('没有内嵌封面的文件返回 null', () {
    expect(readMusicEmbeddedCover('$root/Album A/01 First Song.flac'), isNull);
  });

  test('批次解码拒收截断 / 版本不符的字节', () {
    expect(
      () => decodeMusicScanBatch(encodeMusicKnownFiles(const {})),
      throwsA(isA<MusicScanWireError>()),
    );
  });
}
