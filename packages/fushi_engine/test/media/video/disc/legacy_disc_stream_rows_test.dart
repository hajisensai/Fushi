// BUG-5285：BUG-4245 修复前逐个入库的蓝光流文件行换成正规盘合集。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/disc/legacy_disc_stream_rows.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bluray/bluray_fixture.dart';

/// 在 [root] 下铺一张两条标题（各 1500 秒）的盘，片段 00010 / 00011。
void _writeDisc(String root) {
  for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
    Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
  }
  const int start = 45000 * 4;
  const int seconds = 1500;
  for (final (int i, String clip) in <String>['00010', '00011'].indexed) {
    File(
      p.join(root, 'BDMV', 'PLAYLIST', '0000${i + 1}.mpls'),
    ).writeAsBytesSync(
      buildMplsFixture(
        playItems: <FixturePlayItem>[
          FixturePlayItem(
            clipId: clip,
            inTimeTicks: start,
            outTimeTicks: start + 45000 * seconds,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: start),
        ],
      ),
    );
    File(p.join(root, 'BDMV', 'CLIPINF', '$clip.clpi')).writeAsBytesSync(
      buildClpiFixture(
        presentationStartTicks: start,
        presentationEndTicks: start + 45000 * seconds,
      ),
    );
    File(
      p.join(root, 'BDMV', 'STREAM', '$clip.m2ts'),
    ).writeAsBytesSync(Uint8List(4096));
  }
}

Future<void> _insertStreamRow(FushiDatabase db, String uid, String path) =>
    db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: p.basenameWithoutExtension(path),
        videoPath: path,
      ),
    );

void main() {
  late FushiDatabase db;
  late Directory temp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('fushi-legacy-stream-');
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('盘根推导：m2ts / ssif 认，mpls 与散装视频不认', () {
    final String root = p.join('D:', 'Show', 'DISC1');
    expect(
      blurayDiscRootForStreamFilePath(
        p.join(root, 'BDMV', 'STREAM', '00002.m2ts'),
      ),
      root,
    );
    expect(
      blurayDiscRootForStreamFilePath(
        p.join(root, 'BDMV', 'STREAM', 'SSIF', '00002.ssif'),
      ),
      root,
    );
    expect(
      blurayDiscRootForStreamFilePath(
        p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'),
      ),
      isNull,
    );
    expect(blurayDiscRootForStreamFilePath(p.join(root, 'ep01.m2ts')), isNull);
  });

  test('流文件行换成盘合集：用户清单改挂标题行，流文件行回收，重跑幂等', () async {
    final String root = p.join(temp.path, 'Show', 'DISC1');
    _writeDisc(root);
    await _insertStreamRow(
      db,
      'video/00010',
      p.join(root, 'BDMV', 'STREAM', '00010.m2ts'),
    );
    await _insertStreamRow(
      db,
      'video/00011',
      p.join(root, 'BDMV', 'STREAM', '00011.m2ts'),
    );
    await _insertStreamRow(db, 'video/other', p.join(temp.path, 'other.mkv'));
    final int playlist = await db.createMediaCollection(
      'My list',
      collectionType: 'playlist',
    );
    for (final String uid in <String>[
      'video/other',
      'video/00010',
      'video/00011',
    ]) {
      await db.addToCollection(playlist, MediaKind.video, uid);
    }

    final LegacyDiscStreamMigrationReport report =
        await migrateLegacyDiscStreamRows(db);
    expect(report.candidates, 2);
    expect(report.discs, 1);
    expect(report.reclaimed, 2);
    expect(report.membershipsCarried, 2);

    final List<VideoBookRow> rows = await db.allVideoBooks();
    final Set<String> paths = <String>{
      for (final VideoBookRow row in rows) row.videoPath,
    };
    expect(paths, <String>{
      p.join(temp.path, 'other.mkv'),
      p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'),
      p.join(root, 'BDMV', 'PLAYLIST', '00002.mpls'),
    });
    final Map<String, String> pathByUid = <String, String>{
      for (final VideoBookRow row in rows) row.bookUid: row.videoPath,
    };
    final List<String> members = <String>[
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        playlist,
      ))
        pathByUid[item.entryKey]!,
    ];
    expect(members, hasLength(3));
    expect(members, contains(p.join(temp.path, 'other.mkv')));
    expect(
      members.where((String path) => path.endsWith('.mpls')),
      hasLength(2),
    );
    // 盘合集 + 用户清单。
    expect(await db.getAllMediaCollections(), hasLength(2));

    final LegacyDiscStreamMigrationReport again =
        await migrateLegacyDiscStreamRows(db);
    expect(again.candidates, 0);
    expect(await db.allVideoBooks(), hasLength(3));
  });

  test('盘读不出（只剩流文件）：行原样留着，记进 unreadable', () async {
    final String root = p.join(temp.path, 'HALF');
    Directory(p.join(root, 'BDMV', 'STREAM')).createSync(recursive: true);
    final String path = p.join(root, 'BDMV', 'STREAM', '00000.m2ts');
    File(path).writeAsBytesSync(Uint8List(4096));
    await _insertStreamRow(db, 'video/00000', path);

    final LegacyDiscStreamMigrationReport report =
        await migrateLegacyDiscStreamRows(db);
    expect(report.candidates, 1);
    expect(report.reclaimed, 0);
    expect(report.unreadableRoots, <String>[root]);
    expect(await db.allVideoBooks(), hasLength(1));
  });
}
