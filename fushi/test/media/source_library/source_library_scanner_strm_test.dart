// 来源库扫描：`.strm` 流指针按普通视频入库、HLS 流清单不拆集、IPTV 频道列表按
// 引号感知的 EXTINF 取标题。
//
// - `.strm`：videoPath = `.strm` 自身（标题取文件名、同名字幕照常关联），指向的
//   地址起播时现读——扫描不把第三方 URL 写进行级数据；
// - HLS media playlist（`#EXT-X-TARGETDURATION` …）是一条流：修复前被按行拆成
//   「seg120.ts / seg121.ts」一集一集入库；
// - 频道列表的 `group-title="A, B"` 里的逗号不再把标题切错位。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

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
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_strm_');
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

  test('planScanFromFileList：.strm 归入视频并关联同名字幕', () {
    SourceFileEntry f(String name) => SourceFileEntry(
          name: name,
          path: '/lib/$name',
          isDirectory: false,
        );
    final ScanPlan plan = planScanFromFileList(<SourceFileEntry>[
      f('Show S01E01.strm'),
      f('Show S01E01.srt'),
      f('notes.txt'),
    ]);
    expect(plan.videos, hasLength(1));
    expect(plan.videos.single.videoPath, '/lib/Show S01E01.strm');
    expect(plan.videos.single.subtitlePath, '/lib/Show S01E01.srt');
    expect(plan.playlists, isEmpty);
  });

  test('扫描本地来源：.strm 入库、HLS 清单单条入库、频道列表按 EXTINF 取标题', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final Directory show = Directory(p.join(tmp.path, 'Show'))..createSync();
    File(p.join(show.path, 'Show S01E01.strm'))
        .writeAsStringSync('https://cdn.example/show/e1.m3u8\n');
    File(p.join(show.path, 'Show S01E01.srt')).writeAsStringSync(_srt);
    File(p.join(tmp.path, 'live.m3u8')).writeAsStringSync(
      '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:120\n'
      '#EXTINF:6.0,\nseg120.ts\n#EXTINF:6.0,\nseg121.ts\n',
    );
    File(p.join(tmp.path, 'channels.m3u')).writeAsStringSync(
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-name="NHK" group-title="News, JP",NHK 総合\n'
      'http://iptv.example/nhk.m3u8\n'
      '#EXTINF:-1 tvg-name="BS1" group-title="Sports",\n'
      'rtsp://iptv.example/bs1\n',
    );

    final SourceScanSummary summary =
        await SourceLibraryScanner(db).scan(await _videoSource(db, tmp.path));
    expect(summary.succeeded, isTrue, reason: summary.error ?? '');

    final List<VideoBookRow> rows = await VideoBookRepository(db).listAll();
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
      for (final VideoBookRow r in rows) r.videoPath: r,
    };

    // .strm：videoPath 是 .strm 自身，标题取文件名，字幕 cue 照常解析。
    final VideoBookRow strm = byPath[p.join(show.path, 'Show S01E01.strm')]!;
    expect(strm.title, 'Show S01E01');
    expect(strm.subtitleSource, p.join(show.path, 'Show S01E01.srt'));

    // HLS media playlist：整份一条，分片不入库。
    expect(byPath.containsKey(p.join(tmp.path, 'live.m3u8')), isTrue);
    expect(
      rows.where((VideoBookRow r) => r.videoPath.endsWith('.ts')),
      isEmpty,
      reason: 'HLS 分片不是分集',
    );

    // 频道列表：两条流，标题取引号外逗号后的显示名，空则 tvg-name。
    expect(byPath['http://iptv.example/nhk.m3u8']!.title, 'NHK 総合');
    expect(byPath['rtsp://iptv.example/bs1']!.title, 'BS1');
    expect(rows, hasLength(4));
  });
}
