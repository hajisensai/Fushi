// 视频库「整理文件名」（反馈 ZDYNkAP3Ln）：库里是刮削后的新名、磁盘仍是旧名时，
// 按刮削资料把文件（及跟着它走的 sidecar）改成规范名；在做种的文件走引擎改名
// 保住做种；库里按路径关联的列跟着改；失败整条回滚；可撤销。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';
import 'package:fushi_engine/media/video/video_path_migration.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 内置引擎替身：一个种子，save_path 就是本机目录；改名真的改磁盘（与
/// libtorrent `rename_file` 一样由引擎动文件）。
class _FakeBackend implements TorrentBackend {
  _FakeBackend({
    required this.savePath,
    required this.files,
    this.failListing = false,
    this.refuseIndex,
  });

  final String savePath;
  final List<TorrentFileEntry> files;
  final bool failListing;
  final int? refuseIndex;
  final List<String> renameCalls = <String>[];

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async {
    if (failListing) throw const SocketException('backend offline');
    return <TorrentSnapshot>[
      TorrentSnapshot(
        hash: 'abc123',
        name: 'Bocchi',
        progress: 1,
        state: 'uploading',
        savePath: savePath,
        contentPath: savePath,
        amountLeft: 0,
      ),
    ];
  }

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async => files;

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    renameCalls.add('$torrentId#$fileIndex->$newPath');
    if (fileIndex == refuseIndex) {
      return const TorrentStorageResult(ok: false, error: 'engine refused');
    }
    final TorrentFileEntry file = files.firstWhere(
      (TorrentFileEntry f) => f.index == fileIndex,
    );
    File(
      p.joinAll(<String>[savePath, ...p.posix.split(file.name)]),
    ).renameSync(p.joinAll(<String>[savePath, ...p.posix.split(newPath)]));
    files[files.indexOf(file)] = TorrentFileEntry(
      name: newPath,
      size: file.size,
      progress: file.progress,
      index: file.index,
    );
    return TorrentStorageResult(ok: true, path: newPath);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('规范名与 sidecar 认领（纯函数）', () {
    test('电影：标题 (年份)；Windows 非法字符换全角替身而不是 _', () {
      expect(
        canonicalVideoFileStem(
          const VideoFilenameIdentity(title: 'ぼっち・ざ・ろっく！ Re:', year: 2024),
        ),
        'ぼっち・ざ・ろっく！ Re： (2024)',
      );
      expect(fullwidthSafeFileName('a/b\\c*d?"<>|'), 'a／b＼c＊d？＂＜＞｜');
      expect(fullwidthSafeFileName('Title. '), 'Title');
      expect(fullwidthSafeFileName('CON'), '_CON');
      expect(
        canonicalVideoFileStem(const VideoFilenameIdentity(title: ' :: ')),
        '：：',
      );
      expect(
        canonicalVideoFileStem(const VideoFilenameIdentity(title: '\u0001')),
        isNull,
      );
    });

    test('剧集：标题 (年份) - S01E02；一文件多集写成区间', () {
      expect(
        canonicalVideoFileStem(
          const VideoFilenameIdentity(
            title: 'Show',
            year: 2020,
            seasonNumber: 1,
            episodeNumbers: <int>[2],
          ),
        ),
        'Show (2020) - S01E02',
      );
      expect(
        canonicalVideoFileStem(
          const VideoFilenameIdentity(
            title: 'Show',
            seasonNumber: 0,
            episodeNumbers: <int>[2, 1],
          ),
        ),
        'Show - S00E01-E02',
      );
    });

    test('sidecar：字幕 + nfo + 缩略图跟着走，邻居 ep01.5 的字幕不带走', () {
      final List<String> names = <String>[
        'ep01.mkv',
        'ep01.ja.srt',
        'ep01.ass',
        'ep01.nfo',
        'ep01-poster.jpg',
        'ep01.jpg',
        'ep01.5.mkv',
        'ep01.5.srt',
        'ep01 notes.txt',
      ];
      expect(
        videoFollowingSidecars(videoFileName: 'ep01.mkv', dirFileNames: names),
        unorderedEquals(<String>[
          'ep01.ja.srt',
          'ep01.ass',
          'ep01.nfo',
          'ep01-poster.jpg',
          'ep01.jpg',
        ]),
      );
    });

    test('目标被别的文件占着 → conflict，整条不动；已是规范名 → unchanged', () {
      final String dir = p.join(Directory.systemTemp.path, 'x');
      expect(
        planVideoFilenameMoves(
          videoPath: p.join(dir, 'old.mkv'),
          targetStem: 'New',
          dirFileNames: <String>['old.mkv', 'old.srt', 'New.srt'],
        ).status,
        VideoFilenamePlanStatus.conflict,
      );
      expect(
        planVideoFilenameMoves(
          videoPath: p.join(dir, 'New.mkv'),
          targetStem: 'New',
          dirFileNames: <String>['New.mkv'],
        ).status,
        VideoFilenamePlanStatus.unchanged,
      );
      final VideoFilenameItemDraft ready = planVideoFilenameMoves(
        videoPath: p.join(dir, 'old.mkv'),
        targetStem: 'New',
        dirFileNames: <String>['old.mkv', 'old.zh.ass'],
      );
      expect(ready.status, VideoFilenamePlanStatus.ready);
      expect(ready.moves.map((VideoFileMove m) => p.basename(m.to)), <String>[
        'New.mkv',
        'New.zh.ass',
      ]);
      expect(
        planVideoFilenameMoves(
          videoPath: p.join(dir, 'old.mkv'),
          targetStem: 'New',
          dirFileNames: <String>['old.mkv'],
          claimedTargets: <String>{platformPathKey(p.join(dir, 'New.mkv'))},
        ).status,
        VideoFilenamePlanStatus.conflict,
      );
    });

    test('playlistJson 只换命中集的 path，各集进度原样保留', () {
      final String a = p.join(Directory.systemTemp.path, 'a.mkv');
      final String b = p.join(Directory.systemTemp.path, 'b.mkv');
      final String next = remapPlaylistJson(
        jsonEncode(<Object?>[
          <String, Object?>{'title': 'A', 'path': a, 'positionMs': 42},
          <String, Object?>{'title': 'B', 'path': b, 'positionMs': 7},
        ]),
        MovedMediaFiles(<String, String>{a: '$a.new'}),
      )!;
      final List<Object?> decoded = jsonDecode(next) as List<Object?>;
      expect(decoded[0], <String, Object?>{
        'title': 'A',
        'path': p.normalize('$a.new'),
        'positionMs': 42,
      });
      expect((decoded[1]! as Map<String, Object?>)['path'], b);
      expect(
        remapPlaylistJson(
          jsonEncode(<Object?>[
            <String, Object?>{'title': 'B', 'path': b},
          ]),
          MovedMediaFiles(<String, String>{a: '$a.new'}),
        ),
        isNull,
      );
    });
  });

  test('何时去问下载后端：确定不可能有种子时不问（不为改名去建 session）', () {
    bool consult({
      bool downloads = true,
      bool embedded = true,
      bool alive = false,
      bool resume = false,
      String qb = '',
    }) => videoFilenameOrganizeShouldConsultBackend(
      downloadsAvailable: downloads,
      embeddedSelected: embedded,
      embeddedSessionAlive: alive,
      embeddedHasResumeFiles: resume,
      qbBaseUrl: qb,
    );
    expect(consult(), isFalse, reason: '内置引擎没 session 也没 resume = 没有种子');
    expect(consult(alive: true), isTrue);
    expect(consult(resume: true), isTrue, reason: '有待恢复的种子，改名必须进引擎');
    expect(consult(downloads: false, alive: true), isFalse);
    expect(consult(embedded: false), isFalse, reason: '外接 qb 没配地址');
    expect(consult(embedded: false, qb: 'http://127.0.0.1:8080'), isTrue);
  });

  group('VideoFilenameOrganizeService', () {
    late Directory tmp;
    late FushiDatabase db;
    late String dir;
    late String video;
    late String subtitle;

    Future<void> seedMovie() async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/re',
          title: 'ぼっち・ざ・ろっく！ Re:',
          videoPath: video,
          subtitleSource: Value<String?>(subtitle),
          secondarySubtitleSource: const Value<String?>('embedded:2'),
          lastPositionMs: const Value<int>(12345),
        ),
      );
      await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              bookUid: const Value<String?>('video/re'),
              mediaType: 'movie',
              title: 'ぼっち・ざ・ろっく！ Re:',
              year: const Value<int?>(2024),
              updatedAt: 1,
            ),
          );
      await db
          .into(db.videoFileSpecs)
          .insert(
            VideoFileSpecsCompanion.insert(
              filePath: video,
              fileSizeBytes: 4,
              fileModifiedAt: 1,
              probedAt: 1,
              probeVersion: 1,
            ),
          );
    }

    Future<VideoBookRow> book(String uid) async => (await db.allVideoBooks())
        .firstWhere((VideoBookRow r) => r.bookUid == uid);

    String newVideo() => p.join(dir, 'ぼっち・ざ・ろっく！ Re： (2024).mkv');
    String newSubtitle() => p.join(dir, 'ぼっち・ざ・ろっく！ Re： (2024).ja.ass');

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('fushi_fnorg_');
      dir = p.join(tmp.path, 'dl', 'Bocchi');
      Directory(dir).createSync(recursive: true);
      video = p.join(dir, 'ぼっち・ざ・ろっく！ Re_Re_ (2024).mkv');
      subtitle = p.join(dir, 'ぼっち・ざ・ろっく！ Re_Re_ (2024).ja.ass');
      File(video).writeAsStringSync('mkv!');
      File(subtitle).writeAsStringSync('ass');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      await seedMovie();
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('无下载后端：改磁盘 + 迁库（视频 / 字幕 / 探测缓存），进度不动，可撤销', () async {
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
      ]);
      expect(plan.torrentCheck, VideoFilenameTorrentCheck.noBackend);
      expect(plan.items.single.status, VideoFilenamePlanStatus.ready);

      final VideoFilenameOrganizeResult result = await service.apply(plan);
      expect(result.renamedCount, 1);
      expect(File(newVideo()).existsSync(), isTrue);
      expect(File(newSubtitle()).existsSync(), isTrue);
      expect(File(video).existsSync(), isFalse);
      final VideoBookRow row = await book('video/re');
      expect(row.videoPath, p.normalize(newVideo()));
      expect(row.subtitleSource, p.normalize(newSubtitle()));
      expect(row.secondarySubtitleSource, 'embedded:2');
      expect(row.lastPositionMs, 12345);
      final List<VideoFileSpecRow> specs = await db
          .select(db.videoFileSpecs)
          .get();
      expect(specs.single.filePath, p.normalize(newVideo()));

      final VideoFilenameOrganizeResult undo = await service.apply(
        result.undoPlan!,
      );
      expect(undo.renamedCount, 1);
      expect(File(video).existsSync(), isTrue);
      expect(File(subtitle).existsSync(), isTrue);
      expect((await book('video/re')).videoPath, p.normalize(video));
    });

    test('在做种：种子里的文件走引擎改名，种子外的字幕直接改，任务行跟着改', () async {
      await db.upsertVideoDownloadJob(
        VideoDownloadJobsCompanion.insert(
          jobId: 'job',
          resourceProvider: 'nyaa:test',
          selectedResourceId: 'r',
          mediaKind: 'movie',
          title: 'Bocchi',
          backendKind: 'embedded',
          fingerprint: 'fp',
          torrentHash: const Value<String?>('abc123'),
          backendTaskId: const Value<String?>('abc123'),
          observedSavePath: Value<String?>(p.join(tmp.path, 'dl')),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await db.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: 'job',
          backendFileIndex: const Value<int?>(0),
          originalRelativePath: 'Bocchi/${p.basename(video)}',
          currentRelativePath: 'Bocchi/${p.basename(video)}',
          finalAbsolutePath: Value<String?>(video),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      final _FakeBackend backend = _FakeBackend(
        savePath: p.join(tmp.path, 'dl'),
        files: <TorrentFileEntry>[
          TorrentFileEntry(
            name: 'Bocchi/${p.basename(video)}',
            size: 4,
            progress: 1,
            index: 0,
          ),
        ],
      );
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
        backendFactory: () => backend,
        pathMappings: () async => const <VideoDownloadPathMapping>[],
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
      ]);
      expect(plan.torrentCheck, VideoFilenameTorrentCheck.verified);
      expect(plan.items.single.isSeeding, isTrue);

      final VideoFilenameOrganizeResult result = await service.apply(plan);
      expect(
        result.renamedCount,
        1,
        reason: '${result.failures.map((o) => o.error)}',
      );
      expect(backend.renameCalls, <String>[
        'abc123#0->Bocchi/${p.basename(newVideo())}',
      ]);
      expect(File(newVideo()).existsSync(), isTrue);
      expect(File(newSubtitle()).existsSync(), isTrue);
      final VideoDownloadJobFileRow jobFile =
          (await db.getVideoDownloadJobFiles('job')).single;
      expect(jobFile.currentRelativePath, 'Bocchi/${p.basename(newVideo())}');
      expect(jobFile.finalAbsolutePath, p.normalize(newVideo()));

      await service.apply(result.undoPlan!);
      expect(backend.renameCalls.last, 'abc123#0->Bocchi/${p.basename(video)}');
      expect(File(video).existsSync(), isTrue);
    });

    test('后端连不上：标 unverified，未确认就执行直接拒绝；确认后照常改', () async {
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
        backendFactory: () => _FakeBackend(
          savePath: dir,
          files: <TorrentFileEntry>[],
          failListing: true,
        ),
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
      ]);
      expect(plan.torrentCheck, VideoFilenameTorrentCheck.unverified);
      expect(plan.torrentCheckError, contains('backend offline'));
      await expectLater(
        service.apply(plan),
        throwsA(isA<VideoFilenameUnverifiedTorrentsException>()),
      );
      expect(File(video).existsSync(), isTrue);

      final VideoFilenameOrganizeResult result = await service.apply(
        plan,
        allowUnverifiedTorrents: true,
      );
      expect(result.renamedCount, 1);
      expect(File(newVideo()).existsSync(), isTrue);
    });

    test('中途失败：已改的逆序撤回，库一个字节不动', () async {
      // 视频不在种子里（直接改磁盘先成功），字幕在种子里但引擎拒绝。
      final _FakeBackend backend = _FakeBackend(
        savePath: dir,
        files: <TorrentFileEntry>[
          TorrentFileEntry(
            name: p.basename(subtitle),
            size: 3,
            progress: 1,
            index: 5,
          ),
        ],
        refuseIndex: 5,
      );
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
        backendFactory: () => backend,
      );
      final VideoFilenameOrganizeResult result = await service.apply(
        await service.plan(<String>['video/re']),
      );
      expect(result.renamedCount, 0);
      expect(result.failures.single.error, 'engine refused');
      expect(result.failures.single.rollbackError, isNull);
      expect(result.undoPlan, isNull);
      expect(File(video).existsSync(), isTrue);
      expect(File(subtitle).existsSync(), isTrue);
      expect(File(newVideo()).existsSync(), isFalse);
      expect((await book('video/re')).videoPath, video);
    });

    test('剧集：取作品名 + 季集号命名（分集标题不进文件名）', () async {
      final int collectionId = await db
          .into(db.mediaCollections)
          .insert(MediaCollectionsCompanion.insert(name: 'Show', createdAt: 1));
      final int workId = await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              collectionId: Value<int?>(collectionId),
              mediaType: 'tv',
              title: 'Show: Again?',
              year: const Value<int?>(2019),
              updatedAt: 1,
            ),
          );
      final int seasonId = await db
          .into(db.videoMetadataSeasons)
          .insert(
            VideoMetadataSeasonsCompanion.insert(
              workId: workId,
              seasonNumber: 2,
              updatedAt: 1,
            ),
          );
      final String ep = p.join(dir, '[Group] Show 03 [1080p].mkv');
      File(ep).writeAsStringSync('ep');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep3',
          title: 'Episode title',
          videoPath: ep,
        ),
      );
      await db
          .into(db.videoMetadataEpisodes)
          .insert(
            VideoMetadataEpisodesCompanion.insert(
              seasonId: seasonId,
              bookUid: const Value<String?>('video/ep3'),
              episodeNumber: 3,
              title: const Value<String?>('Episode title'),
              updatedAt: 1,
            ),
          );
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/ep3',
      ]);
      expect(
        p.basename(plan.items.single.moves.single.move.to),
        'Show： Again？ (2019) - S02E03.mkv',
      );
    });

    test('未刮削 / 目标已存在：不进执行', () async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/raw',
          title: 'raw',
          videoPath: p.join(dir, 'raw.mkv'),
        ),
      );
      File(p.join(dir, 'raw.mkv')).writeAsStringSync('x');
      File(newVideo()).writeAsStringSync('someone else');
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
        'video/raw',
      ]);
      expect(
        plan.items.map((VideoFilenameItemPlan i) => i.status),
        <VideoFilenamePlanStatus>[
          VideoFilenamePlanStatus.conflict,
          VideoFilenamePlanStatus.noIdentity,
        ],
      );
      expect((await service.apply(plan)).outcomes, isEmpty);
      expect(File(newVideo()).readAsStringSync(), 'someone else');
    });
  });
}
