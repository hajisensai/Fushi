import 'dart:io';

import 'package:path/path.dart' as p;

const String _dartDefineTestRoot = String.fromEnvironment('HIBIKI_TEST_ROOT');
const String _dartDefineTestRunId =
    String.fromEnvironment('HIBIKI_TEST_RUN_ID');

String? hibikiTestRootPath({
  Map<String, String>? environment,
  String dartDefineRoot = _dartDefineTestRoot,
}) {
  final String raw = dartDefineRoot.trim().isNotEmpty
      ? dartDefineRoot
      : (environment ?? Platform.environment)['HIBIKI_TEST_ROOT'] ?? '';
  if (raw.trim().isEmpty) {
    return null;
  }
  return Directory(raw).absolute.path;
}

String? hibikiTestRunId({
  Map<String, String>? environment,
  String dartDefineRunId = _dartDefineTestRunId,
}) {
  final String raw = dartDefineRunId.trim().isNotEmpty
      ? dartDefineRunId
      : (environment ?? Platform.environment)['HIBIKI_TEST_RUN_ID'] ?? '';
  return raw.trim().isEmpty ? null : raw.trim();
}

Directory? hibikiTestDirectory(
  String child, {
  Map<String, String>? environment,
  String dartDefineRoot = _dartDefineTestRoot,
}) {
  final String? root = hibikiTestRootPath(
    environment: environment,
    dartDefineRoot: dartDefineRoot,
  );
  if (root == null) {
    return null;
  }
  final Directory directory = Directory(p.join(root, child));
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  return directory;
}
