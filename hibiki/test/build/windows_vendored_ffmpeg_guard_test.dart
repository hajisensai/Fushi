import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-416: ffmpeg.exe is vendored into the repo so the Windows desktop release
// is self-contained. Before this, release-desktop.yml downloaded ffmpeg.exe
// from another workflow (ffmpeg-min.yml) via `gh run download`; that artifact
// expires after 90 days and ffmpeg-min only ran manually, so the supply chain
// silently broke and Windows packages shipped with NO ffmpeg -> missing video
// covers/subtitles. These guards keep the vendored binary present and keep the
// release workflow copying it and its runtime DLLs instead of regressing to a
// cross-workflow fetch.
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

  // TODO-2701 (2): the Windows recipe links statically
  // (--extra-ldflags=-static --pkg-config-flags=--static), so zlib and pthread
  // are folded into the exe. libwinpthread-1.dll / zlib1.dll survived from the
  // pre-static MSYS2 generation and were pure dead weight: ffmpeg.exe's import
  // table never named them. This fence keeps them (and any other side-car
  // runtime DLL) from creeping back: the invariant is "the vendored Windows
  // directory holds nothing but the two exes", not "these two DLLs are absent".
  test('vendored Windows dir ships only the exes, no side-car runtime DLLs',
      () {
    final Directory dir = Directory('../third_party/ffmpeg-min/windows');
    expect(dir.existsSync(), isTrue, reason: 'missing ${dir.absolute.path}');
    final List<String> names = dir
        .listSync()
        .whereType<File>()
        .map((File f) => f.uri.pathSegments.last)
        .where((String n) => !n.endsWith('.md') && !n.endsWith('.txt'))
        .toList()
      ..sort();
    // Scale sentinel: an empty/moved directory must fail loudly rather than
    // satisfy "no DLLs found" vacuously.
    expect(names, <String>['ffmpeg.exe', 'ffprobe.exe'],
        reason: 'third_party/ffmpeg-min/windows must contain exactly the two '
            'statically-linked exes. Extra runtime DLLs mean the recipe stopped '
            'linking statically - fix build-ffmpeg-min.sh instead of shipping '
            'MinGW DLLs; missing exes mean the vendored payload is gone.');
  });

  test('vendored Windows exes import only system DLLs', () {
    // The DLL names a PE loads - both the import table and any LoadLibrary
    // call - exist as plain ASCII inside the binary, so a byte scan is enough
    // and needs no dumpbin/objdump. Anything outside this allowlist would have
    // to be shipped next to the exe on every user machine.
    const Set<String> systemDlls = <String>{
      'advapi32.dll',
      'bcrypt.dll',
      'kernel32.dll',
      'kernelbase.dll',
      'msvcrt.dll',
      'ole32.dll',
      'secur32.dll',
      'shell32.dll',
      'user32.dll',
      'ws2_32.dll',
    };
    final RegExp dllPattern = RegExp(r'[A-Za-z0-9_.-]+\.[Dd][Ll][Ll]');
    final List<File> exes = <File>[
      File('../third_party/ffmpeg-min/windows/ffmpeg.exe'),
      File('../third_party/ffmpeg-min/windows/ffprobe.exe'),
    ];
    for (final File exe in exes) {
      expect(exe.existsSync(), isTrue, reason: 'missing ${exe.absolute.path}');
      final String blob = String.fromCharCodes(exe.readAsBytesSync());
      final Set<String> referenced = dllPattern
          .allMatches(blob)
          .map((RegExpMatch m) => m.group(0)!.toLowerCase())
          .toSet();
      // Scale sentinel: a scan that finds no DLL name at all is broken, not
      // clean - every PE names at least kernel32.
      expect(referenced, contains('kernel32.dll'),
          reason: 'DLL-name scan of ${exe.path} found nothing recognisable; '
              'the guard would pass vacuously');
      expect(referenced.difference(systemDlls), isEmpty,
          reason: '${exe.path} references non-system DLLs '
              '${referenced.difference(systemDlls)}; the Windows recipe must '
              'keep linking statically so the exe ships alone (TODO-2701)');
    }
  });

  test(
      'release-desktop Windows job installs the vendored ffmpeg runtime into bundle',
      () {
    final String workflow = readWorkflow('release-desktop.yml');
    final String windowsJob = workflowJob(workflow, 'windows');

    // The install step must copy the committed binary from third_party into the
    // Windows Release runner directory next to the app exe.
    expect(
      windowsJob,
      contains(r'third_party\ffmpeg-min\windows'),
      reason: 'Windows job must source ffmpeg from the vendored third_party '
          'path (TODO-416)',
    );
    expect(windowsJob, contains('ffmpeg.exe'),
        reason: 'the install step must copy ffmpeg.exe into the bundle');
    expect(windowsJob, contains('ffprobe.exe'),
        reason: 'the install step must copy ffprobe.exe into the bundle '
            '(BUG-1420: embedded subtitle fonts and audio container tags '
            'degrade silently without it)');
    // TODO-2701 (2): the copy list itself must not resurrect the dead MinGW
    // runtime DLLs. They are gone from third_party, so naming them here would
    // make the step throw "Missing vendored ffmpeg-min runtime file" and block
    // every release. Scoped to the $runtimeFiles array on purpose: prose around
    // the step may legitimately mention the DLLs to explain why they are gone.
    final RegExp runtimeList = RegExp(r'\$runtimeFiles\s*=\s*@\(([^)]*)\)');
    final RegExpMatch? listMatch = runtimeList.firstMatch(windowsJob);
    expect(listMatch, isNotNull,
        reason: 'could not locate the \$runtimeFiles copy list in the Windows '
            'job; this guard cannot verify what gets shipped');
    final String copyList = listMatch!.group(1)!;
    expect(copyList, contains('ffmpeg.exe'));
    expect(copyList, contains('ffprobe.exe'));
    for (final String dead in <String>['libwinpthread-1.dll', 'zlib1.dll']) {
      expect(copyList, isNot(contains(dead)),
          reason: '$dead is no longer vendored (the Windows recipe links '
              'statically); copying it would hard-fail the release job');
    }
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
    final int installIndex = windowsJob
        .indexOf('Install vendored ffmpeg-min runtime into Windows bundle');
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

  // BUG-550 / TODO-1156: the vendored Windows ffmpeg.exe MUST be built in the
  // clean CI environment (ffmpeg-min.yml on a GitHub-hosted runner), never a
  // developer's local MSYS2 checkout. A locally-built n7.1.5 binary
  // (configure --prefix=/d/ffmpeg715/out) shipped in V35 and crashed on the
  // user's machine with exit -1414549496 (0xABAFB008) across all three video
  // mining ffmpeg calls (cue gif / frame / sentence audio), breaking video
  // mining entirely, while the CI-built predecessor (--prefix=/d/a/...) worked.
  // GitHub-hosted Windows runners always check out under D:\a\ (msys path
  // /d/a/<owner>/<repo>), so the configure string embedded in the PE binary
  // carries a stable CI signature. This fence rejects any re-vendored binary
  // that was built outside CI so the regression cannot silently return.
  test('vendored Windows ffmpeg.exe is a CI build, not a local dev build', () {
    final File ffmpeg = File('../third_party/ffmpeg-min/windows/ffmpeg.exe');
    expect(ffmpeg.existsSync(), isTrue);
    // Latin-1 keeps the embedded ASCII configure string byte-for-byte scannable.
    final String blob = String.fromCharCodes(ffmpeg.readAsBytesSync());
    expect(
      blob.contains('/d/a/'),
      isTrue,
      reason: 'vendored ffmpeg.exe must be built by ffmpeg-min.yml on a '
          'GitHub-hosted Windows runner (configure --prefix under /d/a/...); '
          'a locally-built binary crashed on the user with exit -1414549496 '
          '(BUG-550). Rebuild via `gh workflow run ffmpeg-min.yml` and vendor '
          'the CI artifact, never a local `/d/ffmpeg715`-style build.',
    );
    expect(
      blob.contains('/d/ffmpeg715'),
      isFalse,
      reason: 'the crashing V35 local-build marker /d/ffmpeg715 must never '
          'ship again (BUG-550 / TODO-1156).',
    );
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
