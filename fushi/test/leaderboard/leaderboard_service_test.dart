import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/media/source_library/source_library_privacy.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 假服务端：记下每个请求，按路径回固定形状。
class _FakeServer {
  final List<http.Request> requests = <http.Request>[];
  String accountId = 'ServerAccount001';
  String nickname = 'N';
  String? avatar;

  /// `/v1/me` 永不回（模拟 iOS 冷启动网络还没就绪：请求超时）。
  bool hangMe = false;
  final Set<String> shelfWorks = <String>{};
  bool failShelf = false;

  /// 依次消费的书架请求状态码（空 = 正常处理）。
  final List<int> shelfStatuses = <int>[];

  /// 非 reset 且带 put 的书架请求一律回 413 shelf_full。
  bool shelfFull = false;

  /// 非空时书架请求到达后等它完成才回（模拟慢请求）；[shelfArrived] 在请求到达时完成。
  Completer<void>? shelfGate;
  Completer<void> shelfArrived = Completer<void>();

  /// 书架请求永不回（模拟网络挂死）。
  bool hangShelf = false;

  /// 非空时每个响应带 `Date` 头 = 本地时钟 + 该偏移。
  int Function()? serverNowMs;

  int get shelfCount => shelfWorks.length;

  /// 本账户的上传设备是另一台（直到有请求带 claim 接管）。
  bool ownedElsewhere = false;

  /// 账户已在别处删除 / 本设备已被解绑：带 X-Fushi-Account 的请求一律 401
  /// unknown_account。
  bool accountGone = false;

  List<http.Request> at(String path) =>
      requests.where((http.Request r) => r.url.path == path).toList();

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: <String, String>{
      'content-type': 'application/json',
      if (serverNowMs != null)
        'date': HttpDate.format(
          DateTime.fromMillisecondsSinceEpoch(serverNowMs!(), isUtc: true),
        ),
    },
  );

  Map<String, dynamic> _self() => <String, dynamic>{
    'id': accountId,
    'nickname': nickname,
    'discriminator': 7,
    'avatar': avatar,
    'visibility': 'public',
    'createdAt': 1,
    'shelfCount': shelfCount,
    'emailVerified': true,
    'uploadDevice': !ownedElsewhere,
  };

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final String path = r.url.path;
    if (accountGone && r.headers.containsKey('X-Fushi-Account')) {
      return _json(<String, dynamic>{'error': 'unknown_account'}, 401);
    }
    if (path == '/v1/email/code') {
      return _json(<String, dynamic>{'sent': true}, 202);
    }
    if (path == '/v1/register') return _json(_self(), 201);
    if (path == '/v1/login') return _json(_self());
    if (path == '/v1/me' && r.method == 'DELETE') {
      return _json(<String, dynamic>{'ok': true});
    }
    if (path == '/v1/me') {
      if (hangMe) return Completer<http.Response>().future;
      return _json(_self());
    }
    if (path == '/v1/me/avatar') {
      return _json(<String, dynamic>{'avatar': '/img/avatars/x.jpg'});
    }
    if (path == '/v1/shelf') {
      if (!shelfArrived.isCompleted) shelfArrived.complete();
      if (hangShelf) return Completer<http.Response>().future;
      final Completer<void>? gate = shelfGate;
      if (gate != null) await gate.future;
      if (failShelf) return _json(<String, dynamic>{'error': 'boom'}, 500);
      if (shelfStatuses.isNotEmpty) {
        final int status = shelfStatuses.removeAt(0);
        if (status != 200) {
          return _json(<String, dynamic>{'error': 'e$status'}, status);
        }
      }
      final Map<String, dynamic> body =
          (jsonDecode(utf8.decode(r.bodyBytes)) as Map<Object?, Object?>)
              .cast<String, dynamic>();
      if (ownedElsewhere) {
        if (body['claim'] != true) {
          return _json(<String, dynamic>{
            'error': 'upload_owned_by_other_device',
          }, 409);
        }
        ownedElsewhere = false;
      }
      final List<Object?> put = body['put'] as List<Object?>;
      if (shelfFull && body['reset'] != true && put.isNotEmpty) {
        return _json(<String, dynamic>{'error': 'shelf_full'}, 413);
      }
      if (body['reset'] == true) shelfWorks.clear();
      shelfWorks.removeAll((body['remove'] as List<Object?>).cast<String>());
      String workOf(Object? e) => 'W_${(e! as Map<Object?, Object?>)['title']}';
      shelfWorks.addAll(put.map(workOf));
      return _json(<String, dynamic>{
        'works': <Map<String, dynamic>>[
          for (int i = 0; i < put.length; i++)
            <String, dynamic>{
              'i': i,
              'workId': workOf(put[i]),
              'needsCover': false,
            },
        ],
        'shelfCount': shelfCount,
      });
    }
    return _json(<String, dynamic>{'error': 'not_found'}, 404);
  }
}

LocalShelf _shelf(int n) => LocalShelf(
  entries: <LocalShelfEntry>[
    for (int i = 0; i < n; i++)
      LocalShelfEntry(
        localKey: 'book:$i',
        upload: ShelfEntryUpload(
          kind: LeaderboardKind.book,
          refs: <String>['t:b$i|'],
          title: 'b$i',
          finished: false,
          chars: i + 1,
        ),
      ),
  ],
  daily: <DailyCharsUpload>[DailyCharsUpload(date: '2026-09-01', chars: 3)],
);

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FakeServer server;
  late int now;
  late int backfills;
  late bool backfillThrows;
  late LocalShelf shelf;
  late List<DateTime> builtAt;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lb_service_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    server = _FakeServer();
    now = 1700000000000;
    backfills = 0;
    backfillThrows = false;
    shelf = _shelf(2);
    builtAt = <DateTime>[];
  });
  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  LeaderboardService service({
    int profileId = 1,
    Duration timeout = kLeaderboardRequestTimeout,
  }) => LeaderboardService(
    database: () => db,
    supportRoot: () async => root,
    profileId: () async => profileId,
    httpClientFactory: () async => MockClient(server.handle),
    defaultBaseUrl: Uri.parse('https://rank.example'),
    clockMs: () => now,
    requestTimeout: timeout,
    uploadTimeout: timeout,
    shelfBuilder: (FushiDatabase _, int __, DateTime at) async {
      builtAt.add(at);
      return shelf;
    },
    isbnBackfill: (FushiDatabase _) async {
      backfills++;
      if (backfillThrows) throw StateError('broken OPF');
      return 0;
    },
    avatarEncoder: (String path) async =>
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff]),
  );

  LeaderboardStore store([int profileId = 1]) =>
      LeaderboardStore(supportRoot: root, profileId: profileId);

  test('未开启：load 不发请求，后台同步是 no-op', () async {
    final LeaderboardService s = service();
    await s.load();
    expect(s.status, LeaderboardStatus.disabled);
    expect(s.client, isNull);
    await s.maybeSyncInBackground();
    expect(server.requests, isEmpty);
    expect(backfills, 0);
    expect(() => s.exportRecoveryCode(), throwsStateError);
  });

  test('请求验证码：注册 / 登录两种 purpose，不签名', () async {
    final LeaderboardService s = service();
    await s.requestEmailCode('a@b.cd', forLogin: false, lang: 'zh');
    await s.requestEmailCode('a@b.cd', forLogin: true);
    final List<http.Request> reqs = server.at('/v1/email/code');
    expect(reqs, hasLength(2));
    expect(
      reqs.map(
        (http.Request r) =>
            (jsonDecode(utf8.decode(r.bodyBytes))
                as Map<Object?, Object?>)['purpose'],
      ),
      <String>['register', 'login'],
    );
    expect(reqs.first.headers.containsKey('X-Fushi-Sig'), isFalse);
    await expectLater(
      s.requestEmailCode('bad', forLogin: false),
      throwsArgumentError,
    );
  });

  test('enable：注册后存盘（服务端账户 id + 同意时刻），状态 active', () async {
    final LeaderboardService s = service();
    int notified = 0;
    s.addListener(() => notified++);
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '123456');
    expect(s.status, LeaderboardStatus.active);
    expect(s.self!.account.id, 'ServerAccount001');
    expect(notified, greaterThan(0));
    final Map<String, dynamic> body =
        (jsonDecode(utf8.decode(server.at('/v1/register').single.bodyBytes))
                as Map<Object?, Object?>)
            .cast<String, dynamic>();
    expect(body['email'], 'a@b.cd');
    expect(body['code'], '123456');

    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.accountId, 'ServerAccount001');
    expect(saved.consentAt, now);
    expect(saved.uploadEnabled, isTrue);
    expect(saved.recoveryCode, s.exportRecoveryCode());
    expect(
      LeaderboardIdentity.fromRecoveryCode(saved.recoveryCode).pubkeyBase64Url,
      body['pubkey'],
    );

    // 新实例（重启）从文件恢复。
    final LeaderboardService again = service();
    await again.load();
    expect(again.status, LeaderboardStatus.active);
    expect(again.account!.accountId, 'ServerAccount001');
  });

  test('loginWithEmail：新本机钥匙，存服务端账户 id，同步状态清空', () async {
    final LeaderboardService s = service();
    await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
    final LeaderboardLocalAccount saved = (await store().read())!;
    final LeaderboardIdentity device = LeaderboardIdentity.fromRecoveryCode(
      saved.recoveryCode,
    );
    expect(saved.accountId, 'ServerAccount001');
    expect(saved.accountId, isNot(device.accountId));
    expect(saved.syncState.neverSynced, isTrue);
    expect(server.at('/v1/login').single.headers['X-Fushi-Account'], isNull);
  });

  test('后台同步：首次先回填 ISBN 再全量 reset；30 分钟内不重跑；之后增量', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.requests.clear();

    await s.maybeSyncInBackground();
    expect(backfills, 1);
    final List<http.Request> first = server.at('/v1/shelf');
    expect(first, hasLength(1));
    expect(
      (jsonDecode(utf8.decode(first.single.bodyBytes))
          as Map<Object?, Object?>)['reset'],
      isTrue,
    );
    LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.lastSyncAt, now);
    expect(saved.isbnBackfilledAt, now);
    expect(saved.syncState.entries, hasLength(2));

    now += const Duration(minutes: 10).inMilliseconds;
    server.requests.clear();
    await s.maybeSyncInBackground();
    expect(server.requests, isEmpty);

    now += const Duration(minutes: 25).inMilliseconds;
    shelf = _shelf(3);
    await s.maybeSyncInBackground();
    expect(backfills, 1, reason: 'ISBN 回填 7 天内不重跑');
    final List<http.Request> second = server.at('/v1/shelf');
    final Map<Object?, Object?> body =
        jsonDecode(utf8.decode(second.single.bodyBytes))
            as Map<Object?, Object?>;
    expect(body['reset'], isFalse);
    expect(body['put'], hasLength(1));
    saved = (await store().read())!;
    expect(saved.syncState.entries, hasLength(3));
  });

  test('上传关闭：syncNow 不发书架请求', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    await s.setUploadEnabled(false);
    expect((await store().read())!.uploadEnabled, isFalse);
    server.requests.clear();
    await s.syncNow();
    await s.maybeSyncInBackground();
    expect(server.requests, isEmpty);
  });

  test('同步失败：错误抛给调用方，lastSyncAt 不前进', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.failShelf = true;
    await expectLater(s.syncNow(), throwsA(isA<LeaderboardApiException>()));
    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.lastSyncAt, isNull);
    expect(saved.syncState.neverSynced, isTrue);
  });

  test('导入恢复码：me() 确认后存盘；坏码抛 FormatException 且不落盘', () async {
    final LeaderboardService s = service();
    await expectLater(
      s.importRecoveryCode('FUSHI1-nope', consent: true),
      throwsFormatException,
    );
    expect(await store().read(), isNull);

    final String code = LeaderboardIdentity.generate(
      random: Random(9),
    ).toRecoveryCode();
    await s.importRecoveryCode(code, consent: true);
    expect(server.at('/v1/me'), hasLength(1));
    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.recoveryCode, code);
    expect(saved.syncState.neverSynced, isTrue);
  });

  test('资料 / 头像：updateProfile 与 setAvatarFromFile 刷新 self', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    await s.updateProfile(visibility: 'friends');
    final http.Request patch = server.requests.lastWhere(
      (http.Request r) => r.method == 'PATCH',
    );
    expect(jsonDecode(utf8.decode(patch.bodyBytes)), <String, dynamic>{
      'visibility': 'friends',
    });
    await s.setAvatarFromFile('/whatever.png');
    final http.Request put = server.at('/v1/me/avatar').single;
    expect(put.headers['Content-Type'], 'image/jpeg');
    expect(put.bodyBytes, <int>[0xff, 0xd8, 0xff]);
  });

  test('删除账户：服务端删除成功后删本机文件；本机退出不发请求', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    await s.deleteAccount();
    expect(
      server.requests.where(
        (http.Request r) => r.method == 'DELETE' && r.url.path == '/v1/me',
      ),
      hasLength(1),
    );
    expect(s.status, LeaderboardStatus.disabled);
    expect(await store().read(), isNull);

    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.requests.clear();
    await s.signOutLocally();
    expect(server.requests, isEmpty);
    expect(await store().read(), isNull);
  });

  group('自己资料的本机缓存（反馈 hDfesbQvxB：iOS 冷启动首页头像空白）', () {
    test('冷启动：load 读出上次的昵称 / 头像，不等网络；selfFresh=false', () async {
      server.avatar = '/img/avatars/me.jpg';
      final LeaderboardService first = service();
      await first.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      expect(first.selfFresh, isTrue);
      expect(store().selfCacheFile.existsSync(), isTrue);

      // 重启：网络还没就绪（/v1/me 挂死）。
      server
        ..requests.clear()
        ..hangMe = true;
      final LeaderboardService cold = service();
      int notified = 0;
      cold.addListener(() => notified++);
      await cold.load();
      expect(server.requests, isEmpty, reason: 'load 只读本机文件');
      expect(cold.status, LeaderboardStatus.active);
      expect(cold.self, isNotNull, reason: '冷启动就要有头像可画');
      expect(cold.self!.account.avatar, '/img/avatars/me.jpg');
      expect(cold.self!.account.nickname, 'N');
      expect(cold.selfFresh, isFalse, reason: '缓存不是新鲜值，首页仍要刷新');
      expect(notified, greaterThan(0), reason: 'load 完成要通知，首页据此重建');
    });

    test('刷新回来覆盖缓存：内存与文件都换成服务端新值', () async {
      final LeaderboardService first = service();
      await first.enable(nickname: 'N', email: 'a@b.cd', code: '1');

      server
        ..nickname = 'Renamed'
        ..avatar = '/img/avatars/new.jpg';
      final LeaderboardService cold = service();
      await cold.load();
      expect(cold.self!.account.nickname, 'N');
      await cold.refreshSelf();
      expect(cold.selfFresh, isTrue);
      expect(cold.self!.account.nickname, 'Renamed');

      final LeaderboardService again = service();
      await again.load();
      expect(again.self!.account.nickname, 'Renamed');
      expect(again.self!.account.avatar, '/img/avatars/new.jpg');
    });

    test('改资料 / 换头像同样写缓存', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      server.avatar = '/img/avatars/x.jpg';
      await s.setAvatarFromFile('/whatever.png');
      final LeaderboardService again = service();
      await again.load();
      expect(again.self!.account.avatar, '/img/avatars/x.jpg');
    });

    test('退出删缓存：下次冷启动不显示上一个账户的头像', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      await s.signOutLocally();
      expect(store().selfCacheFile.existsSync(), isFalse);
      final LeaderboardService again = service();
      await again.load();
      expect(again.self, isNull);
    });

    test('缓存属于别的账户（换号后残留）时不用', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      await store().writeSelf(
        LeaderboardSelf.fromJson(<String, dynamic>{
          'id': 'SomeoneElse',
          'nickname': 'X',
          'discriminator': 1,
          'visibility': 'public',
          'createdAt': 1,
        }),
      );
      final LeaderboardService again = service();
      await again.load();
      expect(again.status, LeaderboardStatus.active);
      expect(again.self, isNull);
    });

    test('缓存文件坏了：当没有缓存，账户照常可用', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      store().selfCacheFile.writeAsStringSync('{not json');
      final LeaderboardService again = service();
      await again.load();
      expect(again.status, LeaderboardStatus.active);
      expect(again.self, isNull);
    });

    test('请求在飞时退出：迟到的资料不落回内存、也不重新写出缓存', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      server.hangMe = true;
      final LeaderboardService cold = service();
      await cold.load();
      server.hangMe = false;
      final Future<LeaderboardSelf> inFlight = cold.refreshSelf();
      await cold.signOutLocally();
      await inFlight;
      expect(cold.self, isNull);
      expect(store().selfCacheFile.existsSync(), isFalse);
    });

    test('首页头像：有缓存也要在 load 后联网刷新一次（判 selfFresh 不判 self）', () {
      // _HomeAvatarPill 是私有组件，且 load 的真实文件 IO 在 widget 测试的
      // fakeAsync 里不推进；这里钉它的判据：旧写法 `self != null` 遇到缓存就永远
      // 不刷新，昵称 / 头像会一直停在上次。
      final String src = File(
        'lib/src/pages/implementations/home_dashboard_page.dart',
      ).readAsStringSync();
      final int start = src.indexOf('void _maybeRefreshSelf(');
      expect(start, greaterThan(0));
      final String body = src.substring(start, src.indexOf('\n  }', start));
      expect(body, contains('service.selfFresh'));
      expect(body, isNot(contains('service.self != null')));
      expect(body, contains('LeaderboardStatus.active'));
    });
  });

  test('Profile 隔离：不同 Profile 读写各自的文件', () async {
    final LeaderboardService p1 = service(profileId: 1);
    await p1.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    final LeaderboardService p2 = service(profileId: 2);
    await p2.load();
    expect(p2.status, LeaderboardStatus.disabled);
    expect(await store(2).read(), isNull);
  });

  test('encodeLeaderboardAvatarBytes：居中裁成 384 正方形 JPEG（大西瓜大球不糊）', () {
    final img.Image src = img.Image(width: 800, height: 400);
    final Uint8List out = encodeLeaderboardAvatarBytes(
      Uint8List.fromList(img.encodePng(src)),
    );
    final img.Image decoded = img.decodeJpg(out)!;
    // 大西瓜最大球直径 192 逻辑像素：头像至少要够 2x 屏原生像素。
    expect(kLeaderboardAvatarSize, greaterThanOrEqualTo(384));
    expect(decoded.width, kLeaderboardAvatarSize);
    expect(decoded.height, kLeaderboardAvatarSize);
    expect(out.length, lessThanOrEqualTo(kLeaderboardAvatarMaxBytes));
    expect(
      () => encodeLeaderboardAvatarBytes(Uint8List.fromList(<int>[1, 2, 3])),
      throwsFormatException,
    );
  });

  test('encodeLeaderboardAvatarBytes：高噪点图也压到服务端上限以内', () {
    final Random rnd = Random(7);
    final img.Image noise = img.Image(width: 600, height: 600);
    for (final img.Pixel p in noise) {
      p
        ..r = rnd.nextInt(256)
        ..g = rnd.nextInt(256)
        ..b = rnd.nextInt(256);
    }
    final Uint8List out = encodeLeaderboardAvatarBytes(
      Uint8List.fromList(img.encodePng(noise)),
    );
    expect(out.length, lessThanOrEqualTo(kLeaderboardAvatarMaxBytes));
    expect(img.decodeJpg(out), isNotNull);
  });

  test('leaderboardCoverThumb：没有本地封面 / 文件不在返回 null，否则 ≤300px JPEG', () async {
    LocalShelfEntry entry(String? path) => LocalShelfEntry(
      localKey: 'book:x',
      localCoverPath: path,
      upload: ShelfEntryUpload(
        kind: LeaderboardKind.book,
        refs: <String>['t:x|'],
        title: 'x',
        finished: false,
      ),
    );
    expect(await leaderboardCoverThumb(entry(null)), isNull);
    expect(
      await leaderboardCoverThumb(entry('${root.path}/missing.jpg')),
      isNull,
    );
    final File cover = File('${root.path}/c.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 600, height: 900)));
    final Uint8List? thumb = await leaderboardCoverThumb(entry(cover.path));
    final img.Image decoded = img.decodeJpg(thumb!)!;
    expect(decoded.height, 300);
    expect(decoded.width, 200);
  });

  test('上传设备是另一台：后台同步静默停止并记状态，syncNow 抛专门异常', () async {
    final LeaderboardService s = service();
    server.ownedElsewhere = true;
    await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
    expect(s.isUploadDevice, isFalse, reason: 'login 响应里 uploadDevice=false');
    server.requests.clear();

    await s.maybeSyncInBackground(); // 不抛
    expect(server.at('/v1/shelf'), hasLength(1));
    expect(s.isUploadDevice, isFalse);
    LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.uploadBlockedByOtherDevice, isTrue);
    expect(saved.lastSyncAt, isNull);

    // 被挡住后，后台同步不再发请求。
    now += const Duration(hours: 1).inMilliseconds;
    server.requests.clear();
    await s.maybeSyncInBackground();
    expect(server.requests, isEmpty);

    await expectLater(
      s.syncNow(),
      throwsA(isA<LeaderboardUploadOwnedElsewhere>()),
    );

    // 接管：清空状态、reset + claim 全量同步，之后恢复正常。
    server.requests.clear();
    await s.claimUploadDevice();
    final Map<Object?, Object?> body =
        jsonDecode(utf8.decode(server.at('/v1/shelf').single.bodyBytes))
            as Map<Object?, Object?>;
    expect(body['reset'], isTrue);
    expect(body['claim'], isTrue);
    saved = (await store().read())!;
    expect(saved.uploadBlockedByOtherDevice, isFalse);
    expect(saved.syncState.entries, hasLength(2));
    expect(saved.lastSyncAt, now);
    expect(s.isUploadDevice, isTrue);
  });

  test('接管中途 429：「被另一台挡住」标记已清，后台同步从断点续传', () async {
    final LeaderboardService s = service();
    server.ownedElsewhere = true;
    await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
    await s.maybeSyncInBackground();
    expect((await store().read())!.uploadBlockedByOtherDevice, isTrue);

    shelf = _shelf(501); // 两批：第一批（claim）成功，第二批 429
    server.shelfStatuses.addAll(<int>[200, 429]);
    await expectLater(
      s.claimUploadDevice(),
      throwsA(isA<LeaderboardApiException>()),
    );
    LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.uploadBlockedByOtherDevice, isFalse);
    expect(saved.syncState.entries, hasLength(500));

    now += const Duration(hours: 1).inMilliseconds;
    server.requests.clear();
    await s.maybeSyncInBackground();
    final List<http.Request> shelfReqs = server.at('/v1/shelf');
    expect(shelfReqs, hasLength(1));
    final Map<Object?, Object?> body =
        jsonDecode(utf8.decode(shelfReqs.single.bodyBytes))
            as Map<Object?, Object?>;
    expect(body['reset'], isFalse);
    expect(body['put'], hasLength(1));
    saved = (await store().read())!;
    expect(saved.syncState.entries, hasLength(501));
    expect(saved.lastSyncAt, now);
  });

  test('接管第一批就 429：标记在接管开始时已清（后台同步不会因此永久停下）', () async {
    final LeaderboardService s = service();
    server.ownedElsewhere = true;
    await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
    await s.maybeSyncInBackground();
    expect((await store().read())!.uploadBlockedByOtherDevice, isTrue);

    server.shelfStatuses.add(429);
    await expectLater(
      s.claimUploadDevice(),
      throwsA(isA<LeaderboardApiException>()),
    );
    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.uploadBlockedByOtherDevice, isFalse);
    expect(saved.uploadEnabled, isTrue);
    expect(saved.syncState.neverSynced, isTrue);
  });

  test('被挡住后手动同步：只要有一批被接受就清掉标记（部分失败也算）', () async {
    final LeaderboardService s = service();
    server.ownedElsewhere = true;
    await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
    await s.maybeSyncInBackground();
    expect((await store().read())!.uploadBlockedByOtherDevice, isTrue);

    server.ownedElsewhere = false; // 另一台已放手
    shelf = _shelf(501);
    server.shelfStatuses.addAll(<int>[200, 503]);
    await expectLater(s.syncNow(), throwsA(isA<LeaderboardApiException>()));
    expect((await store().read())!.uploadBlockedByOtherDevice, isFalse);
    expect(s.isUploadDevice, isTrue);
  });

  test('书架满：新条目不上传，droppedForShelfLimit 暴露给 UI，同步不算失败', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    expect(s.droppedForShelfLimit, isNull);
    await s.syncNow();
    expect(s.droppedForShelfLimit, 0);

    shelf = _shelf(4);
    server.shelfFull = true;
    now += 1000;
    await s.syncNow();
    expect(s.droppedForShelfLimit, 2);
    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.lastSyncAt, now);
    expect(saved.syncState.entries, hasLength(2));
  });

  test('请求超时：syncNow 抛 TimeoutException，之后还能重新同步（_syncing 已清）', () async {
    final LeaderboardService s = service(
      timeout: const Duration(milliseconds: 50),
    );
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.hangShelf = true;
    await expectLater(s.syncNow(), throwsA(isA<TimeoutException>()));
    server.hangShelf = false;
    server.requests.clear();
    await s.syncNow();
    expect(server.at('/v1/shelf'), hasLength(1));
    expect((await store().read())!.lastSyncAt, now);
  });

  test('同步期间退出并换号：旧同步的结果不写进新账户', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    final Completer<void> gate = Completer<void>();
    server.shelfGate = gate;
    final Future<void> sync = s.syncNow();
    await server.shelfArrived.future;
    await s.signOutLocally();
    await s.enable(nickname: 'M', email: 'b@b.cd', code: '2');
    final String newCode = s.exportRecoveryCode();
    gate.complete();
    await sync;
    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.recoveryCode, newCode);
    expect(saved.syncState.neverSynced, isTrue);
    expect(saved.lastSyncAt, isNull);
  });

  test('实例已废弃（切 Profile）：在途同步收尾不写账户文件', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    final Completer<void> gate = Completer<void>();
    server.shelfGate = gate;
    final Future<void> sync = s.syncNow();
    await server.shelfArrived.future;
    s.dispose();
    gate.complete();
    await sync;
    final LeaderboardLocalAccount saved = (await store().read())!;
    expect(saved.syncState.neverSynced, isTrue);
    expect(saved.lastSyncAt, isNull);
  });

  test('服务器时钟：按 Date 头校准，书架汇总与签名都用服务器时刻', () async {
    const int skew = 3600 * 1000;
    server.serverNowMs = () => now + skew;
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.requests.clear();
    await s.syncNow();
    expect(builtAt.single.millisecondsSinceEpoch, now + skew);
    expect(
      server.at('/v1/shelf').single.headers['X-Fushi-Time'],
      '${now + skew}',
    );
  });

  test('后台同步失败也节流：30 分钟内不重试', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.failShelf = true;
    await expectLater(
      s.maybeSyncInBackground(),
      throwsA(isA<LeaderboardApiException>()),
    );
    now += const Duration(minutes: 1).inMilliseconds;
    server.requests.clear();
    await s.maybeSyncInBackground();
    expect(server.requests, isEmpty);

    now += const Duration(minutes: 30).inMilliseconds;
    server.failShelf = false;
    await s.maybeSyncInBackground();
    expect(server.at('/v1/shelf'), hasLength(1));
  });
  group('同意（登录 / 导入恢复码）', () {
    test('登录不勾同意：上传默认关闭、不记同意时刻；后台同步零书架请求', () async {
      final LeaderboardService s = service();
      await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: false);
      final LeaderboardLocalAccount saved = (await store().read())!;
      expect(saved.uploadEnabled, isFalse);
      expect(saved.consentAt, isNull);
      expect(s.hasConsent, isFalse);
      server.requests.clear();
      await s.maybeSyncInBackground();
      await s.syncNow();
      expect(server.at('/v1/shelf'), isEmpty);
    });

    test('登录勾了同意：上传开、同意时刻 = 现在', () async {
      final LeaderboardService s = service();
      await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
      final LeaderboardLocalAccount saved = (await store().read())!;
      expect(saved.uploadEnabled, isTrue);
      expect(saved.consentAt, now);
    });

    test('导入恢复码不勾同意：同样默认不上传', () async {
      final LeaderboardService s = service();
      final String code = LeaderboardIdentity.generate(
        random: Random(11),
      ).toRecoveryCode();
      await s.importRecoveryCode(code, consent: false);
      final LeaderboardLocalAccount saved = (await store().read())!;
      expect(saved.uploadEnabled, isFalse);
      expect(saved.consentAt, isNull);
    });

    test('未同意时打开上传：不带 consent 抛 LeaderboardConsentRequired，接管同理', () async {
      final LeaderboardService s = service();
      await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: false);
      await expectLater(
        s.setUploadEnabled(true),
        throwsA(isA<LeaderboardConsentRequired>()),
      );
      await expectLater(
        s.claimUploadDevice(),
        throwsA(isA<LeaderboardConsentRequired>()),
      );
      final LeaderboardLocalAccount saved = (await store().read())!;
      expect(saved.uploadEnabled, isFalse);
      expect(saved.consentAt, isNull);
      expect(server.at('/v1/shelf'), isEmpty);
    });

    test('确认同意后打开上传：记同意时刻，并立即触发一次同步', () async {
      final LeaderboardService s = service();
      await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: false);
      server.requests.clear();
      await s.setUploadEnabled(true, consent: true);
      final LeaderboardLocalAccount saved = (await store().read())!;
      expect(saved.uploadEnabled, isTrue);
      expect(saved.consentAt, now);
      for (int i = 0; i < 50 && server.at('/v1/shelf').isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(server.at('/v1/shelf'), hasLength(1));
      // 排空在途同步（它收尾还要写账户文件）；无变化的增量同步不再发书架请求。
      await s.syncNow();
      expect(server.at('/v1/shelf'), hasLength(1));
      expect((await store().read())!.lastSyncAt, now);
    });
  });

  group('账户在服务端已失效（401 unknown_account）', () {
    test('后台同步：本机自动退出、记提示、不抛；之后不再每 30 分钟失败', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      server.accountGone = true;
      await s.maybeSyncInBackground(); // 不抛
      expect(s.status, LeaderboardStatus.disabled);
      expect(s.accountGoneNotice, isTrue);
      expect(await store().read(), isNull);

      now += const Duration(hours: 1).inMilliseconds;
      server.requests.clear();
      await s.maybeSyncInBackground();
      expect(server.requests, isEmpty);
    });

    test('UI 读榜（签名读请求）同样触发退出；syncNow 把错误抛给调用方', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      server.accountGone = true;
      await expectLater(
        s.client!.rank(),
        throwsA(isA<LeaderboardApiException>()),
      );
      // 异常一到手退出就已落定（BUG-2801）：不许靠让出事件循环等异步落盘。
      expect(s.status, LeaderboardStatus.disabled);
      expect(s.accountGoneNotice, isTrue);
      expect(await store().read(), isNull);

      // 重新登录清掉提示。
      server.accountGone = false;
      await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
      expect(s.accountGoneNotice, isFalse);
      expect(s.status, LeaderboardStatus.active);
    });

    test('同步中途失效：收尾不把旧状态写回（文件保持已删）', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      server.accountGone = true;
      await expectLater(s.syncNow(), throwsA(isA<LeaderboardApiException>()));
      expect(s.status, LeaderboardStatus.disabled);
      expect(await store().read(), isNull);
    });

    test('导入他人恢复码失败（401）：不牵连当前已登录账户', () async {
      final LeaderboardService s = service();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      final String other = LeaderboardIdentity.generate(
        random: Random(21),
      ).toRecoveryCode();
      server.accountGone = true;
      await expectLater(
        s.importRecoveryCode(other, consent: true),
        throwsA(isA<LeaderboardApiException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(s.status, LeaderboardStatus.active);
      expect(await store().read(), isNotNull);
    });
  });

  test('后台节流随换号重置：旧账户刚失败，新登录的账户立即可后台同步', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    server.failShelf = true;
    await expectLater(
      s.maybeSyncInBackground(),
      throwsA(isA<LeaderboardApiException>()),
    );
    server.failShelf = false;
    await s.signOutLocally();
    await s.loginWithEmail(email: 'a@b.cd', code: '1', consent: true);
    server.requests.clear();
    now += const Duration(minutes: 1).inMilliseconds;
    await s.maybeSyncInBackground();
    expect(server.at('/v1/shelf'), hasLength(1));
  });

  test('ISBN 回填：抛错只记日志不挡同步；7 天后才重跑', () async {
    final LeaderboardService s = service();
    await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
    backfillThrows = true;
    await s.maybeSyncInBackground();
    expect(backfills, 1);
    expect(server.at('/v1/shelf'), hasLength(1), reason: '回填失败不挡同步');
    expect((await store().read())!.isbnBackfilledAt, now);

    backfillThrows = false;
    now += const Duration(days: 6).inMilliseconds;
    await s.maybeSyncInBackground();
    expect(backfills, 1);

    now += const Duration(days: 1).inMilliseconds;
    await s.maybeSyncInBackground();
    expect(backfills, 2);
  });

  // 反馈 kEAgATi1LF：来源库隐私开关。书架用真实的 buildLocalShelf 从库里建（不注入
  // 固定书架），钉死「打开开关 → 立即同步 → 服务端撤下已上报的条目」整条链路。
  group('隐私来源：打开开关后从服务端撤下', () {
    late int secretSource;

    LeaderboardService realShelfService() => LeaderboardService(
      database: () => db,
      supportRoot: () async => root,
      profileId: () async => 1,
      httpClientFactory: () async => MockClient(server.handle),
      defaultBaseUrl: Uri.parse('https://rank.example'),
      clockMs: () => now,
      shelfBuilder: (FushiDatabase d, int profileId, DateTime at) =>
          buildLocalShelf(d, profileId: profileId, now: at),
      isbnBackfill: (FushiDatabase _) async => 0,
      coverThumb: (LocalShelfEntry _) async => null,
    );

    Future<void> book(String key, {int? sourceId}) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/x/$key.epub',
          extractDir: '/x/$key',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 0,
          completedAt: Value<DateTime?>(DateTime(2023, 1, 1)),
          sourceId: Value<int?>(sourceId),
        ),
      );
    }

    setUp(() async {
      secretSource = await db
          .into(db.mediaSources)
          .insert(
            MediaSourcesCompanion.insert(
              label: 'nsfw',
              mediaKind: 'book',
              rootPath: '/books/nsfw',
              createdAt: 0,
            ),
          );
      await book('Nsfw', sourceId: secretSource);
      await book('Open');
    });

    Map<Object?, Object?> lastShelfBody() =>
        jsonDecode(utf8.decode(server.at('/v1/shelf').last.bodyBytes))
            as Map<Object?, Object?>;

    Future<SourceLibraryPrivacyResult> toggle(
      LeaderboardService s,
      bool isPrivate,
    ) => setSourceLibraryPrivate(
      db: db,
      sourceId: secretSource,
      isPrivate: isPrivate,
      withdrawFromLeaderboard: s.syncAfterPrivacyChange,
    );

    test('已上报的隐私来源条目被 remove，公开条目保留；开关已落库', () async {
      final LeaderboardService s = realShelfService();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      await s.syncNow();
      expect(server.shelfWorks, <String>{'W_Nsfw', 'W_Open'});

      server.requests.clear();
      final SourceLibraryPrivacyResult result = await toggle(s, true);
      expect(result.outcome, SourceLibraryPrivacyOutcome.privateWithdrawn);
      expect((await db.getMediaSourceById(secretSource))!.isPrivate, isTrue);
      expect(server.at('/v1/shelf'), hasLength(1));
      final Map<Object?, Object?> body = lastShelfBody();
      expect(body['remove'], <Object?>['W_Nsfw']);
      expect(body['put'], isEmpty, reason: '没变的公开条目不重传');
      expect(server.shelfWorks, <String>{'W_Open'});
      final LeaderboardLocalAccount saved = (await store().read())!;
      expect(saved.syncState.entries.keys, <String>[
        'book:Open',
      ], reason: '同步状态不再记着撤下的条目');

      // 关掉：开关落库、不立即同步；下一次同步照常重新上传。
      server.requests.clear();
      final SourceLibraryPrivacyResult cleared = await toggle(s, false);
      expect(cleared.outcome, SourceLibraryPrivacyOutcome.cleared);
      expect(server.requests, isEmpty);
      await s.syncNow();
      expect(server.shelfWorks, <String>{'W_Nsfw', 'W_Open'});
    });

    test('在途同步（开关之前建的书架）结束后再跑一轮，不搭它的便车', () async {
      final LeaderboardService s = realShelfService();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      await s.syncNow();
      expect(server.shelfWorks, <String>{'W_Nsfw', 'W_Open'});

      // 让下一轮有东西可传（读完日变了 → put），请求挂在服务端；期间打开开关。
      await db
          .update(db.epubBooks)
          .write(
            EpubBooksCompanion(
              completedAt: Value<DateTime?>(DateTime(2023, 2, 1)),
            ),
          );
      server.shelfGate = Completer<void>();
      server.shelfArrived = Completer<void>();
      final Future<void> inFlight = s.syncNow();
      await server.shelfArrived.future;
      final Future<SourceLibraryPrivacyResult> toggling = toggle(s, true);
      server.shelfGate!.complete();
      await inFlight;
      server.shelfGate = null;
      final SourceLibraryPrivacyResult result = await toggling;
      expect(result.outcome, SourceLibraryPrivacyOutcome.privateWithdrawn);
      expect(server.shelfWorks, <String>{'W_Open'});
    });

    test('没开排行榜 / 上传关着：不发书架请求，结果为「仅本地」', () async {
      final LeaderboardService s = realShelfService();
      SourceLibraryPrivacyResult result = await toggle(s, true);
      expect(result.outcome, SourceLibraryPrivacyOutcome.privateLocalOnly);
      expect(server.requests, isEmpty);

      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      await s.setUploadEnabled(false);
      server.requests.clear();
      result = await toggle(s, true);
      expect(result.outcome, SourceLibraryPrivacyOutcome.privateLocalOnly);
      expect(server.at('/v1/shelf'), isEmpty);
    });

    test('撤下的同步失败：开关仍生效（不回滚），结果带错误；下次同步补撤', () async {
      final LeaderboardService s = realShelfService();
      await s.enable(nickname: 'N', email: 'a@b.cd', code: '1');
      await s.syncNow();
      server.failShelf = true;
      final SourceLibraryPrivacyResult result = await toggle(s, true);
      expect(result.outcome, SourceLibraryPrivacyOutcome.privateWithdrawFailed);
      expect(result.error, isA<LeaderboardApiException>());
      expect((await db.getMediaSourceById(secretSource))!.isPrivate, isTrue);
      expect(server.shelfWorks, contains('W_Nsfw'));

      server.failShelf = false;
      await s.syncNow();
      expect(server.shelfWorks, <String>{'W_Open'});
    });
  });
}
