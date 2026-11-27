import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_resource_check.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi_engine/media/video/media_path_probe.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// BUG-5605：网络 / 云盘挂载（rclone / WinFsp）上的 stat 能卡十几秒。注入一个「永远不
/// 答复」的假文件系统，证明 UI 路径既不同步等待、也不把卡住当成文件丢失，并且不会
/// 往卡住的挂载上叠请求。
class _BlockingFs {
  final List<String> calls = <String>[];
  final Map<String, Completer<bool>> pending = <String, Completer<bool>>{};

  /// 这些路径立刻答复（不卡）。
  final Map<String, bool> instant = <String, bool>{};

  Future<bool> exists(String path) {
    calls.add(path);
    final bool? quick = instant[path];
    if (quick != null) return Future<bool>.value(quick);
    return (pending[path] = Completer<bool>()).future;
  }

  void release(String path, bool exists) =>
      pending.remove(path)!.complete(exists);
}

void main() {
  late _BlockingFs fs;

  setUp(() {
    fs = _BlockingFs();
    debugOverrideMediaPathExists(fs.exists);
  });
  tearDown(() {
    debugOverrideMediaPathExists(null);
    MediaHandleRegistry.instance.clear();
  });

  group('probeMediaPath（有界三态探测）', () {
    test('卷不答复：超时答 unavailable，不是 missing', () {
      fakeAsync((FakeAsync async) {
        MediaPathPresence? result;
        probeMediaPath(r'Z:\anime\ep01.mkv').then((r) => result = r);
        async.elapse(kMediaPathProbeTimeout - const Duration(milliseconds: 1));
        expect(result, isNull, reason: '时限内还在等卷答复');
        async.elapse(const Duration(milliseconds: 2));
        expect(result, MediaPathPresence.unavailable);
        expect(isMediaVolumeStalled(r'Z:\anime\ep02.mkv'), isTrue);
      });
    });

    test('答复了：present / missing 照实给', () async {
      fs.instant[r'C:\a.mkv'] = true;
      fs.instant[r'C:\b.mkv'] = false;
      expect(await probeMediaPath(r'C:\a.mkv'), MediaPathPresence.present);
      expect(await probeMediaPath(r'C:\b.mkv'), MediaPathPresence.missing);
    });

    test('同路径合并在途请求；卷卡住后同卷不再发新 stat，别的卷不受影响', () {
      fakeAsync((FakeAsync async) {
        final List<MediaPathPresence> results = <MediaPathPresence>[];
        for (int i = 0; i < 5; i++) {
          probeMediaPath(r'Z:\anime\ep01.mkv').then(results.add);
        }
        async.flushMicrotasks();
        expect(fs.calls, <String>[
          r'Z:\anime\ep01.mkv',
        ], reason: '同路径只压一个 stat');
        async.elapse(kMediaPathProbeTimeout);
        expect(results, everyElement(MediaPathPresence.unavailable));

        // 卷卡着：同卷其它文件立刻答 unavailable，不再往挂载上压 stat。
        MediaPathPresence? other;
        probeMediaPath(r'Z:\anime\ep02.mkv').then((r) => other = r);
        async.flushMicrotasks();
        expect(other, MediaPathPresence.unavailable);
        expect(fs.calls, hasLength(1));

        // 本机盘不受牵连。
        fs.instant[r'C:\local.mkv'] = true;
        MediaPathPresence? local;
        probeMediaPath(r'C:\local.mkv').then((r) => local = r);
        async.flushMicrotasks();
        expect(local, MediaPathPresence.present);
      });
    });

    test('同卷并发上限：不把 dart:io IO 线程池占满', () {
      fakeAsync((FakeAsync async) {
        for (int i = 0; i < 6; i++) {
          probeMediaPath(
            'Z:\\anime\\ep0$i.mkv',
            timeout: const Duration(hours: 1),
          );
        }
        async.flushMicrotasks();
        expect(fs.calls, hasLength(kMediaProbeConcurrencyPerVolume));
        // 一个返回，排队的下一个才发。
        fs.release(fs.calls.first, true);
        async.flushMicrotasks();
        expect(fs.calls, hasLength(kMediaProbeConcurrencyPerVolume + 1));
      });
    });

    test('卡住的 stat 返回 → 卷恢复，等待方被唤醒，之后照常探测', () {
      fakeAsync((FakeAsync async) {
        probeMediaPath(r'\\server\openlist\ep01.mkv');
        async.elapse(kMediaPathProbeTimeout);
        expect(isMediaVolumeStalled(r'\\server\openlist\ep09.mkv'), isTrue);
        bool recovered = false;
        whenMediaVolumeRecovered(
          r'\\SERVER\OpenList\x.mkv',
        ).then((_) => recovered = true);
        async.flushMicrotasks();
        expect(recovered, isFalse);

        fs.release(r'\\server\openlist\ep01.mkv', true);
        async.flushMicrotasks();
        expect(recovered, isTrue);
        expect(isMediaVolumeStalled(r'\\server\openlist\ep09.mkv'), isFalse);

        fs.instant[r'\\server\openlist\ep01.mkv'] = true;
        MediaPathPresence? again;
        probeMediaPath(r'\\server\openlist\ep01.mkv').then((r) => again = r);
        async.flushMicrotasks();
        expect(again, MediaPathPresence.present);
      });
    });

    test('卷键：盘符 / UNC 大小写不敏感，POSIX 取根下两级', () {
      expect(mediaVolumeKeyOf(r'Z:\a\b.mkv'), mediaVolumeKeyOf('z:/c.mkv'));
      expect(
        mediaVolumeKeyOf(r'\\Server\Share\a.mkv'),
        mediaVolumeKeyOf(r'\\server\share\b\c.mkv'),
      );
      expect(
        mediaVolumeKeyOf(r'\\server\share\a.mkv'),
        isNot(mediaVolumeKeyOf(r'\\server\other\a.mkv')),
      );
      expect(mediaVolumeKeyOf('/Volumes/nas/a/b.mkv'), '/Volumes/nas');
      expect(
        mediaVolumeKeyOf('/mnt/nas/a.mkv'),
        isNot(mediaVolumeKeyOf('/home/me/a.mkv')),
      );
    });
  });

  group('UI 路径不同步等待、不误判丢失', () {
    test('起播存在性检查：卷卡住不判缺失', () {
      fakeAsync((FakeAsync async) {
        bool? missing;
        isLocalVideoResourceMissing(
          r'Z:\anime\ep01.mkv',
        ).then((r) => missing = r);
        async.flushMicrotasks();
        expect(missing, isNull, reason: '调用立即返回 Future，不同步等 stat');
        async.elapse(kMediaPathProbeTimeout);
        expect(missing, isFalse, reason: '暂不可用 ≠ 文件丢失');
      });
    });

    test('起播存在性检查：卷答复不在才判缺失', () async {
      fs.instant[r'C:\gone.mkv'] = false;
      expect(await isLocalVideoResourceMissing(r'C:\gone.mkv'), isTrue);
    });

    test('ffmpeg 取帧：输入卷卡住时有界返回 null，不起 ffmpeg', () {
      fakeAsync((FakeAsync async) {
        bool done = false;
        String? produced = 'sentinel';
        extractVideoFrameViaFfmpeg(
          inputPath: r'Z:\anime\ep01.mkv',
          outputPath: r'C:\tmp\never.jpg',
        ).then((String? r) {
          produced = r;
          done = true;
        });
        async.flushMicrotasks();
        expect(done, isFalse);
        async.elapse(kMediaPathProbeTimeout);
        expect(done, isTrue);
        expect(produced, isNull);
      });
    });
  });

  group('OffscreenVideoFrameGrabber：源读不动时停手，恢复后再起', () {
    test('探测答 unavailable → 暂停，不起 ffmpeg 也不再探测；卷恢复后自动再起', () async {
      int probes = 0;
      int extracts = 0;
      MediaPathPresence answer = MediaPathPresence.unavailable;
      final Completer<void> recovered = Completer<void>();
      final OffscreenVideoFrameGrabber grabber = OffscreenVideoFrameGrabber(
        videoPath: r'Z:\anime\ep01.mkv',
        sourceProbe: (_) async {
          probes++;
          return answer;
        },
        whenSourceRecovered: (_) => recovered.future,
        frameExtractor:
            ({
              required String inputPath,
              required String outputPath,
              required double atSeconds,
              required int scaleWidth,
              required void Function() onTimedOut,
            }) async {
              extracts++;
              return null;
            },
      );
      addTearDown(grabber.dispose);

      expect(await grabber.grab(0), isNull);
      expect(grabber.isSourceSuspended, isTrue);
      for (int i = 1; i <= 10; i++) {
        expect(await grabber.grab(i * 1000), isNull);
      }
      await grabber.warmUp();
      expect(probes, 1, reason: '暂停期间不再往卡住的挂载上探测');
      expect(extracts, 0, reason: '暂停期间不起 ffmpeg');

      answer = MediaPathPresence.present;
      recovered.complete();
      await Future<void>.delayed(Duration.zero);
      expect(grabber.isSourceSuspended, isFalse);
      await grabber.grab(42000);
      expect(probes, 2);
      expect(extracts, 1, reason: '卷恢复后取帧照常再起');
    });

    test('ffmpeg 连续跑满时限 → 暂停（成功过也一样），不再起新的 ffmpeg', () async {
      int extracts = 0;
      final OffscreenVideoFrameGrabber grabber = OffscreenVideoFrameGrabber(
        videoPath: r'Z:\anime\ep01.mkv',
        sourceProbe: (_) async => MediaPathPresence.present,
        whenSourceRecovered: (_) async {},
        frameExtractor:
            ({
              required String inputPath,
              required String outputPath,
              required double atSeconds,
              required int scaleWidth,
              required void Function() onTimedOut,
            }) async {
              extracts++;
              onTimedOut();
              return null;
            },
      );
      addTearDown(grabber.dispose);

      await grabber.grab(1000);
      expect(grabber.isSourceSuspended, isFalse);
      await grabber.grab(2000);
      expect(grabber.isSourceSuspended, isTrue);
      for (int i = 3; i < 20; i++) {
        await grabber.grab(i * 1000);
      }
      expect(extracts, grabber.ffmpegTimeoutLimit);
      // 卷没卡（源可达只是读不动）：不会因为「恢复」回调立刻完成就又起一轮风暴。
      await Future<void>.delayed(Duration.zero);
      expect(grabber.isSourceSuspended, isTrue);
    });

    test('取帧器单飞：ffmpeg 在跑时并发请求只保留最新一个', () async {
      final List<double> started = <double>[];
      final List<Completer<String?>> running = <Completer<String?>>[];
      final OffscreenVideoFrameGrabber grabber = OffscreenVideoFrameGrabber(
        videoPath: r'C:\a.mkv',
        sourceProbe: (_) async => MediaPathPresence.present,
        whenSourceRecovered: (_) async {},
        frameExtractor:
            ({
              required String inputPath,
              required String outputPath,
              required double atSeconds,
              required int scaleWidth,
              required void Function() onTimedOut,
            }) {
              started.add(atSeconds);
              final Completer<String?> c = Completer<String?>();
              running.add(c);
              return c.future;
            },
      );
      addTearDown(grabber.dispose);

      final Future<Object?> first = grabber.grab(1000);
      await Future<void>.delayed(Duration.zero);
      final Future<Object?> stale = grabber.grab(2000);
      final Future<Object?> latest = grabber.grab(3000);
      await Future<void>.delayed(Duration.zero);
      expect(started, <double>[1.0], reason: '在跑时不另起 ffmpeg');

      running.first.complete(null);
      expect(await first, isNull);
      expect(await stale, isNull, reason: '被更新的请求顶掉');
      await Future<void>.delayed(Duration.zero);
      expect(started, <double>[1.0, 3.0]);
      running.last.complete(null);
      expect(await latest, isNull);
    });
  });
}
