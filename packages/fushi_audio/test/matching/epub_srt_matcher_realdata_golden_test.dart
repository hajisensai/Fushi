// 真实书对拍（不入 CI：书与字幕有版权，不入库；缺数据目录时跳过——缺的是数据，
// 不是原生库，原生库缺失照样失败）。
//
// FUSHI_MATCH_REALDATA_DIR 下每本书三份文件：
//   <名>.sections.json  EPUB 章节（{i,h,t,r:[[start,end,reading]...]} 数组，由
//                       fushi_engine 的 epubSectionsFromBook 导出）
//   <名>.srt            字幕（SubPlz 或设备端转录产物）
//   <名>.golden.tsv     旧 Dart 实现（算法搬进 native/fushi_compute 之前）的输出；本测试
//                       只读其中 `window=<w> matched=<n>` 起的逐窗口块：每行
//                       `cueSentenceIndex\tsectionIndex\tnormCharStart\tnormCharEnd\tscore`
// 每本书对三档窗口逐条比对（score 按 Dart 最短往返十进制比字符串 = 逐位一致）。
@Tags(<String>['realdata'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

void main() {
  final String dir = Platform.environment['FUSHI_MATCH_REALDATA_DIR'] ?? '';
  final List<File> goldens = dir.isEmpty || !Directory(dir).existsSync()
      ? const <File>[]
      : (Directory(dir)
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.golden.tsv'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path)));

  if (goldens.isEmpty) {
    test('真实书对拍', () {}, skip: 'FUSHI_MATCH_REALDATA_DIR 未设置或没有夹具');
    return;
  }

  for (final File golden in goldens) {
    final String stem = golden.path.substring(
      0,
      golden.path.length - '.golden.tsv'.length,
    );
    test('真实书 ${stem.split(Platform.pathSeparator).last} 三档窗口逐条一致', () async {
      final List<dynamic> js =
          jsonDecode(File('$stem.sections.json').readAsStringSync())
              as List<dynamic>;
      final List<EpubSection> sections = <EpubSection>[
        for (final dynamic x in js)
          EpubSection(
            index: x['i'] as int,
            href: x['h'] as String,
            text: x['t'] as String,
            rubies: <EpubRubySpan>[
              for (final dynamic r in x['r'] as List<dynamic>)
                EpubRubySpan(
                  start: r[0] as int,
                  end: r[1] as int,
                  reading: r[2] as String,
                ),
            ],
          ),
      ];
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: File('$stem.srt'),
        bookKey: 'realdata',
      );
      final Map<int, List<String>> expected = <int, List<String>>{};
      List<String>? current;
      for (final String line in golden.readAsLinesSync()) {
        if (line.startsWith('window=')) {
          final int w = int.parse(line.split(' ').first.substring(7));
          current = expected[w] = <String>[];
          continue;
        }
        current?.add(line);
      }
      expect(expected.keys, isNotEmpty);
      for (final MapEntry<int, List<String>> e in expected.entries) {
        final MatchResult r = EpubSrtMatcher.match(
          sections: sections,
          cues: cues,
          searchWindow: e.key,
        );
        final List<String> actual = <String>[
          for (final CueMatch m in r.matches)
            '${m.cueSentenceIndex}\t${m.sectionIndex}\t${m.normCharStart}\t'
                '${m.normCharEnd}\t${m.score}',
        ];
        expect(actual.length, e.value.length, reason: 'window=${e.key}');
        for (int i = 0; i < actual.length; i++) {
          expect(actual[i], e.value[i], reason: 'window=${e.key} cue#$i');
        }
      }
    });
  }
}
