import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 经真原生库：`ffm_playlist_parse` 与本地扫描里的播放列表记录（kind 4）。原生库是硬依赖：
/// 找不到库这里判红（FushiMusicUnavailableError），不 skip。
String _fixtureAlbum() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory candidate = Directory(
      '${dir.path}/native/fushi_music/tests/fixtures/library/Album A',
    );
    if (candidate.existsSync()) return candidate.path;
    dir = dir.parent;
  }
  throw StateError('fixtures not found from ${Directory.current.path}');
}

String _sep(String p) => p.replaceAll('/', Platform.pathSeparator);

void main() {
  test('parseMusicPlaylistFile：列表名、相对条目按目录拼、网络地址原样', () {
    final String base = Platform.isWindows ? r'D:\Music\Lists' : '/music/Lists';
    final MusicPlaylistFile f = parseMusicPlaylistFile(
      Uint8List.fromList(
        utf8.encode(
          '#EXTM3U\n#PLAYLIST:Drive\n#EXTINF:12,A - B\n../Album/x.flac\n'
          'https://example.com/s.mp3\n',
        ),
      ),
      baseDir: base,
    );
    expect(f.name, 'Drive');
    expect(f.entries, <String>[
      Platform.isWindows ? r'D:\Music\Album\x.flac' : '/music/Album/x.flac',
      'https://example.com/s.mp3',
    ]);
  });

  test('parseMusicPlaylistFile：不给目录时相对条目原样交回', () {
    final MusicPlaylistFile f = parseMusicPlaylistFile(
      Uint8List.fromList(utf8.encode('sub/a.mp3\n')),
    );
    expect(f.name, isNull);
    expect(f.entries, <String>[_sep('sub/a.mp3')]);
  });

  test('本地扫描：目录里的 .m3u8 出一条 MusicScanPlaylist，条目与曲目同一拼法', () {
    final Directory tmp = Directory.systemTemp.createTempSync('fushi_pl_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Directory album = Directory('${tmp.path}/Album A')..createSync();
    for (final String name in <String>[
      '01 First Song.flac',
      '02 Second Song.mp3',
    ]) {
      File('${_fixtureAlbum()}/$name').copySync('${album.path}/$name');
    }
    Directory('${tmp.path}/Lists').createSync();
    File('${tmp.path}/Lists/mix.m3u8').writeAsStringSync(
      '#EXTM3U\n../Album A/02 Second Song.mp3\n../Album A/01 First Song.flac\n',
    );

    final MusicScanSession s = MusicScanSession.open(tmp.path);
    final List<MusicScanRecord> records = <MusicScanRecord>[];
    try {
      while (true) {
        final MusicScanBatch b = s.next();
        records.addAll(b.records);
        if (b.done) break;
      }
    } finally {
      s.close();
    }
    final Set<String> trackPaths = records
        .whereType<MusicScannedTrack>()
        .map((MusicScannedTrack t) => t.path)
        .toSet();
    final List<MusicScanPlaylist> lists = records
        .whereType<MusicScanPlaylist>()
        .toList();
    expect(lists, hasLength(1));
    expect(lists.single.path, endsWith('mix.m3u8'));
    expect(lists.single.mtimeMs, greaterThan(0));
    expect(lists.single.playlist.entries, hasLength(2));
    expect(lists.single.playlist.entries.first, endsWith('02 Second Song.mp3'));
    expect(trackPaths.containsAll(lists.single.playlist.entries), isTrue);
  });
}
