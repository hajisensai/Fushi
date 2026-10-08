import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/utils/misc/child_process_containment.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:path/path.dart' as p;

/// PowerShell single-quoted literal: the only escape inside `'…'` is `''`.
String _psLiteral(String value) => "'${value.replaceAll("'", "''")}'";

/// Inline `-Command` text that runs the bundled installer script with typed
/// parameters. Execution policy only governs loading `.ps1` files, so running
/// the script text as a scriptblock needs no execution-policy bypass flag — a
/// high-weight AV/EDR signal that shipped code must never pass (see
/// test/tools/no_powershell_execution_policy_guard_test.dart). Every value is a
/// literal, never interpolated PowerShell.
String bdjInstallerCommand({
  required String script,
  required String action,
  required String bundle,
  required String startSignal,
  String? archive,
  String? stagingDirectory,
}) {
  final StringBuffer command =
      StringBuffer(
          '& ([scriptblock]::Create([IO.File]::ReadAllText(${_psLiteral(script)})))',
        )
        ..write(' -Action ${_psLiteral(action)}')
        ..write(' -Bundle ${_psLiteral(bundle)}')
        ..write(' -StartSignal ${_psLiteral(startSignal)}');
  if (archive != null) command.write(' -Archive ${_psLiteral(archive)}');
  if (stagingDirectory != null) {
    command.write(' -StagingDirectory ${_psLiteral(stagingDirectory)}');
  }
  return command.toString();
}

/// Optional private Java runtime for BD-J discs. HDMV never needs this download.
/// Network access uses the app proxy; the bundled installer only sees a verified
/// local archive and never modifies system JAVA_HOME or other applications.
class BlurayJavaRuntimeManager {
  BlurayJavaRuntimeManager({String? bundleDirectory})
    : bundleDirectory =
          bundleDirectory ??
          p.join(p.dirname(Platform.resolvedExecutable), 'bluray', 'bdj');

  final String bundleDirectory;
  HttpClient? _client;
  Process? _process;
  ChildProcessContainment? _containment;
  Future<void>? _termination;
  bool _processTreeReaped = true;
  bool _cancelled = false;
  bool _installing = false;

  String get _script => p.join(bundleDirectory, 'bdj_runtime.ps1');

  bool get canInstall => Platform.isWindows && File(_script).existsSync();

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    final ChildProcessContainment? containment = _containment;
    if (containment != null) {
      _termination ??= containment.terminateAndWait();
      // The installer awaits this same future before removing its own files.
      unawaited(_termination!.catchError((Object _) {}));
    } else {
      _process?.kill();
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw const BlurayJavaRuntimeException('cancelled');
  }

  Future<String?> probeJavaHome() async {
    if (!canInstall) return null;
    try {
      return await _runInstaller('Probe');
    } on BlurayJavaRuntimeException {
      return null;
    } on ProcessException {
      return null;
    }
  }

  Future<String> install({
    void Function(int received, int? total)? onProgress,
  }) async {
    if (!canInstall) {
      throw const BlurayJavaRuntimeException('installer-unavailable');
    }
    if (_installing) {
      throw const BlurayJavaRuntimeException('install-in-progress');
    }
    _installing = true;
    _cancelled = false;
    Directory? temp;
    Directory? staging;
    try {
      final String? existing = await probeJavaHome();
      _checkCancelled();
      if (existing != null) return existing;
      final Object? decoded = jsonDecode(
        await File(p.join(bundleDirectory, 'manifest.json')).readAsString(),
      );
      final BlurayJavaArchive archive = BlurayJavaArchive.fromManifest(decoded);
      final String? appData = Platform.environment['LOCALAPPDATA'];
      if (appData == null || !p.isAbsolute(appData)) {
        throw const BlurayJavaRuntimeException(
          'component-directory-unavailable',
        );
      }
      final String root = p.join(appData, archive.componentRootSuffix);
      final Random random = Random.secure();
      final String operationId = List<String>.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final String stageName = '.bdj-install-$operationId';
      staging = Directory(p.join(p.dirname(root), stageName));
      temp = await Directory.systemTemp.createTemp('fushi-bdj-download-');
      final File file = File(p.join(temp.path, 'runtime.zip'));
      await _download(archive.url, file, onProgress);
      _checkCancelled();
      final Digest hash = await sha256.bind(file.openRead()).first;
      if (hash.toString() != archive.sha256) {
        throw const BlurayJavaRuntimeException('archive-checksum-mismatch');
      }
      _checkCancelled();
      return await _runInstaller(
        'Install',
        archive: file.path,
        stagingDirectory: staging.path,
      );
    } finally {
      _client?.close(force: true);
      _client = null;
      _installing = false;
      // The child has exited before this point, including cancellation. Only
      // reclaim this operation's UUID stage, never another install or final Root.
      // Only our unique download directory; the installer owns its staging and
      // final directories. Never erase an existing runtime on failure/cancel.
      await Future.wait(<Future<void>>[
        if (staging != null && _processTreeReaped)
          _deleteOwnedDirectory(staging),
        if (temp != null) _deleteOwnedDirectory(temp),
      ]);
    }
  }

  Future<void> _download(
    Uri uri,
    File destination,
    void Function(int received, int? total)? progress,
  ) async {
    final HttpClient client = createAppHttpClient();
    _client = client;
    final HttpClientRequest request = await client.getUrl(uri);
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 45),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw BlurayJavaRuntimeException('download-http-${response.statusCode}');
    }
    final int? total = response.contentLength < 0
        ? null
        : response.contentLength;
    final IOSink sink = destination.openWrite();
    int received = 0;
    try {
      await for (final List<int> bytes in response.timeout(
        const Duration(seconds: 45),
      )) {
        _checkCancelled();
        received += bytes.length;
        if (received > 256 * 1024 * 1024) {
          throw const BlurayJavaRuntimeException('archive-too-large');
        }
        sink.add(bytes);
        progress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<String> _runInstaller(
    String action, {
    String? archive,
    String? stagingDirectory,
  }) async {
    _checkCancelled();
    final Directory handshake = await Directory.systemTemp.createTemp(
      'fushi-bdj-owner-',
    );
    final File signal = File(p.join(handshake.path, 'ready'));
    final ChildProcessContainment containment =
        ChildProcessContainment.platform();
    Process? process;
    Future<String>? output;
    Future<String>? errors;
    try {
      _checkCancelled();
      process = await HelperProcessRegistry.instance
          .start('powershell.exe', <String>[
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            bdjInstallerCommand(
              script: _script,
              action: action,
              bundle: bundleDirectory,
              startSignal: signal.path,
              archive: archive,
              stagingDirectory: stagingDirectory,
            ),
          ]);
      _process = process;
      _processTreeReaped = false;
      output = process.stdout.transform(utf8.decoder).join();
      errors = process.stderr.transform(utf8.decoder).join();
      containment.attach(process.pid);
      _containment = containment;
      _checkCancelled();
      // The script cannot spawn Java until its parent is in our private Job.
      await signal.writeAsString('ready', flush: true);
      final int code = await process.exitCode.timeout(
        Duration(minutes: action == 'Install' ? 10 : 1),
      );
      final String stdout = await output;
      await errors;
      _checkCancelled();
      if (code != 0) {
        throw BlurayJavaRuntimeException('component-$action-failed');
      }
      final Object? result = jsonDecode(stdout);
      if (result is! Map<String, dynamic> ||
          result['ready'] != true ||
          result['javaHome'] is! String) {
        throw const BlurayJavaRuntimeException('invalid-component-result');
      }
      final String home = result['javaHome'] as String;
      if (!p.isAbsolute(home) ||
          !await File(p.join(home, 'bin', 'server', 'jvm.dll')).exists()) {
        throw const BlurayJavaRuntimeException('invalid-java-home');
      }
      return home;
    } on TimeoutException {
      throw const BlurayJavaRuntimeException('component-timeout');
    } finally {
      try {
        await (_termination ?? containment.terminateAndWait());
        _processTreeReaped = true;
      } finally {
        // Even if accounting/termination failed, do not leak the owning handle.
        // Failure still leaves _processTreeReaped false and preserves staging.
        containment.close();
        if (process != null) {
          // An attach failure is also safe: the startup gate prevented Java.
          process.kill();
          await process.exitCode.timeout(
            const Duration(seconds: 3),
            onTimeout: () => -1,
          );
        }
        try {
          await Future.wait(<Future<String>>[
            if (output != null)
              output
                  .timeout(const Duration(seconds: 3), onTimeout: () => '')
                  .catchError((Object _) => ''),
            if (errors != null)
              errors
                  .timeout(const Duration(seconds: 3), onTimeout: () => '')
                  .catchError((Object _) => ''),
          ]);
        } finally {
          if (identical(_containment, containment)) {
            _containment = null;
            _termination = null;
          }
          if (identical(_process, process)) _process = null;
          await _deleteOwnedDirectory(handshake);
        }
      }
    }
  }

  Future<void> _deleteOwnedDirectory(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await directory.delete(recursive: true);
    }
  }
}

class BlurayJavaRuntimeException implements Exception {
  const BlurayJavaRuntimeException(this.code);
  final String code;
  @override
  String toString() => 'BD-J: $code';
}

class BlurayJavaArchive {
  const BlurayJavaArchive(this.url, this.sha256, this.componentRootSuffix);
  final Uri url;
  final String sha256;
  final String componentRootSuffix;

  factory BlurayJavaArchive.fromManifest(Object? manifest) {
    if (manifest is! Map<String, dynamic> || manifest['schema'] != 1) {
      throw const BlurayJavaRuntimeException('invalid-component-manifest');
    }
    final Object? runtime = manifest['runtime'];
    if (runtime is! Map<String, dynamic> ||
        runtime['url'] is! String ||
        runtime['sha256'] is! String ||
        runtime['componentRootSuffix'] is! String) {
      throw const BlurayJavaRuntimeException('invalid-component-manifest');
    }
    final Uri? uri = Uri.tryParse(runtime['url'] as String);
    final String hash = (runtime['sha256'] as String).toLowerCase();
    final String suffix = runtime['componentRootSuffix'] as String;
    final List<String> segments = suffix.replaceAll('\\', '/').split('/');
    if (segments.length != 4 ||
        segments[0] != 'Fushi' ||
        segments[1] != 'components' ||
        segments[2] != 'bdj' ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(segments[3])) {
      throw const BlurayJavaRuntimeException('invalid-component-directory');
    }
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const BlurayJavaRuntimeException('invalid-component-manifest');
    }
    return BlurayJavaArchive(uri, hash, p.joinAll(segments));
  }
}
