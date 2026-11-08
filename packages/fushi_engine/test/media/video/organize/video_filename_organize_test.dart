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
import 'package:fushi_engine/media/video/subtitle_text_override_keys.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart'
    show videoSourceFolderPath;
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
    // 与 libtorrent `rename_file` 一样：新相对路径可以带目录，引擎自己建。
    final String target = p.joinAll(<String>[
      savePath,
      ...p.posix.split(newPath),
    ]);
    Directory(p.dirname(target)).createSync(recursive: true);
    File(
      p.joinAll(<String>[savePath, ...p.posix.split(file.name)]),
    ).renameSync(target);
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

    test('字幕覆盖层源键：只换改了名的 file:<文件名>，按集与目录限定', () {
      final String root = Directory.systemTemp.path;
      final String d1 = p.join(root, 's1');
      final String d2 = p.join(root, 's2');
      final MovedMediaFiles moved = MovedMediaFiles(<String, String>{
        p.join(d1, 'ep01.mkv'): p.join(d1, 'Show - S01E01.mkv'),
        p.join(d1, 'ep01.ja.srt'): p.join(d1, 'Show - S01E01.ja.srt'),
        p.join(d2, 'ep02.ja.srt'): p.join(d2, 'Show - S01E02.ja.srt'),
        // 只搬目录、不改名：键不变，不出现在结果里。
        p.join(d2, 'same.ja.srt'): p.join(root, 'other', 'same.ja.srt'),
      });
      final Map<String, Map<String, String>> keys =
          remapSubtitleOverrideSourceKeys(
            bookUid: 'video/show',
            videoPath: p.join(d1, 'ep01.mkv'),
            playlistJson: jsonEncode(<Object?>[
              <String, Object?>{'path': p.join(d1, 'ep01.mkv')},
              <String, Object?>{'path': p.join(d2, 'ep02.mkv')},
            ]),
            subtitleSource: p.join(d1, 'ep01.ja.srt'),
            secondarySubtitleSource: 'embedded:1',
            moved: moved,
          );
      expect(keys, <String, Map<String, String>>{
        'video/show': <String, String>{
          'file:ep01.mkv': 'file:Show - S01E01.mkv',
          'file:ep01.ja.srt': 'file:Show - S01E01.ja.srt',
        },
        // 第 2 集：同目录的 ep02 字幕 + 本行显式选中的 ep01 字幕（同一个文件，
        // 在这一集下挑过它的改动也该跟着走）。
        'video/show#1': <String, String>{
          'file:ep01.ja.srt': 'file:Show - S01E01.ja.srt',
          'file:ep02.ja.srt': 'file:Show - S01E02.ja.srt',
        },
      });
      // 与播放器同一套编码。
      expect(
        subtitleTextOverrideSourceKey(p.join(d1, 'ep01.ja.srt')),
        'file:ep01.ja.srt',
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

    test('刮削图片（封面 / 附加图 / 元数据图）与手改字幕跟着改名走', () async {
      final String stem = p.basenameWithoutExtension(video);
      final String newStem = p.basenameWithoutExtension(newVideo());
      final String poster = p.join(dir, '$stem-poster.jpg');
      final String fanart = p.join(dir, '$stem-fanart.jpg');
      File(poster).writeAsStringSync('poster');
      File(fanart).writeAsStringSync('fanart');
      // 共享目录电影：封面就是视频旁的 <stem>-poster.jpg（刮削经
      // updateVideoBookCover 写入）。
      await db.updateVideoBookCover('video/re', poster);
      final int workId =
          (await db.select(db.videoMetadataWorks).get()).single.id;
      await db
          .into(db.mediaImages)
          .insert(
            MediaImagesCompanion.insert(
              bookUid: const Value<String?>('video/re'),
              kind: 'backdrop',
              path: fanart,
            ),
          );
      await db
          .into(db.videoMetadataImages)
          .insert(
            VideoMetadataImagesCompanion.insert(
              workId: Value<int?>(workId),
              provider: 'tmdb',
              kind: 'cover',
              remoteUrl: 'https://image.example/poster.jpg',
              localPath: Value<String?>(poster),
              updatedAt: 1,
            ),
          );
      // 用户先在播放器里手改了一条外挂字幕。
      final String oldKey = subtitleTextOverrideSourceKey(subtitle);
      await db
          .into(db.videoSubtitleTextOverrides)
          .insert(
            VideoSubtitleTextOverridesCompanion.insert(
              videoKey: subtitleTextOverrideVideoKey('video/re', 0),
              sourceKey: oldKey,
              startMs: 1000,
              originalText: '原文',
              editedText: '改后',
              updatedAt: 1,
            ),
          );
      // 别的视频的同名源键不受影响。
      await db
          .into(db.videoSubtitleTextOverrides)
          .insert(
            VideoSubtitleTextOverridesCompanion.insert(
              videoKey: 'video/other',
              sourceKey: oldKey,
              startMs: 1000,
              originalText: '原文',
              editedText: '别人的',
              updatedAt: 1,
            ),
          );

      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      final VideoFilenameOrganizeResult result = await service.apply(
        await service.plan(<String>['video/re']),
      );
      expect(result.renamedCount, 1);
      final String newPoster = p.normalize(p.join(dir, '$newStem-poster.jpg'));
      final String newFanart = p.normalize(p.join(dir, '$newStem-fanart.jpg'));
      expect(File(newPoster).existsSync(), isTrue);
      expect((await book('video/re')).coverPath, newPoster);
      expect((await db.select(db.mediaImages).get()).single.path, newFanart);
      expect(
        (await db.select(db.videoMetadataImages).get()).single.localPath,
        newPoster,
      );
      // 播放器按新字幕路径算出的键仍命中那条改动。
      final List<VideoSubtitleTextOverrideRow> mine = await db
          .getVideoSubtitleTextOverrides(
            videoKey: 'video/re',
            sourceKey: subtitleTextOverrideSourceKey(
              (await book('video/re')).subtitleSource,
            ),
          );
      expect(mine.single.editedText, '改后');
      expect(
        subtitleTextOverrideSourceKey((await book('video/re')).subtitleSource),
        isNot(oldKey),
      );
      final List<VideoSubtitleTextOverrideRow> other = await db
          .getVideoSubtitleTextOverrides(
            videoKey: 'video/other',
            sourceKey: oldKey,
          );
      expect(other.single.editedText, '别人的');

      // 撤销：全部回到旧路径 / 旧键。
      await service.apply(result.undoPlan!);
      expect((await book('video/re')).coverPath, p.normalize(poster));
      expect(
        (await db.select(db.videoMetadataImages).get()).single.localPath,
        p.normalize(poster),
      );
      expect(
        (await db.getVideoSubtitleTextOverrides(
          videoKey: 'video/re',
          sourceKey: oldKey,
        )).single.editedText,
        '改后',
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

  group('纯函数：规范目录 / 库根 / 搬空的目录', () {
    test('电影 [标题 (年份)]；剧集再加 Season 01；横跨多季只到作品层', () {
      expect(
        canonicalVideoDirectorySegments(
          const VideoFilenameIdentity(title: 'Re:Zero', year: 2016),
        ),
        <String>['Re：Zero (2016)'],
      );
      expect(
        canonicalVideoDirectorySegments(
          const VideoFilenameIdentity(
            title: 'Show',
            seasonNumber: 0,
            episodeNumbers: <int>[1],
          ),
        ),
        <String>['Show', 'Season 00'],
      );
      expect(
        canonicalVideoDirectorySegments(
          const VideoFilenameIdentity(
            title: 'Show',
            seasonNumber: 1,
            episodeNumbers: <int>[1],
            spansMultipleSeasons: true,
          ),
        ),
        <String>['Show'],
      );
      expect(
        canonicalVideoDirectorySegments(const VideoFilenameIdentity(title: '')),
        isNull,
      );
    });

    test('库根取最深的那个；根本身不算之下', () {
      final String base = p.join(Directory.systemTemp.path, 'lib');
      final String nested = p.join(base, 'anime');
      expect(
        containingLibraryRoot(p.join(nested, 'a', 'x.mkv'), <String>[
          base,
          nested,
        ]),
        p.normalize(nested),
      );
      expect(containingLibraryRoot(base, <String>[base]), isNull);
      expect(
        containingLibraryRoot(p.join(base, 'x.mkv'), <String>['relative']),
        isNull,
      );
    });

    test('搬空候选：根之内、由深到浅、去重', () {
      final String root = p.join(Directory.systemTemp.path, 'lib');
      expect(
        emptiedDirectoryCandidates(<String>[
          p.join(root, 'dl', 'Show', 'a.mkv'),
          p.join(root, 'dl', 'Show', 'a.srt'),
          p.join(root, 'b.mkv'),
        ], root),
        <String>[p.join(root, 'dl', 'Show'), p.join(root, 'dl')],
      );
    });

    test('季图落点：seasonXX-* 进作品目录，其余进季目录', () {
      expect(
        seasonSidecarBelongsInWorkDirectory('season01-poster.jpg'),
        isTrue,
      );
      expect(
        seasonSidecarBelongsInWorkDirectory('season-specials-poster.jpg'),
        isTrue,
      );
      expect(seasonSidecarBelongsInWorkDirectory('season.nfo'), isFalse);
      expect(seasonSidecarBelongsInWorkDirectory('poster.jpg'), isFalse);
    });

    test('跨目录搬：目标目录里的同名文件算冲突；保留原名时只换目录', () {
      final String from = p.join(Directory.systemTemp.path, 'a');
      final String to = p.join(Directory.systemTemp.path, 'b');
      expect(
        planVideoFileMoves(
          videoPath: p.join(from, 'ep01.mkv'),
          dirFileNames: <String>['ep01.mkv'],
          targetDirectory: to,
          targetDirFileNames: <String>['ep01.mkv'],
        ).status,
        VideoFilenamePlanStatus.conflict,
      );
      final VideoFilenameItemDraft draft = planVideoFileMoves(
        videoPath: p.join(from, 'ep01.mkv'),
        dirFileNames: <String>['ep01.mkv', 'ep01.ja.srt'],
        targetDirectory: to,
      );
      expect(draft.status, VideoFilenamePlanStatus.ready);
      expect(draft.moves.map((VideoFileMove m) => m.to), <String>[
        p.join(to, 'ep01.mkv'),
        p.join(to, 'ep01.ja.srt'),
      ]);
      expect(
        planVideoFileMoves(
          videoPath: p.join(to, 'ep01.mkv'),
          dirFileNames: <String>['ep01.mkv'],
          targetDirectory: to,
        ).status,
        VideoFilenamePlanStatus.unchanged,
      );
    });
  });

  group('归到规范目录（VideoOrganizeLayout.directories）', () {
    late Directory tmp;
    late FushiDatabase db;
    late String root;
    late int sourceId;
    late String oldDir;
    late String video;
    late String subtitle;
    const String movieTitle = 'ぼっち・ざ・ろっく！ Re:';
    const String workDirName = 'ぼっち・ざ・ろっく！ Re： (2024)';

    String newDir() => p.join(root, workDirName);
    String newVideo() => p.join(newDir(), '$workDirName.mkv');
    String newSubtitle() => p.join(newDir(), '$workDirName.ja.ass');

    Future<VideoBookRow> book(String uid) async => (await db.allVideoBooks())
        .firstWhere((VideoBookRow r) => r.bookUid == uid);

    Future<int> seedMovie({String uid = 'video/re', String? path}) async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: movieTitle,
          videoPath: path ?? video,
          subtitleSource: Value<String?>(path == null ? subtitle : null),
          sourceId: Value<int?>(sourceId),
          lastPositionMs: const Value<int>(777),
        ),
      );
      return db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              bookUid: Value<String?>(uid),
              mediaType: 'movie',
              title: movieTitle,
              year: const Value<int?>(2024),
              updatedAt: 1,
            ),
          );
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('fushi_dirorg_');
      root = p.join(tmp.path, 'lib');
      oldDir = p.join(root, 'dl', 'Bocchi');
      Directory(oldDir).createSync(recursive: true);
      video = p.join(oldDir, 'ぼっち・ざ・ろっく！ Re_Re_ (2024).mkv');
      subtitle = p.join(oldDir, 'ぼっち・ざ・ろっく！ Re_Re_ (2024).ja.ass');
      File(video).writeAsStringSync('mkv!');
      File(subtitle).writeAsStringSync('ass');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      sourceId = await db
          .into(db.mediaSources)
          .insert(
            MediaSourcesCompanion.insert(
              label: 'lib',
              mediaKind: 'video',
              rootPath: root,
              createdAt: 1,
            ),
          );
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('电影：搬进 <库根>/标题 (年份)/，搬空的旧目录删掉；撤销原路搬回、新目录收掉', () async {
      await seedMovie();
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
      ], layout: VideoOrganizeLayout.directories);
      final VideoFilenameItemPlan item = plan.items.single;
      expect(item.status, VideoFilenamePlanStatus.ready);
      expect(item.changesDirectory, isTrue);
      expect(
        item.moves.map((VideoFilenamePlannedMove m) => m.move.to),
        <String>[newVideo(), newSubtitle()],
      );

      final VideoFilenameOrganizeResult result = await service.apply(plan);
      expect(
        result.renamedCount,
        1,
        reason: '${result.failures.map((o) => o.error)}',
      );
      expect(File(newVideo()).readAsStringSync(), 'mkv!');
      expect(File(newSubtitle()).existsSync(), isTrue);
      expect(Directory(p.join(root, 'dl')).existsSync(), isFalse);
      expect(Directory(root).existsSync(), isTrue, reason: '库根本身绝不删');
      final VideoBookRow row = await book('video/re');
      expect(row.videoPath, p.normalize(newVideo()));
      expect(row.subtitleSource, p.normalize(newSubtitle()));
      expect(row.lastPositionMs, 777);

      final VideoFilenameOrganizeResult undo = await service.apply(
        result.undoPlan!,
      );
      expect(undo.renamedCount, 1);
      expect(File(video).readAsStringSync(), 'mkv!');
      expect(File(subtitle).existsSync(), isTrue);
      expect(Directory(newDir()).existsSync(), isFalse);
      expect((await book('video/re')).videoPath, p.normalize(video));
    });

    test('不在任何来源库根下：outsideLibraryRoot；只改文件名照常可做', () async {
      final String outside = p.join(tmp.path, 'elsewhere', 'movie.mkv');
      Directory(p.dirname(outside)).createSync(recursive: true);
      File(outside).writeAsStringSync('x');
      await seedMovie(uid: 'video/out', path: outside);
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      expect(
        (await service.plan(<String>[
          'video/out',
        ], layout: VideoOrganizeLayout.directories)).items.single.status,
        VideoFilenamePlanStatus.outsideLibraryRoot,
      );
      expect(
        (await service.plan(<String>['video/out'])).items.single.status,
        VideoFilenamePlanStatus.ready,
      );
    });

    test('在做种：保存目录之内走引擎改相对路径（可换目录）；要搬出保存目录的拒绝', () async {
      await seedMovie();
      final String relative = 'dl/Bocchi/${p.basename(video)}';
      _FakeBackend backendAt(String savePath, String name) => _FakeBackend(
        savePath: savePath,
        files: <TorrentFileEntry>[
          TorrentFileEntry(name: name, size: 4, progress: 1, index: 0),
        ],
      );

      final _FakeBackend inside = backendAt(root, relative);
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
        backendFactory: () => inside,
        pathMappings: () async => const <VideoDownloadPathMapping>[],
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
      ], layout: VideoOrganizeLayout.directories);
      expect(plan.items.single.isSeeding, isTrue);
      final VideoFilenameOrganizeResult result = await service.apply(plan);
      expect(
        result.renamedCount,
        1,
        reason: '${result.failures.map((o) => o.error)}',
      );
      expect(inside.renameCalls, <String>[
        'abc123#0->$workDirName/$workDirName.mkv',
      ]);
      expect(File(newVideo()).existsSync(), isTrue);
      await service.apply(result.undoPlan!);
      expect(inside.renameCalls.last, 'abc123#0->$relative');
      expect(File(video).existsSync(), isTrue);

      final VideoFilenameOrganizeService narrow = VideoFilenameOrganizeService(
        database: db,
        backendFactory: () => backendAt(oldDir, p.basename(video)),
        pathMappings: () async => const <VideoDownloadPathMapping>[],
      );
      final VideoFilenameOrganizePlan blocked = await narrow.plan(<String>[
        'video/re',
      ], layout: VideoOrganizeLayout.directories);
      expect(
        blocked.items.single.status,
        VideoFilenamePlanStatus.torrentOutsideSaveRoot,
      );
      expect(blocked.ready, isEmpty);
    });

    test('目录合集：成员全部跟着走 → 换目录键（撤销换回）；拆开合集 → 拒绝', () async {
      await seedMovie();
      final int collectionId = await db
          .into(db.mediaCollections)
          .insert(
            MediaCollectionsCompanion.insert(
              name: 'dl',
              createdAt: 1,
              sourceFolderPath: Value<String?>(
                videoSourceFolderPath(video, root),
              ),
            ),
          );
      await db.addToCollection(collectionId, MediaKind.video, 'video/re');
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/re',
      ], layout: VideoOrganizeLayout.directories);
      expect(
        plan.folderCollectionMoves.single.toKey,
        videoSourceFolderPath(newVideo(), root),
      );
      final VideoFilenameOrganizeResult result = await service.apply(plan);
      expect(result.appliedCollectionMoves, hasLength(1));
      expect(
        (await db.getMediaCollectionById(collectionId))!.sourceFolderPath,
        videoSourceFolderPath(newVideo(), root),
      );
      await service.apply(result.undoPlan!);
      expect(
        (await db.getMediaCollectionById(collectionId))!.sourceFolderPath,
        videoSourceFolderPath(video, root),
      );

      // 同一目录合集里还有一个不在这一批的成员：搬走一个就把合集拆了。
      final String other = p.join(oldDir, 'other.mkv');
      File(other).writeAsStringSync('o');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/other',
          title: 'other',
          videoPath: other,
          sourceId: Value<int?>(sourceId),
        ),
      );
      await db.addToCollection(collectionId, MediaKind.video, 'video/other');
      final VideoFilenameOrganizePlan split = await service.plan(<String>[
        'video/re',
      ], layout: VideoOrganizeLayout.directories);
      expect(
        split.items.single.status,
        VideoFilenamePlanStatus.folderCollectionSplit,
      );
      expect(split.folderCollectionMoves, isEmpty);
    });

    test('多集播放列表：只改名不支持；归目录时各集保留原名搬进季目录，各集进度原样', () async {
      final int showCollection = await db
          .into(db.mediaCollections)
          .insert(MediaCollectionsCompanion.insert(name: 'Show', createdAt: 1));
      final int workId = await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              collectionId: Value<int?>(showCollection),
              mediaType: 'tv',
              title: 'Show',
              year: const Value<int?>(2020),
              updatedAt: 1,
            ),
          );
      final int seasonId = await db
          .into(db.videoMetadataSeasons)
          .insert(
            VideoMetadataSeasonsCompanion.insert(
              workId: workId,
              seasonNumber: 1,
              updatedAt: 1,
            ),
          );
      final String a = p.join(oldDir, 'show 01.mkv');
      final String b = p.join(oldDir, 'show 02.mkv');
      File(a).writeAsStringSync('a');
      File(b).writeAsStringSync('b');
      File(p.join(oldDir, 'show 02.zh.srt')).writeAsStringSync('s');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/pl',
          title: 'Show',
          videoPath: a,
          sourceId: Value<int?>(sourceId),
          playlistJson: Value<String?>(
            jsonEncode(<Object?>[
              <String, Object?>{'title': '1', 'path': a, 'positionMs': 11},
              <String, Object?>{'title': '2', 'path': b, 'positionMs': 22},
            ]),
          ),
        ),
      );
      for (final int n in <int>[1, 2]) {
        await db
            .into(db.videoMetadataEpisodes)
            .insert(
              VideoMetadataEpisodesCompanion.insert(
                seasonId: seasonId,
                bookUid: const Value<String?>('video/pl'),
                episodeNumber: n,
                updatedAt: 1,
              ),
            );
      }
      // 作品级 sidecar（刮削写在旧作品目录的 tvshow.nfo）：作品的全部条目都在
      // 这一批里，跟着搬进新作品目录。
      final String nfo = p.join(oldDir, 'tvshow.nfo');
      File(nfo).writeAsStringSync('<tvshow/>');
      await db
          .into(db.videoSidecarArtifacts)
          .insert(
            VideoSidecarArtifactsCompanion.insert(
              workId: Value<int?>(workId),
              artifactKind: 'nfo',
              path: nfo,
              sha256: 'x',
              generatorVersion: '1',
              writePolicy: 'managed',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      expect(
        (await service.plan(<String>['video/pl'])).items.single.status,
        VideoFilenamePlanStatus.playlistNeedsDirectories,
      );
      final VideoFilenameOrganizePlan plan = await service.plan(<String>[
        'video/pl',
      ], layout: VideoOrganizeLayout.directories);
      expect(plan.items.single.status, VideoFilenamePlanStatus.ready);
      final VideoFilenameOrganizeResult result = await service.apply(plan);
      expect(
        result.renamedCount,
        1,
        reason: '${result.failures.map((o) => o.error)}',
      );
      final String season = p.join(root, 'Show (2020)', 'Season 01');
      expect(File(p.join(season, 'show 01.mkv')).existsSync(), isTrue);
      expect(File(p.join(season, 'show 02.mkv')).existsSync(), isTrue);
      expect(File(p.join(season, 'show 02.zh.srt')).existsSync(), isTrue);
      final String newNfo = p.join(root, 'Show (2020)', 'tvshow.nfo');
      expect(File(newNfo).existsSync(), isTrue);
      expect(
        (await db.select(db.videoSidecarArtifacts).get()).single.path,
        p.normalize(newNfo),
      );
      final VideoBookRow row = await book('video/pl');
      expect(row.videoPath, p.normalize(p.join(season, 'show 01.mkv')));
      final List<Object?> entries =
          jsonDecode(row.playlistJson!) as List<Object?>;
      expect((entries[1]! as Map<String, Object?>)['positionMs'], 22);
      expect(
        (entries[1]! as Map<String, Object?>)['path'],
        p.normalize(p.join(season, 'show 02.mkv')),
      );
      // 旧目录里还有不相干的文件（setUp 放的电影）：不是搬空的目录，原样保留。
      expect(
        Directory(
          oldDir,
        ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
        unorderedEquals(<String>[p.basename(video), p.basename(subtitle)]),
      );
    });

    test('光盘条目：盘内文件名是盘结构，不整理', () async {
      final String mpls = p.join(
        root,
        'Disc',
        'BDMV',
        'PLAYLIST',
        '00001.mpls',
      );
      Directory(p.dirname(mpls)).createSync(recursive: true);
      File(mpls).writeAsStringSync('mpls');
      await seedMovie(uid: 'video/disc', path: mpls);
      final VideoFilenameOrganizeService service = VideoFilenameOrganizeService(
        database: db,
      );
      for (final VideoOrganizeLayout layout in VideoOrganizeLayout.values) {
        expect(
          (await service.plan(<String>[
            'video/disc',
          ], layout: layout)).items.single.status,
          VideoFilenamePlanStatus.disc,
        );
      }
    });
  });
}
