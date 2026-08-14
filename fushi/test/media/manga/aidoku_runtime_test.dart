import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';

void main() {
  late Directory root;
  late File executable;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-aidoku-runtime-');
    executable = File('${root.path}/fake-aidoku-runtime');
    await executable.writeAsString('''#!/bin/sh
case "\$1" in
  inspect)
    printf '%s' '{"manifest":{"info":{"id":"ja.test"}},"runtime":{"imports":["net.send"],"exports":["get_search_manga_list"],"requiresWebView":false}}'
    ;;
  search)
    printf '%s' '{"result":{"entries":[{"key":"manga"}],"has_next_page":false}}'
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
    final List<Object?> pages = await runtime.getPages(
      'source.aix',
      <String, Object?>{'key': 'manga'},
      <String, Object?>{'key': 'chapter'},
    );

    expect(search['has_next_page'], isFalse);
    expect(details['title'], 'Title');
    expect(pages, hasLength(1));
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
}
