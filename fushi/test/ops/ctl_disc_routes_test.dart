import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/media/video/disc/disc_session_remote.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_disc_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_disc.dart';

import '../helpers/test_platform_services.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

/// 播放页原盘遥控面的假件：记下按过的键，按需抛遥控失败。
class _FakeDiscSession implements VideoDiscRemoteControl {
  final List<VideoDiscMenuKey> keys = <VideoDiscMenuKey>[];
  int exits = 0;
  VideoRemoteFailure? failure;
  bool active = true;

  @override
  VideoDiscSessionSnapshot? discSession() => active
      ? const VideoDiscSessionSnapshot(
          bookUid: 'disc1-a',
          title: 'Movie',
          discType: VideoDiscType.bluray,
          remote: false,
          navigationSupported: true,
          menuStarting: false,
          menuActive: true,
          titleReady: false,
          discTitle: 0,
        )
      : null;

  @override
  Future<void> discMenuKey(VideoDiscMenuKey key) async {
    final VideoRemoteFailure? f = failure;
    if (f != null) throw f;
    keys.add(key);
  }

  @override
  Future<void> exitDiscSession() async => exits++;
}

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
  late FushiDatabase db;
  late Directory dir;
  late List<CtlRoute> routes;
  late _FakeDiscSession? session;
  late List<(DiscRef, int?)> opened;
  late int collectionId;
  DiscMenuUnavailableReason? probeResult;
  bool enabled = true;
  bool readonly = false;

  /// 一张蓝光盘：`<root>/BDMV/PLAYLIST/<names>.mpls` + `index.bdmv`（[uhd] 决定版本号）。
  String makeBluray(String name, List<String> playlists, {bool uhd = false}) {
    final String root = p.join(dir.path, name);
    final Directory playlist = Directory(p.join(root, 'BDMV', 'PLAYLIST'))
      ..createSync(recursive: true);
    File(
      p.join(root, 'BDMV', 'index.bdmv'),
    ).writeAsStringSync(uhd ? 'INDX0300' : 'INDX0200');
    for (final String mpls in playlists) {
      File(p.join(playlist.path, mpls)).writeAsBytesSync(<int>[0]);
    }
    return root;
  }

  Future<void> addVideo(String uid, String path, {int? lastPlayedAt}) =>
      db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>(path),
          lastPlayedAt: Value<int?>(lastPlayedAt),
        ),
      );

  setUp(() async {
    enabled = true;
    readonly = false;
    probeResult = null;
    session = _FakeDiscSession();
    opened = <(DiscRef, int?)>[];
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('fushi_disc_ctl_');
    final String disc1 = makeBluray('Disc 1', <String>[
      '00001.mpls',
      '00002.mpls',
    ], uhd: true);
    final String disc2 = makeBluray('Disc 2', <String>['00003.mpls']);
    await addVideo(
      'disc1-a',
      p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls'),
      lastPlayedAt: 10,
    );
    await addVideo(
      'disc1-b',
      p.join(disc1, 'BDMV', 'PLAYLIST', '00002.mpls'),
      lastPlayedAt: 20,
    );
    await addVideo('disc2-a', p.join(disc2, 'BDMV', 'PLAYLIST', '00003.mpls'));
    // 盘根已不在（移动硬盘没插）：规格退回路径判据。
    await addVideo(
      'gone-a',
      p.join(dir.path, 'Gone', 'BDMV', 'PLAYLIST', '00001.mpls'),
    );
    await addVideo('plain', p.join(dir.path, 'movie.mkv'));
    collectionId = await db.createMediaCollection('Box');
    await db.upsertCollectionItemAt(
      collectionId,
      MediaKind.video.dbValue,
      'disc1-b',
      0,
    );
    routes = buildDiscCtlRoutesFor(
      database: () => db,
      videoEnabled: () => enabled,
      isReadonly: () => readonly,
      probe: (DiscRef disc) async => probeResult,
      open: (DiscRef disc, int? collection) async =>
          opened.add((disc, collection)),
      session: () => session,
      reasonText: (DiscMenuUnavailableReason r) => 'reason:${r.name}',
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String> query = const <String, String>{},
  }) {
    final CtlRoute route = routes.singleWhere(
      (CtlRoute r) => r.method == method && r.pattern == pattern,
    );
    return route.handler(
      CtlCall(method: method, path: pattern, body: body, query: query),
    );
  }

  Map<String, Object?> asMap(Object? v) => (v! as Map).cast<String, Object?>();
  List<Map<String, Object?>> discs(Object? v) => <Map<String, Object?>>[
    for (final Object? row in asMap(v)['discs']! as List<Object?>) asMap(row),
  ];

  test('路由都在 /api/admin/disc 下、method + pattern 唯一', () {
    final Set<String> keys = <String>{};
    for (final CtlRoute r in routes) {
      expect(r.pattern, startsWith('$kDiscCtlRoot/'));
      expect(keys.add('${r.method} ${r.pattern}'), isTrue);
    }
  });

  group('列盘', () {
    test('一张盘一行、自然序；开盘成员是最近看过的那条；规格与在线状态', () async {
      final List<Map<String, Object?>> rows = discs(
        await call('GET', '$kDiscCtlRoot/discs'),
      );
      expect(rows.map((Map<String, Object?> r) => r['label']), <String>[
        'Disc 1',
        'Disc 2',
        'Gone',
      ]);
      final Map<String, Object?> disc1 = rows[0];
      expect(disc1['uid'], 'disc1-b');
      expect(disc1['format'], 'uhdBluray');
      expect(disc1['present'], isTrue);
      expect(disc1['collectionId'], collectionId);
      expect(disc1['lastPlayedAt'], 20);
      expect(rows[1]['format'], 'bluray');
      expect(rows[1].containsKey('collectionId'), isFalse);
      expect(rows[2]['present'], isFalse);
      expect(rows[2]['format'], 'bluray');
    });

    test('search 按盘名 / 标题过滤', () async {
      final List<Map<String, Object?>> rows = discs(
        await call(
          'GET',
          '$kDiscCtlRoot/discs',
          query: const <String, String>{'search': 'disc 2'},
        ),
      );
      expect(rows.single['uid'], 'disc2-a');
    });

    test('视频模块关闭 → 422', () async {
      enabled = false;
      expect(call('GET', '$kDiscCtlRoot/discs'), _status(422));
    });
  });

  group('开盘', () {
    test('任一成员 uid 都开这张盘（最近看过的成员 + 主合集）', () async {
      final Map<String, Object?> result = asMap(
        await call(
          'POST',
          '$kDiscCtlRoot/open',
          body: const <String, Object?>{'uid': 'disc1-a'},
        ),
      );
      expect(result['opened'], isTrue);
      expect(result['uid'], 'disc1-b');
      expect(opened, hasLength(1));
      expect(opened.single.$1.book.bookUid, 'disc1-b');
      expect(opened.single.$2, collectionId);
    });

    test('本机开不了菜单 → 501 带原因码与说明，不开页面', () async {
      probeResult = DiscMenuUnavailableReason.mobileBdj;
      await expectLater(
        call(
          'POST',
          '$kDiscCtlRoot/open',
          body: const <String, Object?>{'uid': 'disc2-a'},
        ),
        throwsA(
          isA<CtlFailure>()
              .having((CtlFailure f) => f.status, 'status', 501)
              .having((CtlFailure f) => f.code, 'code', 'mobileBdj')
              .having(
                (CtlFailure f) => f.message,
                'message',
                'reason:mobileBdj',
              ),
        ),
      );
      expect(opened, isEmpty);
    });

    test('不是原盘 → 400；不存在 → 404；缺 uid → 400；只读 → 422', () async {
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/open',
          body: const <String, Object?>{'uid': 'plain'},
        ),
        _status(400),
      );
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/open',
          body: const <String, Object?>{'uid': 'nope'},
        ),
        _status(404),
      );
      expect(call('POST', '$kDiscCtlRoot/open'), _status(400));
      readonly = true;
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/open',
          body: const <String, Object?>{'uid': 'disc2-a'},
        ),
        _status(422),
      );
    });
  });

  group('会话内', () {
    test('状态：有会话带快照，没有时 active=false', () async {
      final Map<String, Object?> status = asMap(
        await call('GET', '$kDiscCtlRoot/session'),
      );
      expect(status['active'], isTrue);
      expect(status['type'], 'bluray');
      expect(status['menuActive'], isTrue);
      session!.active = false;
      expect(
        asMap(await call('GET', '$kDiscCtlRoot/session'))['active'],
        isFalse,
      );
      session = null;
      expect(
        asMap(await call('GET', '$kDiscCtlRoot/session'))['active'],
        isFalse,
      );
    });

    test('菜单键：按枚举名（大小写不敏感）转给播放页', () async {
      await call(
        'POST',
        '$kDiscCtlRoot/session/key',
        body: const <String, Object?>{'key': 'up'},
      );
      final Map<String, Object?> r = asMap(
        await call(
          'POST',
          '$kDiscCtlRoot/session/key',
          body: const <String, Object?>{'key': 'TOPMENU'},
        ),
      );
      expect(session!.keys, <VideoDiscMenuKey>[
        VideoDiscMenuKey.up,
        VideoDiscMenuKey.topMenu,
      ]);
      expect(r['key'], 'topMenu');
      expect(asMap(r['session'])['bookUid'], 'disc1-a');
    });

    test('未知键 → 400；没有会话 → 409；页面报忙 → 409 / 不支持 → 501', () async {
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/session/key',
          body: const <String, Object?>{'key': 'jump'},
        ),
        _status(400),
      );
      session!.failure = const VideoRemoteFailure('busy', '还在启动');
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/session/key',
          body: const <String, Object?>{'key': 'select'},
        ),
        _status(409),
      );
      session!.failure = const VideoRemoteFailure('unsupported', '不能导航');
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/session/key',
          body: const <String, Object?>{'key': 'select'},
        ),
        _status(501),
      );
      session!.active = false;
      expect(
        call(
          'POST',
          '$kDiscCtlRoot/session/key',
          body: const <String, Object?>{'key': 'select'},
        ),
        _status(409),
      );
      expect(call('POST', '$kDiscCtlRoot/session/exit'), _status(409));
    });

    test('退出：走播放页的退出汇聚点', () async {
      final Map<String, Object?> r = asMap(
        await call('POST', '$kDiscCtlRoot/session/exit'),
      );
      expect(r['exited'], isTrue);
      expect(session!.exits, 1);
    });
  });

  test('目录：碟片域每条路由都有描述，全部 read、带视频模块门', () {
    final OpContext context = OpContext(ref: _Ref(_TestAppModel()));
    final OpCatalog catalog = OpCatalog.build(
      routes,
      describeDiscOps(OpDescribeKit(context, routes)),
    );
    expect(catalog.ops, hasLength(routes.length));
    for (final FushiOp op in catalog.ops) {
      expect(op.risk, OpRisk.read, reason: op.id);
      expect(op.undo, isNull, reason: op.id);
      expect(op.availability, isNotNull, reason: op.id);
      expect(op.id, startsWith('disc.'));
    }
  });
}
