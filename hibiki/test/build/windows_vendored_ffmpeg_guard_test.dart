import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-416: ffmpeg.exe is vendored into the repo so the Windows desktop release
// is self-contained. Before this, release-desktop.yml downloaded ffmpeg.exe
// from another workflow (ffmpeg-min.yml) via `gh run download`; that artifact
// expires after 90 days and ffmpeg-min only ran manually, so the supply chain
// silently broke and Windows packages shipped with NO ffmpeg -> missing video
// covers/subtitles. These guards keep the vendored binary present and keep the
// release workflow copying it instead of regressing to a cross-workflow fetch.
void main() {
  String readWorkflow(String name) {
    final File file = File('../.github/workflows/$name');
    expect(file.existsSync(), isTrue,
        reason: 'expected workflow at ${file.absolute.path}');
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

  test('vendored Windows ffmpeg.exe is committed and is a real PE binary', () {
    final File ffmpeg = File('../third_party/ffmpeg-min/windows/ffmpeg.exe');
    expect(ffmpeg.existsSync(), isTrue,
        reason: 'vendored Windows ffmpeg must exist at '
            '${ffmpeg.absolute.path}; release-desktop.yml copies this file');

    final List<int> bytes = ffmpeg.readAsBytesSync();
    // A ~10MB-class ffmpeg, never an empty/LFS-pointer/placeholder file.
    expect(bytes.length, greaterThan(1024 * 1024),
        reason: 'vendored ffmpeg.exe is suspiciously small '
            '(${bytes.length} bytes) - likely a placeholder, not the binary');
    // MS-DOS / PE header magic "MZ".
    expect(bytes.length, greaterThanOrEqualTo(2));
    expect(bytes[0], equals(0x4D), reason: 'expected PE "MZ" magic byte 0');
    expect(bytes[1], equals(0x5A), reason: 'expected PE "MZ" magic byte 1');
  });

  test('release-desktop Windows job installs the vendored ffmpeg into bundle',
      () {
    final String workflow = readWorkflow('release-desktop.yml');
    final String windowsJob = workflowJob(workflow, 'windows');

    // The install step must copy the committed binary from third_party into the
    // Windows Release runner directory next to the app exe.
    expect(
      windowsJob,
      contains(r"third_party\ffmpeg-min\windows\ffmpeg.exe"),
      reason: 'Windows job must source ffmpeg from the vendored third_party '
          'path (TODO-416)',
    );
    expect(
      windowsJob,
      contains(r'hibiki\build\windows\x64\runner\Release'),
      reason: 'vendored ffmpeg must be installed into the Windows Release '
          'bundle directory so it ships next to the app exe',
    );
    expect(windowsJob, contains('Copy-Item'),
        reason: 'the install step must copy the vendored ffmpeg into the '
            'bundle');

    // The vendored copy must run after the Flutter build produced the bundle
    // directory but before the installer is compiled, so it lands in the
    // installer payload.
    final int buildIndex = windowsJob.indexOf('Build Windows release');
    final int installIndex =
        windowsJob.indexOf('Install vendored ffmpeg-min into Windows bundle');
    final int innoIndex = windowsJob.indexOf('Compile installer (Inno Setup)');
    expect(buildIndex, isNonNegative);
    expect(installIndex, isNonNegative,
        reason: 'missing the vendored ffmpeg install step');
    expect(innoIndex, isNonNegative);
    expect(buildIndex, lessThan(installIndex));
    expect(installIndex, lessThan(innoIndex));
  });

  test('release-desktop Windows job no longer fetches ffmpeg cross-workflow',
      () {
    final String workflow = readWorkflow('release-desktop.yml');

    // Regression fence: the old broken supply chain must stay gone.
    expect(workflow, isNot(contains('gh run download')),
        reason: 'must not download ffmpeg artifact from another workflow run '
            '(it expires after 90 days -> Windows ships without ffmpeg)');
    expect(workflow, isNot(contains('ffmpeg-min.yml')),
        reason: 'release-desktop must not reference the ffmpeg-min workflow '
            'for artifacts; the binary is vendored (TODO-416)');
    expect(workflow, isNot(contains('ffmpeg_min_run_id')),
        reason: 'the cross-workflow run-id input is dead once ffmpeg is '
            'vendored');
  });

  test('ffmpeg-min workflow has no deprecated branch push trigger', () {
    final String workflow = readWorkflow('ffmpeg-min.yml');
    expect(
      workflow,
      isNot(contains('worktree-card-glossary-and-video-subtitle-fixes')),
      reason: 'the temporary validation branch push trigger must be removed; '
          'workflow_dispatch is the only intended trigger',
    );
  });
}
