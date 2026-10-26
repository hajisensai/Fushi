import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_music.dart';

import '../helpers/music_ctl_fakes.dart';
import '../helpers/test_platform_services.dart';

/// 音乐域可撤销操作的往返测试（spec §11）：播放遥控（换队列 / 续播 / 暂停 / 上一首 /
/// 下一首 / 跳转）与加扫描根，各一条「执行 → 撤销 → 状态一致」，再加「执行后手动改过
/// → superseded、不覆盖」。以模型身份经 [OpInvoker] 调用，撤销载荷先过一遍 JSON。

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  bool moduleEnabled(ModuleId module) => true;
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late FakeMusicPlayer player;
  late OpCatalog catalog;
  late OpInvoker invoker;
  late List<CtlRoute> routes;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await seedMusicLibrary(db);
    player = FakeMusicPlayer();
    routes = buildMusicCtlRoutesFor(
      database: () => db,
      musicEnabled: () => true,
      player: () => player,
      scraper: () => FakeMusicScraper(db).port,
      removeSource: (FushiDatabase d, int id) async {
        await d.deleteMediaSource(id);
      },
      jobs: MusicScrapeJobs(),
    );
    final OpContext context = OpContext(ref: _Ref(_TestAppModel()));
    catalog = OpCatalog.build(
      routes,
      describeMusicOps(OpDescribeKit(context, routes)),
    );
    invoker = OpInvoker(catalog);
  });

  tearDown(() => db.close());

  Future<OpInvocation> run(String id, [Map<String, Object?>? args]) {
    final FushiOp op = catalog[id]!;
    return invoker.invoke(
      id,
      args ?? const <String, Object?>{},
      caller: OpCaller.model,
      captureUndo: true,
      grantedGates: <String>{
        for (final OpParam g in op.spec.gateParams) g.name,
      },
    );
  }

  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  List<String> queue() => <String>[
    for (final MusicPlayItem item in player.queue) item.trackUid,
  ];
  String? currentUid() => player.current?.trackUid;

  test('目录里音乐域每条路由都有描述，读写分级与撤销声明一致', () {
    expect(catalog.ops, hasLength(routes.length));
    for (final FushiOp op in catalog.ops) {
      if (op.risk == OpRisk.write) expect(op.undo, isNotNull, reason: op.id);
      if (op.risk != OpRisk.write) expect(op.undo, isNull, reason: op.id);
    }
    expect(catalog['music.scrape.start']!.longRunning, isTrue);
  });

  group('播放遥控', () {
    test('从空闲换队列播放 → 撤销 = 停在暂停', () async {
      final OpInvocation played = await run(
        'music.player.play',
        <String, Object?>{'album': 'al-1'},
      );
      expect(player.playing, isTrue);
      expect(await undo(played), OpUndoStatus.done);
      expect(player.playing, isFalse);
    });

    test('换队列 → 撤销换回原队列、原曲目与原播放状态', () async {
      await player.playQueue(<MusicPlayItem>[
        for (final String uid in <String>['t-3', 't-4'])
          musicPlayItemOf((await db.getMusicTrack(uid))!),
      ], startIndex: 1);
      await player.pause();
      final OpInvocation played = await run(
        'music.player.play',
        <String, Object?>{'album': 'al-1'},
      );
      expect(queue(), <String>['t-1', 't-2']);
      expect(await undo(played), OpUndoStatus.done);
      expect(queue(), <String>['t-3', 't-4']);
      expect(currentUid(), 't-4');
      expect(player.playing, isFalse);
    });

    test('暂停 → 撤销续播；暂停后用户又换了歌 → superseded、不动', () async {
      await run('music.player.play', <String, Object?>{'album': 'al-1'});
      final OpInvocation paused = await run('music.player.pause');
      expect(player.playing, isFalse);
      expect(await undo(paused), OpUndoStatus.done);
      expect(player.playing, isTrue);

      final OpInvocation pausedAgain = await run('music.player.pause');
      await player.skipNext(); // 用户手动切到下一首
      expect(await undo(pausedAgain), OpUndoStatus.superseded);
      expect(currentUid(), 't-2');
    });

    test('下一首 / 上一首 / 跳转 → 撤销跳回原曲', () async {
      await run('music.player.play', <String, Object?>{'album': 'al-2'});
      final OpInvocation next = await run('music.player.next');
      expect(currentUid(), 't-4');
      expect(await undo(next), OpUndoStatus.done);
      expect(currentUid(), 't-3');

      final OpInvocation jumped = await run(
        'music.player.jump',
        <String, Object?>{'index': 1},
      );
      expect(currentUid(), 't-4');
      final OpInvocation prev = await run('music.player.previous');
      expect(currentUid(), 't-3');
      expect(await undo(prev), OpUndoStatus.done);
      expect(currentUid(), 't-4');
      expect(await undo(jumped), OpUndoStatus.done);
      expect(currentUid(), 't-3');
    });

    test('续播（原来暂停）→ 撤销回到暂停；续播后用户暂停了 → superseded', () async {
      await run('music.player.play', <String, Object?>{'album': 'al-1'});
      await player.pause();
      final OpInvocation resumed = await run('music.player.play');
      expect(player.playing, isTrue);
      expect(await undo(resumed), OpUndoStatus.done);
      expect(player.playing, isFalse);

      final OpInvocation resumedAgain = await run('music.player.play');
      await player.pause();
      expect(await undo(resumedAgain), OpUndoStatus.superseded);
    });
  });

  group('扫描根', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_music_undo_');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('加文件夹 → 撤销移除它与它的曲目；已被移除 → superseded', () async {
      final OpInvocation added = await run(
        'music.source.add',
        <String, Object?>{'path': dir.path},
      );
      final int id = (added.result! as Map)['id'] as int;
      await db.customStatement(
        "UPDATE music_tracks SET source_id = $id WHERE track_uid = 't-4'",
      );
      expect(await undo(added), OpUndoStatus.done);
      expect(await db.getMediaSourceById(id), isNull);
      expect((await db.getMusicTrack('t-4'))!.deletedAt, isNotNull);
      expect((await db.getMusicTrack('t-3'))!.deletedAt, isNull);

      final OpInvocation again = await run(
        'music.source.add',
        <String, Object?>{'path': dir.path},
      );
      await db.deleteMediaSource((again.result! as Map)['id'] as int);
      expect(await undo(again), OpUndoStatus.superseded);
    });

    test('重复添加（没新建）→ 撤销什么也不删', () async {
      await run('music.source.add', <String, Object?>{'path': dir.path});
      final OpInvocation dup = await run('music.source.add', <String, Object?>{
        'path': dir.path,
      });
      expect((dup.result! as Map)['added'], isFalse);
      expect(await undo(dup), OpUndoStatus.done);
      expect(
        await db.getMediaSourcesByKind(SourceLibraryKind.music.dbValue),
        hasLength(1),
      );
    });
  });
}
