import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/tts/local/voicevox_local_engine.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

class _DoneProcess implements Process {
  _DoneProcess(this._code);
  final int _code;

  @override
  Future<int> get exitCode => Future<int>.value(_code);
  @override
  int get pid => 1;
  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

/// 一直跑到被 kill 的解压子进程（取消 / 「删除」等它退出）。
class _HangingProcess implements Process {
  final Completer<int> _exit = Completer<int>();
  int kills = 0;

  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 2;
  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

String? _uuidAt(String root) => VoicevoxInstallLayout.find(root)?.uuid;

/// 在 [dir] 下写一份最小引擎（清单 + 可执行文件）。
void _writeEngine(
  String dir, {
  String uuid = 'uuid-1',
  String command = 'run.exe',
}) {
  Directory(dir).createSync(recursive: true);
  File(p.join(dir, 'engine_manifest.json')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'name': 'Fake Engine',
      'uuid': uuid,
      'version': '9.9.9',
      'command': command,
      'port': 50021,
    }),
  );
  File(p.join(dir, command)).writeAsStringSync('exe');
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voicevox_local_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('platform keys', () {
    expect(voicevoxPlatformKey(os: 'windows', arch: 'x64'), 'windows-x64');
    expect(voicevoxPlatformKey(os: 'windows', arch: 'arm64'), isNull);
    expect(voicevoxPlatformKey(os: 'macos', arch: 'arm64'), 'macos-arm64');
    expect(voicevoxPlatformKey(os: 'macos', arch: 'x64'), isNull);
    expect(voicevoxPlatformKey(os: 'linux', arch: 'x64'), 'linux-x64');
    expect(voicevoxPlatformKey(os: 'linux', arch: 'arm64'), 'linux-arm64');
    expect(voicevoxPlatformKey(os: 'android', arch: 'arm64'), isNull);
  });

  test('pinned manifests cover every desktop key with checksummed parts', () {
    for (final VoicevoxEngineManifest m in <VoicevoxEngineManifest>[
      kVoicevoxManifest,
      kAivisSpeechManifest,
    ]) {
      expect(m.packages.keys.toSet(), <String>{
        'windows-x64',
        'macos-arm64',
        'linux-x64',
        'linux-arm64',
      });
      for (final List<VoicevoxPackage> pkgs in m.packages.values) {
        expect(pkgs.first.accel, VoicevoxAccel.cpu);
        for (final VoicevoxPackage pkg in pkgs) {
          for (final VoicevoxPackagePart part in pkg.parts) {
            expect(part.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
            expect(part.sizeBytes, greaterThan(100 * 1024 * 1024));
            expect(part.name, contains(m.tag));
          }
        }
      }
    }
    final VoicevoxPackage nvidia = kVoicevoxManifest.packages['windows-x64']!
        .firstWhere((VoicevoxPackage x) => x.accel == VoicevoxAccel.nvidia);
    expect(nvidia.parts.map((VoicevoxPackagePart x) => x.name), <String>[
      'voicevox_engine-windows-nvidia-0.26.0.001.vvppp',
      'voicevox_engine-windows-nvidia-0.26.0.002.vvppp',
    ]);
    expect(
      kVoicevoxManifest.url(nvidia.parts.first).toString(),
      'https://github.com/VOICEVOX/voicevox_engine/releases/download/0.26.0/'
      'voicevox_engine-windows-nvidia-0.26.0.001.vvppp',
    );
    expect(
      kAivisSpeechManifest.packages['windows-x64']!.single.format,
      VoicevoxArchiveFormat.sevenZip,
    );
  });

  test('extract commands per platform', () {
    List<String> exes(VoicevoxArchiveFormat f, String os) =>
        voicevoxExtractCommands(
          format: f,
          archive: 'a',
          dest: 'd',
          os: os,
          windowsTar: r'C:\Windows\System32\tar.exe',
        ).map((VoicevoxExtractCommand c) => c.executable).toList();
    expect(exes(VoicevoxArchiveFormat.zip, 'windows'), <String>[
      r'C:\Windows\System32\tar.exe',
    ]);
    expect(exes(VoicevoxArchiveFormat.sevenZip, 'macos'), <String>[
      '/usr/bin/tar',
    ]);
    expect(exes(VoicevoxArchiveFormat.zip, 'linux'), <String>[
      'unzip',
      'bsdtar',
      'python3',
    ]);
    expect(exes(VoicevoxArchiveFormat.sevenZip, 'linux'), <String>[
      '7z',
      '7za',
      '7zz',
      'bsdtar',
    ]);
    expect(
      voicevoxExtractCommands(
        format: VoicevoxArchiveFormat.sevenZip,
        archive: 'a.7z',
        dest: '/x',
        os: 'linux',
      ).first.arguments,
      <String>['x', '-y', '-o/x', 'a.7z'],
    );
  });

  test('layout found at engine root or one level down', () {
    final String flat = p.join(tmp.path, 'flat');
    _writeEngine(p.join(flat, 'engine'));
    final VoicevoxInstallLayout? a = VoicevoxInstallLayout.find(flat);
    expect(a?.engineDir, p.join(flat, 'engine'));
    expect(a?.executable, p.join(flat, 'engine', 'run.exe'));
    expect(a?.uuid, 'uuid-1');

    final String nested = p.join(tmp.path, 'nested');
    _writeEngine(p.join(nested, 'engine', 'Windows-x64'), command: 'run');
    expect(
      VoicevoxInstallLayout.find(nested)?.engineDir,
      p.join(nested, 'engine', 'Windows-x64'),
    );

    final String broken = p.join(tmp.path, 'broken');
    _writeEngine(p.join(broken, 'engine'));
    File(p.join(broken, 'engine', 'run.exe')).deleteSync();
    expect(VoicevoxInstallLayout.find(broken), isNull);
  });

  test('manifest probe matcher', () {
    expect(voicevoxManifestMatches('{"uuid":"x","name":"n"}', 'x'), isTrue);
    expect(voicevoxManifestMatches('{"uuid":"y"}', 'x'), isFalse);
    expect(voicevoxManifestMatches('not json', 'x'), isFalse);
  });

  group('installer', () {
    final List<int> part1 = utf8.encode('PART-ONE|');
    final List<int> part2 = utf8.encode('PART-TWO');
    late VoicevoxPackage pkg;
    late List<Uri> fetched;
    late List<List<String>> spawned;
    String? joinedAtExtract;

    setUp(() {
      fetched = <Uri>[];
      spawned = <List<String>>[];
      joinedAtExtract = null;
      pkg = VoicevoxPackage(
        accel: VoicevoxAccel.nvidia,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart('e.001.vvppp', part1.length, _sha(part1)),
          VoicevoxPackagePart('e.002.vvppp', part2.length, _sha(part2)),
        ],
      );
    });

    VoicevoxInstaller installer({
      int extractExit = 0,
      bool writeEngine = true,
      List<int>? servePart1,
    }) => VoicevoxInstaller(
      httpClientFactory: () => HttpClient(),
      manifest: kVoicevoxManifest,
      os: 'windows',
      run: (String exe, List<String> args) async =>
          (exitCode: 0, output: 'bsdtar 3.7 - libarchive 3.7 liblzma/5.4'),
      open: (HttpClient client, Uri uri, Map<String, String> headers) async {
        fetched.add(uri);
        final List<int> body = uri.path.endsWith('e.001.vvppp')
            ? (servePart1 ?? part1)
            : part2;
        return ResumableDownloadResponse.bytes(
          statusCode: 200,
          body: body,
          headers: <String, String>{'content-length': '${body.length}'},
        );
      },
      spawn: (String exe, List<String> args) async {
        spawned.add(<String>[exe, ...args]);
        final String archive = args[args.indexOf('-xf') + 1];
        joinedAtExtract = File(archive).readAsStringSync();
        if (writeEngine) _writeEngine(args[args.indexOf('-C') + 1]);
        return _DoneProcess(extractExit);
      },
    );

    test('downloads parts, joins split zip, extracts, cleans up', () async {
      final String root = p.join(tmp.path, 'voicevox_engine');
      final VoicevoxInstaller inst = installer();
      final VoicevoxInstallLayout? layout = await inst.install(
        root: root,
        pkg: pkg,
      );
      expect(inst.step, VoicevoxInstallStep.done);
      expect(layout?.uuid, 'uuid-1');
      expect(fetched.map((Uri u) => p.posix.basename(u.path)), <String>[
        'e.001.vvppp',
        'e.002.vvppp',
      ]);
      expect(fetched.first.host, 'github.com');
      expect(joinedAtExtract, 'PART-ONE|PART-TWO');
      expect(inst.receivedBytes, part1.length + part2.length);
      expect(
        Directory(p.join(root, 'downloads')).listSync(),
        isEmpty,
        reason: 'parts and the joined zip are deleted after extraction',
      );
    });

    test('checksum mismatch is corrupt and never extracts', () async {
      final VoicevoxInstaller inst = installer(
        servePart1: utf8.encode('PART-0NE|'),
      );
      final VoicevoxInstallLayout? layout = await inst.install(
        root: p.join(tmp.path, 'r'),
        pkg: pkg,
      );
      expect(layout, isNull);
      expect(inst.failure, VoicevoxInstallFailure.corrupt);
      expect(spawned, isEmpty);
    });

    test('extractor failure and missing layout are reported', () async {
      VoicevoxInstaller inst = installer(extractExit: 2);
      expect(await inst.install(root: p.join(tmp.path, 'a'), pkg: pkg), isNull);
      expect(inst.failure, VoicevoxInstallFailure.extractFailed);
      inst = installer(writeEngine: false);
      expect(await inst.install(root: p.join(tmp.path, 'b'), pkg: pkg), isNull);
      expect(inst.failure, VoicevoxInstallFailure.layoutMissing);
    });

    test(
      'failed extraction keeps the old engine and leaves no staging',
      () async {
        final String root = p.join(tmp.path, 'swap');
        _writeEngine(p.join(root, 'engine'), uuid: 'uuid-old');
        // 解压器写出了一份「看起来完整」的引擎再报错：不能被当成装好了。
        final VoicevoxInstaller inst = installer(extractExit: 2);
        expect(await inst.install(root: root, pkg: pkg), isNull);
        expect(inst.failure, VoicevoxInstallFailure.extractFailed);
        expect(_uuidAt(root), 'uuid-old');
        expect(
          Directory(p.join(root, kVoicevoxStagingSubdir)).existsSync(),
          isFalse,
        );
        expect(inst.isBusy, isFalse);
      },
    );

    test(
      'fresh install that fails leaves nothing that looks installed',
      () async {
        final String root = p.join(tmp.path, 'fresh');
        final VoicevoxInstaller inst = installer(extractExit: 2);
        expect(await inst.install(root: root, pkg: pkg), isNull);
        expect(_uuidAt(root), isNull);
        expect(Directory(p.join(root, 'engine')).existsSync(), isFalse);
        expect(
          Directory(p.join(root, kVoicevoxStagingSubdir)).existsSync(),
          isFalse,
        );
      },
    );

    test('successful reinstall swaps the engine in whole', () async {
      final String root = p.join(tmp.path, 'reinstall');
      _writeEngine(p.join(root, 'engine'), uuid: 'uuid-old');
      File(p.join(root, 'engine', 'stale.dll')).writeAsStringSync('old');
      final VoicevoxInstaller inst = installer();
      final VoicevoxInstallLayout? layout = await inst.install(
        root: root,
        pkg: pkg,
      );
      expect(layout?.uuid, 'uuid-1');
      expect(layout?.engineDir, p.join(root, 'engine'));
      expect(File(p.join(root, 'engine', 'stale.dll')).existsSync(), isFalse);
      expect(
        Directory(p.join(root, kVoicevoxRetiredSubdir)).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root, kVoicevoxStagingSubdir)).existsSync(),
        isFalse,
      );
    });

    test(
      'cancel during extraction cleans staging and waits for the run',
      () async {
        final String root = p.join(tmp.path, 'cancel');
        _writeEngine(p.join(root, 'engine'), uuid: 'uuid-old');
        final _HangingProcess proc = _HangingProcess();
        final Completer<void> extracting = Completer<void>();
        final VoicevoxInstaller inst = VoicevoxInstaller(
          httpClientFactory: () => HttpClient(),
          manifest: kVoicevoxManifest,
          os: 'windows',
          open:
              (HttpClient client, Uri uri, Map<String, String> headers) async {
                final List<int> body = uri.path.endsWith('e.001.vvppp')
                    ? part1
                    : part2;
                return ResumableDownloadResponse.bytes(
                  statusCode: 200,
                  body: body,
                  headers: <String, String>{'content-length': '${body.length}'},
                );
              },
          spawn: (String exe, List<String> args) async {
            _writeEngine(args[args.indexOf('-C') + 1]);
            extracting.complete();
            return proc;
          },
        );
        final Future<VoicevoxInstallLayout?> run = inst.install(
          root: root,
          pkg: pkg,
        );
        // 同步占位：第二次安装在第一个 await 之前就被挡住。
        expect(inst.isBusy, isTrue);
        expect(await inst.install(root: root, pkg: pkg), isNull);
        await extracting.future;
        await inst.cancelAndWait();
        expect(proc.kills, 1);
        expect(await run, isNull);
        expect(inst.step, VoicevoxInstallStep.cancelled);
        expect(inst.isBusy, isFalse);
        expect(_uuidAt(root), 'uuid-old');
        expect(
          Directory(p.join(root, kVoicevoxStagingSubdir)).existsSync(),
          isFalse,
        );
      },
    );

    test('already-downloaded parts are not fetched again', () async {
      final String root = p.join(tmp.path, 'c');
      final Directory downloads = Directory(p.join(root, 'downloads'))
        ..createSync(recursive: true);
      File(p.join(downloads.path, 'e.001.vvppp')).writeAsBytesSync(part1);
      final VoicevoxInstaller inst = installer();
      expect(await inst.install(root: root, pkg: pkg), isNotNull);
      expect(fetched.map((Uri u) => p.posix.basename(u.path)), <String>[
        'e.002.vvppp',
      ]);
    });

    test('7z on Windows needs a tar with lzma', () async {
      final VoicevoxInstaller inst = VoicevoxInstaller(
        httpClientFactory: () => HttpClient(),
        manifest: kAivisSpeechManifest,
        os: 'windows',
        run: (String exe, List<String> args) async =>
            (exitCode: 0, output: 'bsdtar 3.5.2 - libarchive 3.5.2 zlib/1.2.5'),
        open: (HttpClient c, Uri u, Map<String, String> h) async =>
            fail('should not download'),
        spawn: (String exe, List<String> args) async =>
            fail('should not extract'),
      );
      expect(
        await inst.install(
          root: p.join(tmp.path, 'd'),
          pkg: kAivisSpeechManifest.packages['windows-x64']!.single,
        ),
        isNull,
      );
      expect(inst.failure, VoicevoxInstallFailure.noExtractor);
    });
  });

  group('engine', () {
    VoicevoxLocalEngine engine(
      VoicevoxEngineManifest manifest, {
      MemoryPrefStore? prefs,
    }) => VoicevoxLocalEngine(
      prefs: prefs ?? MemoryPrefStore(),
      httpClientFactory: () => HttpClient(),
      manifest: manifest,
      platformKey: 'windows-x64',
      supported: true,
    );

    test('settings default to the engine port and round-trip', () async {
      final MemoryPrefStore prefs = MemoryPrefStore();
      final VoicevoxLocalEngine e = engine(kAivisSpeechManifest, prefs: prefs);
      expect(e.settings.port, 10101);
      expect(e.endpoint, 'http://127.0.0.1:10101');
      expect(await e.setPort(8088), isFalse); // Irodori-TTS-Server 的端口
      expect(await e.setPort(10200), isTrue);
      expect(engine(kAivisSpeechManifest, prefs: prefs).settings.port, 10200);
      expect(prefs.values.keys, contains('tts_aivis_speech_engine_local'));
      e.dispose();
    });

    test(
      '--use_gpu follows the installed package, not the picked one',
      () async {
        final MemoryPrefStore prefs = MemoryPrefStore();
        final VoicevoxLocalEngine e = engine(kVoicevoxManifest, prefs: prefs);
        expect(e.selectedPackage?.accel, VoicevoxAccel.cpu);
        const VoicevoxInstallLayout fake = VoicevoxInstallLayout(
          root: 'r',
          engineDir: 'r/engine',
          executable: 'r/engine/run.exe',
          uuid: 'u',
          version: '0.26.0',
        );
        expect(e.launchSpec(fake).arguments, <String>[
          '--host',
          '127.0.0.1',
          '--port',
          '50021',
        ]);
        // 只选了 GPU 档、还没重装：磁盘上仍是 CPU 包，不能带 --use_gpu。
        await e.setAccel(VoicevoxAccel.nvidia);
        expect(e.selectedPackage?.parts, hasLength(2));
        expect(e.launchSpec(fake).arguments, isNot(contains('--use_gpu')));
        // 已装的是 GPU 包（安装成功才写的已装档位）：带 --use_gpu，与选中档位无关。
        prefs.values[e.prefKey] = jsonEncode(<String, Object?>{
          'port': 50021,
          'accel': 'cpu',
          'installedAccel': 'nvidia',
        });
        final List<String> args = e
            .launchSpec(fake, environment: <String, String>{'HTTPS_PROXY': 'x'})
            .arguments;
        expect(args.last, '--use_gpu');
        expect(
          e
              .launchSpec(
                fake,
                environment: <String, String>{'HTTPS_PROXY': 'x'},
              )
              .environment['HTTPS_PROXY'],
          'x',
        );
        e.dispose();

        final VoicevoxLocalEngine aivis = engine(kAivisSpeechManifest);
        expect(aivis.launchSpec(fake).arguments, isNot(contains('--use_gpu')));
        aivis.dispose();
      },
    );

    VoicevoxEngineManifest testManifest(VoicevoxPackage gpu) =>
        VoicevoxEngineManifest(
          kind: VoicevoxLocalKind.voicevox,
          repo: 'o/r',
          tag: 't',
          defaultPort: 50021,
          installSubdir: 'voicevox_engine',
          packages: <String, List<VoicevoxPackage>>{
            'windows-x64': <VoicevoxPackage>[
              VoicevoxPackage(
                accel: VoicevoxAccel.cpu,
                format: VoicevoxArchiveFormat.zip,
                parts: gpu.parts,
              ),
              gpu,
            ],
          },
        );

    test('installedAccel is written only after a successful install', () async {
      final List<int> body = utf8.encode('PKG');
      final VoicevoxPackage gpu = VoicevoxPackage(
        accel: VoicevoxAccel.nvidia,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart('g.vvpp', body.length, _sha(body)),
        ],
      );
      final VoicevoxEngineManifest manifest = testManifest(gpu);
      int extractExit = 0;
      final MemoryPrefStore prefs = MemoryPrefStore();
      final VoicevoxLocalEngine e = VoicevoxLocalEngine(
        prefs: prefs,
        httpClientFactory: () => HttpClient(),
        manifest: manifest,
        platformKey: 'windows-x64',
        supported: true,
        installer: VoicevoxInstaller(
          httpClientFactory: () => HttpClient(),
          manifest: manifest,
          os: 'windows',
          open: (HttpClient c, Uri u, Map<String, String> h) async =>
              ResumableDownloadResponse.bytes(
                statusCode: 200,
                body: body,
                headers: <String, String>{'content-length': '${body.length}'},
              ),
          spawn: (String exe, List<String> args) async {
            _writeEngine(args[args.indexOf('-C') + 1]);
            return _DoneProcess(extractExit);
          },
        ),
      );
      await e.setAccel(VoicevoxAccel.nvidia);
      expect(await e.install(installDir: tmp.path), isTrue);
      expect(e.settings.installedAccel, VoicevoxAccel.nvidia);
      expect(e.isInstalled, isTrue);

      // 想换回 CPU 但重装失败：磁盘上还是 GPU 包，已装档位不变、照样带 --use_gpu。
      await e.setAccel(VoicevoxAccel.cpu);
      extractExit = 2;
      expect(await e.install(installDir: tmp.path), isFalse);
      expect(e.settings.accel, VoicevoxAccel.cpu);
      expect(e.settings.installedAccel, VoicevoxAccel.nvidia);
      expect(e.isInstalled, isTrue);
      expect(e.launchSpec(e.layout!).arguments, contains('--use_gpu'));

      await e.remove(deleteFiles: true);
      expect(e.settings.installedAccel, isNull);
      e.dispose();
    });

    test(
      'a failed install into a new location keeps the working one recorded',
      () async {
        final List<int> body = utf8.encode('PKG');
        final VoicevoxPackage gpu = VoicevoxPackage(
          accel: VoicevoxAccel.nvidia,
          format: VoicevoxArchiveFormat.zip,
          parts: <VoicevoxPackagePart>[
            VoicevoxPackagePart('g.vvpp', body.length, _sha(body)),
          ],
        );
        final VoicevoxEngineManifest manifest = testManifest(gpu);
        int extractExit = 0;
        final VoicevoxLocalEngine e = VoicevoxLocalEngine(
          prefs: MemoryPrefStore(),
          httpClientFactory: () => HttpClient(),
          manifest: manifest,
          platformKey: 'windows-x64',
          supported: true,
          installer: VoicevoxInstaller(
            httpClientFactory: () => HttpClient(),
            manifest: manifest,
            os: 'windows',
            open: (HttpClient c, Uri u, Map<String, String> h) async =>
                ResumableDownloadResponse.bytes(
                  statusCode: 200,
                  body: body,
                  headers: <String, String>{'content-length': '${body.length}'},
                ),
            spawn: (String exe, List<String> args) async {
              _writeEngine(args[args.indexOf('-C') + 1]);
              return _DoneProcess(extractExit);
            },
          ),
        );
        final String first = p.join(tmp.path, 'first');
        final String second = p.join(tmp.path, 'second');
        expect(await e.install(installDir: first), isTrue);
        final String? installedDir = e.settings.dir;
        expect(installedDir, startsWith(first));
        expect(e.settings.installedAccel, VoicevoxAccel.cpu);

        // 换到新位置但装失败：旧位置那份能用的引擎仍是记录里的安装，「删除」找得到它。
        extractExit = 2;
        expect(await e.install(installDir: second), isFalse);
        expect(e.settings.dir, installedDir);
        expect(e.settings.installedAccel, VoicevoxAccel.cpu);
        expect(e.isInstalled, isTrue);

        await e.remove(deleteFiles: true);
        expect(Directory(installedDir!).existsSync(), isFalse);
        e.dispose();
      },
    );

    test('remove waits for the in-flight install before deleting', () async {
      final List<int> body = utf8.encode('PKG');
      final VoicevoxPackage gpu = VoicevoxPackage(
        accel: VoicevoxAccel.nvidia,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart('g.vvpp', body.length, _sha(body)),
        ],
      );
      final VoicevoxEngineManifest manifest = testManifest(gpu);
      final _HangingProcess proc = _HangingProcess();
      final Completer<void> extracting = Completer<void>();
      final VoicevoxLocalEngine e = VoicevoxLocalEngine(
        prefs: MemoryPrefStore(),
        httpClientFactory: () => HttpClient(),
        manifest: manifest,
        platformKey: 'windows-x64',
        supported: true,
        installer: VoicevoxInstaller(
          httpClientFactory: () => HttpClient(),
          manifest: manifest,
          os: 'windows',
          open: (HttpClient c, Uri u, Map<String, String> h) async =>
              ResumableDownloadResponse.bytes(
                statusCode: 200,
                body: body,
                headers: <String, String>{'content-length': '${body.length}'},
              ),
          spawn: (String exe, List<String> args) async {
            _writeEngine(args[args.indexOf('-C') + 1]);
            extracting.complete();
            return proc;
          },
        ),
      );
      bool installReturned = false;
      final Future<bool> install = e
          .install(installDir: tmp.path)
          .whenComplete(() => installReturned = true);
      await extracting.future;
      expect(await e.start(), isFalse, reason: '安装中不启动');
      await e.remove(deleteFiles: true);
      expect(installReturned, isTrue, reason: '删除要等安装真正退出');
      expect(await install, isFalse);
      expect(proc.kills, 1);
      expect(
        Directory(p.join(tmp.path, 'voicevox_engine')).existsSync(),
        isFalse,
      );
      expect(e.settings.dir, isNull);
      e.dispose();
    });

    test('remove reports a delete failure and keeps the record', () async {
      final MemoryPrefStore prefs = MemoryPrefStore();
      final VoicevoxLocalEngine e = engine(kVoicevoxManifest, prefs: prefs);
      final String root = p.join(tmp.path, 'voicevox_engine');
      _writeEngine(p.join(root, 'engine'));
      prefs.values[e.prefKey] = jsonEncode(<String, Object?>{
        'dir': root,
        'port': 50021,
        'owned': true,
      });
      // Windows 上打开着的文件删不掉（杀软扫描 / 引擎残留进程的同类情形）。
      final RandomAccessFile lock = File(
        p.join(root, 'engine', 'run.exe'),
      ).openSync(mode: FileMode.append);
      try {
        await expectLater(
          e.remove(deleteFiles: true),
          throwsA(isA<LocalInstallRemoveException>()),
        );
        expect(e.settings.dir, root, reason: '记录保留，用户可以再点删除');
      } finally {
        lock.closeSync();
      }
      await e.remove(deleteFiles: true);
      expect(Directory(root).existsSync(), isFalse);
      expect(e.settings.dir, isNull);
      e.dispose();
    }, skip: Platform.isWindows ? false : '只有 Windows 会因打开的句柄删不掉文件');

    test(
      'isInstalled follows the recorded dir; delete only owned subdir',
      () async {
        final MemoryPrefStore prefs = MemoryPrefStore();
        final VoicevoxLocalEngine e = engine(kVoicevoxManifest, prefs: prefs);
        expect(e.isInstalled, isFalse);
        final String root = p.join(tmp.path, 'voicevox_engine');
        _writeEngine(p.join(root, 'engine'));
        prefs.values[e.prefKey] = jsonEncode(<String, Object?>{
          'dir': root,
          'port': 50021,
          'owned': true,
        });
        expect(e.isInstalled, isTrue);
        expect(e.canDeleteFiles, isTrue);
        // 不是本机托管端口的地址：什么都不做（也不会去起进程）。
        await e.ensureRunningFor('http://127.0.0.1:50999');
        expect(e.server.isRunning, isFalse);
        await e.remove(deleteFiles: true);
        expect(Directory(root).existsSync(), isFalse);
        expect(e.isInstalled, isFalse);
        e.dispose();
      },
    );
  });
}
