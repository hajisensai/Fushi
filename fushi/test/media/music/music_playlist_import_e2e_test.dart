import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi/src/media/music/music_local_playlists.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

/// 端到端：真原生扫描（Rust 认出 .m3u/.m3u8、解析、拼路径）→ 曲目落库 → 播放列表导入。
/// 样本音频取 native/fushi_music/tests/fixtures/library（原生库是硬依赖，找不到判红）。
String _fixtures() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory c = Directory(
      p.join(dir.path, 'native', 'fushi_music', 'tests', 'fixtures', 'library'),
    );
    if (c.existsSync()) return c.path;
    dir = dir.parent;
  }
  throw StateError('fixtures not found');
}

void main() {
  late FushiDatabase db;
  late Directory root;
  late String music;
  late String lists;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    root = Directory.systemTemp.createTempSync('fushi_pl_e2e_');
    music = p.join(root.path, 'Music');
    lists = p.join(music, 'Lists');
    final String fx = _fixtures();
    final String albumA = p.join(music, 'Album A');
    final String cue = p.join(music, 'Cue Album');
    for (final String d in <String>[albumA, cue, lists]) {
      Directory(d).createSync(recursive: true);
    }
    for (final String f in <String>[
      '01 First Song.flac',
      '02 Second Song.mp3',
    ]) {
      File(p.join(fx, 'Album A', f)).copySync(p.join(albumA, f));
    }
    // 日文文件名（Shift_JIS 列表要对上它）。
    File(
      p.join(fx, 'Album A', '01 First Song.flac'),
    ).copySync(p.join(albumA, '曲.flac'));
    for (final String f in <String>['full.cue', 'full.flac']) {
      File(p.join(fx, 'Cue Album', f)).copySync(p.join(cue, f));
    }

    // 1) 扩展 M3U8：相对路径、网络地址、不存在的文件、CUE 整轨文件。
    File(p.join(lists, 'mix.m3u8')).writeAsStringSync(
      '#EXTM3U\n#PLAYLIST:Night Mix\n'
      '#EXTINF:3,X - Second\n../Album A/02 Second Song.mp3\n'
      'https://example.com/stream.mp3\n'
      '../Album A/missing.flac\n'
      '../Cue Album/full.flac\n'
      '../Album A/01 First Song.flac\n',
    );
    // 2) 老式 Shift_JIS .m3u、反斜杠分隔。
    File(p.join(lists, 'legacy.m3u')).writeAsBytesSync(<int>[
      ...ascii.encode(r'..\Album A\'),
      0x8B, 0xC8, // 曲
      ...ascii.encode('.flac\r\n'),
    ]);
    // 3) 别的电脑写的绝对路径（只能按尾段对上）。
    File(p.join(lists, 'foreign.m3u8')).writeAsStringSync(
      r'D:\OldPC\Music\Album A\02 Second Song.mp3'
      '\n'
      '/home/someone/Music/Album A/01 First Song.flac\n',
    );
    // 4) 一条都对不上：不建歌单。
    File(p.join(lists, 'empty.m3u8')).writeAsStringSync('/nowhere/x.mp3\n');
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<MusicScanSummary> scan() => MusicLibraryScanner(
    db,
    discRegistrar: (String root, {bool recursive = true}) async =>
        <String, String>{},
  ).scanSource(sourceId: 1, rootPath: music);

  Future<Map<String, List<String>>> playlistTitles() async {
    final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
      for (final MusicTrackRow t in await db.listMusicTracks()) t.trackUid: t,
    };
    return <String, List<String>>{
      for (final MusicPlaylistRow pl in await db.listMusicPlaylists())
        pl.name: <String>[
          for (final MusicPlaylistEntryRow e
              in await db.listMusicPlaylistEntries(pl.playlistUid))
            p.basename(byUid[e.trackUid]!.path) +
                (byUid[e.trackUid]!.cueStartMs == null
                    ? ''
                    : '@${byUid[e.trackUid]!.cueStartMs}'),
        ],
    };
  }

  test('扫描自动导入：相对 / Shift_JIS / 外机绝对路径都对上，CUE 展开；重扫与删除后不重复', () async {
    final MusicScanSummary s1 = await scan();
    expect(s1.errors, isEmpty);
    expect(s1.importedPlaylistCount, 3);
    final Map<String, List<String>> lists1 = await playlistTitles();
    expect(lists1.keys.toSet(), <String>{'Night Mix', 'legacy', 'foreign'});
    expect(lists1['Night Mix'], <String>[
      '02 Second Song.mp3',
      'full.flac@0',
      'full.flac@1000',
      'full.flac@2000',
      '01 First Song.flac',
    ]);
    expect(lists1['legacy'], <String>['曲.flac']);
    expect(lists1['foreign'], <String>[
      '02 Second Song.mp3',
      '01 First Song.flac',
    ]);

    // 重扫：不重复导入。
    final MusicScanSummary s2 = await scan();
    expect(s2.importedPlaylistCount, 0);
    expect(await db.listMusicPlaylists(), hasLength(3));

    // 用户删掉一份、在 Fushi 里改了另一份：重扫既不导回、也不覆盖。
    final List<MusicPlaylistRow> rows = await db.listMusicPlaylists();
    final MusicPlaylistRow mix = rows.firstWhere(
      (MusicPlaylistRow r) => r.name == 'Night Mix',
    );
    final MusicPlaylistRow legacy = rows.firstWhere(
      (MusicPlaylistRow r) => r.name == 'legacy',
    );
    await db.softDeleteMusicPlaylist(mix.playlistUid, now: 5);
    await db.renameMusicPlaylist(legacy.playlistUid, 'Mine now', now: 5);
    File(
      p.join(lists, 'legacy.m3u'),
    ).writeAsStringSync('../Album A/02 Second Song.mp3\n');
    final MusicScanSummary s3 = await scan();
    expect(s3.importedPlaylistCount, 0);
    final Map<String, List<String>> lists3 = await playlistTitles();
    expect(lists3.keys.toSet(), <String>{'Mine now', 'foreign'});
    expect(lists3['Mine now'], <String>['曲.flac']);
  });

  test('手动导入（曲库外的文件，经 ffm_playlist_parse）', () async {
    await scan();
    final Directory outside = Directory(p.join(root.path, 'Downloads'))
      ..createSync();
    final String file = p.join(outside.path, 'Shared list.m3u8');
    File(file).writeAsStringSync(
      '#EXTM3U\n'
      '${p.join(music, 'Album A', '01 First Song.flac')}\n'
      '../Music/Album A/02 Second Song.mp3\n',
    );
    final MusicPlaylistFile parsed = parseMusicPlaylistFile(
      File(file).readAsBytesSync(),
      baseDir: p.dirname(file),
    );
    final r = await importMusicPlaylistFile(
      db,
      path: file,
      file: parsed,
      now: 1,
      forceNewCopy: true,
    );
    expect(r.outcome, MusicPlaylistImportOutcome.imported);
    expect(r.matched, 2);
    expect((await db.getMusicPlaylist(r.playlistUid))!.name, 'Shared list');
    final r2 = await importMusicPlaylistFile(
      db,
      path: file,
      file: parsed,
      now: 2,
      forceNewCopy: true,
    );
    expect(r2.outcome, MusicPlaylistImportOutcome.alreadyImported);
  });
}
