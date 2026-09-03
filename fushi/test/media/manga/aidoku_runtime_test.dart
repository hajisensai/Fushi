import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File executable;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-aidoku-runtime-');
    // 假运行时按平台落两种壳：POSIX 用 shebang sh 脚本；Windows 上 shebang 脚本
    // 无法被 Process.start 直接拉起（且 chmod 不存在），改写等价 .bat（Dart 的
    // Process 会经 cmd.exe 运行批处理）。两个分支输出逐字节相同的 JSON 负载。
    if (Platform.isWindows) {
      executable = File('${root.path}/fake-aidoku-runtime.bat');
      await executable.writeAsString('''@echo off
if "%~1"=="inspect" (
echo {"manifest":{"info":{"id":"ja.test"}},"runtime":{"imports":["net.send"],"exports":["get_search_manga_list"],"requiresWebView":false}}
exit /b 0
)
if "%~1"=="search" (
echo {"result":{"entries":[{"key":"manga"}],"has_next_page":false}}
exit /b 0
)
if "%~1"=="list" (
echo {"result":{"entries":[{"key":"listed"}],"has_next_page":true}}
exit /b 0
)
if "%~1"=="details" (
echo {"result":{"key":"manga","title":"Title"}}
exit /b 0
)
if "%~1"=="pages" (
echo {"result":[{"content":{"Url":["https://example.test/1.jpg",null]}}]}
exit /b 0
)
echo {"error":"unknown command"} 1>&2
exit /b 2
''');
      return;
    }
    executable = File('${root.path}/fake-aidoku-runtime');
    await executable.writeAsString('''#!/bin/sh
case "\$1" in
  inspect)
    printf '%s' '{"manifest":{"info":{"id":"ja.test"}},"runtime":{"imports":["net.send"],"exports":["get_search_manga_list"],"requiresWebView":false}}'
    ;;
  search)
    printf '%s' '{"result":{"entries":[{"key":"manga"}],"has_next_page":false}}'
    ;;
  list)
    printf '%s' '{"result":{"entries":[{"key":"listed"}],"has_next_page":true}}'
    ;;
  details)
    printf '%s' '{"result":{"key":"manga","title":"Title"}}'
    ;;
  pages)
    printf '%s' '{"result":[{"content":{"Url":["https://example.test/1.jpg",null]}}]}'
    ;;
  *)
    printf '%s' '{"error":"unknown command"}' >&2
    exit 2
    ;;
esac
''');
    final ProcessResult chmod = await Process.run(
      'chmod',
      <String>['+x', executable.path],
    );
    expect(chmod.exitCode, 0);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.aidokuRuntime, null);
    await root.delete(recursive: true);
  });

  test('parses package inspection and runtime capabilities', () async {
    final DesktopAidokuRuntime runtime =
        DesktopAidokuRuntime(executable: executable);

    final AidokuPackageInspection result = await runtime.inspect('source.aix');

    expect(result.manifest['info'], <String, Object?>{'id': 'ja.test'});
    expect(result.imports, <String>['net.send']);
    expect(result.exports, <String>['get_search_manga_list']);
    expect(result.requiresWebView, isFalse);
  });

  test('returns search, details, and page payloads', () async {
    final DesktopAidokuRuntime runtime =
        DesktopAidokuRuntime(executable: executable);

    final Map<String, Object?> search = await runtime.search(
      'source.aix',
      query: '東京',
    );
    final Map<String, Object?> details = await runtime.getDetails(
      'source.aix',
      <String, Object?>{'key': 'manga'},
    );
    final Map<String, Object?> listing = await runtime.browse(
      'source.aix',
      const AidokuListing(id: 'latest', name: 'Latest'),
    );
    final List<Object?> pages = await runtime.getPages(
      'source.aix',
      <String, Object?>{'key': 'manga'},
      <String, Object?>{'key': 'chapter'},
    );

    expect(search['has_next_page'], isFalse);
    expect(details['title'], 'Title');
    expect(listing['has_next_page'], isTrue);
    expect(pages, hasLength(1));
  });

  test('parses manifest listings', () {
    final AidokuPackageInspection inspection =
        AidokuPackageInspection.fromJson(<String, Object?>{
      'manifest': <String, Object?>{
        'info': <String, Object?>{'id': 'ja.test'},
        'listings': <Object?>[
          <String, Object?>{'id': '/latest/', 'name': 'Latest'},
        ],
      },
      'runtime': <String, Object?>{},
    });

    expect(inspection.listings, hasLength(1));
    expect(inspection.listings.single.id, '/latest/');
  });

  test('rejects an invalid search page before spawning', () async {
    final DesktopAidokuRuntime runtime =
        DesktopAidokuRuntime(executable: executable);

    await expectLater(
      runtime.search('source.aix', page: 0),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException error) => error.code,
          'code',
          'INVALID_PAGE',
        ),
      ),
    );
  });

  test('reports a missing bundled runtime explicitly', () async {
    final DesktopAidokuRuntime runtime = DesktopAidokuRuntime(
      executable: File('${root.path}/missing-runtime'),
    );

    await expectLater(
      runtime.inspect('source.aix'),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException error) => error.code,
          'code',
          'RUNTIME_MISSING',
        ),
      ),
    );
  });

  test('iOS runtime sends the shared command contract over its channel',
      () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.aidokuRuntime,
            (MethodCall call) async {
      calls.add(call);
      final Map<Object?, Object?> arguments =
          call.arguments! as Map<Object?, Object?>;
      return switch (arguments['command']) {
        'inspect' => <String, Object?>{
            'manifest': <String, Object?>{
              'info': <String, Object?>{'id': 'ja.test'},
            },
            'runtime': <String, Object?>{
              'imports': <String>['net.send'],
              'exports': <String>['get_search_manga_list'],
              'requiresWebView': false,
            },
          },
        'search' => <String, Object?>{
            'result': <String, Object?>{
              'entries': <Object?>[],
              'has_next_page': false,
            },
          },
        _ => throw PlatformException(code: 'UNEXPECTED_COMMAND'),
      };
    });
    final IosAidokuRuntime runtime = IosAidokuRuntime();

    final AidokuPackageInspection inspection =
        await runtime.inspect('/documents/source.aix');
    final Map<String, Object?> search = await runtime.search(
      '/documents/source.aix',
      query: '東京',
      page: 2,
    );

    expect(inspection.sourceInfo['id'], 'ja.test');
    expect(search['has_next_page'], isFalse);
    expect(calls, hasLength(2));
    expect(calls.first.method, 'invoke');
    expect(calls.last.arguments, <String, Object?>{
      'command': 'search',
      'packagePath': '/documents/source.aix',
      'query': '東京',
      'page': 2,
    });
  });

  test('iOS runtime preserves native error codes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      FushiChannels.aidokuRuntime,
      (MethodCall call) async => throw PlatformException(
        code: 'UNSUPPORTED_IMPORT',
        message: 'js.webview_create is not available',
      ),
    );

    await expectLater(
      IosAidokuRuntime().inspect('/documents/source.aix'),
      throwsA(
        isA<AidokuRuntimeException>()
            .having(
              (AidokuRuntimeException error) => error.code,
              'code',
              'UNSUPPORTED_IMPORT',
            )
            .having(
              (AidokuRuntimeException error) => error.message,
              'message',
              contains('js.webview_create'),
            ),
      ),
    );
  });
}
