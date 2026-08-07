import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// loopback fake：按**解码后**路径供字节，支持 Range，可在 CBZ 传输中途挂起
/// （测取消）。照 `manga_ocr_model_downloader_test.dart` 的 `_ModelServer` 思路。
class _VolumeServer {
  _VolumeServer(this.server) {
    server.listen(_handle);
  }

  final HttpServer server;
  final Map<String, List<int>> payloads = <String, List<int>>{};
  final List<String?> cbzRangeHeaders = <String?>[];
  bool supportRange = true;

  /// 非 null 时：CBZ 响应先写这么多字节、flush，等 [release] 完成后再写余下。
  int? holdCbzAfterBytes;
  final Completer<void> release = Completer<void>();

  static Future<_VolumeServer> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _VolumeServer(server);
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    // 客户端取消会中途断连：写入报错吞掉，避免未处理异步错误判挂测试。
    try {
      final String path = '/${request.uri.pathSegments.join('/')}';
      final List<int>? payload = payloads[path];
      if (payload == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final bool isCbz = path.endsWith('.cbz');
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (isCbz) cbzRangeHeaders.add(range);

      int offset = 0;
      if (range != null && supportRange) {
        final RegExpMatch? match =
            RegExp(r'^bytes=(\d+)-$').firstMatch(range.trim());
        offset = match == null ? 0 : int.parse(match.group(1)!);
        if (offset >= payload.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      final List<int> body = payload.sublist(offset);
      request.response.contentLength = body.length;

      final int? hold = isCbz ? holdCbzAfterBytes : null;
      if (hold != null && hold < body.length) {
        // 前段必须真正上线（默认 8KB 输出缓冲会吞掉小前段导致两端互等死锁）。
        request.response.bufferOutput = false;
        request.response.add(body.sublist(0, hold));
        await request.response.flush();
        await release.future;
        request.response.add(body.sublist(hold));
      } else {
        request.response.add(body);
      }
      await request.response.close();
    } catch (_) {}
  }
}

/// 现场构造一个 CBZ（顶层 `<volume>/` 目录 + 假 jpg）与配套 `.mokuro` JSON。
List<int> _buildCbz(String volume, Map<String, List<int>> images) {
  final Archive archive = Archive();
  images.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile('$volume/$name', bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

String _buildMokuro(String volume, List<String> imageNames) {
  return jsonEncode(<String, Object?>{
    'version': '0.2.0',
    'title': 'ソラの本',
    'volume': volume,
    'pages': <Object?>[
      for (final String name in imageNames)
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': '$volume/$name',
          'blocks': <Object?>[
            <String, Object?>{
              'box': <int>[10, 20, 110, 220],
              'vertical': true,
              'font_size': 32,
              'lines': <String>['一行目'],
            },
          ],
        },
    ],
  });
}

void main() {
  // 注意：不初始化 TestWidgetsFlutterBinding——它会把所有 HttpClient mock 成
  // 恒 400，而本套件走 loopback 真 HTTP；EpubStorage.debugBaseDirectoryOverride
  // 已绕开 path_provider，无需 binding。

  const String series = 'Comic #1';
  const String volume = 'vol1';

  late _VolumeServer server;
  late Directory appDocDir;
  late Directory stagingRoot;
  late HibikiDatabase db;

  setUp(() async {
    server = await _VolumeServer.start();
    appDocDir = await Directory.systemTemp.createTemp('mokuromoe_app');
    stagingRoot = await Directory.systemTemp.createTemp('mokuromoe_staging');
    EpubStorage.debugBaseDirectoryOverride = appDocDir.path;
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await server.close();
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[appDocDir, stagingRoot]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  MokuroMoeVolumeDownloader downloader({int interval = 4}) =>
      MokuroMoeVolumeDownloader(
        client: MokuroMoeClient(
            baseUrl: server.baseUrl, createClient: HttpClient.new),
        createClient: HttpClient.new,
        stagingRoot: stagingRoot,
        progressByteInterval: interval,
      );

  Directory stagingDir() => Directory(p.join(
        stagingRoot.path,
        sanitizeTtuFilename(series),
        sanitizeTtuFilename(volume),
      ));

  void serveVolume({List<int>? cbz}) {
    final List<int> zipBytes = cbz ??
        _buildCbz(volume, <String, List<int>>{
          '001.jpg': <int>[1, 2, 3],
          '002.jpg': <int>[4, 5, 6],
        });
    server.payloads['/mokuro-reader/$series/$volume.cbz'] = zipBytes;
    server.payloads['/mokuro-reader/$series/$volume.mokuro'] =
        utf8.encode(_buildMokuro(volume, <String>['001.jpg', '002.jpg']));
  }

  test('端到端：下载 → 解包 → importFromMokuroPath 落库，阶段有序、staging 清理', () async {
    serveVolume();

    final List<MokuroMoeVolumeDownloadEvent> events = await downloader()
        .run(db: db, seriesName: series, volumeName: volume)
        .toList();

    // 阶段按序出现且以 done 收尾。
    final List<MokuroMoeDownloadStage> stages =
        events.map((MokuroMoeVolumeDownloadEvent e) => e.stage).toList();
    expect(stages.first, MokuroMoeDownloadStage.downloadingMokuro);
    expect(stages, contains(MokuroMoeDownloadStage.downloadingCbz));
    expect(stages, contains(MokuroMoeDownloadStage.extracting));
    expect(stages, contains(MokuroMoeDownloadStage.importing));
    expect(stages.last, MokuroMoeDownloadStage.done);

    final MokuroMoeVolumeDownloadEvent done = events.last;
    expect(done.skippedExisting, isFalse);
    final String bookKey = done.bookKey!;
    // 标题 = `<系列> <卷>`（volumeTitle 口径）。
    expect(
        bookKey,
        sanitizeTtuFilename(
            MokuroMoeVolumeDownloader.volumeTitle(series, volume)));

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull);
    expect(row!.format, 'manga');
    expect(row.chapterCount, 2);
    expect(File(p.join(row.extractDir, 'manga.json')).existsSync(), isTrue);
    // 成功后 staging（cbz/.mokuro/extract）整体清理。
    expect(stagingDir().existsSync(), isFalse);
  });

  test('同卷重跑：DuplicatePolicy.skip() 命中 → done(skippedExisting=true)，不建重复行',
      () async {
    serveVolume();
    await downloader()
        .run(db: db, seriesName: series, volumeName: volume)
        .drain<void>();
    serveVolume(); // 重新供流（上一轮已消费）。

    final List<MokuroMoeVolumeDownloadEvent> events = await downloader()
        .run(db: db, seriesName: series, volumeName: volume)
        .toList();

    expect(events.last.stage, MokuroMoeDownloadStage.done);
    expect(events.last.skippedExisting, isTrue);
    expect(events.last.bookKey, isNull);
    expect((await db.getAllEpubBooks()).length, 1);
  });

  test('断点续传：预置 .part 触发 Range bytes=N-，拼接后 zip 完整可导入', () async {
    final List<int> zipBytes = _buildCbz(volume, <String, List<int>>{
      '001.jpg': List<int>.generate(64, (int i) => i % 251),
      '002.jpg': <int>[4, 5, 6],
    });
    serveVolume(cbz: zipBytes);
    final Directory staging = stagingDir()..createSync(recursive: true);
    File(p.join(staging.path, 'volume.cbz.part'))
        .writeAsBytesSync(zipBytes.sublist(0, 10));

    final List<MokuroMoeVolumeDownloadEvent> events = await downloader()
        .run(db: db, seriesName: series, volumeName: volume)
        .toList();

    expect(server.cbzRangeHeaders.single, 'bytes=10-');
    expect(events.last.stage, MokuroMoeDownloadStage.done);
    expect(events.last.bookKey, isNotNull);
  });

  test('zip 路径穿越（../）：解包报错终止，不在目标外落文件', () async {
    final Archive evil = Archive();
    evil.addFile(ArchiveFile('../evil.jpg', 3, <int>[1, 2, 3]));
    evil.addFile(ArchiveFile('$volume/001.jpg', 3, <int>[1, 2, 3]));
    serveVolume(cbz: ZipEncoder().encode(evil)!);

    await expectLater(
      downloader()
          .run(db: db, seriesName: series, volumeName: volume)
          .drain<void>(),
      throwsA(isA<StateError>()),
    );
    // `../evil.jpg` 若被解出会落在 staging 目录（extract 的父级）——必须不存在。
    expect(File(p.join(stagingDir().path, 'evil.jpg')).existsSync(), isFalse);
    expect(File(p.join(stagingRoot.path, 'evil.jpg')).existsSync(), isFalse);
    // 失败只清解包半成品，已下完的 cbz 保留供重试。
    expect(File(p.join(stagingDir().path, 'volume.cbz')).existsSync(), isTrue);
    expect(
        Directory(p.join(stagingDir().path, 'extract')).existsSync(), isFalse);
  });

  test('取消：流以 MokuroMoeDownloadCancelled 结束，.part 保留供续传', () async {
    serveVolume();
    server.holdCbzAfterBytes = 8;

    final MokuroMoeVolumeDownloader dl = downloader(interval: 1);
    final Completer<Object> streamError = Completer<Object>();
    bool cancelled = false;
    dl.run(db: db, seriesName: series, volumeName: volume).listen(
          (MokuroMoeVolumeDownloadEvent event) {
            // CBZ 阶段一开（服务器挂起前段）→ 请求取消 → 放行余量：下载循环在
            // 下一个 chunk 处看到取消标志并抛错，.part 保留。
            if (!cancelled &&
                event.stage == MokuroMoeDownloadStage.downloadingCbz) {
              cancelled = true;
              dl.cancel();
              server.release.complete();
            }
          },
          onError: (Object e) => streamError.complete(e),
          onDone: () {
            if (!streamError.isCompleted) {
              streamError
                  .complete(StateError('stream completed without error'));
            }
          },
        );

    expect(await streamError.future, isA<MokuroMoeDownloadCancelled>());
    final File part = File(p.join(stagingDir().path, 'volume.cbz.part'));
    expect(part.existsSync(), isTrue, reason: '取消必须保留 .part 供续传');
    expect(File(p.join(stagingDir().path, 'volume.cbz')).existsSync(), isFalse);
    expect((await db.getAllEpubBooks()), isEmpty);
  });
}
