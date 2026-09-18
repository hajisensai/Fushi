// BUG-2569 / BUG-2570：视频来源扫描的导入阶段。
//
//  (1) 扫描**不再跑任何 ffmpeg**：封面抽取从导入路径里删掉了，交给书架的封面补齐
//      产线（`HomeVideoPage._maybeBackfillCovers`，由新行落库的 watch 流触发）。
//      此前每个文件最坏两段 30s ffmpeg，串行 + 进程级排他锁 + UI isolate，几十个
//      文件的文件夹就能把导入拖到几十分钟，移动端还会把 ffprobe 全挤到超时。
//  (2) 逐文件错误隔离：一个文件失败只作废这个文件，其余照常入库，错误里指名道姓。
//      此前整个循环共用 scan 的总 catch，一个坏 sidecar 就让整批 0 条入库。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 记账用 ffmpeg 后端：任何一次调用都被记下来，且**立刻**返回失败。
///
/// 「立刻」很关键——它让本测试即使在修复前也只是变红，而不是真的等两段 30s 超时。
class _RecordingFfmpegBackend implements FfmpegBackend {
  final List<List<String>> runCalls = <List<String>>[];
  final List<List<String>> probeCalls = <List<String>>[];

  int get totalCalls => runCalls.length + probeCalls.length;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runCalls.add(args);
    return const FfmpegRunResult(returnCode: 1, output: 'stub');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    probeCalls.add(args);
    return const FfmpegRunResult(returnCode: 1, output: 'stub');
  }
}

/// 本地传输的替身：条目清单由测试给定，`copyToLocal` 按本地语义原样返回路径。
///
/// 用它是为了能列出一个**磁盘上并不存在**的 sidecar 字幕——真实 sidecar 消失
/// （外接盘掉线、SAF 权限被回收、文件正被移动）时生产代码看到的就是这个形状：
/// 条目在清单里，`readTextWithEncoding` 打开即抛。
class _FakeLocalFs implements SourceFileSystem {
  _FakeLocalFs(this.paths);

  final List<String> paths;

  @override
  bool get isLocal => true;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async =>
      <SourceFileEntry>[
        for (final String path in paths)
          SourceFileEntry(
            name: p.basename(path),
            path: path,
            isDirectory: false,
            sizeBytes: 1,
          ),
      ];

  @override
  Future<List<String>> listSiblingNames(String filePath) async =>
      paths.map(p.basename).toList();

  @override
  Future<String> readText(String filePath) => File(filePath).readAsString();

  @override
  Future<String> copyToLocal(String filePath, String destDir) async => filePath;
}

Future<SourceLibraryRow> _videoSource(FushiDatabase db, String root) async {
  final int id = await db.insertMediaSource(MediaSourcesCompanion.insert(
    label: 'Vids',
    mediaKind: 'video',
    rootPath: root,
    createdAt: 1000,
  ));
  return (await db.getMediaSourceById(id))!;
}

const String _srt = '1\n00:00:01,000 --> 00:00:02,000\nhello\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _RecordingFfmpegBackend backend;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_video_import_');
    backend = _RecordingFfmpegBackend();
    setFfmpegBackendForTesting(backend);
    // 封面目录必须解析得出来，否则抽取器会在 `videoCoversDirectory()` 上抛异常、
    // 被导入循环的内层 catch 吃掉——ffmpeg 一次也不会被调用，本测试就成了假绿
    // （实测：不接这个 mock 时「修复前」也是绿的）。
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => switch (call.method) {
        'getApplicationDocumentsDirectory' => p.join(tmp.path, 'documents'),
        'getTemporaryDirectory' => p.join(tmp.path, 'systemp'),
        'getApplicationSupportDirectory' => p.join(tmp.path, 'support'),
        _ => null,
      },
    );
  });
  tearDown(() {
    setFfmpegBackendForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    AppPaths.debugResetDocumentsLayoutCache();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('BUG-2569 导入阶段不跑 ffmpeg', () {
    test('扫描本地视频来源：一次 ffmpeg / ffprobe 都不起，封面留空入库', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      for (final String name in <String>['a.mkv', 'b.mkv', 'c.mkv']) {
        File(p.join(tmp.path, name)).writeAsStringSync('fake-video-$name');
      }

      final SourceScanSummary summary =
          await SourceLibraryScanner(db).scan(await _videoSource(db, tmp.path));

      expect(summary.succeeded, isTrue, reason: summary.error ?? '');
      expect(summary.importedMediaCount, 3);

      // 这一条是本 bug 的核心契约：导入路径上不允许再有 ffmpeg 调用。修复前每个
      // 文件都会进 extractVideoCover（内嵌封面 + 抽帧两段），这里会是 6。
      expect(
        backend.totalCalls,
        0,
        reason: '导入只负责把条目放进库；抽帧是书架补齐产线的职责',
      );

      final List<VideoBookRow> rows = await VideoBookRepository(db).listAll();
      expect(rows, hasLength(3));
      expect(
        rows.map((VideoBookRow r) => r.coverPath),
        everyElement(isNull),
        reason: '留空封面 = 交给补齐产线的信号',
      );
    });
  });

  group('BUG-2570 逐文件错误隔离', () {
    test('一个文件的 sidecar 读不了，其余照常入库，错误指名道姓', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      // good1 / good2 带真实可读字幕；broken 的 .srt 在清单里但磁盘上没有。
      File(p.join(tmp.path, 'good1.mkv')).writeAsStringSync('v');
      File(p.join(tmp.path, 'good1.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'good2.mkv')).writeAsStringSync('v');
      File(p.join(tmp.path, 'good2.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'broken.mkv')).writeAsStringSync('v');
      final String phantomSub = p.join(tmp.path, 'broken.srt'); // 不创建

      final SourceLibraryScanner scanner = SourceLibraryScanner(db);
      final SourceScanSummary summary = await scanner.scan(
        await _videoSource(db, tmp.path),
        fs: _FakeLocalFs(<String>[
          p.join(tmp.path, 'good1.mkv'),
          p.join(tmp.path, 'good1.srt'),
          p.join(tmp.path, 'good2.mkv'),
          p.join(tmp.path, 'good2.srt'),
          p.join(tmp.path, 'broken.mkv'),
          phantomSub,
        ]),
      );

      // 修复前：异常冒到 scan 的总 catch，importedMediaCount 停在 0、一条都不入库。
      expect(summary.importedMediaCount, 2, reason: '坏文件只作废自己，好文件必须入库');
      final List<VideoBookRow> rows = await VideoBookRepository(db).listAll();
      expect(
        rows.map((VideoBookRow r) => p.basename(r.videoPath)).toSet(),
        <String>{'good1.mkv', 'good2.mkv'},
      );

      // 错误仍然要报出来（不是吞掉），而且要能照着查：说清几个失败、第一个是谁。
      final String? error = summary.error;
      expect(error, isNotNull, reason: '部分失败不能静默');
      expect(error, contains('broken.mkv'));
      expect(error, contains('1 failed'));
      final SourceLibraryRow after = (await db.getMediaSourceById(
        summary.sourceId,
      ))!;
      expect(after.lastScanError, error, reason: '同一条错误要落回来源行');
      expect(after.mediaCount, 2);
    });

    test('全部文件都正常时不产生任何错误', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      File(p.join(tmp.path, 'ok.mkv')).writeAsStringSync('v');
      File(p.join(tmp.path, 'ok.srt')).writeAsStringSync(_srt);

      final SourceScanSummary summary =
          await SourceLibraryScanner(db).scan(await _videoSource(db, tmp.path));

      expect(summary.error, isNull);
      expect(summary.importedMediaCount, 1);
    });
  });
}
