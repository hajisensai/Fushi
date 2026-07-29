import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final Directory repository = Directory('..');
  final String releaseWorkflow = File(
    '${repository.path}/.github/workflows/release-desktop.yml',
  ).readAsStringSync();
  final String macosJob = _jobBlock(releaseWorkflow, 'macos');
  final String macosCommands = _runCommands(macosJob).join('\n');
  final String nonFormalSigningStep = _stepBlock(
    macosJob,
    'Re-sign non-formal macOS app after runtime injection',
  );
  final String formalSigningStep = _stepBlock(
    macosJob,
    'Sign formal macOS app with Developer ID',
  );
  final String validationJob =
      _jobBlock(releaseWorkflow, 'macos-runtime-validation');
  final String validationCommands = _runCommands(validationJob).join('\n');
  final String windowsBuild = File(
    '${repository.path}/tool/mihon/build_desktop_runtime.ps1',
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

  test('macOS release requires Developer ID and hardened runtime', () {
    expect(formalSigningStep, contains('MACOS_DEVELOPER_ID_APPLICATION'));
    expect(formalSigningStep, contains('--options runtime'));
    expect(formalSigningStep, contains('--timestamp'));
    expect(formalSigningStep, contains('Runner/Release.entitlements'));
    expect(formalSigningStep, contains('hibiki-developer-id.p12'));
    expect(formalSigningStep, contains('security create-keychain'));
    expect(formalSigningStep, contains('security import'));
    expect(formalSigningStep, contains('security set-key-partition-list'));
    expect(formalSigningStep, contains('trap cleanup_signing EXIT'));
    expect(formalSigningStep, contains('security delete-keychain'));
    expect(formalSigningStep, contains(r'rm -f "$certificate_path"'));
    expect(formalSigningStep, isNot(contains('mapfile')));
    expect(formalSigningStep, isNot(contains('--sign - --timestamp=none')));
    expect(formalSigningStep, isNot(contains('--deep')));
  });

  test('non-formal macOS release is re-signed after runtime injection', () {
    expect(
      nonFormalSigningStep,
      contains("manifest_channel != 'formal'"),
    );
    expect(
      nonFormalSigningStep,
      contains('codesign --force --sign - --timestamp=none'),
    );
    expect(nonFormalSigningStep, contains('Runner/Release.entitlements'));
    expect(nonFormalSigningStep, contains(r'root.rglob("*")'));
    expect(nonFormalSigningStep, contains(r'len(item.parts), reverse=True'));
    expect(nonFormalSigningStep, isNot(contains('--deep')));
  });

  test('macOS release gates notarization, staple, and Gatekeeper', () {
    expect(macosCommands, contains('notarytool submit'));
    expect(macosCommands, contains('--wait'));
    expect(macosCommands, contains('notary_status='));
    expect(macosCommands, contains(r'json.load(sys.stdin).get("status", "")'));
    expect(macosCommands, contains(r'if [ "$notary_status" != Accepted ]'));
    expect(macosCommands, contains('stapler staple'));
    expect(macosCommands, contains('stapler validate'));
    expect(macosCommands, contains('spctl --assess'));
  });

  test('macOS verifies x64 and arm64 runtimes independently', () {
    expect(
      validationJob,
      contains(
        RegExp(
          r'arch:\s*x64[\s\S]*?runner:\s*macos-15-intel'
          r'[\s\S]*?arch:\s*arm64[\s\S]*?runner:\s*macos-15',
        ),
      ),
    );
    expect(validationCommands, contains('verify_desktop_runtime.sh'));
    expect(validationCommands, contains(r'"${{ matrix.arch }}"'));
    expect(validationCommands, contains('verify_desktop_extension_e2e.ps1'));
    expect(validationCommands, contains(r'-Architecture $architecture'));
    expect(macosVerify, contains(r'architecture="$2"'));
    expect(macosVerify, isNot(contains(r'case "$(uname -m)"')));
  });

  test('release artifacts carry exact license and APK source provenance', () {
    for (final String build in <String>[windowsBuild, macosBuild]) {
      expect(build, contains('LICENSE-M-Extension-Server.txt'));
      expect(build, contains('NOTICE-M-Extension-Server.txt'));
      expect(build, contains('UPSTREAM-M-Extension-Server.txt'));
    }
    for (final String verify in <String>[windowsVerify, macosVerify]) {
      expect(verify, contains('LICENSE-M-Extension-Server.txt'));
      expect(verify, contains('NOTICE-M-Extension-Server.txt'));
      expect(verify, contains('UPSTREAM-M-Extension-Server.txt'));
    }

    final File apkProvenance = File(
      '${repository.path}/third_party/mihon_e2e_extension/UPSTREAM',
    );
    expect(
      apkProvenance.existsSync(),
      isTrue,
      reason: 'fixed E2E APK has no binary-to-source provenance record',
    );
    if (apkProvenance.existsSync()) {
      final String provenance = apkProvenance.readAsStringSync();
      expect(
        provenance,
        matches(RegExp(r'^binary_commit=[0-9a-f]{40}$', multiLine: true)),
      );
      expect(
        provenance,
        matches(RegExp(r'^source_commit=[0-9a-f]{40}$', multiLine: true)),
      );
      expect(
        provenance,
        matches(RegExp(r'^apk_sha256=[0-9a-f]{64}$', multiLine: true)),
      );
      expect(provenance, contains('license=Apache-2.0'));
    }
    expect(releaseWorkflow, contains('MIHON_E2E_APK_SOURCE_COMMIT'));
    expect(releaseWorkflow, contains('MIHON_E2E_APK_LICENSE'));
  });
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

String _stepBlock(String job, String stepName) {
  final List<String> lines = job.split('\n');
  final int start = lines.indexWhere(
    (String line) => line.trim() == '- name: $stepName',
  );
  if (start < 0) {
    throw StateError('Missing workflow step $stepName');
  }
  int end = start + 1;
  while (end < lines.length &&
      !RegExp(r'^\s{6}- (?:name:|uses:)').hasMatch(lines[end])) {
    end++;
  }
  return lines.sublist(start, end).join('\n');
}
