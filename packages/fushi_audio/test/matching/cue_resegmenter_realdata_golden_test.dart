// 真实书重切对拍（不入 CI：书与字幕有版权，不入库；缺数据目录时跳过）。
//
// FUSHI_MATCH_REALDATA_DIR 下每本书：`<名>.sections.json` + `<名>.srt`（格式见
// epub_srt_matcher_realdata_golden_test.dart），以及旧 Dart `_alignPositions`（搬进
// native/fushi_compute 之前）生成的 `<名>.reseg.golden.txt`：默认窗口匹配 → cue 补确定性
// token 时间（support/reseg_golden_support.dart）→ 默认参数重切，每条输出 cue 一行。
// 新实现逐行一致。
@Tags(<String>['realdata'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

import 'support/reseg_golden_support.dart';

void main() {
  final String dir = Platform.environment['FUSHI_MATCH_REALDATA_DIR'] ?? '';
  final List<File> goldens = dir.isEmpty || !Directory(dir).existsSync()
      ? const <File>[]
      : (Directory(dir)
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.reseg.golden.txt'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path)));

  if (goldens.isEmpty) {
    test('真实书重切对拍', () {}, skip: 'FUSHI_MATCH_REALDATA_DIR 未设置或没有夹具');
    return;
  }

  for (final File golden in goldens) {
    final String stem = golden.path.substring(
      0,
      golden.path.length - '.reseg.golden.txt'.length,
    );
    test('真实书 ${stem.split(Platform.pathSeparator).last} 重切逐行一致', () async {
      final List<EpubSection> sections = readRealdataSections(
        '$stem.sections.json',
      );
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: File('$stem.srt'),
        bookKey: 'realdata',
      );
      final MatchResult matched = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
      );
      final CueResegmentResult r = const CueSentenceResegmenter().resegment(
        sections: sections,
        cues: withSyntheticTokens(cues),
        result: matched,
      );
      final List<String> actual = describeResegment(r).split('\n');
      final List<String> expected = golden.readAsStringSync().split('\n');
      expect(actual.length, expected.length);
      for (int i = 0; i < actual.length; i++) {
        expect(actual[i], expected[i], reason: 'line $i');
      }
    });
  }
}
