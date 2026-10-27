// 流式书与 Audiobookshelf 的进度同步：续播规则（服务器明显更靠前且没在播才跳）、
// 播放中定时同步与暂停立即同步、在播时长按增量记账、离线 / 会话被清掉时退回直接写
// 进度、结束时写最后位置并关会话；以及任何网络失败都不外溢。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_progress_sync.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 两条轨：[0,100s) [100s,300s)。
const List<RemoteAudioTrack> _tracks = <RemoteAudioTrack>[
  RemoteAudioTrack(ino: '10', startOffsetMs: 0, durationMs: 100000),
  RemoteAudioTrack(ino: '11', startOffsetMs: 100000, durationMs: 200000),
];

RemoteAudioBinding _binding({
  String? episodeId,
  int updatedAt = 0,
  int? localProgressAt,
}) => RemoteAudioBinding(
  srtBookUid: 'srtbook_1',
  provider: RemoteAudioBinding.providerAudiobookshelf,
  serverConfigId: 'srv',
  itemId: 'item_1',
  episodeId: episodeId,
  tracks: _tracks,
  createdAt: 0,
  updatedAt: updatedAt,
  localProgressAt: localProgressAt,
);

/// 假播放器：测试直接改位置 / 播放状态，再触发监听。
class _FakeHost {
  bool playing = false;
  int fileIndex = 0;
  int positionMs = 0;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<(int, int)> restores = <(int, int)>[];

  /// 模拟服务器记的时长比本机实际解码出来的长：restoreTo 越界抛错。
  bool restoreThrows = false;

  RemotePlaybackHost get host => RemotePlaybackHost(
    isPlaying: () => playing,
    filePosition: () => (fileIndex: fileIndex, positionMs: positionMs),
    restoreTo: (int i, int ms) async {
      if (restoreThrows) throw RangeError.range(ms, 0, 1);
      restores.add((i, ms));
      fileIndex = i;
      positionMs = ms;
    },
    addListener: listeners.add,
    removeListener: listeners.remove,
  );

  void notify() {
    for (final VoidCallback l in List<VoidCallback>.of(listeners)) {
      l();
    }
  }
}

class _Call {
  _Call(this.method, this.path, this.body);
  final String method;
  final String path;
  final Map<String, Object?> body;
}

/// 记录请求的假服务器；[playSession] / [syncStatus] 可按用例改。
class _FakeServer {
  final List<_Call> calls = <_Call>[];
  double serverPosition = 0;
  int syncStatus = 200;
  bool startPlayFails = false;
  bool patchFails = false;

  /// 非空 = 服务器上有这条进度记录（GET /me/progress 应答它）。
  Map<String, Object?>? storedProgress;

  /// 非空 = 读进度 / 会话同步要等它放行（模拟请求在途）。
  Completer<void>? progressGate;
  Completer<void>? syncGate;

  List<_Call> to(String suffix) =>
      calls.where((c) => c.path.endsWith(suffix)).toList();

  Future<http.Response> handle(http.Request request) async {
    Map<String, Object?> body = const <String, Object?>{};
    if (request.body.isNotEmpty) {
      body = jsonDecode(request.body) as Map<String, Object?>;
    }
    // 读进度（GET）单独应答：这里没有「服务器进度记录」，续播退回会话给的位置。
    if (request.method == 'GET' && request.url.path.contains('/me/progress/')) {
      await progressGate?.future;
      final Map<String, Object?>? stored = storedProgress;
      if (stored == null) return http.Response('not found', 404);
      return http.Response(
        jsonEncode(stored),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    calls.add(_Call(request.method, request.url.path, body));
    if (request.url.path.contains('/play')) {
      if (startPlayFails) return http.Response('down', 503);
      return http.Response(
        jsonEncode(<String, Object?>{
          'id': 'sess_1',
          'libraryItemId': 'item_1',
          'duration': 300,
          'currentTime': serverPosition,
          'audioTracks': <Object?>[
            <String, Object?>{'ino': '10', 'duration': 100, 'startOffset': 0},
            <String, Object?>{'ino': '11', 'duration': 200, 'startOffset': 100},
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    if (request.url.path.contains('/session/')) {
      if (request.url.path.endsWith('/sync')) await syncGate?.future;
      return http.Response(syncStatus == 200 ? 'OK' : 'x', syncStatus);
    }
    if (request.url.path.contains('/me/progress/')) {
      return patchFails ? http.Response('x', 500) : http.Response('OK', 200);
    }
    return http.Response('not found', 404);
  }
}

AudiobookshelfApi _api(_FakeServer server) => AudiobookshelfApi(
  serverUrl: Uri.parse('https://abs.example.com'),
  providerId: 'abs-test',
  tokens: const AudiobookshelfTokens(accessToken: 'a'),
  client: MockClient(server.handle),
);

void main() {
  late _FakeServer server;
  late _FakeHost player;
  late DateTime clock;
  late List<String> errors;
  late AudiobookshelfProgressSync sync;
  VoidCallback? tick;

  AudiobookshelfProgressSync build({
    String? episodeId,
    RemoteAudioBinding? binding,
  }) => AudiobookshelfProgressSync(
    api: _api(server),
    binding: binding ?? _binding(episodeId: episodeId),
    deviceId: () async => 'dev-1',
    now: () => clock,
    timerFactory: (Duration interval, void Function() onTick) {
      tick = onTick;
      return Timer(const Duration(days: 1), () {});
    },
    onError: (String what, Object e) => errors.add(what),
  );

  setUp(() {
    server = _FakeServer();
    player = _FakeHost();
    clock = DateTime(2026, 1, 1, 12);
    errors = <String>[];
    tick = null;
    sync = build();
  });

  tearDown(() async => sync.close());

  void advance(int seconds) => clock = clock.add(Duration(seconds: seconds));

  group('续播', () {
    test('服务器明显更靠前且没在播 → 跳到那个位置（跨轨换算）', () async {
      server.serverPosition = 150; // 第 2 轨内 50s
      await sync.attach(player.host);
      expect(player.restores, <(int, int)>[(1, 50000)]);
      expect(sync.hasSession, isTrue);
    });

    test('服务器被改回更早的位置（别的设备）→ 也跳过去', () async {
      server.serverPosition = 20;
      player.fileIndex = 1;
      player.positionMs = 30000; // 绝对 130s
      await sync.attach(player.host);
      expect(player.restores, <(int, int)>[(0, 20000)]);
    });

    test('差距在阈值内 → 不跳', () async {
      server.serverPosition = 12;
      player.positionMs = 10000;
      await sync.attach(player.host);
      expect(player.restores, isEmpty);
    });

    test('刚开书就在播 → 窗口内照样按服务器续播', () async {
      server.serverPosition = 250;
      player.playing = true;
      await sync.attach(player.host);
      expect(player.restores, <(int, int)>[(1, 150000)]);
    });

    test('已经听了很久才查到服务器位置 → 不抢用户的播放，不跳', () async {
      server.serverPosition = 250;
      player.playing = true;
      final Future<void> attaching = sync.attach(player.host);
      clock = clock.add(const Duration(minutes: 5));
      await attaching;
      expect(player.restores, isEmpty);
    });

    test('播客单集：会话走 /play/:episodeId', () async {
      await sync.close();
      sync = build(episodeId: 'ep_9');
      await sync.attach(player.host);
      expect(server.to('/play/ep_9'), hasLength(1));
      final Map<String, Object?> body = server.calls.first.body;
      expect((body['deviceInfo'] as Map)['deviceId'], 'dev-1');
    });

    test('locate：边界与越界', () {
      expect(AudiobookshelfProgressSync.locate(_tracks, 0), (
        fileIndex: 0,
        positionMs: 0,
      ));
      expect(AudiobookshelfProgressSync.locate(_tracks, 100), (
        fileIndex: 1,
        positionMs: 0,
      ));
      expect(AudiobookshelfProgressSync.locate(_tracks, 999), (
        fileIndex: 1,
        positionMs: 200000,
      ));
      expect(
        AudiobookshelfProgressSync.locate(const <RemoteAudioTrack>[], 5),
        isNull,
      );
    });
  });

  group('定期与暂停同步', () {
    test('播放中：定时器触发 → 会话同步，位置是全书绝对秒数，时长是增量', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.fileIndex = 1;
      player.positionMs = 20000; // 绝对 120s
      player.notify(); // 开始播放
      advance(30);
      tick!();
      await pumpEventQueue();

      final _Call call = server.to('/sync').single;
      expect(call.path, '/api/session/sess_1/sync');
      expect(call.body['currentTime'], 120);
      expect(call.body['timeListened'], 30);
      expect(call.body['duration'], 300);
    });

    test('时长是自上次同步的增量，不是累计', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      advance(30);
      player.positionMs = 30000;
      tick!();
      await pumpEventQueue();
      advance(30);
      player.positionMs = 60000;
      tick!();
      await pumpEventQueue();

      final List<_Call> syncs = server.to('/sync');
      expect(syncs.map((c) => c.body['timeListened']), <Object?>[30, 30]);
      expect(syncs.map((c) => c.body['currentTime']), <Object?>[30, 60]);
    });

    test('暂停的那一刻立即同步，并带上刚听的时长', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      advance(12);
      player.positionMs = 12000;
      player.playing = false;
      player.notify();
      await pumpEventQueue();

      final _Call call = server.to('/sync').single;
      expect(call.body['timeListened'], 12);
      expect(call.body['currentTime'], 12);
    });

    test('没在听、位置也没动 → 不发无意义的请求', () async {
      await sync.attach(player.host);
      player.positionMs = 5000;
      advance(30);
      tick!();
      await pumpEventQueue();
      expect(server.to('/sync'), hasLength(1), reason: '第一次：位置从未同步过');
      advance(30);
      tick!();
      await pumpEventQueue();
      expect(server.to('/sync'), hasLength(1), reason: '没动就不再发');
    });
  });

  group('故障退路', () {
    test('开不了会话（离线）→ 直接写进度，不抛', () async {
      server.startPlayFails = true;
      await sync.attach(player.host);
      expect(sync.hasSession, isFalse);
      expect(errors, <String>['startPlay']);

      player.positionMs = 40000;
      advance(30);
      tick!();
      await pumpEventQueue();
      final _Call patch = server.to('/me/progress/item_1').single;
      expect(patch.method, 'PATCH');
      expect(patch.body['currentTime'], 40);
      expect(patch.body['duration'], 300);
    });

    test('会话被服务器清掉（404）→ 本次改用直接写进度，之后都走它', () async {
      await sync.attach(player.host);
      server.syncStatus = 404;
      player.positionMs = 30000;
      advance(30);
      tick!();
      await pumpEventQueue();
      expect(sync.hasSession, isFalse);
      expect(server.to('/me/progress/item_1'), hasLength(1));

      player.positionMs = 60000;
      advance(30);
      tick!();
      await pumpEventQueue();
      expect(server.to('/me/progress/item_1'), hasLength(2));
      expect(server.to('/sync'), hasLength(1), reason: '不再撞已失效的会话');
    });

    test('同步失败不外溢，且同一串连续失败只报一次', () async {
      await sync.attach(player.host);
      server.syncStatus = 500;
      for (int i = 1; i <= 3; i++) {
        player.positionMs = i * 10000;
        advance(30);
        tick!();
        await pumpEventQueue();
      }
      expect(errors, <String>['sync']);
    });

    test('失败的那段时长不丢：下次成功时一并带上', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      server.syncStatus = 500;
      advance(30);
      player.positionMs = 30000;
      tick!();
      await pumpEventQueue();
      server.syncStatus = 200;
      advance(30);
      player.positionMs = 60000;
      tick!();
      await pumpEventQueue();
      expect(server.to('/sync').last.body['timeListened'], 60);
    });
  });

  group('离线听过的位置', () {
    test('同步发不出去也记下本机写入时间；没听过的挂机不记', () async {
      final List<int> stamps = <int>[];
      final AudiobookshelfProgressSync s = AudiobookshelfProgressSync(
        api: _api(server),
        binding: _binding(),
        deviceId: () async => 'dev-1',
        now: () => clock,
        timerFactory: (Duration interval, void Function() onTick) {
          tick = onTick;
          return Timer(const Duration(days: 1), () {});
        },
        onError: (String what, Object e) => errors.add(what),
        onPushed: (int ms) async => stamps.add(ms),
      );
      addTearDown(s.close);
      server.startPlayFails = true;
      server.patchFails = true;
      await s.attach(player.host);

      // 暂停挂机：不算本机写过。
      advance(30);
      tick!();
      await pumpEventQueue();
      expect(stamps, isEmpty);

      // 离线听了一段：写失败，但时间戳照记。
      player.playing = true;
      player.notify();
      advance(30);
      player.positionMs = 30000;
      tick!();
      await pumpEventQueue();
      expect(errors, contains('startPlay'));
      expect(stamps, <int>[clock.millisecondsSinceEpoch]);
    });
  });

  group('结束', () {
    test('close：写最后位置并关会话，之后不再同步', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      advance(8);
      player.positionMs = 8000;
      await sync.close();

      final _Call close = server.to('/close').single;
      expect(close.path, '/api/session/sess_1/close');
      expect(close.body['currentTime'], 8);
      expect(close.body['timeListened'], 8);
      expect(sync.hasSession, isFalse);

      advance(60);
      player.notify();
      await pumpEventQueue();
      expect(server.to('/sync'), isEmpty);
    });

    test('close 幂等，且没会话时退回直接写进度', () async {
      server.startPlayFails = true;
      await sync.attach(player.host);
      player.positionMs = 7000;
      await sync.close();
      await sync.close();
      expect(server.to('/me/progress/item_1'), hasLength(1));
      expect(server.to('/close'), isEmpty);
    });

    test('开会话途中就 close：补关刚开出来的服务器会话，不留孤儿', () async {
      final Completer<void> gate = Completer<void>();
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: Uri.parse('https://abs.example.com'),
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(accessToken: 'a'),
        client: MockClient((http.Request r) async {
          if (r.url.path.contains('/play')) await gate.future;
          return server.handle(r);
        }),
      );
      final AudiobookshelfProgressSync slow = AudiobookshelfProgressSync(
        api: api,
        binding: _binding(),
        deviceId: () async => 'dev-1',
        timerFactory: (_, __) => Timer(const Duration(days: 1), () {}),
      );
      final Future<void> attaching = slow.attach(player.host);
      await pumpEventQueue();
      await slow.close();
      gate.complete();
      await attaching;
      await pumpEventQueue();
      expect(server.to('/close'), hasLength(1), reason: '这个会话没人认领，要补关');
      expect(slow.hasSession, isFalse);
    });

    test('开会话途中就 close：补关带关书那一刻的位置，且不先拿旧位置 PATCH', () async {
      final Completer<void> gate = Completer<void>();
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: Uri.parse('https://abs.example.com'),
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(accessToken: 'a'),
        client: MockClient((http.Request r) async {
          if (r.url.path.contains('/play')) await gate.future;
          return server.handle(r);
        }),
      );
      server.serverPosition = 10;
      final AudiobookshelfProgressSync slow = AudiobookshelfProgressSync(
        api: api,
        binding: _binding(),
        deviceId: () async => 'dev-1',
        timerFactory: (_, __) => Timer(const Duration(days: 1), () {}),
      );
      final Future<void> attaching = slow.attach(player.host);
      await pumpEventQueue();
      player.fileIndex = 1;
      player.positionMs = 42000; // 全书 142s
      await slow.close();
      expect(server.calls.where((c) => c.method == 'PATCH'), isEmpty);
      gate.complete();
      await attaching;
      await pumpEventQueue();
      final _Call close = server.to('/close').single;
      expect(close.body['currentTime'], 142, reason: '不能用会话里服务器的旧位置 10');
    });
  });

  group('续播判定期间的竞态', () {
    test('重切字幕刷新了 updatedAt：不算本机后听的，照样按服务器新进度续播', () async {
      // 绑定刚因重切字幕被改过（updatedAt = 现在），但本机从没写过进度。
      sync = build(binding: _binding(updatedAt: clock.millisecondsSinceEpoch));
      server.storedProgress = <String, Object?>{
        'currentTime': 150,
        'duration': 300,
        'lastUpdate': clock
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      };
      await sync.attach(player.host);
      expect(player.restores, <(int, int)>[(1, 50000)]);
    });

    test('本机开书前确实后听过（localProgressAt 新于服务器很多）→ 不跳', () async {
      sync = build(
        binding: _binding(localProgressAt: clock.millisecondsSinceEpoch),
      );
      server.storedProgress = <String, Object?>{
        'currentTime': 150,
        'duration': 300,
        'lastUpdate': clock
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      };
      await sync.attach(player.host);
      expect(player.restores, isEmpty);
    });

    test('读服务器进度途中暂停：不推旧位置，判定完照样跳到服务器位置', () async {
      server.progressGate = Completer<void>();
      server.storedProgress = <String, Object?>{
        'currentTime': 150,
        'duration': 300,
        'lastUpdate': clock.millisecondsSinceEpoch,
      };
      final Future<void> attaching = sync.attach(player.host);
      await pumpEventQueue();
      player.playing = true;
      player.notify();
      advance(3);
      player.positionMs = 3000;
      player.playing = false;
      player.notify(); // 暂停：平时会立即同步
      tick!();
      await pumpEventQueue();
      expect(server.to('/sync'), isEmpty);
      expect(server.calls.where((c) => c.method == 'PATCH'), isEmpty);
      server.progressGate!.complete();
      await attaching;
      expect(player.restores, <(int, int)>[(1, 50000)]);
    });

    test('暂停后再播的复查：跳转失败只记日志，不成未处理异常', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      advance(10);
      player.positionMs = 10000;
      player.playing = false;
      player.notify(); // 暂停同步 → 记下本机位置 10s
      await pumpEventQueue();
      server.storedProgress = <String, Object?>{
        'currentTime': 250,
        'duration': 300,
        'lastUpdate': clock.millisecondsSinceEpoch,
      };
      player.restoreThrows = true;
      advance(120);
      player.playing = true;
      player.notify(); // 暂停够久 → 复查服务器
      await pumpEventQueue();
      expect(errors, contains('recheck'));
    });
  });

  group('收听时长记账', () {
    test('同步在途期间新攒的时长不被清掉，下次带上', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      advance(30);
      player.positionMs = 30000;
      server.syncGate = Completer<void>();
      tick!(); // 发出 30s，在途
      await pumpEventQueue();
      advance(10);
      player.positionMs = 40000;
      player.playing = false;
      player.notify(); // 在途期间又听了 10s 才暂停
      server.syncGate!.complete();
      server.syncGate = null;
      await pumpEventQueue();
      tick!();
      await pumpEventQueue();
      expect(server.to('/sync').map((c) => c.body['timeListened']), <Object?>[
        30,
        10,
      ]);
    });

    test('close 等在途同步落定，同一段时长不算两次', () async {
      await sync.attach(player.host);
      player.playing = true;
      player.notify();
      advance(30);
      player.positionMs = 30000;
      server.syncGate = Completer<void>();
      tick!();
      await pumpEventQueue();
      final Future<void> closing = sync.close();
      await pumpEventQueue();
      server.syncGate!.complete();
      await closing;
      expect(server.to('/sync').single.body['timeListened'], 30);
      expect(server.to('/close').single.body['timeListened'], 0);
    });
  });
}
