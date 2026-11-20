// 视频库整理的控制通道（ctl_video_organize_routes.dart）：作品明细、手动指定季集、
// 按刮削资料整理文件名、把文件搬到点名的位置，以及各自撤销的往返。磁盘用临时目录
// 上的真实文件，库用内存库，服务是真的 VideoFilenameOrganizeService（不接下载后端）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_video_organize_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late Directory root;
  late VideoFilenameOrganizeService service;
  late List<CtlRoute> routes;
  late int collectionId;
  late int workId;

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, String> query = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) => routes
      .singleWhere((CtlRoute r) => r.method == method && r.pattern == pattern)
      .handler(
        CtlCall(
          method: method,
          path: pattern,
          params: params,
          query: query,
          body: body,
        ),
      );

  Future<String> addVideo(String uid, String relativePath) async {
    final File file = File(p.join(root.path, relativePath));
    await file.create(recursive: true);
    await file.writeAsString(uid);
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: p.basenameWithoutExtension(relativePath),
        videoPath: file.path,
      ),
    );
    return file.path;
  }

  Future<int> addEpisode(int seasonId, int number, {String? bookUid}) =>
      db.upsertVideoMetadataEpisode(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          episodeNumber: number,
          bookUid: Value<String?>(bookUid),
          title: Value<String?>('Episode $number'),
          updatedAt: 1,
        ),
      );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('fushi_video_organize_');
    await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    service = VideoFilenameOrganizeService(database: db);
    routes = buildVideoOrganizeCtlRoutesFor(
      database: () => db,
      organizer: () => service,
    );

    // 一部剧：正片第 1 集挂对了，另一个文件被错挂成特别篇 S00E01（其实是第 2 集）。
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await addVideo('ep1', 'Show/Season 01/Show - S01E01.mkv');
    await addVideo('ep2', 'Show/Season 00/Show - S00E01.mkv');
    await File(
      p.join(root.path, 'Show/Season 00/Show - S00E01.ja.srt'),
    ).writeAsString('sub');
    await db.addToCollection(collectionId, MediaKind.video, 'ep1');
    await db.addToCollection(collectionId, MediaKind.video, 'ep2');
    workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        year: const Value<int?>(2020),
        updatedAt: 1,
      ),
    );
    final int season1 = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 1,
        updatedAt: 1,
      ),
    );
    final int season0 = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 0,
        updatedAt: 1,
      ),
    );
    await addEpisode(season1, 1, bookUid: 'ep1');
    await addEpisode(season1, 2);
    await addEpisode(season0, 1, bookUid: 'ep2');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<List<String>> slotsOf(String uid) async {
    final Map<int, int> seasonNumbers = <int, int>{
      for (final VideoMetadataSeasonRow s in await db.getVideoMetadataSeasons(
        workId,
      ))
        s.id: s.seasonNumber,
    };
    return <String>[
      for (final VideoMetadataEpisodeRow e
          in await db.getVideoMetadataEpisodesByBook(uid))
        'S${seasonNumbers[e.seasonId]}E${e.episodeNumber}',
    ];
  }

  test('作品明细：季、集与本机文件的对应，路径相对来源库根', () async {
    final Map<Object?, Object?> detail =
        await call(
              'GET',
              '$kVideoOrganizeCtlRoot/works/:id/detail',
              params: <String, String>{'id': 'collection:$collectionId'},
            )
            as Map<Object?, Object?>;
    expect((detail['work']! as Map)['mediaType'], 'tv');
    final List<Object?> files = detail['files']! as List<Object?>;
    final Map<Object?, Object?> ep2 = files
        .cast<Map<Object?, Object?>>()
        .singleWhere((Map<Object?, Object?> f) => f['uid'] == 'ep2');
    expect(ep2['path'], 'Show/Season 00/Show - S00E01.mkv');
    expect(ep2['boundTo'], <String>['S00E01']);
    // 应答里不出现库根的绝对路径。
    expect(
      jsonEncode(detail),
      isNot(contains(root.path.split(p.separator).last)),
    );
    final List<Object?> seasons = detail['seasons']! as List<Object?>;
    final Map<Object?, Object?> s1 = seasons
        .cast<Map<Object?, Object?>>()
        .singleWhere((Map<Object?, Object?> s) => s['season'] == 1);
    expect(s1['episodes'], 2);
    expect(s1['localEpisodes'], 1);
    // 缺省只列有本机文件的集。
    expect((s1['listed']! as List<Object?>).length, 1);
  });

  test('手动指定季集：立刻改绑；撤销回到执行前', () async {
    final Map<Object?, Object?> result =
        await call(
              'POST',
              '$kVideoOrganizeCtlRoot/files/:uid/episode',
              params: <String, String>{'uid': 'ep2'},
              body: <String, Object?>{'season': 1, 'episode': 2},
            )
            as Map<Object?, Object?>;
    expect(await slotsOf('ep2'), <String>['S1E2']);
    expect((await db.getVideoEpisodeBindingOverride('ep2'))?.episodeNumber, 2);

    // 撤销载荷过一遍 JSON（与持久化后再撤销同一形态）。
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(result)) as Map<String, Object?>;
    expect(
      await restoreVideoEpisodePin(
        db,
        bookUid: 'ep2',
        applied: payload['applied'],
        snapshot: payload['previous'],
      ),
      isTrue,
    );
    expect(await slotsOf('ep2'), <String>['S0E1']);
    expect(await db.getVideoEpisodeBindingOverride('ep2'), isNull);
  });

  test('手动指定之后用户又改过：撤销不覆盖', () async {
    final Map<Object?, Object?> result =
        await call(
              'POST',
              '$kVideoOrganizeCtlRoot/files/:uid/episode',
              params: <String, String>{'uid': 'ep2'},
              body: <String, Object?>{'season': 1, 'episode': 2},
            )
            as Map<Object?, Object?>;
    await db.setVideoEpisodeBindingOverride(
      'ep2',
      seasonNumber: 0,
      episodeNumber: 1,
    );
    expect(
      await restoreVideoEpisodePin(
        db,
        bookUid: 'ep2',
        applied: result['applied'],
        snapshot: result['previous'],
      ),
      isFalse,
    );
    expect((await db.getVideoEpisodeBindingOverride('ep2'))?.seasonNumber, 0);
  });

  test('指定到不存在的集：404，不留下手动指定', () async {
    await expectLater(
      call(
        'POST',
        '$kVideoOrganizeCtlRoot/files/:uid/episode',
        params: <String, String>{'uid': 'ep2'},
        body: <String, Object?>{'season': 1, 'episode': 99},
      ),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
      ),
    );
    expect(await db.getVideoEpisodeBindingOverride('ep2'), isNull);
  });

  test('改完季集再整理：磁盘按新季集改名并归目录，字幕跟着走；撤销搬回', () async {
    await call(
      'POST',
      '$kVideoOrganizeCtlRoot/files/:uid/episode',
      params: <String, String>{'uid': 'ep2'},
      body: <String, Object?>{'season': 1, 'episode': 2},
    );
    final Map<Object?, Object?> plan =
        await call(
              'GET',
              '$kVideoOrganizeCtlRoot/organize',
              query: <String, String>{'items': 'ep2', 'layout': 'directories'},
            )
            as Map<Object?, Object?>;
    expect(plan['ready'], 1);
    // 预览不动磁盘。
    expect(
      File(p.join(root.path, 'Show/Season 00/Show - S00E01.mkv')).existsSync(),
      isTrue,
    );

    final Map<Object?, Object?> result =
        await call(
              'POST',
              '$kVideoOrganizeCtlRoot/organize',
              body: <String, Object?>{
                'items': <String>['ep2'],
                'layout': 'directories',
              },
            )
            as Map<Object?, Object?>;
    expect(result['renamed'], 1);
    final String moved = p.join(
      root.path,
      'Show (2020)/Season 01/Show (2020) - S01E02.mkv',
    );
    expect(File(moved).existsSync(), isTrue);
    expect(
      File(
        p.join(root.path, 'Show (2020)/Season 01/Show (2020) - S01E02.ja.srt'),
      ).existsSync(),
      isTrue,
    );
    expect((await db.getVideoBookByBookUid('ep2'))!.videoPath, moved);
    // 搬空的旧目录顺手删掉。
    expect(
      Directory(p.join(root.path, 'Show/Season 00')).existsSync(),
      isFalse,
    );
    // 应答只有相对路径，绝对路径留在回执里。
    expect(jsonEncode(result), isNot(contains(p.basename(root.path))));

    final Map<String, Object?> undo =
        jsonDecode(jsonEncode(takeVideoOrganizeUndo(result['undoToken'])))
            as Map<String, Object?>;
    final VideoFilenameOrganizePlan undoPlan = videoOrganizePlanFromJson(undo)!;
    expect(await videoOrganizeUndoStillApplies(undoPlan), isTrue);
    final ({int reverted, List<String> errors}) outcome =
        await revertVideoOrganize(service, undoPlan);
    expect(outcome.errors, isEmpty);
    expect(outcome.reverted, 1);
    final String original = p.join(
      root.path,
      'Show/Season 00/Show - S00E01.mkv',
    );
    expect(File(original).existsSync(), isTrue);
    expect(
      File(
        p.join(root.path, 'Show/Season 00/Show - S00E01.ja.srt'),
      ).existsSync(),
      isTrue,
    );
    expect((await db.getVideoBookByBookUid('ep2'))!.videoPath, original);
    // 回执只能取一次。
    expect(takeVideoOrganizeUndo(result['undoToken']), isNull);
  });

  test('点名搬动：把挂在 Season 00 的电影搬到自己的目录并改名；撤销搬回', () async {
    final Map<Object?, Object?> result =
        await call(
              'POST',
              '$kVideoOrganizeCtlRoot/files/:uid/move',
              params: <String, String>{'uid': 'ep2'},
              body: <String, Object?>{
                'directory': 'The Movie (2016)',
                'name': 'The Movie (2016)',
              },
            )
            as Map<Object?, Object?>;
    expect(result['renamed'], 1);
    final String moved = p.join(
      root.path,
      'The Movie (2016)/The Movie (2016).mkv',
    );
    expect(File(moved).existsSync(), isTrue);
    expect(
      File(
        p.join(root.path, 'The Movie (2016)/The Movie (2016).ja.srt'),
      ).existsSync(),
      isTrue,
    );
    expect((await db.getVideoBookByBookUid('ep2'))!.videoPath, moved);

    final VideoFilenameOrganizePlan undoPlan = videoOrganizePlanFromJson(
      jsonDecode(jsonEncode(takeVideoOrganizeUndo(result['undoToken']))),
    )!;
    final ({int reverted, List<String> errors}) outcome =
        await revertVideoOrganize(service, undoPlan);
    expect(outcome.errors, isEmpty);
    expect(
      File(p.join(root.path, 'Show/Season 00/Show - S00E01.mkv')).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(root.path, 'The Movie (2016)')).existsSync(),
      isFalse,
    );
  });

  test('点名搬动：越出库根 / 非法文件名 400，目标被占 409，都不动磁盘', () async {
    Future<void> expectStatus(Map<String, Object?> body, int status) =>
        expectLater(
          call(
            'POST',
            '$kVideoOrganizeCtlRoot/files/:uid/move',
            params: <String, String>{'uid': 'ep2'},
            body: body,
          ),
          throwsA(
            isA<CtlFailure>().having(
              (CtlFailure f) => f.status,
              'status',
              status,
            ),
          ),
        );

    await expectStatus(<String, Object?>{'directory': '../outside'}, 400);
    await expectStatus(<String, Object?>{'name': 'a:b'}, 400);
    await expectStatus(<String, Object?>{}, 400);
    // 目标名已被另一集占用。
    await expectStatus(<String, Object?>{
      'directory': 'Show/Season 01',
      'name': 'Show - S01E01',
    }, 409);
    expect(
      File(p.join(root.path, 'Show/Season 00/Show - S00E01.mkv')).existsSync(),
      isTrue,
    );
    expect(
      File(
        p.join(root.path, 'Show/Season 01/Show - S01E01.mkv'),
      ).readAsStringSync(),
      'ep1',
    );
  });

  test('搬过去的文件之后又被挪走：撤销判为已被处理', () async {
    final Map<Object?, Object?> result =
        await call(
              'POST',
              '$kVideoOrganizeCtlRoot/files/:uid/move',
              params: <String, String>{'uid': 'ep2'},
              body: <String, Object?>{'name': 'Renamed'},
            )
            as Map<Object?, Object?>;
    final VideoFilenameOrganizePlan undoPlan = videoOrganizePlanFromJson(
      takeVideoOrganizeUndo(result['undoToken']),
    )!;
    await File(
      p.join(root.path, 'Show/Season 00/Renamed.mkv'),
    ).rename(p.join(root.path, 'elsewhere.mkv'));
    expect(await videoOrganizeUndoStillApplies(undoPlan), isFalse);
  });
}
