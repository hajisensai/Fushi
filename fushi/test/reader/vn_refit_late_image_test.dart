@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';
import 'package:fushi_core/fushi_core.dart';

/// VN 屏表重切的两条行为，都用生产 VN shell + 生产 VN CSS 在真 Chrome 里跑。
///
/// ① 开关工具栏（`setChromeInsets`）：下发值没变不重切；值变了但当前屏内容没变时只重切
///    屏表，屏上 DOM、选区与逐字显现原样保留；内容真的变了才重渲。此前每次都整章重量
///    一遍并 `renderScreen(index, true)`，把正在逐字显现的屏直接补完、清掉选区。
/// ② 首屏不等图片：`initialize` 此前要等整章每张 `<img>` 的 load / error，没有时限，
///    一张不结束的图让首屏永远不出。现在先按已知信息切屏，图到了再复核归类并重切。
void main() {
  Future<void> runHarness(String harness, String passLine) async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS execution');
      return;
    }
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setViewMode('vn');
    await settings.setWritingMode('vertical-rl');
    final String css = ReaderContentStyles.css(settings: settings);

    final ({int exitCode, String stdout, String stderr}) result =
        await _runNodeHarness(nodeExe, harness, <String, String>{
          'shell': ReaderVisualNovelScripts.vnShellScript(),
          'selection': ReaderSelectionScripts.source(),
          'units': '$kStudyUnitJs\n$kSentenceAudioOwnershipJs',
          'css': css,
        });
    if (result.exitCode == 77) {
      markTestSkipped('Chrome unavailable: ${result.stdout}');
      return;
    }
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains(passLine));
  }

  test(
    'VN setChromeInsets keeps the current screen (DOM, reveal) unless its '
    'content changed',
    () => runHarness(
      'test/reader/vn_chrome_insets_keep_screen_harness.mjs',
      'PASS VN chrome insets keep screen',
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'VN first screen does not wait for images; a late image re-cuts the '
    'chapter and lands back on the same screen',
    () => runHarness(
      'test/reader/vn_late_image_harness.mjs',
      'PASS VN late image',
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// Runs a Node harness with [payload] piped as JSON on stdin (no file path
/// crosses the process boundary) and returns its exit code, stdout and stderr.
Future<({int exitCode, String stdout, String stderr})> _runNodeHarness(
  String nodeExe,
  String harness,
  Map<String, String> payload,
) async {
  final Process process = await Process.start(nodeExe, <String>[harness]);
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(jsonEncode(payload)));
  await process.stdin.close();
  return (
    exitCode: await process.exitCode,
    stdout: await stdout,
    stderr: await stderr,
  );
}

/// Resolve Node before launching the browser harness so missing CI tools skip.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
