// TS 增量解复用会话的生命周期（HBK-AUDIT-003）：LRU 淘汰与「同路径文件消失」都只把会话
// 移出缓存，原生句柄必须等 worker isolate 上在途的读取结束才释放，且恰好释放一次。
//
// 会话换成可控屏障的 fake：读取挂在 [_BarrierSession.gate] 上，模拟 worker 还拿着裸地址
// 读 / 喂的时刻；close 若落在读取进行中即记一次 use-after-free。
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';
import 'package:test/test.dart';

/// 读取可被屏障挂住的假会话，按事件顺序记日志。
class _BarrierSession implements MpegTsSubtitleDemuxSession {
  _BarrierSession(this.id, this.log, this.readStarted, this.gate);

  final int id;
  final List<String> log;

  /// 读取已进入「worker 持有地址」阶段。
  final Completer<void> readStarted;

  /// 非 null 时读取停在这里，直到测试 complete 它。
  final Completer<void>? gate;

  bool _readInFlight = false;
  int closeCount = 0;

  @override
  int get handle => 0;

  @override
  final List<BitmapSubtitlePacket> packets = <BitmapSubtitlePacket>[];

  @override
  bool completed = false;

  @override
  int get needOffset => 0;

  @override
  Future<List<BitmapSubtitlePacket>> readMore(
    String path, {
    required bool complete,
  }) async {
    if (closeCount > 0) {
      log.add('read-after-close:$id');
      throw StateError('demux session closed');
    }
    _readInFlight = true;
    log.add('read-start:$id');
    if (!readStarted.isCompleted) readStarted.complete();
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    _readInFlight = false;
    log.add('read-end:$id');
    if (complete) completed = true;
    return const <BitmapSubtitlePacket>[];
  }

  @override
  void close() {
    closeCount++;
    log.add(_readInFlight ? 'use-after-free:$id' : 'close:$id');
  }
}

void main() {
  late Directory dir;
  late List<_BarrierSession> sessions;
  late List<String> log;

  /// 第 N 个新建会话的读取屏障（测试预先装好）。
  late Map<int, Completer<void>> gates;

  /// 第 N 个新建会话首次开始读取。
  late List<Completer<void>> started;
  late MpegTsSubtitleDemuxSession Function() originalFactory;

  /// 建一个带抽轨头（DVB，经 TS 承载）的载荷文件。
  String payload(String name) {
    final String path = '${dir.path}/$name.ts';
    File(path).writeAsBytesSync(Uint8List.fromList(<int>[0x47, 0x00, 0x00]));
    File(bitmapSubtitleTrackHeaderPath(path)).writeAsStringSync(
      jsonEncode(
        const BitmapSubtitleTrackHeader(
          codec: BitmapSubtitleCodec.dvb,
        ).toJson(),
      ),
    );
    return path;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_ts_lifecycle_');
    sessions = <_BarrierSession>[];
    log = <String>[];
    gates = <int, Completer<void>>{};
    started = List<Completer<void>>.generate(16, (_) => Completer<void>());
    originalFactory = debugTsDemuxSessionFactory;
    debugTsDemuxSessionFactory = () {
      final int id = sessions.length;
      final _BarrierSession s = _BarrierSession(
        id,
        log,
        started[id],
        gates[id],
      );
      sessions.add(s);
      return s;
    };
  });

  tearDown(() async {
    debugRetireAllTsDemuxSessions();
    await pumpEventQueue();
    debugTsDemuxSessionFactory = originalFactory;
    dir.deleteSync(recursive: true);
  });

  test(
    'evicting the LRU session waits for its in-flight worker read',
    () async {
      final List<String> paths = <String>[
        for (int i = 0; i < 5; i++) payload('track$i'),
      ];
      final Completer<void> gate = gates[0] = Completer<void>();

      final Future<void> first = readGraphicSubtitleTrackInBackground(paths[0]);
      // 第 1 路的 worker 读取开始并停在屏障上。
      await started[0].future;

      // 第 2–5 路：第 5 路新建会话时缓存已满 4 条，淘汰最久未用的第 1 路。
      for (int i = 1; i < 5; i++) {
        await readGraphicSubtitleTrackInBackground(paths[i]);
      }
      expect(sessions, hasLength(5));
      await pumpEventQueue();
      expect(sessions[0].closeCount, 0, reason: 'worker 还在用第 1 路的原生句柄时不得释放');

      gate.complete();
      await first;
      await pumpEventQueue();

      expect(sessions[0].closeCount, 1, reason: '被淘汰的会话最终必须释放（不泄漏）');
      expect(log, isNot(contains('use-after-free:0')));
      expect(log, isNot(contains('read-after-close:0')));
      expect(log.indexOf('read-end:0'), lessThan(log.indexOf('close:0')));
      for (int i = 1; i < 5; i++) {
        expect(sessions[i].closeCount, 0, reason: '仍在缓存里的会话不该被释放');
      }
    },
  );

  test(
    'payload vanishing mid-read defers close until the read finishes',
    () async {
      final String path = payload('vanishing');
      final Completer<void> gate = gates[0] = Completer<void>();

      final Future<void> inFlight = readGraphicSubtitleTrackInBackground(path);
      await started[0].future;

      // 抽轨重来 / 被清理：文件消失，下一次读取走「文件不存在」分支丢弃这条会话。
      File(path).deleteSync();
      expect(await readGraphicSubtitleTrackInBackground(path), isEmpty);
      await pumpEventQueue();
      expect(sessions[0].closeCount, 0, reason: '在途读取还拿着原生句柄');

      gate.complete();
      await inFlight;
      await pumpEventQueue();

      expect(sessions[0].closeCount, 1);
      expect(log, isNot(contains('use-after-free:0')));
      expect(log.indexOf('read-end:0'), lessThan(log.indexOf('close:0')));
      // 文件消失的分支不会为这条路径再建会话。
      expect(sessions, hasLength(1));
    },
  );

  test('a completed read releases its session exactly once', () async {
    final String path = payload('done');
    await readGraphicSubtitleTrackInBackground(path, complete: true);
    await pumpEventQueue();
    expect(sessions, hasLength(1));
    expect(sessions[0].closeCount, 1);

    // 已收尾释放的会话不在缓存里：再丢弃 / 清场都不会二次释放。
    File(path).deleteSync();
    await readGraphicSubtitleTrackInBackground(path);
    debugRetireAllTsDemuxSessions();
    await pumpEventQueue();
    expect(sessions[0].closeCount, 1);
  });
}
