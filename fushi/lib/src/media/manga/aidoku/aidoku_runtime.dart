import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const Duration kAidokuRuntimeTimeout = Duration(seconds: 90);
const int kAidokuRuntimeOutputLimit = 32 * 1024 * 1024;

class AidokuRuntimeException implements Exception {
  const AidokuRuntimeException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'AidokuRuntimeException($code): $message';
}

class AidokuPackageInspection {
  const AidokuPackageInspection({
    required this.manifest,
    required this.imports,
    required this.exports,
    required this.requiresWebView,
  });

  factory AidokuPackageInspection.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> runtime =
        (json['runtime'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return AidokuPackageInspection(
      manifest: (json['manifest'] as Map<Object?, Object?>?)
              ?.cast<String, Object?>() ??
          const <String, Object?>{},
      imports: (runtime['imports'] as List<Object?>? ?? const <Object?>[])
          .map((Object? value) => value.toString())
          .toList(growable: false),
      exports: (runtime['exports'] as List<Object?>? ?? const <Object?>[])
          .map((Object? value) => value.toString())
          .toList(growable: false),
      requiresWebView: runtime['requiresWebView'] == true,
    );
  }

  final Map<String, Object?> manifest;
  final List<String> imports;
  final List<String> exports;
  final bool requiresWebView;
}

abstract interface class AidokuRuntime {
  Future<AidokuPackageInspection> inspect(String packagePath);

  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  });

  Future<Map<String, Object?>> getDetails(
    String packagePath,
    Map<String, Object?> manga,
  );

  Future<List<Object?>> getPages(
    String packagePath,
    Map<String, Object?> manga,
    Map<String, Object?> chapter,
  );
}

class DesktopAidokuRuntime implements AidokuRuntime {
  DesktopAidokuRuntime({
    File? executable,
    this.timeout = kAidokuRuntimeTimeout,
  }) : executable = executable ?? _bundledExecutable();

  final File executable;
  final Duration timeout;

  static bool get isSupported => Platform.isMacOS;

  static File _bundledExecutable() {
    if (!Platform.isMacOS) {
      throw const AidokuRuntimeException(
        'UNSUPPORTED_PLATFORM',
        'The Aidoku runtime is currently bundled for macOS only',
      );
    }
    final Directory contents = File(Platform.resolvedExecutable).parent.parent;
    return File(p.join(
      contents.path,
      'Resources',
      'aidoku_runtime',
      'fushi-aidoku-runtime',
    ));
  }

  @override
  Future<AidokuPackageInspection> inspect(String packagePath) async =>
      AidokuPackageInspection.fromJson(
        await _invoke(<String>['inspect', packagePath]),
      );

  @override
  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  }) async {
    if (page < 1) {
      throw const AidokuRuntimeException(
        'INVALID_PAGE',
        'Aidoku search page must be at least 1',
      );
    }
    final Map<String, Object?> response = await _invoke(<String>[
      'search',
      packagePath,
      query ?? '',
      '$page',
    ]);
    return _object(response['result'], 'search result');
  }

  @override
  Future<Map<String, Object?>> getDetails(
    String packagePath,
    Map<String, Object?> manga,
  ) async {
    final Map<String, Object?> response = await _invoke(<String>[
      'details',
      packagePath,
      jsonEncode(manga),
    ]);
    return _object(response['result'], 'manga details');
  }

  @override
  Future<List<Object?>> getPages(
    String packagePath,
    Map<String, Object?> manga,
    Map<String, Object?> chapter,
  ) async {
    final Map<String, Object?> response = await _invoke(<String>[
      'pages',
      packagePath,
      jsonEncode(manga),
      jsonEncode(chapter),
    ]);
    final Object? result = response['result'];
    if (result is! List<Object?>) {
      throw AidokuRuntimeException(
        'INVALID_RESPONSE',
        'Aidoku runtime returned ${result.runtimeType}, expected a page list',
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _invoke(List<String> arguments) async {
    if (!executable.existsSync()) {
      throw AidokuRuntimeException(
        'RUNTIME_MISSING',
        'Bundled Aidoku runtime is missing from ${executable.path}',
      );
    }
    final Process process;
    try {
      process = await Process.start(
        executable.path,
        arguments,
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
    } on Object catch (error) {
      throw AidokuRuntimeException(
        'START_FAILED',
        'Failed to start the Aidoku runtime',
        cause: error,
      );
    }

    final Future<Uint8List> stdout = _readLimited(process.stdout);
    final Future<Uint8List> stderr = _readLimited(process.stderr);
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException catch (error) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The retained process identity has already been killed. Do not scan
        // or terminate unrelated processes as a fallback.
      }
      throw AidokuRuntimeException(
        'TIMEOUT',
        'Aidoku runtime exceeded ${timeout.inSeconds} seconds',
        cause: error,
      );
    }

    final String output = utf8.decode(await stdout, allowMalformed: true);
    final String errorOutput = utf8.decode(await stderr, allowMalformed: true);
    if (exitCode != 0) {
      throw AidokuRuntimeException(
        'EXIT_$exitCode',
        _errorMessage(errorOutput),
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(output);
    } on FormatException catch (error) {
      throw AidokuRuntimeException(
        'INVALID_JSON',
        'Aidoku runtime returned invalid JSON',
        cause: error,
      );
    }
    return _object(decoded, 'response');
  }

  static Future<Uint8List> _readLimited(Stream<List<int>> stream) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in stream) {
      length += chunk.length;
      if (length > kAidokuRuntimeOutputLimit) {
        throw const AidokuRuntimeException(
          'OUTPUT_TOO_LARGE',
          'Aidoku runtime output exceeded the 32 MiB limit',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Map<String, Object?> _object(Object? value, String label) {
    if (value is! Map<Object?, Object?>) {
      throw AidokuRuntimeException(
        'INVALID_RESPONSE',
        'Aidoku runtime $label was ${value.runtimeType}, expected an object',
      );
    }
    return value.cast<String, Object?>();
  }

  static String _errorMessage(String stderr) {
    try {
      final Object? decoded = jsonDecode(stderr);
      if (decoded is Map<Object?, Object?>) {
        return decoded['error']?.toString() ?? 'Aidoku runtime failed';
      }
    } on FormatException {
      // Fall through to the bounded raw error below.
    }
    final String trimmed = stderr.trim();
    return trimmed.isEmpty ? 'Aidoku runtime failed' : trimmed;
  }
}
