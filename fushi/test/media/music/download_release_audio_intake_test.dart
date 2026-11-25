// 下载入库的发布里随附的 CD / OST 交给音乐库（用户库实况：视频来源没开自动扫描，下载的
// MyGO OST、孤独摇滚 BD 附带 CD 一直没进音乐库）。规划规则与来源扫描同一份，「视频库
// 认领的媒体目录」取库里该来源的视频行。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/download_release_audio_intake.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/music_audio_roots.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  final String root = p.join(p.rootPrefix(p.current), 'video');
  String at(List<String> parts) => p.joinAll(<String>[root, ...parts]);

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<MediaSourceRow> addVideoSource() async {
    final int id = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: normalizeSourceRootPath(root, transport: 'local'),
        createdAt: 1,
      ),
    );
    return (await db.getMediaSourceById(id))!;
  }

  Future<void> addVideo(String uid, String path, int sourceId) => db
      .into(db.videoBooks)
      .insert(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          videoPath: path,
          sourceId: Value<int?>(sourceId),
        ),
      );

  MusicAudioIntake intake(List<PlannedMusicRoot> log) => MusicAudioIntake(
    db,
    registerSource:
        ({
          required String rootPath,
          required bool recursive,
          required int ownerSourceId,
        }) async {
          log.add((rootPath: rootPath, recursive: recursive));
          return null;
        },
  );

  test('BD 原盘入库后，同发布的 CD 目录登记成音乐来源；原盘目录是往上爬的边界', () async {
    final MediaSourceRow source = await addVideoSource();
    // 原盘整盘搬进作品目录（扫描器的盘根 = BDMV 的上一级）；CD 留在原发布目录。
    await addVideo(
      'disc',
      at(<String>[
        'Bocchi [BDMV] (2022)',
        'VOL1',
        'BDMV',
        'PLAYLIST',
        '00001.mpls',
      ]),
      source.id,
    );
    await addVideo(
      'mygo',
      at(<String>[
        'MyGO',
        '[BDMV] 上巻',
        'BRMM_10774',
        'BDMV',
        'PLAYLIST',
        '1.mpls',
      ]),
      source.id,
    );
    final List<PlannedMusicRoot> log = <PlannedMusicRoot>[];
    await adoptDownloadedReleaseAudio(
      db: db,
      intake: intake(log),
      source: source,
      audioPaths: <String>[
        at(<String>['Bocchi', 'vol.1', 'CD', '01.flac']),
        at(<String>['Bocchi', 'vol.2', 'CD', '01.flac']),
        at(<String>['MyGO', '[BDMV] 上巻', 'OST', '01.flac']),
        at(<String>['gone', '01.flac']),
      ],
      fileExists: (String path) => !path.contains('gone'),
    );
    expect(log, <PlannedMusicRoot>[
      // 原发布目录里没有视频：爬到视频来源根下第一层，递归。
      (rootPath: at(<String>['Bocchi']), recursive: true),
      // OST 的上一级装着原盘：停在 OST。
      (rootPath: at(<String>['MyGO', '[BDMV] 上巻', 'OST']), recursive: true),
    ]);
  });

  test('磁盘上都不在 / 网络来源：什么也不做', () async {
    final MediaSourceRow source = await addVideoSource();
    final List<PlannedMusicRoot> log = <PlannedMusicRoot>[];
    final MusicAudioIntakeResult r = await adoptDownloadedReleaseAudio(
      db: db,
      intake: intake(log),
      source: source,
      audioPaths: <String>[
        at(<String>['A', '01.flac']),
      ],
      fileExists: (_) => false,
    );
    expect(r.registeredRoots, isEmpty);
    expect(log, isEmpty);
  });

  test('视频行路径 → 媒体目录：原盘取盘根，散装视频取所在目录', () {
    final p.Context win = p.Context(style: p.Style.windows);
    expect(
      videoMediaDirOfLibraryPath(
        r'D:\v\Show\VOL1\BDMV\STREAM\00000.m2ts',
        context: win,
      ),
      r'D:\v\Show\VOL1',
    );
    expect(
      videoMediaDirOfLibraryPath(r'D:\v\Show\Season 01\e01.mkv', context: win),
      r'D:\v\Show\Season 01',
    );
  });
}
