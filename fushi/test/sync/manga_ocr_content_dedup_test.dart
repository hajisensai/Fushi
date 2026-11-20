/// 互联代跑漫画 OCR 的内容去重：host 按「引擎签名 + 页图 SHA-256」缓存逐页结果，
/// 对端先发清单，命中的页不上传（拍板台 design-nmv-manga-ocr-content-hash）。
///
/// - 老客户端（不发清单）跑完也给上传页写内容缓存；
/// - 换卷名 / 换页名的同内容整卷：一页不传、不跑识别，结果按清单页序与新页名组装；
/// - 部分命中：只传缺的页，只识别缺的页，结果两部分按页序合并；
/// - 缺页拒绝 start、清单只在上传前收、取消与孤儿清扫不碰内容缓存；
/// - 服务报不出签名不开去重；起跑前后签名变了不混两套结果；
/// - 客户端端到端：第二次跑同内容的卷时零上传。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_jobs/file_content_hash_cache.dart';
import 'package:fushi_engine/sync/manga_ocr_content_cache.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

Future<String> _sha256File(String path) async =>
    crypto.sha256.convert(await File(path).readAsBytes()).toString();

String _sha256Bytes(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// 报得出引擎签名的 fake：每页识别结果 = 页图字节拼成的一行文字，产物带
/// `ocr.engine_signature`（= [producedSignature]，缺省同 [signature]）。
class _SigningService
    implements MangaOcrService, MangaOcrEngineSignatureSource {
  _SigningService();

  final String signature = 'local-onnx-test-sig';
  String? producedSignature;
  int started = 0;
  final List<List<String>> ocrInputs = <List<String>>[];

  @override
  Future<String> resolveEngineSignature() async => signature;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: true,
    recognizerReady: true,
    diskBytes: 1,
    totalBytes: 1,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) {
    started += 1;
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    controller.onListen = () {
      unawaited(() async {
        final List<MangaOcrPageFile> pages = enumerateMangaPages(
          Directory(imageDirPath),
        );
        ocrInputs.add(<String>[
          for (final MangaOcrPageFile page in pages) page.relativeUrl,
        ]);
        final Directory outDir = Directory(
          p.join(imageDirPath, kMangaOcrOutDirName),
        )..createSync(recursive: true);
        final File out = File(p.join(outDir.path, kMangaOcrOutputFileName));
        out.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'ocr': <String, Object?>{
              'engine': 'local_onnx',
              'engine_signature': producedSignature ?? signature,
              'schema_version': 1,
            },
            'pages': <Object?>[
              for (final MangaOcrPageFile page in pages)
                <String, Object?>{
                  'url': page.relativeUrl,
                  'width': 100,
                  'height': 200,
                  'blocks': <Object?>[
                    <String, Object?>{
                      'box': <double>[0, 0, 10, 10],
                      'vertical': true,
                      'font_size': 10,
                      'z_index': 0,
                      'lines': <String>[page.file.readAsBytesSync().join(',')],
                    },
                  ],
                },
            ],
          }),
        );
        controller.add(
          MangaOcrVolumeEvent.finished(
            pagesTotal: pages.length,
            mangaJsonPath: out.path,
          ),
        );
        await controller.close();
      }());
    };
    return controller.stream;
  }
}

/// 报不出签名的服务（远端 / 外部 CLI / 老测试替身）：类型上不是签名源。
class _PlainService implements MangaOcrService {
  _PlainService(this._inner);
  final _SigningService _inner;

  @override
  bool get isSupportedPlatform => true;
  @override
  Future<MangaOcrModelStatus> modelStatus() => _inner.modelStatus();
  @override
  Stream<MangaOcrDownloadEvent> downloadModels() => _inner.downloadModels();
  @override
  Future<int> deleteModels() async => 0;
  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => _inner.ocrFolder(imageDirPath: imageDirPath, volumeTitle: volumeTitle);
}

Future<void> _waitTerminal(MangaOcrHostJob job) async {
  for (int i = 0; i < 300 && !job.state.isTerminal; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Map<String, dynamic>> _result(
  MangaOcrHostJobManager manager,
  MangaOcrHostJob job,
) async => jsonDecode((await manager.resultJson(job))!) as Map<String, dynamic>;

List<String> _urls(Map<String, dynamic> manga) => <String>[
  for (final Object? page in manga['pages'] as List<Object?>)
    (page! as Map<String, dynamic>)['url'] as String,
];

List<String> _texts(Map<String, dynamic> manga) => <String>[
  for (final Object? page in manga['pages'] as List<Object?>)
    (((page! as Map<String, dynamic>)['blocks'] as List<Object?>).first!
                as Map<String, dynamic>)['lines']
            .first
        as String,
];

void main() {
  late Directory tmpRoot;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('hbk_manga_ocr_dedup');
  });

  tearDown(() {
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  Directory jobRoot() => Directory(p.join(tmpRoot.path, 'jobs'));

  MangaOcrHostJobManager buildManager(MangaOcrService service) =>
      MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot(),
        contentHasher: _sha256File,
      );

  /// 老客户端形态：不发清单，整卷上传后跑。
  Future<MangaOcrHostJob> runLegacy(
    MangaOcrHostJobManager manager,
    String title,
    Map<String, List<int>> pages,
  ) async {
    final MangaOcrHostJob job = manager.createJob(volumeTitle: title);
    for (final MapEntry<String, List<int>> page in pages.entries) {
      expect(
        await manager.uploadPage(job, name: page.key, bytes: page.value),
        isNull,
      );
    }
    expect(await manager.start(job), isNull);
    await _waitTerminal(job);
    expect(job.state, MangaOcrHostJobState.done);
    return job;
  }

  test('legacy run fills the content cache; a renamed volume with the same '
      'content uploads nothing and runs no OCR', () async {
    final _SigningService service = _SigningService();
    final MangaOcrHostJobManager manager = buildManager(service);
    await runLegacy(manager, '卷一', <String, List<int>>{
      'p1.jpg': <int>[1, 1],
      'p2.jpg': <int>[2, 2],
    });
    expect(service.started, 1);
    expect(
      File(
        p.join(
          jobRoot().path,
          kMangaOcrContentCacheDirName,
          service.signature,
          '${_sha256Bytes(<int>[1, 1])}.json',
        ),
      ).existsSync(),
      isTrue,
    );

    // 另一台设备、另一个卷名、另一套页名，内容相同。
    final MangaOcrHostJob job = manager.createJob(volumeTitle: 'Volume 1');
    final (String? refusal, List<String> known) = await manager.acceptManifest(
      job,
      <Object?>[
        <String, Object?>{
          'name': 'b/002.png',
          'sha256': _sha256Bytes(<int>[2, 2]),
        },
        <String, Object?>{
          'name': 'a/001.png',
          'sha256': _sha256Bytes(<int>[1, 1]),
        },
      ],
    );
    expect(refusal, isNull);
    expect(known, <String>['b/002.png', 'a/001.png']);
    expect(await manager.start(job), isNull);
    expect(job.state, MangaOcrHostJobState.done);
    expect(service.started, 1, reason: 'every page hit the cache: no OCR run');
    final Map<String, dynamic> manga = await _result(manager, job);
    // 清单页序、新页名；识别内容来自缓存。
    expect(_urls(manga), <String>['b/002.png', 'a/001.png']);
    expect(_texts(manga), <String>['2,2', '1,1']);
    expect(
      (manga['ocr'] as Map<String, dynamic>)['engine_signature'],
      service.signature,
    );
    expect(job.toStatusJson()['pagesSkipped'], 2);
  });

  test('partial hit: only the missing page is uploaded and recognised; the '
      'result merges both in manifest order', () async {
    final _SigningService service = _SigningService();
    final MangaOcrHostJobManager manager = buildManager(service);
    await runLegacy(manager, 'A', <String, List<int>>{
      'x.jpg': <int>[7],
    });

    final MangaOcrHostJob job = manager.createJob(volumeTitle: 'B');
    final (String? refusal, List<String> known) = await manager.acceptManifest(
      job,
      <Object?>[
        <String, Object?>{
          'name': 'p1.jpg',
          'sha256': _sha256Bytes(<int>[7]),
        },
        <String, Object?>{
          'name': 'p2.jpg',
          'sha256': _sha256Bytes(<int>[8]),
        },
      ],
    );
    expect(refusal, isNull);
    expect(known, <String>['p1.jpg']);
    expect(
      await manager.uploadPage(job, name: 'p2.jpg', bytes: <int>[8]),
      isNull,
    );
    expect(await manager.start(job), isNull);
    await _waitTerminal(job);
    expect(job.state, MangaOcrHostJobState.done, reason: '${job.error}');
    expect(service.ocrInputs.last, <String>['p2.jpg']);
    final Map<String, dynamic> manga = await _result(manager, job);
    expect(_urls(manga), <String>['p1.jpg', 'p2.jpg']);
    expect(_texts(manga), <String>['7', '8']);
    expect(job.pagesDone, 2);
    expect(job.pagesTotal, 2);
  });

  test('start refuses a manifest page that is neither cached nor uploaded; '
      'manifest is only accepted before uploads', () async {
    final _SigningService service = _SigningService();
    final MangaOcrHostJobManager manager = buildManager(service);
    final MangaOcrHostJob job = manager.createJob(volumeTitle: 'C');
    final (String? refusal, List<String> known) = await manager.acceptManifest(
      job,
      <Object?>[
        <String, Object?>{
          'name': 'p1.jpg',
          'sha256': _sha256Bytes(<int>[1]),
        },
        <String, Object?>{'name': 'p2.jpg'},
      ],
    );
    expect(refusal, isNull);
    expect(known, isEmpty);
    expect(
      await manager.uploadPage(job, name: 'p1.jpg', bytes: <int>[1]),
      isNull,
    );
    expect(await manager.start(job), (400, 'missing_pages'));
    final (String? late, _) = await manager.acceptManifest(job, <Object?>[
      <String, Object?>{'name': 'p1.jpg'},
    ]);
    expect(late, 'bad_state');

    final MangaOcrHostJob other = manager.createJob(volumeTitle: 'D');
    final (String? dup, _) = await manager.acceptManifest(other, <Object?>[
      <String, Object?>{'name': 'p1.jpg'},
      <String, Object?>{'name': 'p1.jpg'},
    ]);
    expect(dup, 'bad_manifest');
    final (String? traversal, _) = await manager.acceptManifest(
      other,
      <Object?>[
        <String, Object?>{'name': '../evil.jpg'},
      ],
    );
    expect(traversal, 'bad_name');
  });

  test('cancel and the orphan sweep leave the content cache alone', () async {
    final _SigningService service = _SigningService();
    MangaOcrHostJobManager manager = buildManager(service);
    await runLegacy(manager, 'E', <String, List<int>>{
      'p.jpg': <int>[5],
    });
    final MangaOcrHostJob job = manager.createJob(volumeTitle: 'E');
    await manager.uploadPage(job, name: 'p.jpg', bytes: <int>[5]);
    await manager.cancelAndCleanup(job);
    final Directory cache = Directory(
      p.join(jobRoot().path, kMangaOcrContentCacheDirName),
    );
    expect(cache.existsSync(), isTrue);

    // 新管理器（host 重启）首次触达时做孤儿清扫：时钟拨到一天后，任务根下的目录
    // 全都过了 TTL，卷目录被删，内容缓存留着。
    final Directory old = Directory(p.join(jobRoot().path, 'vol_stale'))
      ..createSync(recursive: true);
    manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: jobRoot(),
      contentHasher: _sha256File,
      now: () => DateTime.now().add(const Duration(days: 1)),
    );
    manager.createJob(volumeTitle: 'F');
    expect(old.existsSync(), isFalse);
    expect(cache.existsSync(), isTrue);
    expect(
      await MangaOcrContentCache(
        root: cache,
      ).read(service.signature, _sha256Bytes(<int>[5])),
      isNotNull,
    );
  });

  test('a service without an engine signature gets no dedup', () async {
    final _PlainService service = _PlainService(_SigningService());
    final MangaOcrHostJobManager manager = buildManager(service);
    expect((await manager.capability()).containsKey('contentDedup'), isFalse);
    final MangaOcrHostJob job = manager.createJob(volumeTitle: 'G');
    await manager.uploadPage(job, name: 'p.jpg', bytes: <int>[3]);
    expect(await manager.start(job), isNull);
    await _waitTerminal(job);
    expect(job.state, MangaOcrHostJobState.done);
    expect(
      Directory(
        p.join(jobRoot().path, kMangaOcrContentCacheDirName),
      ).existsSync(),
      isFalse,
    );
    expect(
      (await buildManager(_SigningService()).capability())['contentDedup'],
      isTrue,
    );
  });

  test(
    'cached pages from another engine signature are never mixed in',
    () async {
      final _SigningService service = _SigningService();
      final MangaOcrHostJobManager manager = buildManager(service);
      await runLegacy(manager, 'H', <String, List<int>>{
        'p1.jpg': <int>[1],
      });
      final MangaOcrHostJob job = manager.createJob(volumeTitle: 'I');
      await manager.acceptManifest(job, <Object?>[
        <String, Object?>{
          'name': 'p1.jpg',
          'sha256': _sha256Bytes(<int>[1]),
        },
        <String, Object?>{
          'name': 'p2.jpg',
          'sha256': _sha256Bytes(<int>[2]),
        },
      ]);
      await manager.uploadPage(job, name: 'p2.jpg', bytes: <int>[2]);
      // 清单之后、识别之前，host 换了模型：产物自报的签名不同。
      service.producedSignature = 'local-onnx-other-model';
      expect(await manager.start(job), isNull);
      await _waitTerminal(job);
      expect(job.state, MangaOcrHostJobState.error);
      expect(job.error, contains('engine_changed'));

      // 不同签名下查不到旧签名的结果。
      final MangaOcrContentCache cache = MangaOcrContentCache(
        root: Directory(p.join(jobRoot().path, kMangaOcrContentCacheDirName)),
      );
      expect(
        await cache.read('local-onnx-other-model', _sha256Bytes(<int>[1])),
        isNull,
      );
      expect(
        await cache.read(service.signature, _sha256Bytes(<int>[1])),
        isNotNull,
      );
    },
  );

  test('content cache prunes the least recently used entries', () async {
    final MangaOcrContentCache cache = MangaOcrContentCache(
      root: Directory(p.join(tmpRoot.path, 'cc')),
      maxEntries: 10,
    );
    for (int i = 0; i < 12; i++) {
      final String sha = _sha256Bytes(<int>[i]);
      await cache.write('sig', sha, <String, Object?>{
        'url': 'x',
        'blocks': <Object?>[],
      });
      File(
        p.join(tmpRoot.path, 'cc', 'sig', '$sha.json'),
      ).setLastModifiedSync(DateTime(2026, 1, 1, 0, i));
    }
    await cache.prune();
    expect(await cache.read('sig', _sha256Bytes(<int>[0])), isNull);
    expect(await cache.read('sig', _sha256Bytes(<int>[11])), isNotNull);
    final int left = Directory(
      p.join(tmpRoot.path, 'cc', 'sig'),
    ).listSync().length;
    expect(left, 9);
  });

  group('client end to end', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = SyncRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('a second run of the same content uploads no page', () async {
      final _SigningService service = _SigningService();
      final List<String> uploads = <String>[];
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot(),
        contentHasher: (String path) {
          uploads.add(p.basename(path));
          return _sha256File(path);
        },
      );
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
        port: 0,
        token: 'tok',
        mangaOcrJobs: manager,
      );
      await server.start();
      addTearDown(server.stop);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: 'http://127.0.0.1:${server.port}'),
      ]);
      await repo.setFushiClientToken('tok');

      final InterconnectMangaOcrClient client = InterconnectMangaOcrClient(
        repo: repo,
        pollDelay: (int attempt) => const Duration(milliseconds: 10),
        hashCache: FileContentHashCache(hasher: _sha256File),
      );
      final MangaOcrRemoteTarget? target = await client.probe();
      expect(target, isNotNull);
      expect(target!.capability.contentDedup, isTrue);

      Directory volume(String name) {
        final Directory dir = Directory(p.join(tmpRoot.path, name))
          ..createSync(recursive: true);
        File(p.join(dir.path, '01.jpg')).writeAsBytesSync(<int>[9, 1]);
        File(p.join(dir.path, '02.jpg')).writeAsBytesSync(<int>[9, 2]);
        return dir;
      }

      Future<Map<String, dynamic>> run(Directory dir, String title) async {
        final List<MangaOcrRemoteEvent> events = await client
            .run(target: target, imageDirPath: dir.path, volumeTitle: title)
            .toList();
        final MangaOcrRemoteEvent last = events.last;
        expect(last.finished, isTrue);
        return jsonDecode(File(last.mangaJsonPath!).readAsStringSync())
            as Map<String, dynamic>;
      }

      final Map<String, dynamic> first = await run(volume('phoneA'), '卷');
      expect(uploads, hasLength(2));
      expect(service.started, 1);

      uploads.clear();
      final Map<String, dynamic> second = await run(volume('phoneB'), '別の名前');
      expect(uploads, isEmpty, reason: 'host already had both pages');
      expect(
        service.started,
        1,
        reason: 'no OCR run for a fully cached volume',
      );
      expect(_urls(second), _urls(first));
      expect(_texts(second), <String>['9,1', '9,2']);
    });
  });
}
