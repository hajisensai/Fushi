import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 记录引擎发给后端的命令；[openGate] 非空时 openPair 等它完成（模拟取流中）。
class _FakeBackend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  MusicPlayItem? current;
  MusicPlayItem? next;
  Completer<void>? openGate;

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings s) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
    Duration startAt = Duration.zero,
  }) async {
    this.current = current;
    this.next = next;
    log.add('open:${current.trackUid}+${next?.trackUid}');
    final Completer<void>? gate = openGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    this.next = next;
    log.add('next:${next?.trackUid}');
  }

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(String uid) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  durationMs: 200000,
);

List<MusicPlayItem> _items(String uids) => <MusicPlayItem>[
  for (final String u in uids.split('')) _item(u),
];

String _uids(List<MusicPlayItem> q) =>
    q.map((MusicPlayItem i) => i.trackUid).join();

void main() {
  late _FakeBackend backend;
  late MusicPlayerEngine engine;
  final List<String> started = <String>[];

  setUp(() {
    backend = _FakeBackend();
    started.clear();
    engine = MusicPlayerEngine(backendFactory: () => backend, random: Random(1))
      ..onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
  });

  tearDown(() => engine.dispose());

  Future<void> advance([String? uid]) async {
    backend.controller.add(MusicBackendAdvanced(uid));
    await Future<void>.delayed(Duration.zero);
  }

  group('removeFromQueue', () {
    test('移除预排的下一首：后端立刻换成新的下一首，当前曲不打断', () async {
      await engine.playQueue(_items('abcd'));
      expect(backend.log, <String>['open:a+b']);
      await engine.removeFromQueue(1);
      expect(_uids(engine.queue), 'acd');
      expect(engine.current?.trackUid, 'a');
      expect(backend.log, <String>['open:a+b', 'next:c']);
    });

    test('移除当前曲之前的：index 跟着前移；不影响下一首就不重发', () async {
      await engine.playQueue(_items('abcd'), startIndex: 2);
      await engine.removeFromQueue(0);
      expect(_uids(engine.queue), 'bcd');
      expect(engine.index, 1);
      expect(engine.current?.trackUid, 'c');
      expect(backend.log, <String>['open:c+d']);
    });

    test('当前曲 / 越界不能移除', () async {
      await engine.playQueue(_items('abc'), startIndex: 1);
      await engine.removeFromQueue(1);
      await engine.removeFromQueue(-1);
      await engine.removeFromQueue(3);
      expect(_uids(engine.queue), 'abc');
      expect(engine.index, 1);
    });

    test('移除最后一首后面的：当前曲成了队尾，下一首取消', () async {
      await engine.playQueue(_items('ab'));
      await engine.removeFromQueue(1);
      expect(backend.next, isNull);
      expect(backend.log.last, 'next:null');
    });

    test('单曲循环：预排的是当前曲本身，移除别的不重发', () async {
      await engine.playQueue(_items('abc'));
      await engine.setRepeatMode(MusicRepeatMode.one);
      final int before = backend.log.length;
      await engine.removeFromQueue(1);
      expect(backend.log.length, before);
      expect(backend.next?.trackUid, 'a');
    });

    test('随机模式下移除，关随机后原始顺序里也没有它', () async {
      await engine.playQueue(_items('abcde'), shuffle: true);
      final MusicPlayItem victim = engine.queue[2];
      await engine.removeFromQueue(2);
      await engine.setShuffle(false);
      expect(engine.queue, isNot(contains(victim)));
      expect(engine.queue, hasLength(4));
      expect(engine.current?.trackUid, 'a');
    });
  });

  group('moveInQueue', () {
    test('把后面的挪到当前曲之后：成为新的下一首', () async {
      await engine.playQueue(_items('abcd'));
      await engine.moveInQueue(3, 1);
      expect(_uids(engine.queue), 'adbc');
      expect(engine.current?.trackUid, 'a');
      expect(backend.log.last, 'next:d');
    });

    test('跨过当前曲挪动：index 跟着当前曲走', () async {
      await engine.playQueue(_items('abcd'), startIndex: 1);
      await engine.moveInQueue(0, 3);
      expect(_uids(engine.queue), 'bcda');
      expect(engine.index, 0);
      expect(engine.current?.trackUid, 'b');
      expect(backend.log, <String>['open:b+c']);
      await engine.moveInQueue(3, 0);
      expect(_uids(engine.queue), 'abcd');
      expect(engine.index, 1);
    });

    test('挪动当前曲本身：index 跟着走，下一首按新位置对齐', () async {
      await engine.playQueue(_items('abcd'));
      await engine.moveInQueue(0, 2);
      expect(_uids(engine.queue), 'bcad');
      expect(engine.index, 2);
      expect(engine.current?.trackUid, 'a');
      expect(backend.log.last, 'next:d');
    });

    test('非随机时挪动后关开随机不会还原掉', () async {
      await engine.playQueue(_items('abcd'));
      await engine.moveInQueue(3, 1);
      await engine.setShuffle(true);
      await engine.setShuffle(false);
      expect(_uids(engine.queue), 'adbc');
    });
  });

  group('playNext / addToQueue', () {
    test('下一首播放：按顺序插到当前曲之后，后端预排第一首', () async {
      await engine.playQueue(_items('abc'));
      await engine.playNext(_items('xy'));
      expect(_uids(engine.queue), 'axybc');
      expect(backend.log.last, 'next:x');
    });

    test('已在队列里的挪过来不重复；当前曲本身跳过', () async {
      await engine.playQueue(_items('abcd'), startIndex: 1);
      await engine.playNext(<MusicPlayItem>[
        _item('d'),
        _item('b'),
        _item('a'),
      ]);
      expect(_uids(engine.queue), 'bdac');
      expect(engine.index, 0);
      expect(engine.current?.trackUid, 'b');
      expect(backend.log.last, 'next:d');
    });

    test('加入播放队列：追加到队尾；当前是最后一首时补上下一首', () async {
      await engine.playQueue(_items('ab'), startIndex: 1);
      expect(backend.next, isNull);
      await engine.addToQueue(_items('xa'));
      expect(_uids(engine.queue), 'bxa');
      expect(engine.current?.trackUid, 'b');
      expect(backend.log.last, 'next:x');
    });

    test('没有队列时直接开播', () async {
      await engine.playNext(_items('xy'));
      expect(engine.current?.trackUid, 'x');
      expect(backend.log, <String>['open:x+y']);
      await engine.stop();
      await engine.addToQueue(_items('z'));
      expect(engine.current?.trackUid, 'z');
    });

    test('随机模式下插队：关随机后它仍紧跟在当前曲后面', () async {
      await engine.playQueue(_items('abcde'), startIndex: 2, shuffle: true);
      await engine.playNext(_items('x'));
      expect(engine.queue[engine.index + 1].trackUid, 'x');
      await engine.setShuffle(false);
      expect(_uids(engine.queue), 'abcxde');
      expect(engine.current?.trackUid, 'c');
      expect(backend.next?.trackUid, 'x');
    });
  });

  group('clearQueue', () {
    test('只留当前曲，不打断；下一首取消', () async {
      await engine.playQueue(_items('abcd'), startIndex: 2);
      await engine.clearQueue();
      expect(_uids(engine.queue), 'c');
      expect(engine.index, 0);
      expect(engine.isPlaying, isTrue);
      expect(backend.log, <String>['open:c+d', 'next:null']);
    });

    test('列表循环下清空：下一首接回当前曲自己', () async {
      await engine.playQueue(_items('abc'));
      await engine.setRepeatMode(MusicRepeatMode.all);
      await engine.clearQueue();
      expect(backend.next?.trackUid, 'a');
    });
  });

  group('与后端的切换期 / 打开期一致', () {
    test('切换期移除了后端已在解码的下一首：它出声时放回当前曲之后', () async {
      await engine.playQueue(_items('abcd'));
      await engine.removeFromQueue(1);
      expect(backend.log.last, 'next:c');
      // mpv 切换期内 b 已经在解码，换不掉：随后报 b 出声。
      await advance('b');
      expect(_uids(engine.queue), 'abcd');
      expect(engine.current?.trackUid, 'b');
      expect(backend.log.last, 'next:c');
      expect(started, <String>['a', 'b']);
    });

    test('切换期插队：后端已承诺的那首先播，插的那首紧接着不被跳过', () async {
      await engine.playQueue(_items('abcd'));
      await engine.playNext(_items('x'));
      expect(backend.log.last, 'next:x');
      await advance('b');
      expect(_uids(engine.queue), 'abxcd');
      expect(engine.current?.trackUid, 'b');
      expect(backend.log.last, 'next:x');
    });

    test('正常推进不受影响；重复曲目按离当前曲最近的那格对位', () async {
      await engine.playQueue(_items('abc'));
      await engine.appendToQueue(_items('a'));
      await advance('b');
      await advance('c');
      expect(engine.index, 2);
      await advance('a');
      expect(engine.index, 3, reason: '是队尾那格 a，不是队首');
    });

    test('取流中编辑队列：打开完成后把后端的下一首对齐到新队列', () async {
      backend.openGate = Completer<void>();
      final Future<void> opening = engine.playQueue(_items('abc'));
      await Future<void>.delayed(Duration.zero);
      expect(engine.resolving, isTrue);
      await engine.removeFromQueue(1);
      expect(backend.log, <String>['open:a+b'], reason: '打开中不向后端发');
      backend.openGate!.complete();
      await opening;
      expect(backend.log, <String>['open:a+b', 'next:c']);
    });

    test('播完停下后编辑：不碰后端，再按播放按新队列整对打开', () async {
      await engine.playQueue(_items('ab'), startIndex: 1);
      backend.controller.add(const MusicBackendCompleted());
      await engine.addToQueue(_items('x'));
      expect(backend.log, <String>['open:b+null']);
      await engine.play();
      expect(backend.log.last, 'open:b+x');
    });
  });

  group('「下一首播放」标记 / 撤销移除', () {
    test('playNext 插进来的带标记，轮到它播时去掉；addToQueue 挪走的不带', () async {
      await engine.playQueue(_items('abc'));
      await engine.playNext(_items('xy'));
      expect(_uids(engine.queue), 'axybc');
      expect(
        <bool>[for (int i = 0; i < 5; i++) engine.isPlayNextAt(i)],
        <bool>[false, true, true, false, false],
      );
      await advance('x');
      expect(engine.isPlayNextAt(1), isFalse, reason: 'x 已是当前曲');
      expect(engine.isPlayNextAt(2), isTrue);
      await engine.addToQueue(_items('y'));
      expect(_uids(engine.queue), 'axbcy');
      expect(engine.isPlayNextAt(4), isFalse);
      await engine.jumpTo(0);
      await engine.jumpTo(1);
      expect(engine.isPlayNextAt(1), isFalse, reason: '播过的绕回来也不再带标记');
    });

    test('换队列 / 清空去掉全部标记', () async {
      await engine.playQueue(_items('abc'));
      await engine.playNext(_items('x'));
      await engine.clearQueue();
      await engine.addToQueue(_items('x'));
      expect(engine.isPlayNextAt(1), isFalse);
      await engine.playNext(_items('y'));
      await engine.playQueue(_items('yz'), startIndex: 1);
      await engine.jumpTo(0);
      expect(engine.isPlayNextAt(1), isFalse);
    });

    test('撤销移除：放回原位，标记一并恢复；后端下一首随之对齐', () async {
      await engine.playQueue(_items('abc'));
      await engine.playNext(_items('x'));
      final MusicPlayItem removed = engine.queue[1];
      final bool mark = engine.isPlayNextAt(1);
      await engine.removeFromQueue(1);
      expect(backend.log.last, 'next:b');
      await engine.insertIntoQueue(1, removed, playNext: mark);
      expect(_uids(engine.queue), 'axbc');
      expect(engine.isPlayNextAt(1), isTrue);
      expect(backend.log.last, 'next:x');
    });

    test('放回当前曲之前：index 后移，当前曲不变；已在队列里的不重复放', () async {
      await engine.playQueue(_items('abc'), startIndex: 1);
      final MusicPlayItem a = engine.queue[0];
      await engine.removeFromQueue(0);
      expect(engine.index, 0);
      await engine.insertIntoQueue(0, a);
      expect(_uids(engine.queue), 'abc');
      expect(engine.index, 1);
      expect(engine.current?.trackUid, 'b');
      await engine.insertIntoQueue(3, a);
      expect(_uids(engine.queue), 'abc');
    });
  });

  test('后端自管队列（Apple Music 电台）时不能编辑', () async {
    final MusicPlayerEngine ext = MusicPlayerEngine(
      backendFactory: () => backend,
      capabilitiesOf: (MusicPlayItem i) => i.trackUid == 'radio'
          ? const MusicBackendCapabilities(
              signalPath: false,
              abLoop: false,
              externalQueue: true,
            )
          : MusicBackendCapabilities.full,
    )..onTrackStarted = (_) {};
    addTearDown(ext.dispose);
    await ext.playQueue(<MusicPlayItem>[_item('radio'), _item('b')]);
    expect(ext.canEditQueue, isFalse);
    await ext.removeFromQueue(1);
    await ext.moveInQueue(1, 0);
    await ext.playNext(_items('x'));
    await ext.addToQueue(_items('y'));
    await ext.clearQueue();
    expect(_uids(ext.queue), 'radiob');
    await ext.jumpTo(1);
    expect(ext.canEditQueue, isTrue);
  });
}
