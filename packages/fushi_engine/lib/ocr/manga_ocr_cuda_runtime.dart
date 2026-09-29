import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ocr/manga_ocr_cuda_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_cuda_worker.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';

/// Installs the pinned Windows Python runtime without consulting system Python,
/// pip configuration, package indexes, PATH, or the user's site-packages.
class MangaOcrCudaRuntime {
  MangaOcrCudaRuntime(
    Directory directory, {
    List<MangaOcrModelFile> manifest = kMangaOcrCudaModelManifest,
    String requirements = kMangaOcrCudaRequirements,
    String workerSource = kMangaOcrCudaWorkerSource,
    Directory? runtimeLibrariesDirectory,
    HelperProcessRegistry? processRegistry,
  }) : _directory = directory.absolute,
       _manifest = List<MangaOcrModelFile>.unmodifiable(manifest),
       _requirements = requirements,
       _workerSource = workerSource,
       _runtimeLibrariesDirectory =
           runtimeLibrariesDirectory ??
           File(Platform.resolvedExecutable).parent,
       _processRegistry = processRegistry ?? HelperProcessRegistry.instance;

  final Directory _directory;
  final List<MangaOcrModelFile> _manifest;
  final String _requirements;
  final String _workerSource;
  final Directory _runtimeLibrariesDirectory;
  final HelperProcessRegistry _processRegistry;
  static final Map<String, Future<void>> _installations =
      <String, Future<void>>{};
  static const String _markerName = '.ready.json';
  static const List<String> _crtFiles = <String>[
    'msvcp140.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
  ];
  static const List<String> _requiredFiles = <String>[
    'python.exe',
    'python311.dll',
    'python311.zip',
    'python311._pth',
    'worker.py',
    ..._crtFiles,
    'Lib/site-packages/torch/__init__.py',
    'Lib/site-packages/transformers/__init__.py',
    'Lib/site-packages/PIL/__init__.py',
  ];

  String get pythonExecutable =>
      p.join(_directory.path, 'runtime', 'python.exe');
  String get workerPath => p.join(_directory.path, 'runtime', 'worker.py');

  String get _fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode(<Object>[
            kMangaOcrCudaRuntimeVersion,
            kMangaOcrCudaPythonPathConfiguration,
            _requirements,
            _workerSource,
            for (final MangaOcrModelFile file in _manifest)
              <Object?>[file.fileName, file.expectedBytes, file.sha256],
          ]),
        ),
      )
      .toString();

  String get _environmentFingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode(<Object>[
            kMangaOcrCudaRuntimeVersion,
            kMangaOcrCudaPythonPathConfiguration,
            _requirements,
            for (final MangaOcrModelFile file in _manifest)
              if (file.role == MangaOcrModelRole.runtime)
                <Object?>[file.fileName, file.expectedBytes, file.sha256],
          ]),
        ),
      )
      .toString();

  Future<Map<String, dynamic>?> _readReceipt(Directory runtime) async {
    final File marker = File(p.join(runtime.path, _markerName));
    if (!await _regularFile(marker.path) || await marker.length() > 65536) {
      return null;
    }
    try {
      final Object? value = jsonDecode(await marker.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> _runtimeInstalled(
    Directory runtime,
    Map<String, dynamic>? receipt,
  ) async {
    if (await FileSystemEntity.type(runtime.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        receipt == null ||
        receipt['environmentFingerprint'] != _environmentFingerprint) {
      return false;
    }
    for (final String name in _requiredFiles) {
      if (name != 'worker.py' &&
          !await _regularFile(p.join(runtime.path, name))) {
        return false;
      }
    }
    return true;
  }

  /// Deliberately cheap: the multi-GB payload is hashed only during preparation.
  Future<bool> isReady() async {
    final Directory runtime = Directory(p.join(_directory.path, 'runtime'));
    try {
      final Map<String, dynamic>? receipt = await _readReceipt(runtime);
      if (receipt?['fingerprint'] != _fingerprint ||
          !await _runtimeInstalled(runtime, receipt) ||
          !await _regularFile(workerPath)) {
        return false;
      }
      final Object? assets = receipt?['assets'];
      if (assets is! Map) {
        return false;
      }
      for (final MangaOcrModelFile file in _manifest) {
        if (!await _matchesAsset(
          File(p.join(_directory.path, file.fileName)),
          file,
          assets[file.fileName],
        )) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  /// Downloading precedes this stream. Cancellation waits for the active child
  /// process to exit and for temporary files/locks to be released.
  Stream<MangaOcrDownloadEvent> prepare() {
    final _Installation operation = _Installation();
    late final StreamController<MangaOcrDownloadEvent> controller;
    controller = StreamController<MangaOcrDownloadEvent>(
      onListen: () => unawaited(_prepare(operation, controller)),
      onCancel: operation.cancel,
    );
    return controller.stream;
  }

  Future<void> _prepare(
    _Installation operation,
    StreamController<MangaOcrDownloadEvent> controller,
  ) async {
    Directory? staging;
    RandomAccessFile? lock;
    bool fileLocked = false;
    bool published = false;
    bool completed = false;
    String? lockKey;
    Future<void>? predecessor;
    final Completer<void> released = Completer<void>();
    try {
      await _directory.create(recursive: true);
      final String root = await _directory.resolveSymbolicLinks();
      lockKey = Platform.isWindows ? root.toLowerCase() : root;
      predecessor = _installations[lockKey] ?? Future<void>.value();
      _installations[lockKey] = released.future;
      await Future.any(<Future<void>>[predecessor, operation.cancelled.future]);
      operation.check();
      final String lockPath = p.join(root, '.runtime-install.lock');
      await _rejectLink(lockPath);
      lock = await File(lockPath).open(mode: FileMode.append);
      while (!fileLocked) {
        operation.check();
        try {
          await lock.lock(FileLock.exclusive);
          fileLocked = true;
        } on FileSystemException catch (error) {
          // Non-blocking lock contention is cancellable; other I/O errors fail.
          if (!<int>[11, 33, 35].contains(error.osError?.errorCode)) {
            rethrow;
          }
          await Future.any(<Future<void>>[
            Future<void>.delayed(const Duration(milliseconds: 100)),
            operation.cancelled.future,
          ]);
        }
      }
      operation.check();
      await _cleanInterruptedInstallations(root, operation);
      if (await isReady()) {
        operation.committed = true;
        completed = true;
        return;
      }
      final Directory runtime = Directory(p.join(root, 'runtime'));
      await _rejectLink(runtime.path);
      final Map<String, dynamic>? receipt = await _readReceipt(runtime);
      final bool runtimeInstalled = await _runtimeInstalled(runtime, receipt);
      final Map<String, Object?> assets = await _verifyAssets(
        root,
        operation,
        controller,
        receipt?['assets'],
      );
      operation.check();
      if (runtimeInstalled) {
        // Model repairs and worker updates do not require unpacking 7.56 GB of
        // already installed wheels. The runtime and asset receipts are separate.
        await File(workerPath).writeAsString(_workerSource);
        await _writeReceipt(runtime, assets, operation);
        operation.committed = true;
        completed = true;
        return;
      }
      staging = await Directory(root).createTemp('.runtime-install-');
      _event(controller, name: 'Python');
      await _extractZip(
        File(p.join(root, kMangaOcrCudaPythonArchiveFileName)),
        staging,
        operation,
      );
      await File(
        p.join(staging.path, 'python311._pth'),
      ).writeAsString(kMangaOcrCudaPythonPathConfiguration);
      await _copyRuntimeLibraries(staging);
      await _extractZip(
        File(p.join(root, kMangaOcrCudaPipWheelFileName)),
        Directory(p.join(staging.path, 'Lib', 'site-packages')),
        operation,
      );
      final File requirements = File(p.join(staging.path, 'requirements.lock'));
      await requirements.writeAsString(_requirements);
      _event(controller, name: 'PyTorch / Transformers');
      await _runPython(operation, staging, <String>[
        '-I',
        '-m',
        'pip',
        '--isolated',
        'install',
        '--no-index',
        '--find-links',
        root,
        '--only-binary=:all:',
        '--require-hashes',
        '--no-deps',
        '--no-compile',
        '--no-warn-script-location',
        '--disable-pip-version-check',
        '--no-cache-dir',
        '-r',
        requirements.path,
      ]);
      await _runPython(operation, staging, <String>[
        '-I',
        '-m',
        'pip',
        '--isolated',
        'check',
        '--disable-pip-version-check',
      ]);
      _event(controller, name: 'torch / transformers / PIL');
      await _runPython(operation, staging, <String>[
        '-I',
        '-c',
        'import torch, transformers, PIL; '
            'from transformers import VisionEncoderDecoderModel, ViTImageProcessor; '
            'import jaconv; print(torch.__version__, transformers.__version__, PIL.__version__)',
      ]);
      await File(
        p.join(staging.path, 'worker.py'),
      ).writeAsString(_workerSource);
      for (final String name in _requiredFiles) {
        if (!await _regularFile(p.join(staging.path, name))) {
          throw StateError('Incomplete manga-ocr runtime: $name');
        }
      }
      operation.check();
      if (await runtime.exists()) {
        await runtime.delete(recursive: true);
      }
      operation.check();
      staging = await staging.rename(runtime.path);
      published = true;
      operation.check();
      await _writeReceipt(runtime, assets, operation);
      operation.check();
      operation.committed = true;
      staging = null;
      completed = true;
    } catch (error, stack) {
      if (!operation.isCancelled) {
        controller.addError(error, stack);
      }
    } finally {
      try {
        // A cancelled commit must never leave a ready marker. Only directories
        // created by this operation are recursively removed.
        if (staging != null && await staging.exists()) {
          if (published) {
            final File marker = File(p.join(staging.path, _markerName));
            if (await marker.exists()) {
              await marker.delete();
            }
          }
          await staging.delete(recursive: true);
        }
        if (fileLocked) {
          await lock!.unlock();
        }
      } catch (error, stack) {
        if (!operation.isCancelled) {
          controller.addError(error, stack);
        }
      } finally {
        try {
          // Closing the handle also releases the OS lock if cleanup/unlock
          // failed. Always finish cancellation, even on filesystem errors.
          await lock?.close();
        } catch (error, stack) {
          if (!operation.isCancelled) {
            controller.addError(error, stack);
          }
        }
        // A cancelled queued operation must not let its successor bypass the
        // still-running predecessor (POSIX locks are per process).
        unawaited(
          (predecessor ?? Future<void>.value()).then((_) {
            released.complete();
            if (lockKey != null &&
                identical(_installations[lockKey], released.future)) {
              _installations.remove(lockKey);
            }
          }),
        );
        operation.finished.complete();
        if (completed && !operation.isCancelled) {
          _event(controller, done: true);
        }
        unawaited(controller.close());
      }
    }
  }

  static Future<void> _cleanInterruptedInstallations(
    String root,
    _Installation operation,
  ) async {
    final String normalizedRoot = p.normalize(root);
    await for (final FileSystemEntity entity in Directory(
      root,
    ).list(followLinks: false)) {
      operation.check();
      if (!RegExp(
        r'^\.runtime-install-[a-zA-Z0-9]+$',
      ).hasMatch(p.basename(entity.path))) {
        continue;
      }
      final String path = p.normalize(entity.absolute.path);
      if (!p.isWithin(normalizedRoot, path) ||
          p.dirname(path) != normalizedRoot) {
        throw StateError(
          'Interrupted runtime directory escapes model directory: $path',
        );
      }
      final FileSystemEntityType type = await FileSystemEntity.type(
        path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        throw StateError(
          'Interrupted runtime directory must not be a link: $path',
        );
      }
      if (type != FileSystemEntityType.directory) {
        continue;
      }
      final Directory directory = Directory(path);
      final String resolved = await directory.resolveSymbolicLinks();
      if (!p.isWithin(normalizedRoot, resolved) ||
          p.dirname(resolved) != normalizedRoot) {
        throw StateError(
          'Interrupted runtime directory resolves outside model directory: $path',
        );
      }
      // Directory.delete unlinks nested links; it does not recurse into their
      // targets. This runs under both locks, before creating our own stage.
      await directory.delete(recursive: true);
    }
  }

  Future<Map<String, Object?>> _verifyAssets(
    String root,
    _Installation operation,
    StreamController<MangaOcrDownloadEvent> controller,
    Object? previousAssets,
  ) async {
    final Set<String> names = <String>{};
    final Map<String, Object?> assets = <String, Object?>{};
    for (final MangaOcrModelFile item in _manifest) {
      _safeRelativePath(item.fileName);
      if (p.basename(item.fileName) != item.fileName ||
          !names.add(item.fileName.toLowerCase())) {
        throw StateError('Invalid runtime manifest filename: ${item.fileName}');
      }
      final String? expected = item.sha256;
      if (expected == null || expected.isEmpty) {
        if (item.role == MangaOcrModelRole.runtime) {
          throw StateError('Runtime asset has no SHA256: ${item.fileName}');
        }
      }
      if (expected != null &&
          expected.isNotEmpty &&
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expected)) {
        throw StateError('Invalid SHA256: ${item.fileName}');
      }
      operation.check();
      final File file = File(p.join(root, item.fileName));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('Missing downloaded asset: ${item.fileName}');
      }
      if (await file.length() != item.expectedBytes) {
        await _discardCorrupt(
          file,
          'size does not match ${item.expectedBytes}',
        );
      }
      final Map<String, Object?> identity = _assetIdentity(
        item,
        await file.stat(),
      );
      final Object? previous = previousAssets is Map
          ? previousAssets[item.fileName]
          : null;
      if (previous is Map && _sameIdentity(identity, previous)) {
        assets[item.fileName] = identity;
        continue;
      }
      if (expected == null || expected.isEmpty) {
        assets[item.fileName] = identity;
        continue;
      }
      int received = 0;
      int notified = 0;
      final Digest actual = await sha256
          .bind(
            file.openRead().map((List<int> bytes) {
              operation.check();
              received += bytes.length;
              if (received - notified >= 8 * 1024 * 1024 ||
                  received == item.expectedBytes) {
                notified = received;
                controller.add(
                  MangaOcrDownloadEvent(
                    fileName: item.fileName,
                    receivedBytes: received,
                    totalBytes: item.expectedBytes,
                    installing: true,
                  ),
                );
              }
              return bytes;
            }),
          )
          .first;
      operation.check();
      if (!_sameIdentity(identity, _assetIdentity(item, await file.stat()))) {
        throw StateError(
          'Asset changed during SHA256 validation: ${item.fileName}',
        );
      }
      if (actual.toString() != expected.toLowerCase()) {
        await _discardCorrupt(file, 'SHA256 $actual does not match $expected');
      }
      if (item.role == MangaOcrModelRole.runtime) {
        if (!item.fileName.endsWith('.zip') &&
            !item.fileName.endsWith('.whl')) {
          throw StateError('Unsupported runtime archive: ${item.fileName}');
        }
        await _validateArchive(file, operation);
      }
      assets[item.fileName] = identity;
    }
    if (!names.contains(kMangaOcrCudaPythonArchiveFileName.toLowerCase()) ||
        !names.contains(kMangaOcrCudaPipWheelFileName.toLowerCase())) {
      throw StateError('Runtime manifest must include embedded Python and pip');
    }
    return assets;
  }

  Future<void> _copyRuntimeLibraries(Directory target) async {
    for (final String name in <String>[
      ..._crtFiles,
      'msvcp140_1.dll',
      'msvcp140_2.dll',
      'msvcp140_codecvt_ids.dll',
      'concrt140.dll',
    ]) {
      final File source = File(p.join(_runtimeLibrariesDirectory.path, name));
      if (await _regularFile(source.path)) {
        await source.copy(p.join(target.path, name));
      } else if (_crtFiles.contains(name)) {
        throw StateError('Manga-ocr requires bundled Microsoft runtime: $name');
      }
    }
  }

  Future<void> _runPython(
    _Installation operation,
    Directory runtime,
    List<String> arguments,
  ) async {
    operation.check();
    final Process process = await _processRegistry.start(
      p.join(runtime.path, 'python.exe'),
      <String>[
        '-I',
        '-c',
        _installerBootstrap,
        pid.toString(),
        jsonEncode(arguments),
      ],
      workingDirectory: runtime.path,
      environment: <String, String>{
        'PYTHONNOUSERSITE': '1',
        'PYTHONPATH': '',
        'HF_HUB_OFFLINE': '1',
        'TRANSFORMERS_OFFLINE': '1',
        'HF_HUB_DISABLE_TELEMETRY': '1',
        'PIP_NO_INDEX': '1',
        // --isolated still reads global/site config and PIP_CONFIG_FILE.
        // pip compares os.devnull literally, hence lower-case Windows "nul".
        'PIP_CONFIG_FILE': Platform.isWindows ? 'nul' : '/dev/null',
      },
    );
    operation.process = process;
    if (operation.isCancelled) {
      process.kill(ProcessSignal.sigkill);
    }
    String diagnostics = '';
    Future<void> drain(Stream<List<int>> stream) async {
      await for (final String chunk in stream.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        diagnostics += chunk;
        if (diagnostics.length > 16384) {
          diagnostics = diagnostics.substring(diagnostics.length - 16384);
        }
      }
    }

    try {
      final Future<void> stdout = drain(process.stdout);
      final Future<void> stderr = drain(process.stderr);
      final int code = await process.exitCode;
      await Future.wait(<Future<void>>[stdout, stderr]);
      operation.check();
      if (code != 0) {
        throw StateError(
          'Manga-ocr runtime installation exited ($code): $diagnostics',
        );
      }
    } finally {
      operation.process = null;
    }
  }

  static Future<void> _discardCorrupt(File file, String reason) async {
    await file.delete();
    throw StateError(
      'Removed corrupt ${p.basename(file.path)} ($reason). Download it again.',
    );
  }

  static Future<bool> _regularFile(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file &&
      (await File(path).stat()).size > 0;

  static Future<void> _rejectLink(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Runtime path must not be a link: $path');
    }
  }

  static void _safeRelativePath(String name) {
    final String normalized = name.replaceAll('\\', '/');
    final List<String> parts = normalized.split('/');
    if (normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized.contains('\u0000') ||
        normalized.isEmpty ||
        parts.any(
          (String part) =>
              part == '..' ||
              part == '.' ||
              part.endsWith(' ') ||
              part.endsWith('.') ||
              RegExp(
                r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                caseSensitive: false,
              ).hasMatch(part),
        )) {
      throw StateError('Unsafe runtime archive path: $name');
    }
  }

  static Future<void> _validateArchive(
    File file,
    _Installation operation,
  ) async {
    final InputFileStream input = InputFileStream(file.path);
    try {
      // InputFileStream retains only ZIP metadata and buffered file slices,
      // including for the multi-GB torch wheel. Never request entry content here.
      final ZipDirectory directory = ZipDirectory.read(input);
      for (final ZipFileHeader entry in directory.fileHeaders) {
        operation.check();
        _safeRelativePath(entry.filename);
        if (((entry.externalFileAttributes ?? 0) >> 16) & 0xF000 == 0xA000) {
          throw StateError(
            'Runtime archive links are not allowed: ${entry.filename}',
          );
        }
      }
    } finally {
      await input.close();
    }
  }

  static Map<String, Object?> _assetIdentity(
    MangaOcrModelFile item,
    FileStat stat,
  ) => <String, Object?>{
    'size': stat.size,
    'modified': stat.modified.microsecondsSinceEpoch,
    'sha256': item.sha256,
  };

  static bool _sameIdentity(
    Map<String, Object?> identity,
    Map<Object?, Object?> previous,
  ) =>
      identity['size'] == previous['size'] &&
      identity['modified'] == previous['modified'] &&
      identity['sha256'] == previous['sha256'];

  static Future<bool> _matchesAsset(
    File file,
    MangaOcrModelFile item,
    Object? previous,
  ) async {
    if (previous is! Map ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    final FileStat stat = await file.stat();
    return stat.size == item.expectedBytes &&
        _sameIdentity(_assetIdentity(item, stat), previous);
  }

  Future<void> _writeReceipt(
    Directory runtime,
    Map<String, Object?> assets,
    _Installation operation,
  ) async {
    final File pending = File(p.join(runtime.path, '.ready.pending.json'));
    final File marker = File(p.join(runtime.path, _markerName));
    bool replaced = false;
    try {
      operation.check();
      await pending.writeAsString(
        jsonEncode(<String, Object?>{
          'fingerprint': _fingerprint,
          'environmentFingerprint': _environmentFingerprint,
          'assets': assets,
        }),
        flush: true,
      );
      operation.check();
      await pending.rename(marker.path);
      replaced = true;
      operation.check();
    } finally {
      if (await pending.exists()) {
        await pending.delete();
      }
      if (replaced && operation.isCancelled && await marker.exists()) {
        await marker.delete();
      }
    }
    operation.check();
    operation.committed = true;
  }

  static Future<void> _extractZip(
    File file,
    Directory target,
    _Installation operation,
  ) async {
    final InputFileStream input = InputFileStream(file.path);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      int total = 0;
      for (final ArchiveFile entry in archive) {
        operation.check();
        _safeRelativePath(entry.name);
        total += entry.size;
        // Only embedded Python and bootstrap pip are extracted by Dart. Wheels
        // containing large native libraries are streamed/unpacked by pip.
        if (entry.isSymbolicLink ||
            entry.size > 64 * 1024 * 1024 ||
            total > 256 * 1024 * 1024) {
          throw StateError(
            'Invalid embedded Python/pip archive entry: ${entry.name}',
          );
        }
        final String destination = p.normalize(p.join(target.path, entry.name));
        if (!p.isWithin(target.path, destination)) {
          throw StateError(
            'Runtime archive escapes extraction directory: ${entry.name}',
          );
        }
        if (!entry.isFile) {
          await Directory(destination).create(recursive: true);
          continue;
        }
        await File(destination).parent.create(recursive: true);
        final OutputFileStream output = OutputFileStream(destination);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      }
    } finally {
      await input.close();
    }
  }

  static void _event(
    StreamController<MangaOcrDownloadEvent> controller, {
    String name = 'runtime',
    bool done = false,
  }) {
    controller.add(
      MangaOcrDownloadEvent(
        fileName: name,
        receivedBytes: 0,
        totalBytes: 0,
        installing: true,
        done: done,
      ),
    );
  }

  /// The install/check/import runs in this process, not an untracked child.
  /// The native process handle survives PID reuse and observes crashes/forced
  /// app exit too. No stdin/CRT read is started during NumPy DLL loading.
  static const String _installerBootstrap = r'''
import ctypes
import json
import os
import runpy
import sys
import threading
import time

parent = int(sys.argv[1])
arguments = json.loads(sys.argv[2])
if os.name == "nt":
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.WaitForSingleObject.restype = ctypes.c_uint32
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x00100000, False, parent)
    if not handle:
        os._exit(125)
    def watch_parent():
        kernel.WaitForSingleObject(handle, 0xFFFFFFFF)
        kernel.CloseHandle(handle)
        os._exit(125)
else:
    def watch_parent():
        while os.getppid() == parent:
            time.sleep(0.1)
        os._exit(125)
threading.Thread(target=watch_parent, daemon=True).start()
if arguments and arguments[0] == "-I":
    arguments = arguments[1:]
if arguments[0] == "-m":
    sys.argv = arguments[1:]
    runpy.run_module(arguments[1], run_name="__main__", alter_sys=True)
elif arguments[0] == "-c":
    sys.argv = ["-c"]
    exec(compile(arguments[1], "<manga-ocr-install>", "exec"), {"__name__": "__main__"})
else:
    raise RuntimeError("Unsupported manga-ocr installation command")
''';
}

class _Installation {
  final Completer<void> cancelled = Completer<void>();
  final Completer<void> finished = Completer<void>();
  Process? process;
  bool committed = false;
  bool get isCancelled => cancelled.isCompleted;

  void check() {
    if (isCancelled) {
      throw const _InstallationCancelled();
    }
  }

  Future<void> cancel() async {
    if (finished.isCompleted) {
      return;
    }
    // Once the verified installation is committed, only lock release remains;
    // cancellation still waits for cleanup but does not undo completed work.
    if (!committed) {
      if (!cancelled.isCompleted) {
        cancelled.complete();
      }
      process?.kill(ProcessSignal.sigkill);
    }
    await finished.future;
  }
}

class _InstallationCancelled implements Exception {
  const _InstallationCancelled();
}
