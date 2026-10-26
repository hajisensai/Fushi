import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_media_links_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

import 'book_metadata_test_fixture.dart';

/// 作品图谱 / 人物写操作的撤销往返（数据层对称方法，不删用户数据）：经 `OpInvoker`
/// 以模型身份执行，撤销载荷先 JSON 往返。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late OpCatalog catalog;
  late OpInvoker invoker;

  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: '原作');
  const MediaLinkEndpoint video = (
    kind: MediaLinkKind.videoEpisode,
    key: 'video/anime',
  );
  final MediaLinkId linkId = mediaLinkIdFor(
    MediaLinkRelation.adaptation,
    book,
    video,
  );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_links_undo_');
    final BookMetaTestModel model = BookMetaTestModel(db, prefs, thumbs);
    final OpContext context = OpContext(ref: BookMetaRef(model));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
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

  Future<OpInvocation> run(String id, Map<String, Object?> args) =>
      invoker.invoke(
        id,
        args,
        caller: OpCaller.model,
        captureUndo: true,
        grantedGates: <String>{
          for (final OpParam g in catalog[id]!.spec.gateParams) g.name,
        },
      );

  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  Future<void> suggest() => db.proposeMediaLink(
    relation: MediaLinkRelation.adaptation,
    from: book,
    to: video,
    source: 'mal',
  );

  Future<MediaLinkState?> state() async {
    final MediaLinkRow? row = await db.mediaLinkById(linkId);
    return row == null ? null : mediaLinkStateOf(row);
  }

  const Map<String, Object?> pick = <String, Object?>{
    'endpoint': 'book:原作',
    'other': 'video_episode:video/anime',
  };

  test('风险级：三条 read、四条可撤销的 write', () {
    for (final String id in <String>[
      'links.list',
      'people.list',
      'people.get',
    ]) {
      expect(catalog[id]!.risk, OpRisk.read, reason: id);
    }
    for (final String id in <String>[
      'links.accept',
      'links.reject',
      'links.infer',
      'people.same',
    ]) {
      expect(catalog[id]!.risk, OpRisk.write, reason: id);
      expect(catalog[id]!.undo, isNotNull, reason: id);
    }
  });

  test('接受 → 撤销退回建议；接受后用户又删了 → superseded、墓碑保留', () async {
    await suggest();
    final OpInvocation accepted = await run('links.accept', pick);
    expect(await state(), MediaLinkState.confirmed);
    expect(await undo(accepted), OpUndoStatus.done);
    expect(await state(), MediaLinkState.suggested);

    final OpInvocation again = await run('links.accept', pick);
    await db.removeMediaLink(linkId);
    expect(await undo(again), OpUndoStatus.superseded);
    expect(await state(), MediaLinkState.removed);
  });

  test('不相关 → 撤销恢复成建议；之后用户又确认了 → superseded', () async {
    await suggest();
    final OpInvocation rejected = await run('links.reject', pick);
    expect(await state(), MediaLinkState.removed);
    expect(await undo(rejected), OpUndoStatus.done);
    expect(await state(), MediaLinkState.suggested);

    final OpInvocation again = await run('links.reject', pick);
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: video,
    );
    expect(await undo(again), OpUndoStatus.superseded);
    expect(await state(), MediaLinkState.confirmed);
  });

  test('查找相关作品 → 撤销删掉本轮新建议（不写墓碑）；用户已处理的保留', () async {
    mediaLinkInferOverride = (OpContext _, MediaLinkEndpoint self) => () async {
      await suggest();
      return 1;
    };
    final OpInvocation inferred = await run('links.infer', <String, Object?>{
      'endpoint': 'book:原作',
    });
    expect(await state(), MediaLinkState.suggested);
    expect(await undo(inferred), OpUndoStatus.done);
    expect(await db.mediaLinkById(linkId), isNull, reason: '不留墓碑，下次还能再提');

    final OpInvocation again = await run('links.infer', <String, Object?>{
      'endpoint': 'book:原作',
    });
    await db.confirmMediaLink(linkId);
    expect(await undo(again), OpUndoStatus.superseded);
    expect(await state(), MediaLinkState.confirmed);
  });

  group('同一人', () {
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

    Future<PersonIdentityBridgeRow?> bridge() =>
        db.manualPersonBridge('ref:video:p1', 'ref:music:a1');

    test('确认（执行前没有桥）→ 撤销删掉桥，建议重新出现', () async {
      final OpInvocation merged = await run('people.same', <String, Object?>{
        'node': 'ref:video:p1',
        'other': 'ref:music:a1',
        'same': true,
      });
      expect((await bridge())!.deletedAt, isNull);
      expect(await undo(merged), OpUndoStatus.done);
      expect(await bridge(), isNull);
    });

    test('否决一对之前确认过的 → 撤销恢复成确认（原 createdAt）', () async {
      await db.setManualPersonBridge(
        'ref:video:p1',
        'ref:music:a1',
        same: true,
        at: 5,
      );
      final OpInvocation split = await run('people.same', <String, Object?>{
        'node': 'ref:video:p1',
        'other': 'ref:music:a1',
        'same': false,
      });
      expect((await bridge())!.deletedAt, isNotNull);
      expect(await undo(split), OpUndoStatus.done);
      final PersonIdentityBridgeRow restored = (await bridge())!;
      expect(restored.deletedAt, isNull);
      expect(restored.createdAt, 5);
    });

    test('之后用户在人物页又改判 → superseded、不覆盖', () async {
      final OpInvocation merged = await run('people.same', <String, Object?>{
        'node': 'ref:video:p1',
        'other': 'ref:music:a1',
        'same': true,
      });
      await db.setManualPersonBridge(
        'ref:video:p1',
        'ref:music:a1',
        same: false,
        at: DateTime.now().millisecondsSinceEpoch + 1000,
      );
      expect(await undo(merged), OpUndoStatus.superseded);
      expect((await bridge())!.deletedAt, isNotNull);
    });
  });
}
