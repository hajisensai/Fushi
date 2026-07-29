import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String multiplatform =
      File('../.github/workflows/build-multiplatform.yml').readAsStringSync();
  final String android =
      File('../.github/workflows/main.yml').readAsStringSync();
  final String release =
      File('../.github/workflows/release-desktop.yml').readAsStringSync();

  test('Mihon-only changes trigger PR and release workflows', () {
    for (final MapEntry<String, Set<String>> workflow in <String, Set<String>>{
      'multiplatform PR': _triggerPaths(multiplatform, 'pull_request'),
      'android PR': _triggerPaths(android, 'pull_request'),
      'desktop release push': _triggerPaths(release, 'push'),
    }.entries) {
      expect(
        workflow.value,
        containsAll(<String>{
          'tool/mihon/**',
          'third_party/m_extension_server/**',
          'third_party/mihon-source-api/**',
          'hibiki/android/**/*.gradle*',
          'hibiki/android/gradle/**',
        }),
        reason: '${workflow.key} paths: ${workflow.value}',
      );
    }
  });

  test('Windows and macOS jobs execute real extension E2E steps', () {
    for (final MapEntry<String, String> workflow in <String, String>{
      'multiplatform': multiplatform,
      'release': release,
    }.entries) {
      expect(
        workflow.value,
        contains(
          'https://raw.githubusercontent.com/keiyoushi/extensions/'
          '9aaf4bd95c3d24a34a280371aeb6267141b4d235/apk/'
          'tachiyomi-all.mangadex-v1.4.211.apk',
        ),
        reason: '${workflow.key} does not pin the extension APK by commit',
      );
      expect(
        workflow.value,
        contains(
          '44f8617edb3b754957b1ac4fedf789181d72820c58ac1c18a1d242ea864f4e0d',
        ),
        reason: '${workflow.key} does not pin the extension APK digest',
      );

      for (final String jobName in <String>['windows', 'macos']) {
        final String job = _jobBlock(workflow.value, jobName);
        final String commands = _runCommands(job).join('\n');
        expect(
          commands,
          contains('verify_desktop_extension_e2e.ps1'),
          reason:
              '${workflow.key}/$jobName does not invoke the desktop extension E2E harness',
        );
        expect(
          commands,
          contains('-ApkPath'),
          reason:
              '${workflow.key}/$jobName does not supply a real extension APK',
        );
        expect(
          commands,
          contains('MIHON_E2E_APK_SHA256'),
          reason: '${workflow.key}/$jobName does not verify the pinned digest',
        );
        expect(
          commands,
          contains('Tee-Object'),
          reason: '${workflow.key}/$jobName does not retain an E2E report',
        );
        expect(
          commands,
          allOf(contains('catch'), contains('throw')),
          reason:
              '${workflow.key}/$jobName does not propagate setup or E2E failures',
        );
        expect(
          job,
          allOf(
            contains('if: always()'),
            contains('mihon-extension-e2e-$jobName'),
            contains('if-no-files-found: error'),
          ),
          reason:
              '${workflow.key}/$jobName does not always publish an auditable report',
        );
      }
    }
  });
}

Set<String> _triggerPaths(String workflow, String trigger) {
  final List<String> lines = workflow.split(RegExp(r'\r?\n'));
  final int triggerStart =
      lines.indexWhere((String line) => line.trimRight() == '  $trigger:');
  if (triggerStart < 0) {
    return <String>{};
  }

  int triggerEnd = lines.length;
  for (int index = triggerStart + 1; index < lines.length; index++) {
    if (RegExp(r'^  [a-zA-Z_][a-zA-Z0-9_-]*:\s*$').hasMatch(lines[index])) {
      triggerEnd = index;
      break;
    }
  }
  int pathsIndex = -1;
  for (int index = triggerStart + 1; index < triggerEnd; index++) {
    final String trimmed = lines[index].trimLeft();
    final int indent = lines[index].length - trimmed.length;
    if (indent >= 4 && trimmed.startsWith('paths:')) {
      pathsIndex = index;
      break;
    }
  }
  if (pathsIndex < 0) {
    return <String>{};
  }

  final RegExpMatch? alias =
      RegExp(r'^paths:\s+\*(\S+)\s*$').firstMatch(lines[pathsIndex].trim());
  if (alias != null) {
    final String anchor = alias.group(1)!;
    pathsIndex = lines.indexWhere(
      (String line) => line.trim() == 'paths: &$anchor',
    );
    if (pathsIndex < 0) {
      return <String>{};
    }
  }
  return _pathEntries(lines, pathsIndex);
}

Set<String> _pathEntries(List<String> lines, int pathsIndex) {
  final int pathsIndent =
      lines[pathsIndex].length - lines[pathsIndex].trimLeft().length;
  final Set<String> paths = <String>{};
  for (final String line in lines.skip(pathsIndex + 1)) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    final int indent = line.length - line.trimLeft().length;
    if (indent <= pathsIndent) {
      break;
    }
    final RegExpMatch? entry = RegExp(r'^-\s+(.+?)\s*$').firstMatch(trimmed);
    if (entry != null) {
      paths.add(
        entry
            .group(1)!
            .replaceAll(RegExp(r'\s+#.*$'), '')
            .replaceAll(RegExp(r'''^['"]|['"]$'''), ''),
      );
    }
  }
  return paths;
}

String _jobBlock(String workflow, String jobName) {
  final List<String> lines = workflow.split(RegExp(r'\r?\n'));
  final int start =
      lines.indexWhere((String line) => line.trimRight() == '  $jobName:');
  if (start < 0) {
    throw StateError('Missing workflow job $jobName');
  }
  int end = start + 1;
  while (end < lines.length &&
      !RegExp(r'^  [a-zA-Z0-9_-]+:\s*$').hasMatch(lines[end])) {
    end++;
  }
  return lines.sublist(start + 1, end).join('\n');
}

List<String> _runCommands(String job) {
  final List<String> commands = <String>[];
  final List<String> lines = job.split('\n');
  for (int index = 0; index < lines.length; index++) {
    if (!RegExp(r'^\s{6}- name:').hasMatch(lines[index])) {
      continue;
    }
    final StringBuffer step = StringBuffer();
    index++;
    while (index < lines.length &&
        !RegExp(r'^\s{6}- (?:name:|uses:)').hasMatch(lines[index])) {
      final String line = lines[index];
      if (!line.trimLeft().startsWith('#')) {
        step.writeln(line);
      }
      index++;
    }
    index--;
    final String value = step.toString();
    if (RegExp(r'^\s{8}run:', multiLine: true).hasMatch(value)) {
      commands.add(value);
    }
  }
  return commands;
}
