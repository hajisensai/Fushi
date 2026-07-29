import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_child_process_containment.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';

class DesktopMihonRuntime extends MihonBridgeRuntime
    implements CancellableMihonRuntime {
  DesktopMihonRuntime({
    required this.dataDirectory,
    Directory? resourceDirectory,
    http.Client? httpClient,
  })  : resourceDirectory = resourceDirectory ?? _defaultResourceDirectory(),
        _processContainment = MihonChildProcessContainment.platform(),
        _http = httpClient ?? http.Client();

  final Directory dataDirectory;
  final Directory resourceDirectory;
  final http.Client _http;
  final MihonChildProcessContainment _processContainment;

  Process? _process;
  int? _port;
  String? _token;
  Future<void>? _starting;
  bool _disposed = false;
  bool _restartUsed = false;
  final Map<String, _CachedApk> _apkCache = <String, _CachedApk>{};
  final Map<String, http.Client> _imageClients = <String, http.Client>{};
  int _imageRequestSequence = 0;

  @visibleForTesting
  int? get processId => _process?.pid;

  Uri _uri(String path) {
    final int? port = _port;
    if (port == null) {
      throw const MihonRuntimeException(
        'NOT_STARTED',
        'M-Extension-Server is not running',
      );
    }
    return Uri.parse('http://127.0.0.1:$port$path');
  }

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer $_token',
        // NanoHTTPD 2.3.1 falls back to US-ASCII when a request content type
        // omits its charset. Mihon manga URLs commonly contain CJK text, so
        // omitting this parameter corrupts those URLs into U+FFFD on the
        // bridge round trip and makes otherwise valid detail pages return 404.
        'Content-Type': 'application/json; charset=utf-8',
      };

  @override
  Future<MihonCapabilities> getCapabilities() async {
    await _ensureStarted();
    return _readCapabilities();
  }

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async {
    final Map<String, Object?> response = await _postObject(
      '/inspect',
      <String, Object?>{'data': await _apkBase64(apkPath)},
    );
    return MihonExtensionInspection.fromJson(response);
  }

  @override
  Future<String> installPrivateExtension(String apkPath) async => apkPath;

  @override
  Future<void> uninstallPrivateExtension(String packageName) async {
    await invalidateExtension(packageName);
  }

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments,
  ) async {
    final Map<String, Object?> payload = <String, Object?>{
      'data': await _apkBase64(extension.apkPath),
      'method': method,
      ...arguments,
    };
    return _postJson('/dalvik', payload);
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) =>
      fetchImageRequest(
        extension,
        source,
        page,
        requestId: 'direct-${_imageRequestSequence++}',
        preferences: preferences,
      );

  @override
  Future<Uint8List> fetchImageRequest(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    required String requestId,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    await _ensureStarted();
    final Uri requested = Uri.parse(page.resolvedUrl);
    final int? port = _port;
    if (requested.scheme != 'http' ||
        requested.host != '127.0.0.1' ||
        requested.port != port ||
        !requested.path.startsWith('/image/')) {
      throw const MihonRuntimeException(
        'INVALID_IMAGE_URL',
        'Mihon bridge returned an image URL outside its authenticated proxy',
      );
    }
    final http.Client imageClient = http.Client();
    final http.Client? replaced = _imageClients[requestId];
    replaced?.close();
    _imageClients[requestId] = imageClient;
    try {
      final http.Response response = await imageClient
          .get(requested, headers: _headers)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != HttpStatus.ok) {
        throw MihonRuntimeException(
          'IMAGE_HTTP_${response.statusCode}',
          'Mihon image proxy request failed',
        );
      }
      if (response.bodyBytes.isEmpty) {
        throw const MihonRuntimeException(
          'EMPTY_IMAGE',
          'Mihon source returned an empty image',
        );
      }
      return response.bodyBytes;
    } finally {
      if (identical(_imageClients[requestId], imageClient)) {
        _imageClients.remove(requestId);
      }
      imageClient.close();
    }
  }

  @override
  Future<void> cancelImageRequests(Iterable<String> requestIds) async {
    for (final String requestId in requestIds) {
      _imageClients.remove(requestId)?.close();
    }
  }

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    await _ensureStarted();
    final http.Response response = await _http
        .post(
          _uri('/source-image'),
          headers: _headers,
          body: jsonEncode(<String, Object?>{
            'data': await _apkBase64(extension.apkPath),
            'sourceId': source.id,
            'url': url,
            'preferences': mihonBridgePreferences(source, preferences),
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != HttpStatus.ok || response.bodyBytes.isEmpty) {
      throw MihonRuntimeException(
        'IMAGE_HTTP_${response.statusCode}',
        'Mihon source image request failed',
      );
    }
    return response.bodyBytes;
  }

  @override
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) async {
    await _postObject(
      '/source-data/clear',
      <String, Object?>{
        'data': await _apkBase64(extension.apkPath),
        'sourceId': source.id,
      },
    );
    await _restart();
  }

  @override
  Future<void> invalidateExtension(String packageName) async {
    _apkCache.removeWhere(
      (String path, _CachedApk value) =>
          p.basenameWithoutExtension(path) == packageName,
    );
    await _restart();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      if (_process != null && _port != null) {
        await _http
            .post(_uri('/stop'), headers: _headers)
            .timeout(const Duration(milliseconds: 600));
      }
    } catch (_) {
      // Process identity is retained below; a failed graceful stop never causes
      // a port/PID scan or termination of unrelated processes.
    }
    try {
      final Process? process = _process;
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(milliseconds: 700));
        } on TimeoutException {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            // Closing the Windows Job Object below is the final exact-process
            // backstop. The app-level exit barrier must remain bounded.
          }
        }
      }
    } finally {
      _processContainment.close();
    }
    _process = null;
    _port = null;
    _token = null;
    _apkCache.clear();
    for (final http.Client client in _imageClients.values) {
      client.close();
    }
    _imageClients.clear();
    _http.close();
  }

  Future<void> _ensureStarted() async {
    if (_disposed) {
      throw const MihonRuntimeException(
        'DISPOSED',
        'Mihon runtime has been disposed',
      );
    }
    if (_process != null && _port != null) return;
    final Future<void>? current = _starting;
    if (current != null) return current;
    final Future<void> start = _start();
    _starting = start;
    try {
      await start;
    } finally {
      if (identical(_starting, start)) _starting = null;
    }
  }

  Future<void> _start() async {
    final File java = File(_javaExecutablePath());
    final File server = File(p.join(
      resourceDirectory.path,
      'm-extension-server.jar',
    ));
    if (!java.existsSync() || !server.existsSync()) {
      throw MihonRuntimeException(
        'RUNTIME_MISSING',
        'Bundled Java/M-Extension-Server is missing from '
            '${resourceDirectory.path}',
      );
    }
    await dataDirectory.create(recursive: true);
    final Directory preferences =
        Directory(p.join(dataDirectory.path, 'preferences'));
    await preferences.create(recursive: true);
    final ServerSocket socket =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int port = socket.port;
    await socket.close();
    final Random random = Random.secure();
    final String token = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final Process process = await Process.start(
      java.path,
      <String>[
        '-Xmx512m',
        '-Djava.awt.headless=true',
        '-Djava.util.prefs.userRoot=${preferences.path}',
        '-jar',
        server.path,
        '$port',
        dataDirectory.path,
      ],
      environment: <String, String>{'HIBIKI_MIHON_TOKEN': token},
      mode: ProcessStartMode.normal,
    );
    if (_disposed) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Process identity is exact; the runtime is already shutting down.
      }
      throw const MihonRuntimeException(
        'DISPOSED',
        'Mihon runtime was disposed while the sidecar was starting',
      );
    }
    try {
      _processContainment.attach(process.pid);
    } catch (error) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // This is still the exact retained child. Startup fails rather than
        // allowing an uncontained JVM to outlive Hibiki.
      }
      throw MihonRuntimeException(
        'PROCESS_CONTAINMENT_FAILED',
        'Failed to contain the Mihon sidecar process',
        cause: error,
      );
    }
    _process = process;
    _port = port;
    _token = token;
    process.stdout.listen((List<int> _) {});
    process.stderr.listen((List<int> _) {});
    unawaited(process.exitCode.then((int _) {
      if (identical(_process, process)) {
        _process = null;
        _port = null;
        _token = null;
      }
    }));

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final MihonCapabilities capabilities = await _readCapabilities();
        if (!capabilities.isUsable) {
          throw const MihonRuntimeException(
            'INCOMPATIBLE_BRIDGE',
            'Bundled M-Extension-Server lacks required Mihon capabilities',
          );
        }
        return;
      } catch (error) {
        lastError = error;
        if (await _hasExited(process)) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    process.kill();
    _process = null;
    _port = null;
    _token = null;
    throw MihonRuntimeException(
      'START_TIMEOUT',
      'M-Extension-Server did not become ready',
      cause: lastError,
    );
  }

  Future<MihonCapabilities> _readCapabilities() async {
    final http.Response response = await _http
        .get(_uri('/capabilities'), headers: _headers)
        .timeout(const Duration(seconds: 2));
    if (response.statusCode != HttpStatus.ok) {
      throw MihonRuntimeException(
        'CAPABILITIES_HTTP_${response.statusCode}',
        'M-Extension-Server capabilities request failed',
      );
    }
    return MihonCapabilities.fromJson(
      (jsonDecode(response.body) as Map<Object?, Object?>)
          .cast<String, Object?>(),
    );
  }

  Future<Map<String, Object?>> _postObject(
    String path,
    Map<String, Object?> body,
  ) async {
    final Object? response = await _postJson(path, body);
    if (response is! Map<Object?, Object?>) {
      throw MihonRuntimeException(
        'INVALID_RESPONSE',
        '$path returned ${response.runtimeType}, expected an object',
      );
    }
    return response.cast<String, Object?>();
  }

  Future<Object?> _postJson(
    String path,
    Map<String, Object?> body, {
    bool allowRestart = true,
  }) async {
    await _ensureStarted();
    try {
      final http.Response response = await _http
          .post(_uri(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 45));
      final Object? decoded =
          response.body.isEmpty ? null : jsonDecode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final Map<Object?, Object?>? error =
            decoded is Map<Object?, Object?> ? decoded : null;
        throw MihonRuntimeException(
          'BRIDGE_HTTP_${response.statusCode}',
          error?['error']?.toString() ?? 'Mihon bridge request failed',
        );
      }
      return decoded;
    } on MihonRuntimeException {
      rethrow;
    } on Object catch (error) {
      if (allowRestart && !_restartUsed) {
        _restartUsed = true;
        await _restart();
        return _postJson(path, body, allowRestart: false);
      }
      throw MihonRuntimeException(
        'BRIDGE_IO',
        'M-Extension-Server request failed',
        cause: error,
      );
    } finally {
      if (!allowRestart) _restartUsed = false;
    }
  }

  Future<void> _restart() async {
    final Process? process = _process;
    _process = null;
    _port = null;
    _token = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The retained Process object is the only identity we ever terminate.
      }
    }
  }

  Future<String> _apkBase64(String apkPath) async {
    final File file = File(apkPath);
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw MihonRuntimeException(
        'APK_MISSING',
        'Extension APK does not exist: $apkPath',
      );
    }
    final _CachedApk? cached = _apkCache[apkPath];
    if (cached != null &&
        cached.modifiedAt == stat.modified &&
        cached.size == stat.size) {
      return cached.base64;
    }
    final String encoded = base64Encode(await file.readAsBytes());
    _apkCache[apkPath] = _CachedApk(
      modifiedAt: stat.modified,
      size: stat.size,
      base64: encoded,
    );
    return encoded;
  }

  String _javaExecutablePath() {
    final String runtimeName = Platform.isMacOS
        ? (Abi.current() == Abi.macosArm64
            ? 'runtime-macos-arm64'
            : 'runtime-macos-x64')
        : 'runtime';
    return p.join(
      resourceDirectory.path,
      runtimeName,
      'bin',
      Platform.isWindows ? 'java.exe' : 'java',
    );
  }

  static Future<bool> _hasExited(Process process) async {
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 1));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  static Directory _defaultResourceDirectory() {
    final Directory executable = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      return Directory(p.normalize(p.join(
        executable.path,
        '..',
        'Resources',
        'mihon_bridge',
      )));
    }
    return Directory(p.join(executable.path, 'mihon_bridge'));
  }
}

class _CachedApk {
  const _CachedApk({
    required this.modifiedAt,
    required this.size,
    required this.base64,
  });

  final DateTime modifiedAt;
  final int size;
  final String base64;
}
