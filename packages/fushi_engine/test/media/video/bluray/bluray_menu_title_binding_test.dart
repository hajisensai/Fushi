// BUG-5312：原盘菜单「ALL PLAY」播的是被扫描按集切开的整条播放列表（`00001`）。
// 它不能再给整条播放列表建一行（合集里凭空多出一集「<盘名> - 00001」），进度要按
// 播放头落到对应那一集、记在那一集自己的时间轴上。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/disc/disc_library_import.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bluray_episode_fixture.dart';

void main() {
  late FushiDatabase db;
  late Directory temp;
  late String disc;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('fushi-bd-menu-bind-');
    disc = p.join(temp.path, 'BOCCHI [BDMV]', 'Disc 1');
    // 两集：1442 秒 + 1422 秒（各一个整段用满的 m2ts）。
    writeEpisodicDisc(disc, episodes: 2, discName: 'BOCCHI THE ROCK! 1');
    await DiscLibraryImporter(db).importBlurayDiscs(
      <String>[disc],
      sourceId: null,
      restoreDissolvedGroups: false,
    );
  });

  tearDown(() async {
    await db.close();
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄占用；临时目录留给系统清。
    }
  });

  String mpls(String id) => p.join(disc, 'BDMV', 'PLAYLIST', '$id.mpls');

  test('菜单进入按集切开的播放列表：不建整卷行，绑到各集', () async {
    final List<String> before = <String>[
      for (final VideoBookRow row in await VideoBookRepository(db).listAll())
        row.bookUid,
    ];
    final BlurayMenuTitleBinding binding =
        (await ensureBlurayMenuTitleInLibrary(db, mpls('00001')))!;

    expect(binding.row, isNull);
    expect(
      binding.episodes.map((BlurayMenuEpisode e) => e.row.videoPath),
      <String>[episodePath(disc, 1), episodePath(disc, 2)],
    );
    expect(
      binding.episodes.map((BlurayMenuEpisode e) => (e.startMs, e.endMs)),
      <(int, int)>[(0, 1442000), (1442000, 2864000)],
    );
    final List<VideoBookRow> after = await VideoBookRepository(db).listAll();
    expect(after.map((VideoBookRow r) => r.bookUid).toSet(), before.toSet());
    expect(
      after.where((VideoBookRow r) => p.equals(r.videoPath, mpls('00001'))),
      isEmpty,
    );
  });

  test('播放列表时间轴上的位置记到播放头所在那一集、按该集自己的时间轴', () async {
    final BlurayMenuTitleBinding binding =
        (await ensureBlurayMenuTitleInLibrary(db, mpls('00001')))!;
    final String ep1 = binding.episodes[0].row.bookUid;
    final String ep2 = binding.episodes[1].row.bookUid;

    ({String uid, int ms}) at(int playlistMs) {
      final ({BlurayMenuEpisode episode, int positionMs}) progress = binding
          .progressAt(playlistMs)!;
      return (uid: progress.episode.row.bookUid, ms: progress.positionMs);
    }

    expect(at(0), (uid: ep1, ms: 0));
    expect(at(1453000), (uid: ep2, ms: 11000));
    // 反馈里那条整卷行上的 24:13 落在第 1 集里。
    expect(at(1453000 - 22000), (uid: ep1, ms: 1431000));
    // 越过末集终点（片尾空白）仍记末集，夹在集长内。
    expect(at(9999999), (uid: ep2, ms: 1422000));
    expect(binding.hasEpisode(ep2), isTrue);
    expect(binding.hasEpisode('other'), isFalse);
  });

  test('没被切开的播放列表（特典）照旧是单条标题', () async {
    final BlurayMenuTitleBinding binding =
        (await ensureBlurayMenuTitleInLibrary(db, mpls('00002')))!;
    expect(binding.episodes, isEmpty);
    expect(binding.row!.videoPath, mpls('00002'));
    expect(binding.progressAt(5000), isNull);
  });
}
