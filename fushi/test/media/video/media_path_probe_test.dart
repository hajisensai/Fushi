import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_resource_check.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi_engine/media/video/media_path_probe.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
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
  });

  group('awaitMediaPathExists（必达路径：无时限，不给假答案）', () {
    test('卷慢过有界时限：照样等到真实答复，同时把卷记为卡住让推测性路径停手', () {
      fakeAsync((FakeAsync async) {
        bool? exists;
        awaitMediaPathExists(r'Z:\anime\ep01.mkv').then((r) => exists = r);
        async.elapse(kMediaPathProbeTimeout * 5);
        expect(exists, isNull, reason: '冷挂载首个 stat 慢不是「不在」，继续等');
        expect(isMediaVolumeStalled(r'Z:\anime\ep02.mkv'), isTrue);

        MediaPathPresence? speculative;
        probeMediaPath(r'Z:\anime\ep02.mkv').then((r) => speculative = r);
        async.flushMicrotasks();
        expect(speculative, MediaPathPresence.unavailable);

        fs.release(r'Z:\anime\ep01.mkv', true);
        async.flushMicrotasks();
        expect(exists, isTrue);
        expect(isMediaVolumeStalled(r'Z:\anime\ep02.mkv'), isFalse);
      });
    });

    test('卷卡着时不往挂载上压新 stat：等恢复后再问，答复照实给', () {
      fakeAsync((FakeAsync async) {
        probeMediaPath(r'Z:\anime\ep01.mkv');
        async.elapse(kMediaPathProbeTimeout);
        expect(isMediaVolumeStalled(r'Z:\anime\ep02.mkv'), isTrue);

        bool? exists;
        awaitMediaPathExists(r'Z:\anime\ep02.mkv').then((r) => exists = r);
        async.elapse(kMediaPathProbeTimeout * 3);
        expect(fs.calls, <String>[r'Z:\anime\ep01.mkv'], reason: '卷卡着不发新 stat');
        expect(exists, isNull);

        fs.instant[r'Z:\anime\ep02.mkv'] = false;
        fs.release(r'Z:\anime\ep01.mkv', true);
        async.flushMicrotasks();
        expect(fs.calls, contains(r'Z:\anime\ep02.mkv'));
        expect(exists, isFalse, reason: '卷答复了才判不在');
      });
    });

    test('排队期间卷卡住（stat 被跳过）：恢复后重来，不当成不在', () {
      fakeAsync((FakeAsync async) {
        // 占满同卷并发槽位，第三个排队。
        probeMediaPath(r'Z:\anime\busy0.mkv');
        probeMediaPath(r'Z:\anime\busy1.mkv');
        bool? exists;
        awaitMediaPathExists(r'Z:\anime\queued.mkv').then((r) => exists = r);
        async.flushMicrotasks();
        expect(fs.calls, hasLength(kMediaProbeConcurrencyPerVolume));

        // 占槽的 stat 超时 → 卷卡住；其中一个返回让出槽位，排队那条被跳过。
        async.elapse(kMediaPathProbeTimeout);
        fs.release(r'Z:\anime\busy0.mkv', true);
        async.flushMicrotasks();
        expect(exists, isNull, reason: '被跳过不是「不在」');
        expect(fs.calls, isNot(contains(r'Z:\anime\queued.mkv')));

        fs.instant[r'Z:\anime\queued.mkv'] = true;
        fs.release(r'Z:\anime\busy1.mkv', true);
        async.flushMicrotasks();
        expect(exists, isTrue);
      });
    });

    test('导入 / 制卡用的 ffmpeg 取帧：输入卷慢时等它答复，不静默返回 null，也不同步等', () {
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
        expect(done, isFalse, reason: '调用立即返回 Future，不同步等 stat');
        async.elapse(kMediaPathProbeTimeout * 5);
        expect(done, isFalse, reason: '冷挂载慢过 2 s 也不放弃（审查后修正）');
        fs.release(r'Z:\anime\ep01.mkv', false);
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(produced, isNull, reason: '卷答复不在才返回 null');
      });
    });

    test('导入抽封面 / 元数据：同样等真实答复，同路径合并成一个 stat', () {
      fakeAsync((FakeAsync async) {
        bool coverDone = false;
        bool metaDone = false;
        extractEmbeddedCoverViaFfmpeg(
          audioPath: r'Z:\music\a.flac',
          outputPath: r'C:\tmp\never.jpg',
        ).then((_) => coverDone = true);
        extractAudioMetadataViaFfprobe(
          inputPath: r'Z:\music\a.flac',
        ).then((_) => metaDone = true);
        async.elapse(kMediaPathProbeTimeout * 5);
        expect(coverDone, isFalse);
        expect(metaDone, isFalse);
        expect(fs.calls, <String>[r'Z:\music\a.flac']);
        fs.release(r'Z:\music\a.flac', false);
        async.flushMicrotasks();
        expect(coverDone, isTrue);
        expect(metaDone, isTrue);
      });
    });

    test('片段导出：卷慢不报「暂不可用」，答复不在才报 inputMissing', () {
      fakeAsync((FakeAsync async) {
        VideoClipExportResult? result;
        exportVideoClipViaFfmpeg(
          inputPath: r'Z:\anime\ep01.mkv',
          startMs: 0,
          endMs: 1000,
          outputPath: r'C:\tmp\never_clip.mp4',
        ).then((VideoClipExportResult r) => result = r);
        async.elapse(kMediaPathProbeTimeout * 5);
        expect(result, isNull);
        fs.release(r'Z:\anime\ep01.mkv', false);
        async.flushMicrotasks();
        expect(result?.failure, VideoClipExportFailure.inputMissing);
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

    test('卷卡住引起的超时 / 暂停不计入「没 ffmpeg」熔断：卷恢复后缩略图回得来（审查后修正）', () async {
      // 探测按调用顺序答复（取帧前一次；ffmpeg 连续超时后复查一次）。
      final List<MediaPathPresence> answers = <MediaPathPresence>[
        MediaPathPresence.present, // grab(1000)
        MediaPathPresence.present, // grab(2000)
        MediaPathPresence.unavailable, // grab(2000) 连续超时后复查：卷卡住
        MediaPathPresence.present, // grab(3000)
        MediaPathPresence.unavailable, // grab(4000)
        MediaPathPresence.present, // grab(5000)
      ];
      bool timeOut = true;
      Completer<void> recovered = Completer<void>();
      int extracts = 0;
      final OffscreenVideoFrameGrabber grabber = OffscreenVideoFrameGrabber(
        videoPath: r'Z:\anime\ep01.mkv',
        sourceProbe: (_) async => answers.removeAt(0),
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
              if (timeOut) onTimedOut();
              return null;
            },
      );
      addTearDown(grabber.dispose);

      // 冷挂载：两次 ffmpeg 跑满时限，复查时卷已卡住 → 暂停，等恢复。
      await grabber.grab(1000);
      await grabber.grab(2000);
      expect(grabber.isSourceSuspended, isTrue);
      timeOut = false;
      recovered.complete();
      await Future<void>.delayed(Duration.zero);
      expect(grabber.isUnavailable, isFalse);

      // 恢复后一次普通失败（片尾取不到帧）：旧实现把两次超时也算进「从没成功过」，
      // 凑满 3 次就永久熔断、只显时间戳。
      await grabber.grab(3000);
      expect(grabber.isUnavailable, isFalse);

      // 探测答 unavailable 的暂停同样不计数：再卡一次、再恢复，照样能取。
      recovered = Completer<void>();
      await grabber.grab(4000);
      expect(grabber.isSourceSuspended, isTrue);
      recovered.complete();
      await Future<void>.delayed(Duration.zero);
      await grabber.grab(5000);
      expect(grabber.isUnavailable, isFalse);
      expect(extracts, 4);
      expect(answers, isEmpty);
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
