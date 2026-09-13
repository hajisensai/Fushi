import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final Directory resourceDirectory = Directory(
    Platform.environment['FUSHI_TEST_MIHON_RESOURCES'] ??
        'build/windows/x64/runner/Debug/mihon_bridge',
  );
  final bool bridgeAvailable =
      Platform.isWindows &&
      File('${resourceDirectory.path}/runtime/bin/java.exe').existsSync() &&
      File('${resourceDirectory.path}/m-extension-server.jar').existsSync();

  test(
    'source errors cross the real runtime boundary without restarting it',
    () async {
      final Directory data = await Directory.systemTemp.createTemp(
        'mihon-http-error-',
      );
      final File apk = File('${data.path}/fixture.apk')
        ..writeAsBytesSync(<int>[0]);
      final http.Client realClient = http.Client();
      final DesktopMihonRuntime runtime = DesktopMihonRuntime(
        dataDirectory: data,
        resourceDirectory: resourceDirectory,
        httpClient: MockClient((http.Request request) async {
          if (request.url.path != '/dalvik') {
            final http.Request forwarded =
                http.Request(request.method, request.url)
                  ..headers.addAll(request.headers)
                  ..bodyBytes = request.bodyBytes;
            return http.Response.fromStream(await realClient.send(forwarded));
          }
          final Map<String, dynamic> payload =
              jsonDecode(request.body) as Map<String, dynamic>;
          if (payload['method'] == 'external') {
            return http.Response(
              jsonEncode(<String, Object>{
                'errorKind': 'sourceHttp',
                'sourceStatusCode': 502,
                'error': 'HTTP error 502',
                'stackTrace': 'source trace',
              }),
              502,
            );
          }
          if (payload['method'] == 'gateway') {
            return http.Response('<html>502</html>', 502);
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      final MihonExtensionRef extension = MihonExtensionRef(
        packageName: 'fixture',
        apkPath: apk.path,
      );
      try {
        await runtime.getCapabilities();
        final int? pid = runtime.processId;
        await expectLater(
          runtime.invokeBridge(extension, 'external', <String, Object?>{}),
          throwsA(
            isA<MihonRuntimeException>()
                .having(
                  (MihonRuntimeException e) => e.code,
                  'code',
                  'SOURCE_HTTP_502',
                )
                .having(
                  (MihonRuntimeException e) => e.details,
                  'details',
                  'source trace',
                ),
          ),
        );
        await expectLater(
          runtime.invokeBridge(extension, 'gateway', <String, Object?>{}),
          throwsA(
            isA<MihonRuntimeException>().having(
              (MihonRuntimeException e) => e.code,
              'code',
              'BRIDGE_HTTP_502',
            ),
          ),
        );
        expect(
          await runtime.invokeBridge(extension, 'healthy', <String, Object?>{}),
          <String, Object>{'ok': true},
        );
        expect(runtime.processId, pid);
      } finally {
        await runtime.dispose();
        realClient.close();
        await data.delete(recursive: true);
      }
    },
    skip: !bridgeAvailable,
  );

  test(
    'bundled Java bridge is stopped without a residual process',
    () async {
      final Directory dataDirectory = await Directory.systemTemp.createTemp(
        'hibiki-mihon-runtime-test-',
      );
      final DesktopMihonRuntime runtime = DesktopMihonRuntime(
        dataDirectory: dataDirectory,
        resourceDirectory: resourceDirectory,
      );
      try {
        final capabilities = await runtime.getCapabilities();
        expect(capabilities.isUsable, isTrue);
        final int pid = runtime.processId!;

        await runtime.dispose();

        final ProcessResult lookup =
            await Process.run('powershell.exe', <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              'if (Get-Process -Id $pid -ErrorAction SilentlyContinue) '
                  '{ exit 1 }',
            ]);
        expect(
          lookup.exitCode,
          0,
          reason: 'Mihon Java PID $pid remained after runtime.dispose()',
        );
      } finally {
        await runtime.dispose();
        if (dataDirectory.existsSync()) {
          await dataDirectory.delete(recursive: true);
        }
      }
    },
    skip: bridgeAvailable
        ? false
        : 'Windows debug bundle with Java/M-Extension-Server is unavailable',
  );

  test(
    'one source timeout does not kill or replay concurrent bridge requests',
    () async {
      final Directory data = await Directory.systemTemp.createTemp(
        'mihon-timeout-',
      );
      final File apk = await File(
        '${data.path}/test.apk',
      ).writeAsString('fixture');
      final Completer<void> pendingStarted = Completer<void>();
      final Completer<void> releasePending = Completer<void>();
      final http.Client realClient = http.Client();
      int timedOutCalls = 0;
      final DesktopMihonRuntime runtime = DesktopMihonRuntime(
        dataDirectory: data,
        resourceDirectory: resourceDirectory,
        httpClient: MockClient((http.Request request) async {
          if (request.url.path != '/dalvik') {
            final http.Request forwarded =
                http.Request(request.method, request.url)
                  ..headers.addAll(request.headers)
                  ..bodyBytes = request.bodyBytes;
            return realClient.send(forwarded).then(http.Response.fromStream);
          }
          final Map<String, dynamic> payload =
              jsonDecode(request.body) as Map<String, dynamic>;
          if (payload['method'] == 'slow') {
            timedOutCalls++;
            throw TimeoutException('fixture source timeout');
          }
          pendingStarted.complete();
          await releasePending.future;
          return http.Response('{"ok":true}', 200);
        }),
      );
      final MihonExtensionRef extension = MihonExtensionRef(
        packageName: 'test',
        apkPath: apk.path,
      );
      try {
        await runtime.getCapabilities();
        final int pid = runtime.processId!;
        final Future<Object?> pending = runtime.invokeBridge(
          extension,
          'pending',
          <String, Object?>{},
        );
        await pendingStarted.future;
        await expectLater(
          runtime.invokeBridge(extension, 'slow', <String, Object?>{}),
          throwsA(
            isA<MihonRuntimeException>().having(
              (MihonRuntimeException error) => error.code,
              'code',
              'BRIDGE_TIMEOUT',
            ),
          ),
        );
        expect(runtime.processId, pid);
        expect(timedOutCalls, 1);
        releasePending.complete();
        expect(await pending, <String, Object>{'ok': true});
        expect((await runtime.getCapabilities()).isUsable, isTrue);
      } finally {
        if (!releasePending.isCompleted) releasePending.complete();
        await runtime.dispose();
        realClient.close();
        await data.delete(recursive: true);
      }
    },
    skip: bridgeAvailable
        ? false
        : 'Built desktop Mihon Java bundle is unavailable',
  );
}
