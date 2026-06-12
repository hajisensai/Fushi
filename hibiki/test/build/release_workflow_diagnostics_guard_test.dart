import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String readReleaseWorkflow() {
    final File file = File('../.github/workflows/release.yml');
    expect(file.existsSync(), isTrue,
        reason: 'expected release workflow at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String workflowStep(String workflow, String name) {
    final String marker = '    - name: $name';
    final int start = workflow.indexOf(marker);
    expect(start, isNonNegative, reason: 'missing workflow step: $name');
    final int next = workflow.indexOf('\n    - name:', start + marker.length);
    return workflow.substring(start, next == -1 ? workflow.length : next);
  }

  test('Android release workflow bounds and diagnoses APK build hangs', () {
    final String workflow = readReleaseWorkflow();
    final String debugChannelBuild = workflowStep(
      workflow,
      'Build release-signed debug-channel APK',
    );
    final String splitReleaseBuild = workflowStep(
      workflow,
      'Build release APK (split per ABI)',
    );
    final String preBuildDiagnostics = workflowStep(
      workflow,
      'Collect Android release build diagnostics',
    );
    final String postBuildDiagnostics = workflowStep(
      workflow,
      'Collect Android post-build diagnostics',
    );

    expect(workflow, contains('timeout-minutes: 90'));

    for (final String step in <String>[debugChannelBuild, splitReleaseBuild]) {
      expect(step, contains('timeout-minutes:'));
      expect(step, contains('flutter --verbose build apk'));
      expect(
          step,
          contains('--build-name '
              '"\${{ steps.channel.outputs.build_version_name }}"'));
      expect(
          step,
          contains('--build-number '
              '"\${{ steps.channel.outputs.android_build_number }}"'));
    }

    expect(debugChannelBuild, contains('--release'));
    expect(debugChannelBuild, isNot(contains('--split-per-abi')));
    expect(splitReleaseBuild, contains('--split-per-abi --release'));

    expect(preBuildDiagnostics, contains('flutter --version'));
    expect(preBuildDiagnostics, contains('dart --version'));
    expect(preBuildDiagnostics, contains('java -version'));
    expect(preBuildDiagnostics, contains('timeout 120s ./gradlew --version'));
    expect(preBuildDiagnostics, contains('build/app/outputs/flutter-apk'));
    expect(
      workflow.indexOf('Collect Android release build diagnostics'),
      lessThan(workflow.indexOf('Build release-signed debug-channel APK')),
      reason:
          'environment/path diagnostics must finish before the build step can '
          'hang, because in-progress step logs are not reliably downloadable.',
    );

    expect(postBuildDiagnostics, contains(r'if: ${{ always() &&'));
    expect(
        postBuildDiagnostics, contains('find build/app/outputs/flutter-apk'));
    expect(
        postBuildDiagnostics, contains('find build/app/outputs -maxdepth 5'));
    expect(
      workflow.indexOf('Build release APK (split per ABI)'),
      lessThan(workflow.indexOf('Collect Android post-build diagnostics')),
    );
  });
}
