import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ocr/manga_ocr_cuda_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_cuda_runtime.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() async {
    await fixture.directory.delete(recursive: true);
  });

  test(
    'prepares a private offline runtime and cheap readiness marker',
    () async {
      final MangaOcrCudaRuntime runtime = fixture.runtime();
      expect(await runtime.isReady(), isFalse);
      final List<MangaOcrDownloadEvent> events = await runtime
          .prepare()
          .toList();
      expect(events.last.done, isTrue);
      expect(
        events.every((MangaOcrDownloadEvent event) => event.installing),
        isTrue,
      );
      expect(await runtime.isReady(), isTrue);
      expect(await File(runtime.workerPath).readAsString(), 'fixture worker');
      expect(
        await File(
          p.join(p.dirname(runtime.pythonExecutable), 'python311._pth'),
        ).readAsString(),
        kMangaOcrCudaPythonPathConfiguration,
      );
      expect(fixture.registry.calls, hasLength(3));
      final _Invocation install = fixture.registry.calls.first;
      expect(install.executable, endsWith('python.exe'));
      expect(p.isWithin(fixture.directory.path, install.executable), isTrue);
      expect(
        install.arguments,
        containsAll(<String>[
          '-I',
          '--isolated',
          '--no-index',
          '--find-links',
          fixture.directory.path,
          '--only-binary=:all:',
          '--require-hashes',
          '--no-deps',
          '--no-compile',
          '--no-cache-dir',
          '--disable-pip-version-check',
        ]),
      );
      expect(install.arguments, isNot(contains('--target')));
      expect(install.environment['HF_HUB_OFFLINE'], '1');
      expect(install.environment['PYTHONNOUSERSITE'], '1');
      expect(
        install.environment['PIP_CONFIG_FILE'],
        Platform.isWindows ? 'nul' : '/dev/null',
      );
      expect(install.launchArguments.take(2), <String>['-I', '-c']);
      expect(install.launchArguments[2], contains('kernel.OpenProcess'));
      expect(
        install.launchArguments[2],
        contains('kernel.WaitForSingleObject'),
      );
      expect(install.launchArguments[2], contains('os._exit(125)'));
      expect(install.launchArguments[3], pid.toString());
      expect(fixture.registry.calls[1].arguments, contains('check'));
      expect(
        fixture.registry.calls[2].arguments.last,
        contains('import torch, transformers, PIL'),
      );
      // A matching size/mtime receipt avoids reading large unchanged archives.
      final List<MangaOcrDownloadEvent> second = await runtime
          .prepare()
          .toList();
      expect(second, hasLength(1));
      expect(fixture.registry.calls, hasLength(3));
      expect(await runtime.isReady(), isTrue);
      await File(
        p.join(
          p.dirname(runtime.pythonExecutable),
          'Lib/site-packages/torch/__init__.py',
        ),
      ).delete();
      expect(await runtime.isReady(), isFalse);
    },
  );

  test('worker or pinned manifest changes invalidate the marker', () async {
    await fixture.runtime().prepare().drain<void>();
    expect(
      await fixture.runtime(workerSource: 'new worker').isReady(),
      isFalse,
    );
    final List<MangaOcrModelFile> changed = <MangaOcrModelFile>[
      ...fixture.manifest,
      const MangaOcrModelFile(
        fileName: 'new-model.bin',
        url: 'unused',
        expectedBytes: 1,
        role: MangaOcrModelRole.recognizer,
      ),
    ];
    expect(await fixture.runtime(manifest: changed).isReady(), isFalse);
  });

  test('a changed worker is refreshed without reinstalling Python', () async {
    await fixture.runtime().prepare().drain<void>();
    final MangaOcrCudaRuntime changed = fixture.runtime(
      workerSource: 'new worker',
    );
    await changed.prepare().drain<void>();
    expect(await changed.isReady(), isTrue);
    expect(await File(changed.workerPath).readAsString(), 'new worker');
    expect(fixture.registry.calls, hasLength(3));
  });

  test(
    'changed same-size model is rehashed and corrupt import cannot reuse ready receipt',
    () async {
      final MangaOcrCudaRuntime runtime = fixture.runtime();
      await runtime.prepare().drain<void>();
      final File model = File(p.join(fixture.directory.path, 'model.bin'));
      final DateTime previousTime = await model.lastModified();
      await model.writeAsBytes(<int>[9, 9, 9]);
      await model.setLastModified(previousTime.add(const Duration(seconds: 2)));
      expect(await runtime.isReady(), isFalse);
      await expectLater(
        runtime.prepare().drain<void>(),
        throwsA(isA<StateError>()),
      );
      expect(await model.exists(), isFalse);
      expect(await runtime.isReady(), isFalse);
      expect(fixture.registry.calls, hasLength(3));
      // A later correct repair updates only its receipt and keeps installed pip.
      await model.writeAsBytes(<int>[1, 2, 3]);
      await model.setLastModified(previousTime.add(const Duration(seconds: 4)));
      final List<MangaOcrDownloadEvent> events = await runtime
          .prepare()
          .toList();
      expect(
        events
            .where((MangaOcrDownloadEvent e) => e.totalBytes > 0)
            .map((e) => e.fileName),
        <String>['model.bin'],
      );
      expect(await runtime.isReady(), isTrue);
      expect(fixture.registry.calls, hasLength(3));
    },
  );

  test(
    'changed expected hash forces verification even when file stat is unchanged',
    () async {
      await fixture.runtime().prepare().drain<void>();
      final List<MangaOcrModelFile> changed = fixture.manifest
          .map(
            (MangaOcrModelFile item) => item.fileName != 'model.bin'
                ? item
                : MangaOcrModelFile(
                    fileName: item.fileName,
                    url: item.url,
                    expectedBytes: item.expectedBytes,
                    role: item.role,
                    sha256: '0' * 64,
                  ),
          )
          .toList();
      final MangaOcrCudaRuntime runtime = fixture.runtime(manifest: changed);
      expect(await runtime.isReady(), isFalse);
      await expectLater(
        runtime.prepare().drain<void>(),
        throwsA(isA<StateError>()),
      );
      expect(fixture.registry.calls, hasLength(3));
    },
  );

  for (final bool wrongSize in <bool>[false, true]) {
    test(
      'corrupt ${wrongSize ? 'size' : 'SHA256'} asset is removed before running code',
      () async {
        final File asset = File(p.join(fixture.directory.path, 'model.bin'));
        await asset.writeAsBytes(wrongSize ? <int>[1] : <int>[9, 9, 9]);
        await expectLater(
          fixture.runtime().prepare().drain<void>(),
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              contains('Removed corrupt model.bin'),
            ),
          ),
        );
        expect(await asset.exists(), isFalse);
        expect(fixture.registry.calls, isEmpty);
        expect(await fixture.runtime().isReady(), isFalse);
      },
    );
  }

  test('unpinned executable runtime assets are rejected', () async {
    final List<MangaOcrModelFile> manifest = fixture.manifest
        .map(
          (MangaOcrModelFile item) => MangaOcrModelFile(
            fileName: item.fileName,
            url: item.url,
            expectedBytes: item.expectedBytes,
            role: item.role,
            sha256: item.role == MangaOcrModelRole.runtime ? null : item.sha256,
          ),
        )
        .toList();
    await expectLater(
      fixture.runtime(manifest: manifest).prepare().drain<void>(),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('no SHA256'),
        ),
      ),
    );
    expect(fixture.registry.calls, isEmpty);
  });

  test('zero-byte download is removed so the downloader can retry', () async {
    final File model = File(p.join(fixture.directory.path, 'model.bin'));
    await model.writeAsBytes(<int>[]);
    await expectLater(
      fixture.runtime().prepare().drain<void>(),
      throwsA(isA<StateError>()),
    );
    expect(await model.exists(), isFalse);
    expect(fixture.registry.calls, isEmpty);
  });

  test('rejects symbolic links inside archives', () async {
    final ArchiveFile link = ArchiveFile.string('redirect', '../outside')
      ..mode = 0xA1FF
      ..isSymbolicLink = true
      ..nameOfLinkedFile = '../outside';
    await fixture.replacePythonArchive(<ArchiveFile>[link]);
    await expectLater(
      fixture.runtime().prepare().drain<void>(),
      throwsA(isA<StateError>()),
    );
    expect(fixture.registry.calls, isEmpty);
  });

  for (final String entry in <String>[
    '../escaped.txt',
    'C:/escaped.txt',
    'nested/../../escaped.txt',
    'safe.txt:evil',
  ]) {
    test('rejects ZIP traversal or Windows path $entry', () async {
      await fixture.replacePythonArchive(<ArchiveFile>[
        ArchiveFile.string(entry, 'escape'),
      ]);
      await expectLater(
        fixture.runtime().prepare().drain<void>(),
        throwsA(isA<StateError>()),
      );
      expect(fixture.registry.calls, isEmpty);
      expect(await fixture.runtime().isReady(), isFalse);
      expect(
        await File(
          p.join(fixture.directory.parent.path, 'escaped.txt'),
        ).exists(),
        isFalse,
      );
    });
  }

  test('validates wheel entry paths before invoking pip', () async {
    await fixture.replaceAsset(
      'example-1.0-py3-none-any.whl',
      _zip(<ArchiveFile>[ArchiveFile.string('../outside.py', 'escape')]),
    );
    await expectLater(
      fixture.runtime().prepare().drain<void>(),
      throwsA(isA<StateError>()),
    );
    expect(fixture.registry.calls, isEmpty);
  });

  test(
    'missing app-local Microsoft runtime fails without assuming system DLLs',
    () async {
      await File(p.join(fixture.crt.path, 'msvcp140.dll')).delete();
      await expectLater(
        fixture.runtime().prepare().drain<void>(),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('msvcp140.dll'),
          ),
        ),
      );
      expect(fixture.registry.calls, isEmpty);
      expect(await fixture.runtime().isReady(), isFalse);
      expect(await fixture.stagingDirectories(), isEmpty);
    },
  );

  test(
    'failed import never publishes runtime and drains child diagnostics',
    () async {
      fixture.registry.failureCall = 3;
      await expectLater(
        fixture.runtime().prepare().drain<void>(),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('fixture import failure'),
          ),
        ),
      );
      expect(await fixture.runtime().isReady(), isFalse);
      expect(await fixture.stagingDirectories(), isEmpty);
      expect(
        await Directory(p.join(fixture.directory.path, 'runtime')).exists(),
        isFalse,
      );
    },
  );

  test(
    'concurrent preparations run one installation for the same directory',
    () async {
      fixture.registry.pauseFirst = true;
      final Future<void> first = fixture.runtime().prepare().drain<void>();
      await fixture.registry.started.future;
      final Future<void> second = fixture.runtime().prepare().drain<void>();
      fixture.registry.active!.finish(0);
      await Future.wait(<Future<void>>[first, second]);
      expect(fixture.registry.calls, hasLength(3));
      expect(fixture.registry.maxActive, 1);
      expect(await fixture.runtime().isReady(), isTrue);
    },
  );

  test(
    'cancelling installation waits for child exit and removes staging',
    () async {
      fixture.registry.pauseFirst = true;
      final StreamSubscription<MangaOcrDownloadEvent> subscription = fixture
          .runtime()
          .prepare()
          .listen((_) {});
      await fixture.registry.started.future;
      final _FakeProcess child = fixture.registry.active!;
      bool cancelled = false;
      final Future<void> cancel = subscription.cancel().then(
        (_) => cancelled = true,
      );
      await child.killed.future;
      expect(cancelled, isFalse);
      expect(await fixture.runtime().isReady(), isFalse);
      expect(await fixture.stagingDirectories(), isNotEmpty);
      child.finish(-1);
      await cancel;
      expect(cancelled, isTrue);
      expect(await fixture.stagingDirectories(), isEmpty);
      expect(fixture.registry.calls, hasLength(1));
      // The cancellation releases the directory lock for a later retry.
      fixture.registry.pauseFirst = false;
      await fixture.runtime().prepare().drain<void>();
      expect(await fixture.runtime().isReady(), isTrue);
    },
  );

  test(
    'cancelling a queued install neither kills the owner nor bypasses it',
    () async {
      fixture.registry.pauseFirst = true;
      final Future<void> first = fixture.runtime().prepare().drain<void>();
      await fixture.registry.started.future;
      final _FakeProcess owner = fixture.registry.active!;
      final StreamSubscription<MangaOcrDownloadEvent> queued = fixture
          .runtime()
          .prepare()
          .listen((_) {});
      await queued.cancel();
      expect(owner.killed.isCompleted, isFalse);
      final Future<void> third = fixture.runtime().prepare().drain<void>();
      owner.finish(0);
      await Future.wait(<Future<void>>[first, third]);
      expect(fixture.registry.calls, hasLength(3));
      expect(fixture.registry.maxActive, 1);
    },
  );

  test('bad marker is treated as not ready', () async {
    await fixture.runtime().prepare().drain<void>();
    await File(
      p.join(fixture.directory.path, 'runtime', '.ready.json'),
    ).writeAsString('{broken');
    expect(await fixture.runtime().isReady(), isFalse);
  });

  test('marker without environment receipt cannot skip installation', () async {
    final MangaOcrCudaRuntime runtime = fixture.runtime();
    await runtime.prepare().drain<void>();
    final File marker = File(
      p.join(fixture.directory.path, 'runtime', '.ready.json'),
    );
    final Map<String, dynamic> data =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    data.remove('environmentFingerprint');
    await marker.writeAsString(jsonEncode(data));
    expect(await runtime.isReady(), isFalse);
    await runtime.prepare().drain<void>();
    expect(fixture.registry.calls, hasLength(6));
    expect(await runtime.isReady(), isTrue);
  });

  test(
    'locked preparation removes only abandoned installer directories',
    () async {
      final Directory stale = await Directory(
        p.join(fixture.directory.path, '.runtime-install-deadbeef'),
      ).create();
      await File(
        p.join(stale.path, 'partial-wheel'),
      ).writeAsString('interrupted');
      final Directory unrelated = await Directory(
        p.join(fixture.directory.path, 'keep-me'),
      ).create();
      final File keep = await File(
        p.join(unrelated.path, 'data'),
      ).writeAsString('user data');
      await fixture.runtime().prepare().drain<void>();
      expect(await stale.exists(), isFalse);
      expect(await keep.readAsString(), 'user data');
      expect(
        await File(p.join(fixture.directory.path, 'model.bin')).exists(),
        isTrue,
      );
      expect(await fixture.runtime().isReady(), isTrue);
    },
  );

  test('abandoned staging cleanup never follows a directory link', () async {
    final Directory outside = await Directory.systemTemp.createTemp(
      'manga-runtime-outside-',
    );
    final File keep = await File(
      p.join(outside.path, 'keep'),
    ).writeAsString('outside data');
    final Link link = Link(
      p.join(fixture.directory.path, '.runtime-install-link'),
    );
    try {
      await link.create(outside.path);
      await expectLater(
        fixture.runtime().prepare().drain<void>(),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('must not be a link'),
          ),
        ),
      );
      expect(await keep.readAsString(), 'outside data');
      expect(fixture.registry.calls, isEmpty);
    } finally {
      if (await link.exists()) await link.delete();
      await outside.delete(recursive: true);
    }
  });
}

List<int> _zip(List<ArchiveFile> entries) {
  final Archive archive = Archive();
  for (final ArchiveFile entry in entries) {
    archive.addFile(entry);
  }
  return ZipEncoder().encode(archive)!;
}

class _Fixture {
  _Fixture(this.directory, this.crt);
  final Directory directory;
  final Directory crt;
  final _FakeRegistry registry = _FakeRegistry();
  final List<MangaOcrModelFile> manifest = <MangaOcrModelFile>[];

  static Future<_Fixture> create() async {
    final Directory root = await Directory.systemTemp.createTemp(
      'manga-cuda-runtime-test-',
    );
    final Directory crt = await Directory(p.join(root.path, 'app')).create();
    final _Fixture fixture = _Fixture(root, crt);
    for (final String name in <String>[
      'msvcp140.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
    ]) {
      await File(p.join(crt.path, name)).writeAsString('fixture DLL');
    }
    await fixture.replacePythonArchive(<ArchiveFile>[
      for (final String name in <String>[
        'python.exe',
        'python311.dll',
        'python311.zip',
      ])
        ArchiveFile.string(name, 'fixture Python'),
    ]);
    await fixture.replaceAsset(
      kMangaOcrCudaPipWheelFileName,
      _zip(<ArchiveFile>[ArchiveFile.string('pip/__init__.py', 'fixture pip')]),
    );
    await fixture.replaceAsset(
      'example-1.0-py3-none-any.whl',
      _zip(<ArchiveFile>[
        ArchiveFile.string('example/__init__.py', 'fixture example'),
      ]),
    );
    await fixture.replaceAsset('model.bin', <int>[
      1,
      2,
      3,
    ], role: MangaOcrModelRole.recognizer);
    return fixture;
  }

  Future<void> replacePythonArchive(List<ArchiveFile> entries) =>
      replaceAsset(kMangaOcrCudaPythonArchiveFileName, _zip(entries));

  Future<void> replaceAsset(
    String name,
    List<int> bytes, {
    MangaOcrModelRole role = MangaOcrModelRole.runtime,
  }) async {
    await File(p.join(directory.path, name)).writeAsBytes(bytes);
    manifest.removeWhere((MangaOcrModelFile item) => item.fileName == name);
    manifest.add(
      MangaOcrModelFile(
        fileName: name,
        url: 'https://example.invalid/$name',
        expectedBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        role: role,
      ),
    );
  }

  MangaOcrCudaRuntime runtime({
    String workerSource = 'fixture worker',
    List<MangaOcrModelFile>? manifest,
  }) => MangaOcrCudaRuntime(
    directory,
    manifest: manifest ?? this.manifest,
    requirements: 'fixture==1.0 --hash=sha256:fixture',
    workerSource: workerSource,
    runtimeLibrariesDirectory: crt,
    processRegistry: registry,
  );

  Future<List<FileSystemEntity>> stagingDirectories() async => directory
      .list()
      .where(
        (FileSystemEntity item) =>
            p.basename(item.path).startsWith('.runtime-install-'),
      )
      .toList();
}

class _Invocation {
  _Invocation(this.executable, this.launchArguments, this.environment)
    : arguments = (jsonDecode(launchArguments.last) as List<dynamic>)
          .cast<String>();
  final String executable;
  final List<String> arguments;
  final List<String> launchArguments;
  final Map<String, String> environment;
}

class _FakeRegistry extends HelperProcessRegistry {
  final List<_Invocation> calls = <_Invocation>[];
  final Completer<void> started = Completer<void>();
  _FakeProcess? active;
  bool pauseFirst = false;
  int? failureCall;
  int _active = 0;
  int maxActive = 0;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    calls.add(
      _Invocation(executable, arguments, environment ?? <String, String>{}),
    );
    expect(runInShell, isFalse);
    if (calls.last.arguments.contains('install')) {
      for (final String module in <String>['torch', 'transformers', 'PIL']) {
        final File init = File(
          p.join(
            workingDirectory!,
            'Lib',
            'site-packages',
            module,
            '__init__.py',
          ),
        );
        await init.parent.create(recursive: true);
        await init.writeAsString('fixture installed module');
      }
    }
    final _FakeProcess process = _FakeProcess();
    active = process;
    _active++;
    if (_active > maxActive) maxActive = _active;
    unawaited(
      process.exitCode.then((_) {
        _active--;
      }),
    );
    if (!started.isCompleted) started.complete();
    if (!pauseFirst || calls.length != 1) {
      scheduleMicrotask(
        () => process.finish(
          failureCall == calls.length ? 1 : 0,
          error: failureCall == calls.length ? 'fixture import failure' : null,
        ),
      );
    }
    return process;
  }
}

class _FakeProcess implements Process {
  final Completer<int> _exit = Completer<int>();
  final Completer<void> killed = Completer<void>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 987654;
  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!killed.isCompleted) killed.complete();
    return true;
  }

  void finish(int code, {String? error}) {
    if (error != null) _stderr.add(utf8.encode(error));
    unawaited(_stderr.close());
    _exit.complete(code);
  }
}
