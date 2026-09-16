import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2536：有声书从上一章连续读到新章，新章第一句之前的插图（章扉画 / 合并进
/// 宿主顶部的单图片章）既不触发图片等待、也不揭防剧透遮罩。
///
/// 根因：新文档里 cue 推进锚点 `__fushiPrevHighlight` 为空（载入后
/// `resetImagePauseAnchor` 归零），`__fushiImageBetween(null, el)` 直接返回 null，
/// 文档开头到第一句之间的图从不进暂停判定 / 揭遮罩区间。
///
/// 修法：reader 在音频跨章落地后的第一次真实 cue 高亮传 `fromChapterStart=true`
/// （`_consumeAudioChapterArrival`），JS 把 `document.body` 当作上一句锚点。手动跳章 /
/// 位置恢复不带标记，行为不变（章首图没被音频读到，不该暂停也不该揭）。
///
/// 两层守护：
/// ① 行为级——node 真执行 audiobook_bridge.dart 里切出的高亮 JS，在 fake DOM 上断言
///    章首图暂停 / 揭遮罩 / gaiji 不算插图 / 手动到达不触发 / 两条高亮路径都透传。
/// ② 源码级——reader 侧到达标记的接线不被回退。
void main() {
  test(
    'BUG-2536: chapter-start illustration pauses and unblurs on audio arrival '
    '(executes bridge JS via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }
      final File jsTest =
          File('test/media/audiobook/chapter_start_image_pause_test.js');
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );
      expect(
        result.exitCode,
        0,
        reason: 'BUG-2536 chapter-start image pause behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );

  group('reader wiring guard (BUG-2536)', () {
    final String reader = File(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    ).readAsStringSync();
    final String bridge = File(
      'lib/src/media/audiobook/audiobook_bridge.dart',
    ).readAsStringSync();

    test('音频跨章导航前记下到达章，图片章停留已落在目标宿主时不重复触发', () {
      expect(
        reader,
        contains(
            '_audioChapterArrivalSection = pausedOnTarget ? -1 : newSection;'),
        reason: '_handleCueCrossChapter 须在 _navigateToChapter 前记下到达章',
      );
      expect(reader, contains('Future<bool> _pauseThroughImageOnlyChapters('),
          reason: '图片章停留序列须回报是否已在目标宿主上停留过（TODO-1128 合并图）');
    });

    test('到达标记只在目标章落地后的第一次真实 cue 高亮消费', () {
      final int i = reader.indexOf('bool _consumeAudioChapterArrival(');
      expect(i, greaterThan(-1));
      final String fn = reader.substring(i, i + 500);
      expect(
          fn,
          contains(
              'if (cue == null || cue.textFragmentId.isEmpty) return false;'),
          reason: '未匹配 cue 的清高亮不消费标记，等第一条匹配 cue');
      expect(
          fn,
          contains(
              'if (_restoreInFlight || _currentChapter != section) return false;'),
          reason: '载入期瞬态 notify 不消费标记');
      expect(reader,
          contains('fromChapterStart: _consumeAudioChapterArrival(cue),'),
          reason: '_onCueChanged 的高亮须透传到达标记');
    });

    test('JS 桥两条高亮路径都把 fromChapterStart 透传到 __fushiImagePauseAdvance', () {
      expect(
          bridge,
          contains(
              'if (fromChapterStart && document.body) prev = document.body;'),
          reason: '章首到达以 document.body 为上一句锚点');
      expect(
          bridge,
          contains(
              '\${jsonEncode(raw)}, \$reveal, \$pauseEnabled, \$fromChapterStart);'),
          reason: 'sasayaki 路径 Dart→JS 须传 fromChapterStart');
      expect(bridge, contains("'\$fromChapterStart);}'"),
          reason: 'selector 路径 Dart→JS 须传 fromChapterStart');
    });
  });
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
