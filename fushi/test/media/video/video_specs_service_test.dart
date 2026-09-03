import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_dynamic_range.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';

/// 规格服务：缓存三层（内存 → DB → ffprobe）、失效判据、并发上限。
///
/// 探测入口是注入的，不真起 ffprobe；但**文件是真的**（写进临时目录），因为失效判据
/// 依赖真实的 `FileStat.size` / `modified`，拿假 stat 测等于没测。
void main() {
  late Directory tempDir;
  late FushiDatabase db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_specs_service');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String writeFile(String name, {int size = 1024}) {
    final File file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(List<int>.filled(size, 0));
    return file.path;
  }

  VideoProbeFacts facts({
    int width = 3840,
    int height = 2160,
    String transfer = 'smpte2084',
    List<AudioTrackFacts> audio = const <AudioTrackFacts>[],
  }) =>
      VideoProbeFacts(
        durationMs: 90 * 60 * 1000,
        containerBitrate: 15000000,
        video: VideoStreamFacts(
          codec: 'hevc',
          width: width,
          height: height,
          pixelFormat: 'yuv420p10le',
          bitDepth: 10,
          frameRateMilli: 23976,
          colorPrimaries: 'bt2020',
          colorTransfer: transfer,
        ),
        audioTracks: audio,
      );

  test('探一次后可同步读到，且落库', () async {
    final String path = writeFile('a.mkv');
    int probeCalls = 0;
    final VideoSpecsService service = VideoSpecsService(
      db,
      probe: (String p) async {
        probeCalls++;
        return facts();
      },
    );
    addTearDown(service.dispose);

    expect(service.specsFor(path), isNull, reason: '探之前同步读必须是 null');

    final VideoProbeFacts? resolved = await service.resolve(path);
    expect(resolved, isNotNull);
    expect(probeCalls, 1);

    // 同步读now命中
    final VideoProbeFacts? cached = service.specsFor(path);
    expect(cached!.video!.resolutionLabel, '4K');
    expect(cached.video!.dynamicRange, VideoDynamicRange.hdr10);

    // 真落库了
    final VideoFileSpecRow? row = await db.videoFileSpec(path);
    expect(row, isNotNull);
    expect(row!.width, 3840);
    expect(row.colorTransfer, 'smpte2084');
    expect(row.probeVersion, kVideoProbeFieldSetVersion);
    expect(row.fileSizeBytes, 1024, reason: '失效判据要存真实文件大小');
  });

  test('第二个服务实例从 DB 命中，不再探', () async {
    final String path = writeFile('b.mkv');
    final VideoSpecsService first =
        VideoSpecsService(db, probe: (String p) async => facts());
    await first.resolve(path);
    first.dispose();

    int secondProbeCalls = 0;
    final VideoSpecsService second = VideoSpecsService(
      db,
      probe: (String p) async {
        secondProbeCalls++;
        return facts();
      },
    );
    addTearDown(second.dispose);

    await second.prime(<String>[path]);
    expect(secondProbeCalls, 0, reason: 'DB 命中就不该再起 ffprobe');
    expect(second.specsFor(path)!.video!.resolutionLabel, '4K');
  });

  group('失效判据', () {
    test('文件大小变了 → 重探', () async {
      final String path = writeFile('c.mkv', size: 100);
      final VideoSpecsService first =
          VideoSpecsService(db, probe: (String p) async => facts());
      await first.resolve(path);
      first.dispose();

      // 换了个更大的同名文件（换片源）。
      File(path).writeAsBytesSync(List<int>.filled(5000, 1));

      int probeCalls = 0;
      final VideoSpecsService second = VideoSpecsService(
        db,
        probe: (String p) async {
          probeCalls++;
          return facts(width: 1920, height: 1080, transfer: 'bt709');
        },
      );
      addTearDown(second.dispose);

      final VideoProbeFacts? fresh = await second.resolve(path);
      expect(probeCalls, 1, reason: '大小变了必须重探');
      expect(fresh!.video!.resolutionLabel, '1080p');
      expect(fresh.video!.dynamicRange, VideoDynamicRange.sdr);
    });

    test('探测器字段集版本变了 → 重探', () async {
      final String path = writeFile('d.mkv');
      final FileStat stat = File(path).statSync();
      // 直接塞一条「上个版本探的」缓存行。
      await db.upsertVideoFileSpec(videoFileSpecCompanion(
        filePath: path,
        facts: facts(),
        fileSizeBytes: stat.size,
        fileModifiedAt: stat.modified.millisecondsSinceEpoch,
      ).copyWith(probeVersion: const Value<int>(0)));

      int probeCalls = 0;
      final VideoSpecsService service = VideoSpecsService(
        db,
        probe: (String p) async {
          probeCalls++;
          return facts();
        },
      );
      addTearDown(service.dispose);

      await service.prime(<String>[path]);
      await service.drain();
      expect(probeCalls, 1, reason: '字段集扩了，旧行的新字段是空的，必须重探');
    });

    test('文件不存在 → 不探，记为无结论', () async {
      final String missing =
          '${tempDir.path}${Platform.pathSeparator}nope.mkv';
      int probeCalls = 0;
      final VideoSpecsService service = VideoSpecsService(
        db,
        probe: (String p) async {
          probeCalls++;
          return facts();
        },
      );
      addTearDown(service.dispose);

      expect(await service.resolve(missing), isNull);
      expect(probeCalls, 0, reason: '文件都没有，起 ffprobe 是白起');
      expect(service.isResolved(missing), isTrue, reason: '记下来别反复重试');
    });
  });

  test('探不出规格时不落库（否则永远命中空壳、再也不重试）', () async {
    final String path = writeFile('e.mkv');
    final VideoSpecsService service = VideoSpecsService(
      db,
      probe: (String p) async => VideoProbeFacts.empty,
    );
    addTearDown(service.dispose);

    expect(await service.resolve(path), isNull);
    expect(await db.videoFileSpec(path), isNull,
        reason: '空结果不该在库里留一行');
    expect(service.isResolved(path), isTrue, reason: '本次会话内不重试');
  });

  test('prime 批量：已知的跳过，只探缺的', () async {
    final String known = writeFile('f1.mkv');
    final String unknown = writeFile('f2.mkv');

    final VideoSpecsService seeder =
        VideoSpecsService(db, probe: (String p) async => facts());
    await seeder.resolve(known);
    seeder.dispose();

    final List<String> probed = <String>[];
    final VideoSpecsService service = VideoSpecsService(
      db,
      probe: (String p) async {
        probed.add(p);
        return facts();
      },
    );
    addTearDown(service.dispose);

    await service.prime(<String>[known, unknown]);
    await service.drain();

    expect(probed, <String>[unknown], reason: '只该探库里没有的那个');
    expect(service.specsFor(known), isNotNull);
    expect(service.specsFor(unknown), isNotNull);
  });

  test('并发不超过上限', () async {
    final List<String> paths = <String>[
      for (int i = 0; i < 8; i++) writeFile('g$i.mkv'),
    ];
    int running = 0;
    int peak = 0;
    final VideoSpecsService service = VideoSpecsService(
      db,
      probe: (String p) async {
        running++;
        peak = peak > running ? peak : running;
        // 让出事件循环，制造真正的重叠窗口。
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        running--;
        return facts();
      },
    );
    addTearDown(service.dispose);

    await service.prime(paths);
    await service.drain();

    expect(peak, lessThanOrEqualTo(kVideoSpecsProbeConcurrency),
        reason: '并发上限被突破会跟正在播放的视频抢磁盘');
    expect(peak, greaterThan(1), reason: '也不能退化成串行');
    for (final String path in paths) {
      expect(service.specsFor(path), isNotNull, reason: '$path 应已探完');
    }
  });

  test('音轨往返落库不丢字段', () async {
    final String path = writeFile('h.mkv');
    final VideoSpecsService service = VideoSpecsService(
      db,
      probe: (String p) async => facts(audio: const <AudioTrackFacts>[
        AudioTrackFacts(
          index: 1,
          codec: 'flac',
          channels: 6,
          channelLayout: '5.1',
          sampleRate: 48000,
          language: 'jpn',
          title: '日本語 5.1',
          isDefault: true,
        ),
        AudioTrackFacts(
          index: 2,
          codec: 'aac',
          channels: 2,
          channelLayout: 'stereo',
          language: 'eng',
          isCommentary: true,
        ),
      ]),
    );
    addTearDown(service.dispose);

    await service.resolve(path);

    // 换一个实例，强制走「从 DB 解码」这条路。
    final VideoSpecsService reader =
        VideoSpecsService(db, probe: (String p) async => VideoProbeFacts.empty);
    addTearDown(reader.dispose);
    await reader.prime(<String>[path]);

    final List<AudioTrackFacts> tracks = reader.specsFor(path)!.audioTracks;
    expect(tracks, hasLength(2));
    expect(tracks[0].codecLabel, 'FLAC');
    expect(tracks[0].channelLabel, '5.1');
    expect(tracks[0].language, 'jpn');
    expect(tracks[0].title, '日本語 5.1');
    expect(tracks[0].isDefault, isTrue);
    expect(tracks[1].isCommentary, isTrue);
    expect(tracks[1].channelLabel, '2.0');
  });

  test('落库失败不丢已探到的结果（探测成功 ≠ 持久化成功）', () async {
    final String path = writeFile('j.mkv');
    // 制造一个必然写失败的持久化层。**不能用 db.close()**：实测 drift 关闭后的
    // 查询既不抛也不挂，读返回 null、写返回 0，根本造不出失败。把表 drop 掉才是
    // 真的会抛（no such table）。
    await db.customStatement('DROP TABLE video_file_specs');

    final VideoSpecsService service =
        VideoSpecsService(db, probe: (String p) async => facts());
    addTearDown(service.dispose);

    final VideoProbeFacts? resolved = await service.resolve(path);
    expect(resolved, isNotNull, reason: 'ffprobe 明明成功了');
    expect(service.specsFor(path), isNotNull,
        reason: '写库失败只是丢了跨启动缓存，本次会话的事实照样有效——'
            '一起判死会让角标在探测成功时消失，且 isResolved 已 true 不再重试');
    expect(service.specsFor(path)!.video!.resolutionLabel, '4K');
  });

  test('resolve 与队列共用在途表：同一文件不会并发探两次', () async {
    final String path = writeFile('k.mkv');
    int probeCalls = 0;
    final VideoSpecsService service = VideoSpecsService(
      db,
      probe: (String p) async {
        probeCalls++;
        // 留出重叠窗口：prime 起的那次还没落地，resolve 就进来了。
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        return facts();
      },
    );
    addTearDown(service.dispose);

    // 集卡渲染排队 + 用户紧接着开「媒体信息」弹窗。
    final Future<void> primed = service.prime(<String>[path]);
    final Future<VideoProbeFacts?> resolved = service.resolve(path);
    await primed;
    final VideoProbeFacts? facts0 = await resolved;
    await service.drain();

    expect(probeCalls, 1,
        reason: '起第二个 ffprobe 正好废掉并发上限想守的东西（别跟播放中的视频抢 IO）');
    expect(facts0, isNotNull);
    expect(service.specsFor(path), isNotNull);
  });

  test('invalidate 清掉内存与库两处', () async {
    final String path = writeFile('i.mkv');
    final VideoSpecsService service =
        VideoSpecsService(db, probe: (String p) async => facts());
    addTearDown(service.dispose);

    await service.resolve(path);
    expect(await db.videoFileSpec(path), isNotNull);

    await service.invalidate(path);
    expect(service.specsFor(path), isNull);
    expect(service.isResolved(path), isFalse);
    expect(await db.videoFileSpec(path), isNull);
  });

  group('删书时回收规格缓存（表以文件路径为键、与 book 无 FK，没人清就只增不减）',
      () {
    test('单视频：删书清掉它的规格行', () async {
      const String main = r'D:\media\solo.mkv';
      await db.customStatement(
        'INSERT INTO video_books (book_uid, title, video_path, imported_at) '
        "VALUES ('solo', '单片', '$main', 1700000000)",
      );
      await db.upsertVideoFileSpec(videoFileSpecCompanion(
        filePath: main,
        facts: facts(),
        fileSizeBytes: 1,
        fileModifiedAt: 1,
      ));
      expect(await db.videoFileSpec(main), isNotNull);

      await db.deleteVideoBook('solo');
      expect(await db.videoFileSpec(main), isNull);
    });

    test('播放列表：每一集的规格行都要清', () async {
      const String main = r'D:\media\ep1.mkv';
      const String ep2 = r'D:\media\ep2.mkv';
      const String ep3 = r'D:\media\ep3.mkv';
      const String playlist =
          r'[{"title":"1","path":"D:\\media\\ep1.mkv"},'
          r'{"title":"2","path":"D:\\media\\ep2.mkv"},'
          r'{"title":"3","path":"D:\\media\\ep3.mkv"}]';
      await db.customStatement(
        'INSERT INTO video_books (book_uid, title, video_path, playlist_json, '
        'imported_at) VALUES (?, ?, ?, ?, ?)',
        <Object?>['series', '连续剧', main, playlist, 1700000000],
      );
      for (final String path in <String>[main, ep2, ep3]) {
        await db.upsertVideoFileSpec(videoFileSpecCompanion(
          filePath: path,
          facts: facts(),
          fileSizeBytes: 1,
          fileModifiedAt: 1,
        ));
      }

      await db.deleteVideoBook('series');

      for (final String path in <String>[main, ep2, ep3]) {
        expect(await db.videoFileSpec(path), isNull, reason: '$path 该被清');
      }
    });

    test('别的书的规格行不受牵连', () async {
      const String mine = r'D:\media\mine.mkv';
      const String other = r'D:\media\other.mkv';
      await db.customStatement(
        'INSERT INTO video_books (book_uid, title, video_path, imported_at) '
        "VALUES ('mine', 'A', '$mine', 1700000000)",
      );
      for (final String path in <String>[mine, other]) {
        await db.upsertVideoFileSpec(videoFileSpecCompanion(
          filePath: path,
          facts: facts(),
          fileSizeBytes: 1,
          fileModifiedAt: 1,
        ));
      }

      await db.deleteVideoBook('mine');

      expect(await db.videoFileSpec(mine), isNull);
      expect(await db.videoFileSpec(other), isNotNull,
          reason: '只清这本书涉及的文件');
    });

    test('坏 playlist_json 不让删除事务回滚（只清主视频）', () async {
      const String main = r'D:\media\broken.mkv';
      await db.customStatement(
        'INSERT INTO video_books (book_uid, title, video_path, playlist_json, '
        'imported_at) VALUES (?, ?, ?, ?, ?)',
        <Object?>['broken', 'B', main, '{not json at all', 1700000000],
      );
      await db.upsertVideoFileSpec(videoFileSpecCompanion(
        filePath: main,
        facts: facts(),
        fileSizeBytes: 1,
        fileModifiedAt: 1,
      ));

      await db.deleteVideoBook('broken');

      expect(await db.videoFileSpec(main), isNull);
      expect(
        await (db.select(db.videoBooks)
              ..where((t) => t.bookUid.equals('broken')))
            .getSingleOrNull(),
        isNull,
        reason: '书本身必须删掉——不能因为一条脏缓存键让整个事务回滚',
      );
    });
  });
}
