import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-209 / TODO-398 source guard: Windows WGC structured native logging +
/// minidump install contract. Host cannot run WGC (Windows-only API), so we use
/// source-scan guards to pin invariants that cannot be behavior-tested on host:
/// log always-compiled, key lifecycle points instrumented, FrameArrived success
/// path not per-frame logged, crash dump handler installed and chained.
String _read(List<String> candidates, String name) {
  final File? f = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(f, isNotNull, reason: '$name not found');
  return f!.readAsStringSync();
}

void main() {
  test('WGC structured native log is always compiled (not gated by NDEBUG)',
      () {
    final String logHeader = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/utils/wgc_log.h',
      '../packages/flutter_inappwebview_windows/windows/utils/wgc_log.h',
    ], 'wgc_log.h');
    final String logSrc = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/utils/wgc_log.cpp',
      '../packages/flutter_inappwebview_windows/windows/utils/wgc_log.cpp',
    ], 'wgc_log.cpp');

    expect(logHeader.contains('#ifndef NDEBUG'), isFalse,
        reason:
            'wgc_log.h must not gate WgcLog under #ifndef NDEBUG (Release must compile it)');
    expect(logSrc.contains('#ifndef NDEBUG'), isFalse,
        reason: 'wgc_log.cpp must not gate writing under #ifndef NDEBUG');
    expect(logSrc.contains('#ifdef _DEBUG'), isFalse,
        reason: 'wgc_log.cpp must not gate writing under #ifdef _DEBUG');

    expect(logSrc.contains('CreateFileW'), isTrue,
        reason:
            'WgcLog must use raw Win32 CreateFileW (zero heap alloc on crash path)');
    expect(logSrc.contains('WriteFile'), isTrue,
        reason: 'WgcLog must use raw Win32 WriteFile');
    expect(logSrc.contains('FOLDERID_LocalAppData'), isTrue,
        reason:
            'WgcLog must locate path via SHGetKnownFolderPath(FOLDERID_LocalAppData)');
    expect(logSrc.contains('Hibiki'), isTrue,
        reason:
            'WgcLog must write under LOCALAPPDATA Hibiki (same path as Dart fold-in)');
    // TODO-398 regression: native wide-string path literals must use an
    // escaped double backslash. A single backslash separator is an illegal
    // escape -- MSVC raises C4129 and drops it, so the log would land at
    // "...LocalAppDataHibikiwgc_capture.log" and the Dart reader
    // (Hibiki + separator + wgc_capture.log) never finds it. Pin it here.
    expect(logSrc.contains(r'L"\\Hibiki"'), isTrue,
        reason:
            r'wgc_log.cpp must use escaped separator L"\\Hibiki", not single backslash');
    expect(logSrc.contains(r'L"\\wgc_capture.log"'), isTrue,
        reason:
            r'wgc_log.cpp must use escaped separator L"\\wgc_capture.log", not single backslash');
    expect(RegExp(r'L"\\[^\\]').hasMatch(logSrc), isFalse,
        reason:
            r'no single-backslash path literal allowed -- MSVC C4129 drops the separator');
    expect(logSrc.contains('GetCurrentThreadId'), isTrue,
        reason: 'log line must carry thread id');
    expect(logSrc.contains('GetSystemTime'), isTrue,
        reason: 'log line must carry timestamp');
  });

  test(
      'texture_bridge.cc instruments key WGC lifecycle points; FrameArrived success path not per-frame logged',
      () {
    final String src = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ], 'texture_bridge.cc');

    expect(src.contains('#include "../utils/wgc_log.h"'), isTrue,
        reason: 'texture_bridge.cc must include wgc_log.h');

    for (final String evt in <String>[
      'create-pool',
      'retire',
      'stop',
      'recreate',
      'createSession-fail',
      'startCapture-fail',
      'retire-close-start',
      'retire-remove-start',
      'retire-remove',
      'retire-register-start',
      'retire-register',
      'handler-release-done',
    ]) {
      expect(src.contains('WgcLog::Write("$evt"'), isTrue,
          reason: 'texture_bridge.cc must log WgcLog at lifecycle point: $evt');
    }

    final int retireStart =
        src.indexOf('void TextureBridge::RetireFramePoolLocked()');
    expect(retireStart, greaterThanOrEqualTo(0));
    final int retireEnd = src.indexOf('void TextureBridge::', retireStart + 1);
    final String retireBody = src.substring(retireStart, retireEnd);
    expect(retireBody.contains('WgcLog::Write("retire"'), isTrue,
        reason:
            'RetireFramePoolLocked must log the retired frame pool pointer (crash forensics)');

    final int ofaStart = src.indexOf('void TextureBridge::OnFrameArrived()');
    expect(ofaStart, greaterThanOrEqualTo(0));
    final String ofaBody = src.substring(ofaStart);
    expect(ofaBody.contains('WgcLog::Write("frame-getfail"'), isTrue,
        reason: 'OnFrameArrived TryGetNextFrame failure should be observable');
    final int frameAvailIdx = ofaBody.indexOf('frame_available_()');
    expect(frameAvailIdx, greaterThanOrEqualTo(0));
    final String afterDeliver = ofaBody.substring(frameAvailIdx);
    expect(afterDeliver.contains('WgcLog::Write'), isFalse,
        reason:
            'No WgcLog after successful frame delivery (per-frame fire would flood disk)');
  });

  test(
      'runner installs process-level minidump filter and chains the previous filter',
      () {
    final String mainCpp = _read(<String>[
      'hibiki/windows/runner/main.cpp',
      'windows/runner/main.cpp',
    ], 'main.cpp');
    final String crashCpp = _read(<String>[
      'hibiki/windows/runner/crash_dump.cpp',
      'windows/runner/crash_dump.cpp',
    ], 'crash_dump.cpp');

    final int installIdx = mainCpp.indexOf('InstallCrashDumpHandler()');
    final int coInitIdx = mainCpp.indexOf('CoInitializeEx');
    expect(installIdx, greaterThanOrEqualTo(0),
        reason: 'main.cpp must call InstallCrashDumpHandler');
    expect(coInitIdx, greaterThan(installIdx),
        reason:
            'crash dump handler must be installed before CoInitializeEx / Flutter engine');

    expect(crashCpp.contains('MiniDumpWriteDump'), isTrue,
        reason: 'crash_dump.cpp must use MiniDumpWriteDump');
    expect(crashCpp.contains('SetUnhandledExceptionFilter'), isTrue,
        reason: 'crash_dump.cpp must SetUnhandledExceptionFilter');
    expect(crashCpp.contains('g_previous_filter'), isTrue,
        reason: 'crash_dump.cpp must save the previous filter');
    expect(
        RegExp(r'return\s+g_previous_filter\s*\(').hasMatch(crashCpp), isTrue,
        reason: 'must chain back to previous filter after writing own dump');
    expect(crashCpp.contains('FOLDERID_LocalAppData'), isTrue,
        reason:
            'dump must be written into LOCALAPPDATA app dir, not relying on system WER');
    expect(crashCpp.contains('Hibiki'), isTrue,
        reason:
            'dump dir should share LOCALAPPDATA Hibiki root with wgc_capture.log');
    // TODO-398 regression: same escaped-double-backslash invariant as
    // wgc_log.cpp. A single backslash literal is C4129 in MSVC and drops the
    // separator, so dumps would land at a malformed concatenated path.
    expect(crashCpp.contains(r'L"\\Hibiki"'), isTrue,
        reason:
            r'crash_dump.cpp must use escaped separator L"\\Hibiki", not single backslash');
    expect(crashCpp.contains(r'L"\\crashdumps"'), isTrue,
        reason:
            r'crash_dump.cpp must use escaped separator L"\\crashdumps", not single backslash');
    expect(crashCpp.contains(r'L"\\hibiki-"'), isTrue,
        reason:
            r'crash_dump.cpp must use escaped separator L"\\hibiki-", not single backslash');
    expect(RegExp(r'L"\\[^\\]').hasMatch(crashCpp), isFalse,
        reason:
            r'no single-backslash path literal allowed -- MSVC C4129 drops the separator');
  });

  test(
      'Dart startup folds WGC log into ErrorLogService upload chain (Windows only)',
      () {
    final String mainDart = _read(<String>[
      'hibiki/lib/main.dart',
      'lib/main.dart',
    ], 'main.dart');
    expect(mainDart.contains('WgcCaptureLog.foldIntoErrorLog()'), isTrue,
        reason:
            'main.dart must fold WGC log at startup (into existing upload chain)');
  });
}
