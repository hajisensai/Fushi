import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

const Duration kAidokuRuntimeTimeout = Duration(seconds: 90);
const int kAidokuRuntimeOutputLimit = 32 * 1024 * 1024;

/// 运行时错误码：源站返回了 Cloudflare 挑战页。[AidokuRuntimeException.challengeUrl]
/// 给出被拦的那一页，UI 可以在 WebView 里打开它完成验证后重试（BUG-1876）。
const String kAidokuCloudflareChallengeCode = 'CLOUDFLARE_CHALLENGE';

class AidokuRuntimeException implements Exception {
  const AidokuRuntimeException(
    this.code,
    this.message, {
    this.cause,
    this.challengeUrl,
  });

  final String code;
  final String message;
  final Object? cause;

  /// 仅 [kAidokuCloudflareChallengeCode]：被 Cloudflare 拦下的请求 URL。
  final Uri? challengeUrl;

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

  Map<String, Object?> get sourceInfo =>
      (manifest['info'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
      const <String, Object?>{};

  List<AidokuListing> get listings =>
      (manifest['listings'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> value) =>
                AidokuListing.fromJson(value.cast<String, Object?>()),
          )
          .where((AidokuListing listing) => listing.id.isNotEmpty)
          .toList(growable: false);
}

class AidokuListing {
  const AidokuListing({
    required this.id,
    required this.name,
    this.kind = 'Default',
  });

  factory AidokuListing.fromJson(Map<String, Object?> json) => AidokuListing(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'Default',
      );

  final String id;
  final String name;
  final String kind;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'kind': kind,
      };
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

  Future<Map<String, Object?>> browse(
    String packagePath,
    AidokuListing listing, {
    int page = 1,
  });

  Future<List<Object?>> getPages(
    String packagePath,
    Map<String, Object?> manga,
    Map<String, Object?> chapter,
  );
}

abstract final class AidokuRuntimeFactory {
  static bool get isSupported => Platform.isMacOS || Platform.isIOS;

  static AidokuRuntime create() {
    if (Platform.isMacOS) return DesktopAidokuRuntime();
    if (Platform.isIOS) return IosAidokuRuntime(jar: AidokuCookieJar.shared);
    throw const AidokuRuntimeException(
      'UNSUPPORTED_PLATFORM',
      'Aidoku extensions are currently supported on macOS and iOS',
    );
  }
}

class IosAidokuRuntime implements AidokuRuntime {
  IosAidokuRuntime({
    this.timeout = kAidokuRuntimeTimeout,
    this.jar,
    AidokuCloudflareResolver? resolver,
  }) : _resolver = resolver;

  final Duration timeout;

  /// 随每次调用送进 host 的 cookie / UA；null = 不带（旧行为，测试用）。
  final AidokuCookieJar? jar;

  /// 显式注入的解题器；未注入时每次调用读 [AidokuCloudflareGate.resolver]，
  /// 这样 UI 装好 resolver 前创建的 runtime 也能用上它。
  final AidokuCloudflareResolver? _resolver;

  AidokuCloudflareResolver? get resolver =>
      _resolver ?? AidokuCloudflareGate.resolver;

  @override
  Future<AidokuPackageInspection> inspect(String packagePath) async =>
      AidokuPackageInspection.fromJson(
        await _invoke(<String, Object?>{
          'command': 'inspect',
          'packagePath': packagePath,
        }),
      );

  @override
  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  }) async {
    _validatePage(page);
    final Map<String, Object?> response = await _invoke(<String, Object?>{
      'command': 'search',
      'packagePath': packagePath,
      'query': query ?? '',
      'page': page,
    });
    return _object(response['result'], 'search result');
  }

  @override
  Future<Map<String, Object?>> browse(
    String packagePath,
    AidokuListing listing, {
    int page = 1,
  }) async {
    _validatePage(page);
    final Map<String, Object?> response = await _invoke(<String, Object?>{
      'command': 'list',
      'packagePath': packagePath,
      'listing': listing.toJson(),
      'page': page,
    });
    return _object(response['result'], 'listing result');
  }

  @override
  Future<Map<String, Object?>> getDetails(
    String packagePath,
    Map<String, Object?> manga,
  ) async {
    final Map<String, Object?> response = await _invoke(<String, Object?>{
      'command': 'details',
      'packagePath': packagePath,
      'manga': manga,
    });
    return _object(response['result'], 'manga details');
  }

  @override
  Future<List<Object?>> getPages(
    String packagePath,
    Map<String, Object?> manga,
    Map<String, Object?> chapter,
  ) async {
    final Map<String, Object?> response = await _invoke(<String, Object?>{
      'command': 'pages',
      'packagePath': packagePath,
      'manga': manga,
      'chapter': chapter,
    });
    final Object? result = response['result'];
    if (result is! List<Object?>) {
      throw AidokuRuntimeException(
        'INVALID_RESPONSE',
        'Aidoku runtime returned ${result.runtimeType}, expected a page list',
      );
    }
    return result;
  }

  /// 一次调用 = 「带当前 cookie 调 host → 若被 Cloudflare 拦下且能解题 → 解完
  /// 带新 cookie **重试一次**」。只重试一次：第二次仍被拦说明解题没拿到有效
  /// `cf_clearance`（UA 不一致 / 用户没过验证），再循环只会无限弹 WebView。
  Future<Map<String, Object?>> _invoke(Map<String, Object?> request) async {
    final AidokuCookieJar? jar = this.jar;
    if (jar != null) await jar.ensureLoaded();
    try {
      return await _invokeOnce(request, jar);
    } on AidokuRuntimeException catch (error) {
      final Uri? challengeUrl = error.challengeUrl;
      final AidokuCloudflareResolver? resolver = this.resolver;
      if (challengeUrl == null || resolver == null) rethrow;
      if (!await resolver(challengeUrl)) rethrow;
      return _invokeOnce(request, jar);
    }
  }

  Future<Map<String, Object?>> _invokeOnce(
    Map<String, Object?> request,
    AidokuCookieJar? jar,
  ) async {
    final Map<String, Object?> payload = <String, Object?>{
      ...request,
      if (jar != null) 'network': jar.networkPayload(),
    };
    try {
      final Object? response = await FushiChannels.aidokuRuntime
          .invokeMethod<Object?>('invoke', payload)
          .timeout(timeout);
      return _object(response, 'response');
    } on TimeoutException catch (error) {
      throw AidokuRuntimeException(
        'TIMEOUT',
        'Aidoku runtime exceeded ${timeout.inSeconds} seconds',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw AidokuRuntimeException(
        error.code,
        error.message ?? 'Aidoku runtime failed',
        cause: error,
        challengeUrl: error.code == kAidokuCloudflareChallengeCode
            ? _challengeUrl(error.details)
            : null,
      );
    } on MissingPluginException catch (error) {
      throw AidokuRuntimeException(
        'RUNTIME_MISSING',
        'The embedded Aidoku runtime is unavailable in this iOS build',
        cause: error,
      );
    }
  }

  /// Swift 桥把 host 的错误信封整个塞进 `FlutterError.details`；只认 https 的
  /// `challengeUrl`——解题 WebView 只该打开源站页面。
  static Uri? _challengeUrl(Object? details) {
    if (details is! Map<Object?, Object?>) return null;
    final Uri? url = Uri.tryParse(details['challengeUrl']?.toString() ?? '');
    if (url == null || !url.isScheme('https') || url.host.isEmpty) return null;
    return url;
  }

  static void _validatePage(int page) {
    if (page < 1) {
      throw const AidokuRuntimeException(
        'INVALID_PAGE',
        'Aidoku page must be at least 1',
      );
    }
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
  Future<Map<String, Object?>> browse(
    String packagePath,
    AidokuListing listing, {
    int page = 1,
  }) async {
    if (page < 1) {
      throw const AidokuRuntimeException(
        'INVALID_PAGE',
        'Aidoku listing page must be at least 1',
      );
    }
    final Map<String, Object?> response = await _invoke(<String>[
      'list',
      packagePath,
      jsonEncode(listing.toJson()),
      '$page',
    ]);
    return _object(response['result'], 'listing result');
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
