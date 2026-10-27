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

  Map<String, Object?> pick2(String relation, {String? selfIs}) =>
      <String, Object?>{
        ...pick,
        'relation': relation,
        if (selfIs != null) 'selfIs': selfIs,
      };

  test('风险级：四条 read、六条可撤销的 write', () {
    for (final String id in <String>[
      'links.candidates',
      'links.list',
      'people.list',
      'people.get',
    ]) {
      expect(catalog[id]!.risk, OpRisk.read, reason: id);
    }
    for (final String id in <String>[
      'links.accept',
      'links.reject',
      'links.add',
      'links.remove',
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

  // BUG-3802：AI 只能接受 / 否决 / 推断建议，用户点名「把 A 和 B 关联起来」时没有任何
  // 操作能做到（详情页「关联作品」对话框背后的手动连接从没进操作目录）。
  group('手动关联（links.candidates / links.add / links.remove）', () {
    int later() => DateTime.now().millisecondsSinceEpoch + 60000;

    test('候选按种类 + 标题找本机条目，给出 links.add 要的端点', () async {
      final OpInvocation found = await run(
        'links.candidates',
        <String, Object?>{'kind': 'video_episode', 'search': 'アニメ'},
      );
      final Map<Object?, Object?> r = found.result! as Map<Object?, Object?>;
      expect(r['total'], 1);
      expect((r['items']! as List<Object?>).single, <String, Object?>{
        'endpoint': 'video_episode:video/anime',
        'title': 'アニメ',
      });
    });

    test('改编：按 selfIs 定方向、恒为确认；撤销（执行前没有这一行）→ 墓碑', () async {
      final OpInvocation added = await run('links.add', <String, Object?>{
        'endpoint': 'video_episode:video/anime',
        'other': 'book:原作',
        'relation': 'adaptation',
        'selfIs': 'adaptation',
      });
      // 本条（动画）是改编 → 方向 原作 → 动画，与 linkId 同一身份。
      final MediaLinkRow row = (await db.mediaLinkById(linkId))!;
      expect(mediaLinkStateOf(row), MediaLinkState.confirmed);
      expect(row.source, MediaLinkSource.manual);
      expect(await undo(added), OpUndoStatus.done);
      expect(await state(), MediaLinkState.removed);
    });

    test('把一条建议手动连上 → 撤销恢复成原来的建议', () async {
      await suggest();
      final OpInvocation added = await run('links.add', <String, Object?>{
        'endpoint': 'book:原作',
        'other': 'video_episode:video/anime',
        'relation': 'adaptation',
        'selfIs': 'original',
      });
      expect(await state(), MediaLinkState.confirmed);
      expect(await undo(added), OpUndoStatus.done);
      final MediaLinkRow row = (await db.mediaLinkById(linkId))!;
      expect(mediaLinkStateOf(row), MediaLinkState.suggested);
      expect(row.source, 'mal');
    });

    test('关联后用户又移除了 → 撤销 superseded、不覆盖', () async {
      final OpInvocation added = await run(
        'links.add',
        pick2('adaptation', selfIs: 'original'),
      );
      await db.removeMediaLink(linkId, at: later());
      expect(await undo(added), OpUndoStatus.superseded);
      expect(await state(), MediaLinkState.removed);
    });

    test('same_work 无方向；参数不全 / 关系不合法时拒绝、不写库', () async {
      await run('links.add', pick2('same_work'));
      final MediaLinkId same = mediaLinkIdFor(
        MediaLinkRelation.sameWork,
        book,
        video,
      );
      expect(
        mediaLinkStateOf((await db.mediaLinkById(same))!),
        MediaLinkState.confirmed,
      );

      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        pick2('adaptation'), // 缺 selfIs
        pick2('theme_song'), // 两端不是音乐 + 视频
        pick2('soundtrack'), // 不在可手动连接的关系里
        <String, Object?>{
          'endpoint': 'book:原作',
          'other': 'book:不存在',
          'relation': 'same_work',
        },
      ]) {
        await expectLater(
          run('links.add', bad),
          throwsA(isA<CtlFailure>()),
          reason: '$bad',
        );
      }
      expect(await db.mediaLinkById(linkId), isNull);
    });

    test('移除确认的关联 → 撤销恢复成确认；建议不能当关联移除', () async {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: video,
        at: 5,
      );
      final OpInvocation removed = await run('links.remove', pick);
      expect(await state(), MediaLinkState.removed);
      expect(await undo(removed), OpUndoStatus.done);
      final MediaLinkRow row = (await db.mediaLinkById(linkId))!;
      expect(mediaLinkStateOf(row), MediaLinkState.confirmed);
      expect(row.createdAt, 5);

      await db.discardMediaLinkSuggestion(linkId);
      await db.removeMediaLink(linkId);
      await db.restoreMediaLinkSuggestion(linkId);
      await expectLater(run('links.remove', pick), throwsA(isA<CtlFailure>()));
    });
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
