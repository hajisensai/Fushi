import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String readRepositoryWorkflow(String relativePath) {
    final File file = File('../.github/workflows/$relativePath');
    expect(file.existsSync(), isTrue,
        reason: 'expected workflow at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String readReleaseWorkflow() {
    return readRepositoryWorkflow('release.yml');
  }

  String readBuildMultiplatformWorkflow() {
    return readRepositoryWorkflow('build-multiplatform.yml');
  }

  String workflowJob(String workflow, String name) {
    final String marker = '  $name:\n';
    final int start = workflow.indexOf(marker);
    expect(start, isNonNegative, reason: 'missing workflow job: $name');
    final RegExp nextJobPattern = RegExp(r'\n  [a-zA-Z0-9_-]+:\n');
    final Match? nextJob = nextJobPattern.firstMatch(
      workflow.substring(start + marker.length),
    );
    return workflow.substring(
      start,
      nextJob == null ? workflow.length : start + marker.length + nextJob.start,
    );
  }

  String workflowStep(String workflow, String name) {
    final String marker = '    - name: $name';
    final int start = workflow.indexOf(marker);
    expect(start, isNonNegative, reason: 'missing workflow step: $name');
    final int next = workflow.indexOf('\n    - name:', start + marker.length);
    return workflow.substring(start, next == -1 ? workflow.length : next);
  }

  void expectWorkflowOrder(
    String workflow,
    String before,
    String after,
  ) {
    final int beforeIndex = workflow.indexOf(before);
    final int afterIndex = workflow.indexOf(after);
    expect(beforeIndex, isNonNegative,
        reason: 'missing workflow marker: $before');
    expect(afterIndex, isNonNegative,
        reason: 'missing workflow marker: $after');
    expect(beforeIndex, lessThan(afterIndex));
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

  test('build-multiplatform Android appSmoke removes aliyun mirrors first', () {
    final String workflow = readBuildMultiplatformWorkflow();
    final String androidJob = workflowJob(workflow, 'android');
    final String removeAliyunMirrors = workflowStep(
      androidJob,
      'Remove aliyun mirrors from gradle files',
    );
    final String appSmoke = workflowStep(
      androidJob,
      'Run Android comprehensive automation contract',
    );

    expect(removeAliyunMirrors, contains('working-directory: hibiki/android'));
    expect(removeAliyunMirrors,
        contains('sed -i "/maven.*aliyun/d" build.gradle'));
    expect(
      removeAliyunMirrors,
      contains('sed -i "/maven.*aliyun/d" settings.gradle'),
    );
    expect(appSmoke, contains('--platform=android --only=appSmoke'));
    expectWorkflowOrder(
      androidJob,
      'Flutter pub get',
      'Remove aliyun mirrors from gradle files',
    );
    expectWorkflowOrder(
      androidJob,
      'Remove aliyun mirrors from gradle files',
      'Run Android comprehensive automation contract',
    );
  });
}
