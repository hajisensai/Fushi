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

  String readBuildAndroidWorkflow() {
    return readRepositoryWorkflow('main.yml');
  }

  String readReleaseDesktopWorkflow() {
    return readRepositoryWorkflow('release-desktop.yml');
  }

  String readAndroidBuildGradle() {
    final File file = File('android/app/build.gradle');
    expect(file.existsSync(), isTrue,
        reason: 'expected build.gradle at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String readRepositoryTool(String relativePath) {
    final File file = File('../tool/$relativePath');
    expect(file.existsSync(), isTrue,
        reason: 'expected tool at ${file.absolute.path}');
    return file.readAsStringSync();
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

    // TODO-841: push/debug 通道只打 arm64-only 瘦身（debug 包太大，正常人只用
    // arm64）；beta/formal 的 split-per-abi 必须保留全 ABI（资产名依赖全 ABI）。
    expect(debugChannelBuild, contains('--target-platform android-arm64'),
        reason: 'TODO-841: push/debug 通道只打 arm64-only 瘦身');
    expect(splitReleaseBuild, isNot(contains('--target-platform')),
        reason: 'beta/formal 必须保留全 ABI，不得限制到单一 ABI');

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

  test(
      'TODO-414: Android versionCode is the monotonic git-rev-count + base, '
      'never the overflowing *1000000 formula', () {
    final String releaseWorkflow = readReleaseWorkflow();
    final String mainWorkflow = readBuildAndroidWorkflow();
    final String buildGradle = readAndroidBuildGradle();

    // The *1000000 build number produced versionCode ~6.6e9 (int32 overflow /
    // over Android's 2.1e9 ceiling), so beta/release Android packages could not
    // be built. The Android build number must be the bare release sequence.
    expect(releaseWorkflow, isNot(contains('* 1000000')),
        reason: 'the *1000000 build number overflows int32 / Android 2.1e9 '
            'versionCode ceiling (TODO-414)');
    expect(releaseWorkflow, isNot(contains('PUBSPEC_BUILD * 1000000')));
    expect(releaseWorkflow, contains(r'ANDROID_BUILD_NUMBER=$RELEASE_SEQUENCE'),
        reason: 'Android build number must be the bare monotonic commit count; '
            'the versionCode base is applied in build.gradle');

    // main.yml validation builds must use the same monotonic sequence (full
    // history + --build-number) so debug/release versionCode matches release.yml.
    expect(mainWorkflow, contains('fetch-depth: 0'),
        reason: 'shallow checkout would truncate git rev-list --count HEAD');
    expect(mainWorkflow,
        contains(r'RELEASE_SEQUENCE=$(git rev-list --count HEAD)'));
    expect(
        r'--build-number "$RELEASE_SEQUENCE"'.allMatches(mainWorkflow).length,
        greaterThanOrEqualTo(2),
        reason: 'debug + release validation builds must carry the shared '
            'build number so their versionCode matches release.yml');

    // TODO-841: main.yml 的 14 天 debug artifact 也瘦身成 arm64-only。
    expect(mainWorkflow, contains('flutter build apk --debug '
        '--target-platform android-arm64'),
        reason: 'TODO-841: push 的 debug artifact 也只打 arm64-only');

    // build.gradle owns the one-time migration floor + ceiling assertion.
    expect(buildGradle, contains('def versionCodeBase = 1000000000'),
        reason: 'one-time versionCode floor above every shipped versionCode');
    expect(buildGradle, contains('def maxVersionCode = 2100000000'),
        reason: 'ceiling guard must match Android 2.1e9 limit');
    expect(buildGradle, contains('output.versionCodeOverride = computed'),
        reason: 'versionCode must be the bounds-checked computed value');
    expect('throw new GradleException'.allMatches(buildGradle).length,
        greaterThanOrEqualTo(3),
        reason: 'fat + split versionCode ceiling assertions must both throw '
            '(plus the pre-existing keystore guards)');
  });

  test('Windows desktop release smokes bundled ffmpeg in final bundle', () {
    final String workflow = readReleaseDesktopWorkflow();
    final String smoke = workflowStep(
      workflow,
      'Smoke test bundled ffmpeg in Windows bundle',
    );

    expect(
      smoke,
      contains(r'hibiki\build\windows\x64\runner\Release\ffmpeg.exe'),
      reason: 'release must test the exact ffmpeg.exe copied beside hibiki.exe',
    );
    expect(
      smoke,
      contains('tool/ffmpeg-min/smoke-test.sh'),
      reason:
          'the final bundle smoke must exercise subtitle, GIF, frame, cover, and sentence audio commands',
    );
    expect(
      smoke,
      contains(r'$env:FIXTURE_FFMPEG'),
      reason:
          'representative MP4/MKV fixtures must be generated by a full ffmpeg, not the minimal runtime binary',
    );
    expect(
      smoke,
      contains('choco install ffmpeg'),
      reason:
          'GitHub runners that lack full ffmpeg still need a fixture generator, but it must not be bundled',
    );
    expect(
      smoke,
      isNot(contains(r'FIXTURE_FFMPEG="$FFMPEG_MIN"')),
      reason:
          'the minimal bundled ffmpeg must not need MP4/MKV muxers or video/subtitle encoders just to generate smoke fixtures',
    );
    expect(
      smoke,
      isNot(contains('SELF_CONTAINED_FIXTURES=1')),
      reason:
          'release smoke should use a full fixture generator instead of expanding the minimal ffmpeg allowlist',
    );
    expect(
      smoke,
      contains(r'& $target -version'),
      reason:
          'PowerShell must execute the copied Windows binary outside MSYS2 before installer compilation',
    );
    expectWorkflowOrder(
      workflow,
      'Install vendored ffmpeg-min runtime into Windows bundle',
      'Smoke test bundled ffmpeg in Windows bundle',
    );
    expectWorkflowOrder(
      workflow,
      'Smoke test bundled ffmpeg in Windows bundle',
      'Compile installer (Inno Setup)',
    );
  });

  test(
      'TODO-652: Windows ffmpeg smoke tolerates external chocolatey flake '
      'without failing the desktop release', () {
    final String workflow = readReleaseDesktopWorkflow();
    final String smoke = workflowStep(
      workflow,
      'Smoke test bundled ffmpeg in Windows bundle',
    );

    // The bundled binary -version check stays a hard gate (it is the shipped
    // deliverable, no external dependency): it must still throw on failure.
    expect(
      smoke,
      contains(r'throw "Bundled ffmpeg failed -version'),
      reason: 'the bundled ffmpeg -version gate must remain a hard failure; '
          'it verifies the exact binary we ship',
    );

    // The fixture ffmpeg is only a reference generator fetched from chocolatey,
    // whose source intermittently returns 504. Its acquisition must be retried
    // and, on persistent failure, skipped with a loud warning - never throw and
    // fail the whole Desktop release (TODO-652, mirrors TODO-624 precedent).
    expect(
      smoke,
      contains(r'for ($attempt = 1; $attempt -le 3; $attempt++)'),
      reason: 'choco install ffmpeg must be retried to absorb transient 504s',
    );
    expect(
      smoke,
      isNot(contains(r'Get-Command ffmpeg -ErrorAction Stop')),
      reason:
          'fixture ffmpeg lookup must not hard-throw when chocolatey flakes; '
          'that regressed the whole Desktop workflow on runs +130/+132',
    );
    expect(
      smoke,
      contains('::warning title=Fixture ffmpeg unavailable'),
      reason: 'a persistent fixture-ffmpeg outage must surface a visible '
          'warning, not a silent pass',
    );
    expect(
      smoke,
      contains('exit 0'),
      reason: 'when only the reference fixture is unavailable the step skips '
          'the comparison smoke and exits 0 instead of failing the release',
    );
  });

  test('ffmpeg smoke fixture generation does not require the minimal binary',
      () {
    final String smoke = readRepositoryTool('ffmpeg-min/smoke-test.sh');

    expect(
      smoke,
      contains(r'FIXTURE_FFMPEG="${FIXTURE_FFMPEG:-ffmpeg}"'),
      reason:
          'fixture generation should default to a full host ffmpeg while FFMPEG_MIN exercises runtime extraction paths',
    );
    expect(
      smoke,
      isNot(contains('SELF_CONTAINED_FIXTURES')),
      reason:
          'do not add a path that asks the minimal runtime ffmpeg to author representative MP4/MKV fixtures',
    );
    expect(
      smoke,
      isNot(contains('-c:v mpeg4')),
      reason:
          'mpeg4 fixture authoring would pressure the minimal build to ship input-generation-only encoders/muxers',
    );
  });
}
