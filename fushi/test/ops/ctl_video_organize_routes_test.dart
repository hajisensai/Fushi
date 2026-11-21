// 视频库整理的控制通道（ctl_video_organize_routes.dart）：作品明细、手动指定季集、
// 按刮削资料整理文件名、把文件搬到点名的位置，以及各自撤销的往返。磁盘用临时目录
// 上的真实文件，库用内存库，服务是真的 VideoFilenameOrganizeService（不接下载后端）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_video_organize_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';
import 'package:fushi_engine/media/video/organize/video_work_regroup.dart';
import 'package:path/path.dart' as p;

/// 可控执行顺序：armed 后，第一条碰到 [table] 的语句处插入 [race]（模拟别的写入方
/// 恰好在这一刻提交）。读语句在读完之后插入，写语句在写之前插入——正好落在
/// 「读当前值」与「写回」之间。[race] 收到的是该语句所在的 executor（事务内就是
/// 事务 executor，等价于另一个连接在这两步之间已提交）。
class _RaceGate extends QueryInterceptor {
  String? table;
  Future<void> Function(QueryExecutor executor)? race;
  int fired = 0;

  void arm(String table, Future<void> Function(QueryExecutor executor) race) {
    this.table = table;
    this.race = race;
  }

  Future<void> _maybeRace(QueryExecutor executor, String statement) async {
    final String? t = table;
    final Future<void> Function(QueryExecutor executor)? r = race;
    if (t == null || r == null || !statement.contains(t)) return;
    table = null;
    race = null;
    fired++;
    await r(executor);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final List<Map<String, Object?>> rows = await executor.runSelect(
      statement,
      args,
    );
    await _maybeRace(executor, statement);
    return rows;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await _maybeRace(executor, statement);
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await _maybeRace(executor, statement);
    return executor.runDelete(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await _maybeRace(executor, statement);
    return executor.runInsert(statement, args);
  }
}

void main() {
  late FushiDatabase db;
  late _RaceGate gate;
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
    gate = _RaceGate();
    db = FushiDatabase.forTesting(NativeDatabase.memory().interceptWith(gate));
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

  test('撤销季集指定的读与写之间别处改了指定：新值不被旧快照盖掉（HBK-AUDIT-029）', () async {
    final Map<String, Object?> payload =
        jsonDecode(
              jsonEncode(
                await call(
                  'POST',
                  '$kVideoOrganizeCtlRoot/files/:uid/episode',
                  params: <String, String>{'uid': 'ep2'},
                  body: <String, Object?>{'season': 1, 'episode': 2},
                ),
              ),
            )
            as Map<String, Object?>;
    // 撤销读到「当前指定 = S1E2」的那一刻，同进程另一任务提交新指定 S0E1（不 await，
    // 走根 zone，不混进撤销的事务）。
    Future<void>? concurrent;
    gate.arm('video_episode_binding_overrides', (QueryExecutor _) async {
      concurrent = Zone.root.run(
        () => db.setVideoEpisodeBindingOverride(
          'ep2',
          seasonNumber: 0,
          episodeNumber: 1,
        ),
      );
    });
    await restoreVideoEpisodePin(
      db,
      bookUid: 'ep2',
      applied: payload['applied'],
      snapshot: payload['previous'],
    );
    await concurrent;
    expect(gate.fired, 1);
    final VideoEpisodeBindingOverrideRow? now = await db
        .getVideoEpisodeBindingOverride('ep2');
    expect((now?.seasonNumber, now?.episodeNumber), (0, 1));
  });

  test('手动指定季集：快照读与写入之间别处提交的指定进快照，撤销不抹掉它（BUG-5143）', () async {
    // pinEpisode 读「执行前指定」的那一刻，同进程另一任务提交指定 S0E1（不 await，
    // 走根 zone，不混进 pinEpisode 的事务）。快照必须是这次写入实际覆盖掉的值：
    // 要么 S0E1 先落、进快照，要么排在写入之后、撤销时判 superseded；都不能被撤销抹掉。
    Future<void>? concurrent;
    gate.arm('video_episode_binding_overrides', (QueryExecutor _) async {
      concurrent = Zone.root.run(
        () => db.setVideoEpisodeBindingOverride(
          'ep2',
          seasonNumber: 0,
          episodeNumber: 1,
        ),
      );
    });
    final Map<String, Object?> payload =
        jsonDecode(
              jsonEncode(
                await call(
                  'POST',
                  '$kVideoOrganizeCtlRoot/files/:uid/episode',
                  params: <String, String>{'uid': 'ep2'},
                  body: <String, Object?>{'season': 1, 'episode': 2},
                ),
              ),
            )
            as Map<String, Object?>;
    await concurrent;
    expect(gate.fired, 1);
    await restoreVideoEpisodePin(
      db,
      bookUid: 'ep2',
      applied: payload['applied'],
      snapshot: payload['previous'],
    );
    final VideoEpisodeBindingOverrideRow? now = await db
        .getVideoEpisodeBindingOverride('ep2');
    expect((now?.seasonNumber, now?.episodeNumber), (0, 1));
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

  test('ifFree：目标集已绑着另一个本机文件就 409，不改绑、不留手动指定', () async {
    await expectLater(
      call(
        'POST',
        '$kVideoOrganizeCtlRoot/files/:uid/episode',
        params: <String, String>{'uid': 'ep2'},
        body: <String, Object?>{'season': 1, 'episode': 1, 'ifFree': true},
      ),
      throwsA(
        isA<CtlFailure>()
            .having((CtlFailure f) => f.status, 'status', 409)
            .having((CtlFailure f) => f.code, 'code', 'episode_occupied'),
      ),
    );
    expect(await slotsOf('ep1'), <String>['S1E1']);
    expect(await slotsOf('ep2'), <String>['S0E1']);
    expect(await db.getVideoEpisodeBindingOverride('ep2'), isNull);

    // 空着的集照常改绑。
    await call(
      'POST',
      '$kVideoOrganizeCtlRoot/files/:uid/episode',
      params: <String, String>{'uid': 'ep2'},
      body: <String, Object?>{'season': 1, 'episode': 2, 'ifFree': true},
    );
    expect(await slotsOf('ep2'), <String>['S1E2']);
    expect(await slotsOf('ep1'), <String>['S1E1']);
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

  group('合集分栏（拍板台 iR6ccUys9H）', () {
    late int season0Id;

    setUp(() async {
      // 一集短篇：文件名带集号 01（被文件名推进第 1 季），刮削认成特别篇 S00E02。
      await addVideo('short1', 'Show/Shorts/Show Petit 01.mkv');
      await db.addToCollection(collectionId, MediaKind.video, 'short1');
      season0Id = (await db.getVideoMetadataSeasons(
        workId,
      )).singleWhere((VideoMetadataSeasonRow s) => s.seasonNumber == 0).id;
      await addEpisode(season0Id, 2, bookUid: 'short1');
    });

    Future<Map<Object?, Object?>> sections() async =>
        await call(
              'GET',
              '$kVideoOrganizeCtlRoot/works/:id/sections',
              params: <String, String>{'id': 'collection:$collectionId'},
            )
            as Map<Object?, Object?>;

    Map<String, List<Object?>> sectionFiles(
      Map<Object?, Object?> data,
    ) => <String, List<Object?>>{
      for (final Map<Object?, Object?> s
          in (data['sections']! as List<Object?>).cast<Map<Object?, Object?>>())
        s['key']! as String: s['files']! as List<Object?>,
    };

    Map<Object?, Object?> fileOf(Map<Object?, Object?> data, String uid) =>
        (data['files']! as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .singleWhere((Map<Object?, Object?> f) => f['uid'] == uid);

    Future<Map<Object?, Object?>> setSection(Map<String, Object?> body) async =>
        await call('POST', '$kVideoOrganizeCtlRoot/sections', body: body)
            as Map<Object?, Object?>;

    test('查询：与详情页同一分栏；第 0 季文件归 PV·特典；报出可疑点', () async {
      final Map<Object?, Object?> data = await sections();
      expect(data['tabs'], isTrue);
      expect(sectionFiles(data), <String, List<Object?>>{
        's1': <Object?>['ep1', 'short1'],
        'extras': <Object?>['ep2'],
      });
      expect(fileOf(data, 'short1')['source'], 'filename');
      expect(fileOf(data, 'short1')['boundTo'], <String>['S00E02']);
      expect(fileOf(data, 'short1')['path'], 'Show/Shorts/Show Petit 01.mkv');
      final List<Map<Object?, Object?>> warnings =
          (data['warnings']! as List<Object?>).cast<Map<Object?, Object?>>();
      expect(
        warnings.map((Map<Object?, Object?> w) => w['kind']),
        containsAll(<String>['bound_to_special', 'duplicate_episode_number']),
      );
      expect(
        warnings.singleWhere(
          (Map<Object?, Object?> w) => w['kind'] == 'duplicate_episode_number',
        )['uids'],
        <Object?>['ep1', 'short1'],
      );
    });

    test('钉到 PV·特典：分栏立刻变；撤销回到执行前', () async {
      final Map<Object?, Object?> result = await setSection(<String, Object?>{
        'items': <String>['short1'],
        'section': 'extras',
      });
      expect(result['applied'], 'extras');
      expect((result['items']! as List<Object?>).single, <String, Object?>{
        'uid': 'short1',
        'section': 'extras',
        'source': 'manual',
      });
      final Map<Object?, Object?> after = await sections();
      expect(sectionFiles(after), <String, List<Object?>>{
        's1': <Object?>['ep1'],
        'extras': <Object?>['ep2', 'short1'],
      });
      expect(fileOf(after, 'short1')['derivedSection'], 's1');
      expect(after['warnings'], isEmpty);

      // 撤销载荷过一遍 JSON（与持久化后再撤销同一形态）。
      final Map<String, Object?> payload =
          jsonDecode(jsonEncode(result)) as Map<String, Object?>;
      final ({int reverted, int superseded}) undo =
          await restoreVideoCollectionSections(
            db,
            applied: payload['applied'],
            previous: payload['previous'],
          );
      expect(undo, (reverted: 1, superseded: 0));
      expect(
        await db.getVideoCollectionSectionOverrides(<String>['short1']),
        isEmpty,
      );
      expect(sectionFiles(await sections())['s1'], <Object?>['ep1', 'short1']);
    });

    test('钉到第 2 季 / 改回自动；之后又被改过的撤销保留现状', () async {
      final Map<Object?, Object?> result = await setSection(<String, Object?>{
        'items': <String>['short1', 'ep1'],
        'section': 'season',
        'season': 2,
      });
      expect(
        await db.getVideoCollectionSectionOverrides(<String>['short1', 'ep1']),
        <String, String>{'short1': 's2', 'ep1': 's2'},
      );
      await db.setVideoCollectionSectionOverrides(<String>['ep1'], 'extras');
      final ({int reverted, int superseded}) undo =
          await restoreVideoCollectionSections(
            db,
            applied: result['applied'],
            previous: result['previous'],
          );
      expect(undo, (reverted: 1, superseded: 1));
      expect(
        await db.getVideoCollectionSectionOverrides(<String>['short1', 'ep1']),
        <String, String>{'ep1': 'extras'},
      );

      await setSection(<String, Object?>{
        'items': <String>['ep1'],
        'section': 'auto',
      });
      expect(fileOf(await sections(), 'ep1')['section'], 's1');
    });

    test('撤销分栏的读与写之间别处提交了新分栏：保留新值、报 superseded（HBK-AUDIT-029）', () async {
      final Map<String, Object?> payload =
          jsonDecode(
                jsonEncode(
                  await setSection(<String, Object?>{
                    'items': <String>['short1'],
                    'section': 'extras',
                  }),
                ),
              )
              as Map<String, Object?>;
      // 撤销碰到分栏表的那一刻（读完当前值之后 / 写回之前），另一写入方把 short1
      // 提交成第 2 季。
      gate.arm('video_collection_section_overrides', (QueryExecutor ex) async {
        await ex.runUpdate(
          'INSERT OR REPLACE INTO video_collection_section_overrides '
          '(book_uid, section_key, updated_at) VALUES (?, ?, ?)',
          <Object?>['short1', 's2', 2],
        );
      });
      final ({int reverted, int superseded}) undo =
          await restoreVideoCollectionSections(
            db,
            applied: payload['applied'],
            previous: payload['previous'],
          );
      expect(gate.fired, 1);
      expect(
        await db.getVideoCollectionSectionOverrides(<String>['short1']),
        <String, String>{'short1': 's2'},
      );
      expect(undo, (reverted: 0, superseded: 1));
    });

    test('分栏条件写：四种 expected / replacement 组合只在当前值吻合时命中', () async {
      Future<Map<String, String>> now() =>
          db.getVideoCollectionSectionOverrides(<String>['short1']);
      Future<bool> cas(String? expected, String? replacement) =>
          db.compareAndSetVideoCollectionSectionOverride(
            'short1',
            expected: expected,
            replacement: replacement,
          );
      expect(await cas(null, null), isTrue);
      expect(await cas('s2', 'extras'), isFalse);
      expect(await cas(null, 'extras'), isTrue);
      expect(await now(), <String, String>{'short1': 'extras'});
      expect(await cas(null, 's2'), isFalse);
      expect(await cas(null, null), isFalse);
      expect(await cas('s2', null), isFalse);
      expect(await cas('extras', 's2'), isTrue);
      expect(await now(), <String, String>{'short1': 's2'});
      expect(await cas('s2', null), isTrue);
      expect(await now(), isEmpty);
      // 文件行已不在：不插孤儿行（外键），算没命中。
      expect(
        await db.compareAndSetVideoCollectionSectionOverride(
          'gone',
          expected: null,
          replacement: 's2',
        ),
        isFalse,
      );
    });

    test('手动指定到第 0 季：分栏跟着进 PV·特典（修前只看文件名）', () async {
      await call(
        'POST',
        '$kVideoOrganizeCtlRoot/files/:uid/episode',
        params: <String, String>{'uid': 'short1'},
        body: <String, Object?>{'season': 0, 'episode': 2},
      );
      final Map<Object?, Object?> data = await sections();
      expect(fileOf(data, 'short1')['section'], 'extras');
      expect(fileOf(data, 'short1')['source'], 'pinnedEpisode');
    });

    test('参数不对 400、未知视频 404，都不写库', () async {
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{
          'items': <String>['short1'],
          'section': 'season',
        },
        <String, Object?>{
          'items': <String>['short1'],
          'section': 'season',
          'season': 0,
        },
        <String, Object?>{
          'items': <String>['short1'],
          'section': 'bogus',
        },
        <String, Object?>{'items': <String>[], 'section': 'extras'},
      ]) {
        await expectLater(
          setSection(body),
          throwsA(
            isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
          ),
          reason: '$body',
        );
      }
      await expectLater(
        setSection(<String, Object?>{
          'items': <String>['short1', 'nope'],
          'section': 'extras',
        }),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
      expect(
        await db.getVideoCollectionSectionOverrides(<String>['short1']),
        isEmpty,
      );
    });
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
      'Show (2020)',
      'Season 01',
      'Show (2020) - S01E02.mkv',
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
      'Show',
      'Season 00',
      'Show - S00E01.mkv',
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
      'The Movie (2016)',
      'The Movie (2016).mkv',
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

  group('摆放审计与拆并作品', () {
    late int season0;

    Future<void> setDuration(String uid, int minutes) async {
      final VideoBookRow row = (await db.getVideoBookByBookUid(uid))!;
      await db.upsertVideoFileSpec(
        VideoFileSpecsCompanion.insert(
          filePath: row.videoPath,
          fileSizeBytes: 1,
          fileModifiedAt: 1,
          probedAt: 1,
          probeVersion: 1,
          durationMs: Value<int?>(minutes * 60000),
        ),
      );
    }

    Future<void> pin(bool value, {String? uid}) =>
        (db.update(db.mediaCollectionItems)..where(
              (tbl) => uid == null
                  ? tbl.collectionId.equals(collectionId)
                  : tbl.entryKey.equals(uid),
            ))
            .write(MediaCollectionItemsCompanion(pinnedByUser: Value(value)));

    Future<Set<String>> members(int id) async => <String>{
      for (final MediaCollectionItemRow item in await db.getCollectionItems(id))
        item.entryKey,
    };

    Future<Map<Object?, Object?>> regroup(Map<String, Object?> body) async =>
        await call('POST', '$kVideoOrganizeCtlRoot/regroup', body: body)
            as Map<Object?, Object?>;

    setUp(() async {
      // 一部 100 分钟的剧场版被挂成《Show》的特别篇 S00E02；ep2 是真的特别篇。
      await addVideo('movie', 'Show/Season 00/Show - S00E02.mkv');
      await db.addToCollection(
        collectionId,
        MediaKind.video,
        'movie',
        userIntent: false,
      );
      season0 = (await db.getVideoMetadataSeasons(
        workId,
      )).firstWhere((VideoMetadataSeasonRow s) => s.seasonNumber == 0).id;
      await addEpisode(season0, 2, bookUid: 'movie');
      await setDuration('ep1', 24);
      await setDuration('ep2', 25);
      await setDuration('movie', 100);
      await db.setVideoEpisodeBindingOverride(
        'movie',
        seasonNumber: 0,
        episodeNumber: 2,
      );
      // 外层 setUp 按用户意图加的成员是 pinned；这里当作扫描归组的（不 pin）。
      await pin(false);
    });

    test('审计只报电影长度的特别篇文件，带正片时长基线', () async {
      final Map<Object?, Object?> result =
          await call('GET', '$kVideoOrganizeCtlRoot/audit')
              as Map<Object?, Object?>;
      expect(jsonDecode(jsonEncode(result['findings'])), <Object?>[
        <String, Object?>{
          'kind': 'feature_in_specials',
          'work': 'collection:$collectionId',
          'workTitle': 'Show',
          'uid': 'movie',
          'title': 'Show - S00E02',
          'boundTo': 'S00E02',
          'durationMinutes': 100,
          'episodeMinutes': 24,
          'path': 'Show/Season 00/Show - S00E02.mkv',
        },
      ]);
      expect(jsonEncode(result), isNot(contains(root.path)));
      expect(result.containsKey('unknownDuration'), isFalse);
    });

    test('detail：给出每部作品挂在第 0 季的全部文件与作品事实（给模型判断用）', () async {
      // 时长判据不报的短特别篇也要在清单里。
      await setDuration('movie', 24);
      final Map<Object?, Object?> result =
          await call(
                'GET',
                '$kVideoOrganizeCtlRoot/audit',
                query: const <String, String>{'detail': 'true'},
              )
              as Map<Object?, Object?>;
      expect(result['findings'], isEmpty);
      final List<Object?> works =
          jsonDecode(jsonEncode(result['works'])) as List<Object?>;
      final Map<String, Object?> work = works.single! as Map<String, Object?>;
      expect(work['work'], 'collection:$collectionId');
      expect(work['title'], 'Show');
      expect(work['episodeMinutes'], 24);
      expect(work['localRegularFiles'], 1);
      // 正片里已绑着本机文件的集：模型判 episode 时要避开。
      expect(work['occupied'], <String, Object?>{
        '1': <int>[1],
      });
      expect((work['seasons']! as Map<String, Object?>).keys, contains('1'));
      // 时长判据一个都不报，清单里两个第 0 季文件都在（按 uid 排）。
      final List<Object?> files = work['files']! as List<Object?>;
      expect(
        <Object?>[
          for (final Object? f in files) (f! as Map<String, Object?>)['uid'],
        ],
        <String>['ep2', 'movie'],
      );
      final Map<String, Object?> file = files[1]! as Map<String, Object?>;
      expect(file['path'], 'Show/Season 00/Show - S00E02.mkv');
      expect(file['minutes'], 24);
      expect(file['boundTo'], 'S00E02');
      expect(jsonEncode(result), isNot(contains(root.path)));
      // 不带 detail 时不输出。
      expect(
        (await call('GET', '$kVideoOrganizeCtlRoot/audit')
                as Map<Object?, Object?>)
            .containsKey('works'),
        isFalse,
      );
    });

    test('全库联表：一次看全文件 → 作品 → 季集 → 时长 → 目录，可筛选分页', () async {
      Future<Map<Object?, Object?>> files([
        Map<String, String> query = const <String, String>{},
      ]) async =>
          await call('GET', '$kVideoOrganizeCtlRoot/files', query: query)
              as Map<Object?, Object?>;
      final Map<Object?, Object?> all = await files();
      expect(all['columns'], <String>[
        'uid',
        'work',
        'boundTo',
        'minutes',
        'path',
      ]);
      expect(all['total'], 3);
      expect(jsonDecode(jsonEncode(all['works'])), <String, Object?>{
        'collection:$collectionId': <String, Object?>{
          'title': 'Show',
          'type': 'tv',
        },
      });
      expect(jsonEncode(all), isNot(contains(root.path)));
      List<Object?> uids(Map<Object?, Object?> r) => <Object?>[
        for (final Object? row in r['rows']! as List<Object?>)
          (row! as List<Object?>)[0],
      ];
      expect(uids(all).toSet(), <String>{'ep1', 'ep2', 'movie'});

      final Map<Object?, Object?> specials = await files(<String, String>{
        'season': '0',
        'minMinutes': '60',
      });
      expect(jsonDecode(jsonEncode(specials['rows'])), <Object?>[
        <Object?>[
          'movie',
          'collection:$collectionId',
          'S00E02',
          100,
          'Show/Season 00/Show - S00E02.mkv',
        ],
      ]);
      expect(uids(await files(<String, String>{'q': 's00e02'})), <String>[
        'movie',
      ]);
      expect((await files(<String, String>{'type': 'movie'}))['total'], 0);
      expect((await files(<String, String>{'unbound': 'true'}))['total'], 0);

      final Map<Object?, Object?> page = await files(<String, String>{
        'limit': '2',
      });
      expect(page['rows'], hasLength(2));
      expect(page['nextOffset'], 2);
      final Map<Object?, Object?> rest = await files(<String, String>{
        'limit': '2',
        'offset': '2',
      });
      expect(rest['rows'], hasLength(1));
      expect(rest.containsKey('nextOffset'), isFalse);
    });

    test('缺时长的第 0 季文件现探；探不出的计入 unknownDuration，不当成没问题', () async {
      // 规格缓存是懒探的：电影还没被探过。
      final String moviePath = (await db.getVideoBookByBookUid(
        'movie',
      ))!.videoPath;
      await db.deleteVideoFileSpec(moviePath);
      final Map<Object?, Object?> cold =
          await call('GET', '$kVideoOrganizeCtlRoot/audit')
              as Map<Object?, Object?>;
      expect(cold['findings'], isEmpty);
      expect(cold['unknownDuration'], 1);

      final List<List<String>> probed = <List<String>>[];
      routes = buildVideoOrganizeCtlRoutesFor(
        database: () => db,
        organizer: () => service,
        probeDurations: (List<String> paths) async {
          probed.add(paths);
          await setDuration('movie', 100);
        },
      );
      // probe=false（库管家预估）：只用已有缓存，不探。
      final Map<Object?, Object?> cached =
          await call(
                'GET',
                '$kVideoOrganizeCtlRoot/audit',
                query: const <String, String>{'probe': 'false'},
              )
              as Map<Object?, Object?>;
      expect(probed, isEmpty);
      expect(cached['unknownDuration'], 1);
      final Map<Object?, Object?> warm =
          await call('GET', '$kVideoOrganizeCtlRoot/audit')
              as Map<Object?, Object?>;
      // 只探缺时长的第 0 季文件，不把整库排进去。
      expect(probed, <List<String>>[
        <String>[moviePath],
      ]);
      expect(
        <Object?>[
          for (final Object? f in warm['findings']! as List<Object?>)
            (f! as Map)['uid'],
        ],
        <String>['movie'],
      );
      expect(warm.containsKey('unknownDuration'), isFalse);
    });

    test('合集里的本机文件全是电影长度的特别篇：报 features_only_work', () async {
      await db.removeFromCollection(collectionId, MediaKind.video, 'ep1');
      await (db.update(
        db.videoMetadataEpisodes,
      )..where((tbl) => tbl.bookUid.equals('ep1'))).write(
        const VideoMetadataEpisodesCompanion(bookUid: Value<String?>(null)),
      );
      final Map<Object?, Object?> result =
          await call('GET', '$kVideoOrganizeCtlRoot/audit')
              as Map<Object?, Object?>;
      final List<Object?> findings = result['findings']! as List<Object?>;
      // 没有本机正片，也没有资料源记的正片时长 → 没有基线，只看 60 分钟下限。
      expect(findings, hasLength(1));
      expect((findings.single! as Map)['kind'], 'features_only_work');
      expect((findings.single! as Map).containsKey('episodeMinutes'), isFalse);
    });

    test('拆成独立作品：移出合集、解绑分集、清手动季集；撤销原样挪回', () async {
      final List<String> orderBefore = <String>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          item.entryKey,
      ];
      final Map<Object?, Object?> result = await regroup(<String, Object?>{
        'items': <String>['movie'],
        'to': 'standalone',
      });
      expect(jsonDecode(jsonEncode(result['moved'])), <Object?>[
        <String, Object?>{
          'uid': 'movie',
          'title': 'Show - S00E02',
          'from': 'collection:$collectionId',
          'to': 'book:movie',
        },
      ]);
      expect(await members(collectionId), <String>{'ep1', 'ep2'});
      expect(await db.getVideoMetadataEpisodesByBook('movie'), isEmpty);
      expect(await db.getVideoEpisodeBindingOverride('movie'), isNull);
      // 移出记了成员墓碑：重扫不按文件名把它并回去。
      expect(
        (await db.getAllCollectionMemberTombstones()).any(
          (CollectionMemberTombstoneRow t) => t.entryKey == 'movie',
        ),
        isTrue,
      );
      // 修好的文件不再出现在审计里。
      expect(
        (await call('GET', '$kVideoOrganizeCtlRoot/audit') as Map)['findings'],
        isEmpty,
      );

      final VideoRegroupRevert reverted = await revertVideoRegroup(
        db,
        jsonDecode(jsonEncode(result['previous'])),
      );
      expect(reverted, (reverted: 1, superseded: 0, failed: 0));
      expect(<String>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          item.entryKey,
      ], orderBefore);
      expect(await slotsOf('movie'), <String>['S0E2']);
      final VideoEpisodeBindingOverrideRow? pin = await db
          .getVideoEpisodeBindingOverride('movie');
      expect((pin?.seasonNumber, pin?.episodeNumber), (0, 2));
    });

    test('拆成独立作品后又被放进别的作品合集：撤销判为已被处理，不放回原合集', () async {
      final Map<Object?, Object?> result = await regroup(<String, Object?>{
        'items': <String>['movie'],
        'to': 'standalone',
      });
      await addVideo('other', 'Films/Other.mkv');
      final int films = await db.createMediaCollection(
        'Films',
        collectionType: 'playlist',
      );
      await db.addToCollection(films, MediaKind.video, 'other');
      await db.addToCollection(films, MediaKind.video, 'movie');
      final VideoRegroupRevert reverted = await revertVideoRegroup(
        db,
        jsonDecode(jsonEncode(result['previous'])),
      );
      expect(reverted, (reverted: 0, superseded: 1, failed: 0));
      expect(await members(collectionId), <String>{'ep1', 'ep2'});
      expect(await members(films), <String>{'other', 'movie'});
    });

    test('另组一部 / 并进已有作品；之后又被挪过的撤销保留现状', () async {
      final Map<Object?, Object?> created = await regroup(<String, Object?>{
        'items': <String>['movie', 'ep2'],
        'to': 'new',
        'name': 'Show the Movie',
      });
      expect(created['created'], isTrue);
      final int newId = int.parse(
        '${created['target']}'.substring('collection:'.length),
      );
      expect(await members(newId), <String>{'movie', 'ep2'});
      expect(await members(collectionId), <String>{'ep1'});

      // 再把 ep2 并回原作品：第一次挪动的撤销对 ep2 已不适用。
      final Map<Object?, Object?> back = await regroup(<String, Object?>{
        'items': <String>['ep2'],
        'to': 'collection:$collectionId',
      });
      expect((back['moved']! as List<Object?>), hasLength(1));
      final VideoRegroupRevert reverted = await revertVideoRegroup(
        db,
        jsonDecode(jsonEncode(created['previous'])),
      );
      expect(reverted, (reverted: 1, superseded: 1, failed: 0));
      expect(await members(collectionId), <String>{'ep1', 'ep2', 'movie'});
      // 挪空的新建合集随之删除。
      expect(await db.getMediaCollectionById(newId), isNull);
    });

    test('拒绝：把作品挪空、未知视频、目标不对；用户亲手放的成员跳过', () async {
      Future<void> expectStatus(Map<String, Object?> body, int status) =>
          expectLater(
            regroup(body),
            throwsA(
              isA<CtlFailure>().having(
                (CtlFailure f) => f.status,
                'status',
                status,
              ),
            ),
          );

      await expectStatus(<String, Object?>{
        'items': <String>['ep1', 'ep2', 'movie'],
        'to': 'standalone',
      }, 409);
      await expectStatus(<String, Object?>{
        'items': <String>['nope'],
        'to': 'standalone',
      }, 404);
      await expectStatus(<String, Object?>{
        'items': <String>['movie'],
        'to': 'book:ep1',
      }, 400);
      await expectStatus(<String, Object?>{
        'items': <String>['movie'],
        'to': 'new',
        'name': '  ',
      }, 400);
      expect(await members(collectionId), <String>{'ep1', 'ep2', 'movie'});

      // 用户亲手放进合集的成员（pinned）不由这条操作移出。
      await pin(true, uid: 'ep2');
      final Map<Object?, Object?> result = await regroup(<String, Object?>{
        'items': <String>['ep2'],
        'to': 'standalone',
      });
      expect(result['moved'], isEmpty);
      expect(jsonDecode(jsonEncode(result['skipped'])), <Object?>[
        <String, Object?>{'uid': 'ep2', 'reason': 'pinned_by_user'},
      ]);
      expect(result.containsKey('previous'), isFalse);
    });
  });
}
