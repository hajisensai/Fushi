import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final Directory repository = Directory('..');
  final String androidBuild = File(
    '${repository.path}/hibiki/android/app/build.gradle',
  ).readAsStringSync();
  final String wrapper = File(
    '${repository.path}/hibiki/android/gradle/wrapper/'
    'gradle-wrapper.properties',
  ).readAsStringSync();
  final String windowsBuild = File(
    '${repository.path}/tool/mihon/build_desktop_runtime.ps1',
  ).readAsStringSync();
  final String windowsDownloader = File(
    '${repository.path}/tool/mihon/cache_verified_download.ps1',
  ).readAsStringSync();
  final String macosBuild = File(
    '${repository.path}/tool/mihon/build_desktop_runtime.sh',
  ).readAsStringSync();
  final String windowsVerify = File(
    '${repository.path}/tool/mihon/verify_desktop_runtime.ps1',
  ).readAsStringSync();
  final String macosVerify = File(
    '${repository.path}/tool/mihon/verify_desktop_runtime.sh',
  ).readAsStringSync();
  final String serverBuildPatch = File(
    '${repository.path}/third_party/m_extension_server/'
    'server-build.gradle.patch',
  ).readAsStringSync();

  test('Gradle and JitPack inputs are locked and verified', () {
    expect(wrapper, contains('distributionSha256Sum='));
    expect(
      File(
        '${repository.path}/hibiki/android/gradle/'
        'verification-metadata.xml',
      ).existsSync(),
      isTrue,
      reason: 'Gradle dependency verification metadata is missing',
    );
    expect(
      File(
        '${repository.path}/hibiki/android/gradle.lockfile',
      ).existsSync(),
      isTrue,
      reason: 'Gradle/JitPack dependency locks are missing',
    );
    expect(androidBuild, contains('lockAllConfigurations()'));
  });

  test('Mihon source archive uses locked atomic cache publication', () {
    expect(androidBuild, contains('FileChannel.open'));
    expect(androidBuild, contains('StandardOpenOption.CREATE_NEW'));
    expect(androidBuild, contains('ATOMIC_MOVE'));
    expect(androidBuild, contains('mihonSourceArchiveSha256'));
    expect(
      androidBuild,
      isNot(contains('archive.withOutputStream { output -> output << input }')),
      reason: 'the network response still writes directly to the final cache',
    );
  });

  test('desktop downloads use unique same-directory temporary files', () {
    expect(windowsBuild, contains('cache_verified_download.ps1'));
    expect(windowsDownloader, contains('[Guid]::NewGuid().ToString("N")'));
    expect(windowsDownloader, contains('FileMode]::CreateNew'));
    expect(windowsDownloader, contains('[IO.File]::Move'));
    expect(
      macosBuild,
      contains(r'mktemp "$archive_path.tmp.XXXXXX"'),
    );
    expect(macosBuild, contains(r'mv "$download_tmp" "$archive_path"'));
  });

  test('desktop cache publication is serialized across processes', () {
    expect(windowsDownloader, contains('FileShare]::None'));
    expect(windowsDownloader, contains(r'$archiveLockPath'));
    expect(macosBuild, contains(r'mkdir "$archive_lock"'));
    expect(macosBuild, contains(r'rmdir "$archive_lock"'));
  });

  test('desktop build performs an online then offline same-hash gate', () {
    for (final String build in <String>[windowsBuild, macosBuild]) {
      expect(build, contains('--offline'));
      expect(build, contains('online'));
      expect(build, contains('offline'));
      expect(build, contains('sha256'));
    }
    expect(serverBuildPatch, contains('isPreserveFileTimestamps = false'));
    expect(serverBuildPatch, contains('isReproducibleFileOrder = true'));
  });

  test('runtime verification recomputes manifest hashes from final files', () {
    expect(windowsVerify, contains('ConvertFrom-Json'));
    expect(windowsVerify, contains(r'Get-FileHash -LiteralPath $server'));
    expect(windowsVerify, contains('mExtensionServer.sha256'));
    expect(macosVerify, contains('checksums.json'));
    expect(macosVerify, contains('shasum -a 256'));
    expect(macosVerify, contains(r'sha256_file "$server"'));
    expect(macosVerify, contains('mExtensionServer'));
  });

  test('Windows runtime verification rejects a tampered final server JAR',
      () async {
    final Directory runtime =
        await Directory.systemTemp.createTemp('mihon-verify-win-');
    addTearDown(() => runtime.delete(recursive: true));
    await _writeTamperedRuntimeFixture(runtime, windows: true);

    final ProcessResult result = await Process.run(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        File(
          '${repository.path}/tool/mihon/verify_desktop_runtime.ps1',
        ).absolute.path,
        '-RuntimeDirectory',
        runtime.path,
      ],
    );

    expect(result.exitCode, isNot(0));
    expect(
      '${result.stdout}\n${result.stderr}',
      contains('M-Extension-Server checksum mismatch'),
    );
  }, skip: !Platform.isWindows);

  test('macOS runtime verification rejects a tampered final server JAR',
      () async {
    final Directory runtime =
        await Directory.systemTemp.createTemp('mihon-verify-mac-');
    addTearDown(() => runtime.delete(recursive: true));
    await _writeTamperedRuntimeFixture(runtime, windows: false);

    final ProcessResult result = await Process.run(
      r'C:\Program Files\Git\bin\bash.exe',
      <String>[
        _gitBashPath(
          File(
            '${repository.path}/tool/mihon/verify_desktop_runtime.sh',
          ).absolute.path,
        ),
        _gitBashPath(runtime.absolute.path),
      ],
    );

    expect(result.exitCode, isNot(0));
    expect(
      '${result.stdout}\n${result.stderr}',
      contains('M-Extension-Server checksum mismatch'),
    );
  }, skip: !Platform.isWindows);

  test('verified downloader has executable bad-cache and concurrency seams',
      () {
    final File helper = File(
      '${repository.path}/tool/mihon/cache_verified_download.ps1',
    );
    expect(
      helper.existsSync(),
      isTrue,
      reason:
          'missing isolated downloader used by bad-cache/kill/concurrency tests',
    );
    if (!helper.existsSync()) {
      return;
    }
    final String source = windowsDownloader;
    expect(
      source,
      contains(r'[Parameter(Mandatory = $true)][string] $Uri'),
    );
    expect(
      source,
      contains(r'[Parameter(Mandatory = $true)][string] $Destination'),
    );
    expect(
      source,
      contains(r'[Parameter(Mandatory = $true)][string] $Sha256'),
    );
    expect(source, contains('HIBIKI_MIHON_DOWNLOAD_TEST_DELAY_MS'));
  });

  test('verified downloader replaces a bad cache without partial publication',
      () async {
    final Directory temporary =
        await Directory.systemTemp.createTemp('mihon-cache-bad-');
    addTearDown(() => temporary.delete(recursive: true));
    final File destination = File('${temporary.path}/fixture.bin');
    await destination.writeAsString('corrupt-cache');
    final List<int> payload =
        List<int>.generate(4096, (int index) => index % 251);
    int requests = 0;
    final HttpServer server = await _serveFixture(payload, () => requests++);
    addTearDown(server.close);

    final ProcessResult result = await _runDownloader(
      helper: File(
        '${repository.path}/tool/mihon/cache_verified_download.ps1',
      ),
      uri: Uri.parse('http://127.0.0.1:${server.port}/fixture.bin'),
      destination: destination,
      sha256Hex: sha256.convert(payload).toString(),
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(await destination.readAsBytes(), payload);
    expect(requests, 1);
    expect(
      temporary
          .listSync()
          .where((FileSystemEntity entry) => entry.path.contains('.tmp-')),
      isEmpty,
    );
  }, skip: !Platform.isWindows);

  test('concurrent verified downloaders publish one complete cache entry',
      () async {
    final Directory temporary =
        await Directory.systemTemp.createTemp('mihon-cache-concurrent-');
    addTearDown(() => temporary.delete(recursive: true));
    final File destination = File('${temporary.path}/fixture.bin');
    final List<int> payload =
        List<int>.generate(128 * 1024, (int index) => index % 239);
    int requests = 0;
    final HttpServer server = await _serveFixture(
      payload,
      () => requests++,
      responseDelay: const Duration(milliseconds: 250),
    );
    addTearDown(server.close);
    final File helper = File(
      '${repository.path}/tool/mihon/cache_verified_download.ps1',
    );
    final Uri uri = Uri.parse('http://127.0.0.1:${server.port}/fixture.bin');
    final String digest = sha256.convert(payload).toString();

    final List<ProcessResult> results =
        await Future.wait(<Future<ProcessResult>>[
      _runDownloader(
        helper: helper,
        uri: uri,
        destination: destination,
        sha256Hex: digest,
      ),
      _runDownloader(
        helper: helper,
        uri: uri,
        destination: destination,
        sha256Hex: digest,
      ),
    ]);

    expect(
      results.map((ProcessResult result) => result.exitCode),
      everyElement(0),
      reason: results
          .map((ProcessResult result) => '${result.stdout}\n${result.stderr}')
          .join('\n'),
    );
    expect(await destination.readAsBytes(), payload);
    expect(requests, 1, reason: 'the cache lock did not collapse downloads');
  }, skip: !Platform.isWindows);

  test('killing a downloader leaves no final partial and the lock recovers',
      () async {
    final Directory temporary =
        await Directory.systemTemp.createTemp('mihon-cache-kill-');
    addTearDown(() => temporary.delete(recursive: true));
    final File destination = File('${temporary.path}/fixture.bin');
    final List<int> payload =
        List<int>.generate(8192, (int index) => index % 227);
    final HttpServer server = await _serveFixture(payload, () {});
    addTearDown(server.close);
    final File helper = File(
      '${repository.path}/tool/mihon/cache_verified_download.ps1',
    );
    final Uri uri = Uri.parse('http://127.0.0.1:${server.port}/fixture.bin');
    final String digest = sha256.convert(payload).toString();

    final Process doomed = await _startDownloader(
      helper: helper,
      uri: uri,
      destination: destination,
      sha256Hex: digest,
      environment: <String, String>{
        'HIBIKI_MIHON_DOWNLOAD_TEST_DELAY_MS': '5000',
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 750));
    expect(doomed.kill(), isTrue, reason: 'downloader exited before kill seam');
    await doomed.exitCode;
    expect(destination.existsSync(), isFalse);

    final ProcessResult retry = await _runDownloader(
      helper: helper,
      uri: uri,
      destination: destination,
      sha256Hex: digest,
    );
    expect(retry.exitCode, 0, reason: '${retry.stdout}\n${retry.stderr}');
    expect(await destination.readAsBytes(), payload);
  }, skip: !Platform.isWindows);
}

Future<HttpServer> _serveFixture(
  List<int> payload,
  void Function() onRequest, {
  Duration responseDelay = Duration.zero,
}) async {
  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) async {
    onRequest();
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentLength = payload.length
      ..add(payload);
    await request.response.close();
  });
  return server;
}

Future<void> _writeTamperedRuntimeFixture(
  Directory runtime, {
  required bool windows,
}) async {
  final File java = File(
    windows
        ? '${runtime.path}/runtime/bin/java.exe'
        : '${runtime.path}/runtime-macos-x64/bin/java',
  );
  await java.create(recursive: true);
  await File('${runtime.path}/m-extension-server.jar')
      .writeAsString('tampered-final-jar');
  await File('${runtime.path}/LICENSE-M-Extension-Server.txt')
      .writeAsString('fixture');
  await File('${runtime.path}/NOTICE-M-Extension-Server.txt')
      .writeAsString('fixture');
  await File('${runtime.path}/checksums.json').writeAsString(
    jsonEncode(<String, Object>{
      'mExtensionServer': <String, String>{
        'sha256': List<String>.filled(64, '0').join(),
      },
    }),
  );
}

String _gitBashPath(String windowsPath) {
  final String normalized = windowsPath.replaceAll(r'\', '/');
  final Match? drive = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
  if (drive == null) {
    return normalized;
  }
  return '/${drive.group(1)!.toLowerCase()}/${drive.group(2)}';
}

Future<Process> _startDownloader({
  required File helper,
  required Uri uri,
  required File destination,
  required String sha256Hex,
  Map<String, String> environment = const <String, String>{},
}) {
  return Process.start(
    'powershell.exe',
    <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      helper.absolute.path,
      '-Uri',
      uri.toString(),
      '-Destination',
      destination.absolute.path,
      '-Sha256',
      sha256Hex,
    ],
    environment: environment,
  );
}

Future<ProcessResult> _runDownloader({
  required File helper,
  required Uri uri,
  required File destination,
  required String sha256Hex,
}) async {
  final Process process = await _startDownloader(
    helper: helper,
    uri: uri,
    destination: destination,
    sha256Hex: sha256Hex,
  );
  final Future<String> stdout =
      process.stdout.transform(systemEncoding.decoder).join();
  final Future<String> stderr =
      process.stderr.transform(systemEncoding.decoder).join();
  final int exitCode = await process.exitCode;
  return ProcessResult(
    process.pid,
    exitCode,
    await stdout,
    await stderr,
  );
}
