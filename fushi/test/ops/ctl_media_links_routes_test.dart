import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_media_links_routes.dart';
import 'package:fushi/src/ops/op_context.dart';

import 'book_metadata_test_fixture.dart';

Matcher _ctlFailure(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

/// 作品图谱 / 人物路由：内存库上走真实数据层（建议的确认 / 否决、人物图）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late BookMetaTestModel model;
  late List<CtlRoute> routes;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_links_');
    model = BookMetaTestModel(db, prefs, thumbs);
    routes = buildMediaLinksCtlRoutes(OpContext(ref: BookMetaRef(model)));
    await seedBook(db, '原作');
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/anime',
        title: 'アニメ',
        videoPath: '/v/anime.mkv',
      ),
    );
  });

  tearDown(() async {
    mediaLinkInferOverride = null;
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

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

  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: '原作');
  const MediaLinkEndpoint video = (
    kind: MediaLinkKind.videoEpisode,
    key: 'video/anime',
  );

  Future<void> suggest() => db.proposeMediaLink(
    relation: MediaLinkRelation.adaptation,
    from: book,
    to: video,
    source: 'mal',
    confidence: 0.8,
    reason: 'MAL source material',
  );

  Future<MediaLinkRow?> row() => db.mediaLinkById(
    mediaLinkIdFor(MediaLinkRelation.adaptation, book, video),
  );

  Map<String, String> self(String wire) => <String, String>{'endpoint': wire};

  test('ls：站在一端看另一端，带来源 / 置信度 / 理由；state 过滤', () async {
    await suggest();
    final Map<String, Object?> listed =
        (await call(
              'GET',
              '$kMediaLinksCtlRoot/:endpoint',
              params: self('video_episode:video/anime'),
            ))!
            as Map<String, Object?>;
    expect(listed['title'], 'アニメ');
    final Map<String, Object?> link =
        (listed['links']! as List<Object?>).single! as Map<String, Object?>;
    expect(link['state'], 'suggested');
    expect(link['relation'], 'adaptation');
    expect(link['otherIs'], 'from');
    expect((link['other']! as Map<String, Object?>)['endpoint'], 'book:原作');
    expect(link['reason'], 'MAL source material');
    final Map<String, Object?> confirmed =
        (await call(
              'GET',
              '$kMediaLinksCtlRoot/:endpoint',
              params: self('book:原作'),
              query: <String, String>{'state': 'confirmed'},
            ))!
            as Map<String, Object?>;
    expect(confirmed['links'], isEmpty);
  });

  test('ls：端点格式不对 400、本机没有 404、模块关掉 422', () async {
    expect(
      () => call('GET', '$kMediaLinksCtlRoot/:endpoint', params: self('原作')),
      _ctlFailure(400),
    );
    expect(
      () =>
          call('GET', '$kMediaLinksCtlRoot/:endpoint', params: self('book:没有')),
      _ctlFailure(404),
    );
    model.disabled.add(ModuleId.video);
    expect(
      () => call(
        'GET',
        '$kMediaLinksCtlRoot/:endpoint',
        params: self('video_episode:video/anime'),
      ),
      _ctlFailure(422),
    );
  });

  test('accept：建议 → 已确认；再接受 409；找不到另一端 404', () async {
    await suggest();
    final Map<String, Object?> accepted =
        (await call(
              'POST',
              '$kMediaLinksCtlRoot/:endpoint/accept',
              params: self('book:原作'),
              body: <String, Object?>{'other': 'video_episode:video/anime'},
            ))!
            as Map<String, Object?>;
    expect((accepted['link']! as Map<String, Object?>)['state'], 'confirmed');
    expect((await row())!.isUserConfirmed, isTrue);
    expect(
      () => call(
        'POST',
        '$kMediaLinksCtlRoot/:endpoint/accept',
        params: self('book:原作'),
        body: <String, Object?>{'other': 'video_episode:video/anime'},
      ),
      _ctlFailure(409),
    );
    expect(
      () => call(
        'POST',
        '$kMediaLinksCtlRoot/:endpoint/accept',
        params: self('book:原作'),
        body: <String, Object?>{'other': 'game:g1'},
      ),
      _ctlFailure(404),
    );
  });

  test('reject：建议 → 墓碑（之后不再出现在列表里）；已确认的不能当建议否决', () async {
    await suggest();
    await call(
      'POST',
      '$kMediaLinksCtlRoot/:endpoint/reject',
      params: self('book:原作'),
      body: <String, Object?>{
        'other': 'video_episode:video/anime',
        'relation': 'adaptation',
      },
    );
    expect((await row())!.deletedAt, isNotNull);

    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: video,
    );
    expect(
      () => call(
        'POST',
        '$kMediaLinksCtlRoot/:endpoint/reject',
        params: self('book:原作'),
        body: <String, Object?>{'other': 'video_episode:video/anime'},
      ),
      _ctlFailure(409),
    );
  });

  test('infer：回本轮新增的建议与是否走了 AI；音乐端点没有推断来源 422', () async {
    mediaLinkInferOverride = (OpContext _, MediaLinkEndpoint self) => () async {
      await suggest();
      return 1;
    };
    final Map<String, Object?> got =
        (await call(
              'POST',
              '$kMediaLinksCtlRoot/:endpoint/infer',
              params: self('book:原作'),
            ))!
            as Map<String, Object?>;
    expect(got['added'], 1);
    expect(got['ai'], isFalse);
    expect(got['suggestions'], hasLength(1));

    mediaLinkInferOverride = (OpContext _, MediaLinkEndpoint self) => null;
    await db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: 't1',
            path: '/m/t1.flac',
            title: 'OP',
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
    expect(
      () => call(
        'POST',
        '$kMediaLinksCtlRoot/:endpoint/infer',
        params: self('music_track:t1'),
      ),
      _ctlFailure(422),
    );
  });

  group('人物', () {
    setUp(() async {
      await db
          .into(db.videoMetadataPeople)
          .insert(
            VideoMetadataPeopleCompanion.insert(
              personKey: 'p1',
              name: '花澤香菜',
              updatedAt: 1,
            ),
          );
      await db
          .into(db.musicArtists)
          .insert(
            MusicArtistsCompanion.insert(
              artistUid: 'a1',
              name: '花澤香菜',
              addedAt: 1,
            ),
          );
    });

    test('ls 按名字搜；get 带「可能是同一人」建议', () async {
      final Map<String, Object?> listed =
          (await call(
                'GET',
                kPeopleCtlRoot,
                query: <String, String>{'search': '花澤'},
              ))!
              as Map<String, Object?>;
      expect(listed['total'], 2);
      final Map<String, Object?> page =
          (await call(
                'GET',
                '$kPeopleCtlRoot/:node',
                params: <String, String>{'node': 'ref:video:p1'},
              ))!
              as Map<String, Object?>;
      expect(page['name'], '花澤香菜');
      expect(
        ((page['suggestions']! as List<Object?>).single!
            as Map<String, Object?>)['node'],
        'ref:music:a1',
      );
      expect(
        () => call(
          'GET',
          '$kPeopleCtlRoot/:node',
          params: <String, String>{'node': 'ref:video:none'},
        ),
        _ctlFailure(404),
      );
    });

    test('same=true 合并；再 same=false = 取消合并；外部 id 合并的不能拆', () async {
      final Map<String, Object?> merged =
          (await call(
                'POST',
                '$kPeopleCtlRoot/:node/same',
                params: <String, String>{'node': 'ref:video:p1'},
                body: <String, Object?>{'other': 'ref:music:a1', 'same': true},
              ))!
              as Map<String, Object?>;
      expect(merged['previous'], isNull);
      expect(
        (await db.manualPersonBridge(
          'ref:video:p1',
          'ref:music:a1',
        ))!.deletedAt,
        isNull,
      );
      expect(
        () => call(
          'POST',
          '$kPeopleCtlRoot/:node/same',
          params: <String, String>{'node': 'ref:video:p1'},
          body: <String, Object?>{'other': 'ref:music:a1', 'same': true},
        ),
        _ctlFailure(409),
      );
      await call(
        'POST',
        '$kPeopleCtlRoot/:node/same',
        params: <String, String>{'node': 'ref:video:p1'},
        body: <String, Object?>{'other': 'ref:music:a1', 'same': false},
      );
      expect(
        (await db.manualPersonBridge(
          'ref:video:p1',
          'ref:music:a1',
        ))!.deletedAt,
        isNotNull,
      );
      expect(
        () => call(
          'POST',
          '$kPeopleCtlRoot/:node/same',
          params: <String, String>{'node': 'ref:video:p1'},
          body: <String, Object?>{'other': 'ref:music:a1'},
        ),
        _ctlFailure(400),
      );
    });
  });
}
