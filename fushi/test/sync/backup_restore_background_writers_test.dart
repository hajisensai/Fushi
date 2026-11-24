// BUG-5387（反馈 hfLuOcL7n0）：导入备份换库时，媒体库后台任务（来源扫描、刮削、整文件
// 哈希升级、封面回填、响度回写）还在跑，写进已关闭 / 已换掉的库。关库（备份恢复走的
// `AppModel.closeDatabase` → `FushiDatabase.close`）必须先取消并等它们停稳；停稳之后
// 它们拿着旧库读出的行身份，一条也写不进去。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_loudness_scanner.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/source_library/source_scan_temp.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_content_fingerprint.dart';
import 'package:path/path.dart' as p;

/// 列目录卡在 [gate] 上的本地文件系统：模拟扫描正在读一个大来源（网络盘）时用户点了
/// 「导入备份」。
class _GatedFs implements SourceFileSystem {
  _GatedFs(this.gate);

  final Future<void> gate;
  final Completer<void> listing = Completer<void>();
  static const LocalSourceFileSystem _local = LocalSourceFileSystem();

  @override
  bool get isLocal => true;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    if (!listing.isCompleted) listing.complete();
    await gate;
    return _local.listFiles(dirPath, recursive: recursive);
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) =>
      _local.listSiblingNames(filePath);

  @override
  Future<String> readText(String filePath) => _local.readText(filePath);

  @override
  Future<String> copyToLocal(String filePath, String destDir) =>
      _local.copyToLocal(filePath, destDir);
}

/// 一首要测很久的 FFmpeg（真机上一首最长 5 分钟）。
class _SlowFfmpeg implements FfmpegBackend {
  final Completer<FfmpegRunResult> result = Completer<FfmpegRunResult>();
  final Completer<void> started = Completer<void>();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}

MusicTracksCompanion _track(String uid) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  durationMs: const Value<int?>(2000),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bug5387_'));
  tearDown(() {
    debugResetSourceScanTempSession();
    debugSourceScanTempRoot = null;
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放不算失败。
    }
  });

  test('扫描进行中开始换库：关库等扫描停稳，扫描之后一条都写不进库', () async {
    final String dbFile = p.join(tmp.path, 'fushi.db');
    final String root = p.join(tmp.path, 'anime');
    for (int i = 0; i < 5; i++) {
      File(p.join(root, 'Show - 0$i.mkv'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, i));
    }
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase(File(dbFile)),
    );
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'anime',
        mediaKind: 'video',
        rootPath: root,
        recursive: const Value<bool>(true),
        createdAt: 1000,
      ),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;

    final Completer<void> gate = Completer<void>();
    final _GatedFs fs = _GatedFs(gate.future);
    Object? scanError;
    final Future<void> scan =
        SourceLibraryScanner(
              db,
              transcribeAudiobook: null,
              requestVideoContentFullHash: () {},
            )
            .scan(source, fs: fs)
            .then<void>(
              (_) {},
              onError: (Object e) {
                scanError = e;
              },
            );
    await fs.listing.future;
    expect(db.backgroundWork.inFlightLabels, contains('source.scan'));

    // 用户确认导入备份 → 关库。
    bool closed = false;
    final Future<void> closing = db.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse, reason: '扫描还没停，库不能先关（否则它打在已关闭的连接上）');

    // 列目录回来了：扫描继续往下走，但它的 SQL 被拦下。
    gate.complete();
    await closing;
    await scan;
    expect(scanError, isA<DatabaseWorkCancelledException>());

    final FushiDatabase reopened = FushiDatabase.forTesting(
      NativeDatabase(File(dbFile)),
    );
    addTearDown(reopened.close);
    expect(
      await reopened.select(reopened.videoBooks).get(),
      isEmpty,
      reason: '取消后的扫描一条视频都不能入库',
    );
    expect(
      (await reopened.getMediaSourceById(sourceId))!.lastScannedAt,
      isNull,
      reason: '被取消的扫描不写扫描结果',
    );
  });

  test('响度测到一半换库：关库不等 FFmpeg，旧库的曲目身份写不进新库', () async {
    final FushiDatabase oldDb = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final FushiDatabase newDb = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(newDb.close);
    await oldDb.into(oldDb.musicTracks).insert(_track('a'));
    // 恢复进来的新库里恰好有同一个 track_uid。
    await newDb.into(newDb.musicTracks).insert(_track('a'));

    FushiDatabase current = oldDb;
    final _SlowFfmpeg ffmpeg = _SlowFfmpeg();
    final MusicLoudnessScanner scanner = MusicLoudnessScanner(
      database: () => current,
      enabled: () => true,
      ffmpeg: () => ffmpeg,
    );
    final Future<void> scanning = scanner.schedule();
    await ffmpeg.started.future;

    // 换库：关旧库（不等那首测完），换上新库。
    await oldDb.close();
    current = newDb;
    await scanning;
    expect(scanner.isRunning, isFalse);
    expect(scanner.lastError, isNull);

    // 旧那首这时才测完：结果被丢弃，不写进新库。
    ffmpeg.result.complete(
      const FfmpegRunResult(returnCode: 1, output: 'late'),
    );
    await Future<void>.delayed(Duration.zero);
    final MusicTrackRow a = (await newDb.getMusicTrack('a'))!;
    expect(a.r128ScannedAt, isNull);
    expect(a.rgTrackGain, isNull);
  });

  test('整文件哈希升级算到一半换库：关库不等哈希，升级器按取消收尾', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File video = File(p.join(tmp.path, 'v', '01.mkv'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List<int>.generate(200 * 1024, (int i) => i % 251));
    await db
        .into(db.videoBooks)
        .insert(
          VideoBooksCompanion.insert(
            bookUid: 'video/01',
            title: '01',
            videoPath: video.path,
          ),
        );
    final VideoContentFingerprint? sampled =
        await computeVideoContentFingerprint(video.path);
    await recordVideoContentFingerprint(db, 'video/01', sampled!);

    final Completer<VideoContentFingerprint?> hash =
        Completer<VideoContentFingerprint?>();
    final Completer<void> hashing = Completer<void>();
    final VideoContentFullHashUpgrader upgrader = VideoContentFullHashUpgrader(
      db,
      fullHashOf: (String _) {
        if (!hashing.isCompleted) hashing.complete();
        return hash.future;
      },
    );
    upgrader.request();
    final Future<int>? running = upgrader.running;
    await hashing.future;
    await db.close();
    expect(await running, 0);
    hash.complete(await computeVideoContentFullHash(video.path));
  });
}
