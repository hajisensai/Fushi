import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/test_environment.dart';

void main() {
  test('hibikiTestDirectory resolves children under an explicit test root', () {
    final Directory temp = Directory.systemTemp.createTempSync('hibiki-root-');
    addTearDown(() => temp.deleteSync(recursive: true));

    final Directory? docs = hibikiTestDirectory(
      'app-documents',
      environment: <String, String>{'HIBIKI_TEST_ROOT': temp.path},
      dartDefineRoot: '',
    );

    expect(docs, isNotNull);
    expect(docs!.path, contains('app-documents'));
    expect(docs.path, startsWith(temp.path));
    expect(docs.existsSync(), isTrue);
  });

  test('dart-define root wins over process environment', () {
    final Directory envRoot =
        Directory.systemTemp.createTempSync('hibiki-env-');
    final Directory defineRoot =
        Directory.systemTemp.createTempSync('hibiki-define-');
    addTearDown(() => envRoot.deleteSync(recursive: true));
    addTearDown(() => defineRoot.deleteSync(recursive: true));

    final Directory? support = hibikiTestDirectory(
      'app-support',
      environment: <String, String>{'HIBIKI_TEST_ROOT': envRoot.path},
      dartDefineRoot: defineRoot.path,
    );

    expect(support, isNotNull);
    expect(support!.path, startsWith(defineRoot.path));
  });
}
