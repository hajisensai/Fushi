// 离线评测：segments.jsonl（转录检查点，或候选模型按同格式产出的替身）
// → AsrCueBuilder → transcript.srt + tokens sidecar → 与 app 相同的对齐收尾链
// → transcript.aligned.srt。不跑 ASR、不碰数据库，用于 cue 构建 / 匹配层 A/B。
//
//   dart run tool/asr_rebuild_eval.dart <epub> <segments.jsonl> <输出作业目录> [extractDir]
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final String epub = args[0];
  final String segmentsPath = args[1];
  final String jobDir = args[2];
  final String extractDir = args.length > 3
      ? args[3]
      : p.join(Directory.systemTemp.path, 'asr_rebuild_eval_$pid');
  Directory(jobDir).createSync(recursive: true);
  final List<AsrTranscribedSegment> segments = <AsrTranscribedSegment>[
    for (final String line in File(segmentsPath).readAsLinesSync())
      if (line.trim().isNotEmpty)
        AsrTranscribedSegment.fromJson(
          (jsonDecode(line) as Map<Object?, Object?>).cast<String, Object?>(),
        ),
  ];
  // -DTAIL_PAD=-1 复现旧段尾（外扩边界），用于基线对照。
  const int tailPad = int.fromEnvironment('TAIL_PAD', defaultValue: 80);
  final List<AsrCue> asrCues = const AsrCueBuilder(
    tailPadMs: tailPad,
  ).build(segments);
  final String srt = p.join(jobDir, AsrJobFiles.srt);
  File(srt).writeAsStringSync(serializeAsrCuesToSrt(asrCues));
  File(
    p.join(jobDir, AsrJobFiles.cueTokens),
  ).writeAsStringSync(serializeAsrCueTokens(asrCues));
  // 检查点旁的 state.json（各文件时长）与能量包络一起带过来，对齐收尾里的
  // 句界吸附才能跑；没有就写空状态（只当作「是转录产物」的标记）。
  final String srcDir = p.dirname(segmentsPath);
  final File srcState = File(p.join(srcDir, AsrJobFiles.state));
  if (srcState.existsSync()) {
    srcState.copySync(p.join(jobDir, AsrJobFiles.state));
  } else {
    File(p.join(jobDir, AsrJobFiles.state)).writeAsStringSync('{}');
  }
  for (final FileSystemEntity e in Directory(srcDir).listSync()) {
    final String name = p.basename(e.path);
    if (e is File &&
        name.startsWith('transcript.energy.') &&
        srcDir != jobDir) {
      e.copySync(p.join(jobDir, name));
    }
  }

  final Stopwatch sw = Stopwatch()..start();
  final List<EpubSection> sections = epubSectionsFromBook(
    EpubParser.parseSyncFromPath(epub, extractDir),
  );
  final List<AudioCue> cues = await parseCuesForFormat(File(srt), 'eval', 0);
  final bool timing = await attachAsrCueTokenTiming(cues, srt);
  final ProbeResult probe = await EpubCueMatcher.probeInIsolate(
    sections: sections,
    cues: cues,
  );
  final MatchResult result =
      probe.bestResult ??
      await EpubCueMatcher.matchInIsolate(sections: sections, cues: cues);
  final ({List<AudioCue> cues, MatchResult result}) done =
      await finalizeAlignedCues(
        sections: sections,
        cues: cues,
        result: result,
        subtitlePath: srt,
        hasTokenTiming: timing,
      );
  // 只含命中书文的 cue（Hoshi 等按文本游标匹配的外部播放器用）。
  File(p.join(jobDir, 'transcript.matched.srt')).writeAsStringSync(
    serializeAudioCuesToSrt(<AudioCue>[
      for (int i = 0; i < done.cues.length; i++)
        if (done.result.matches[i].matched) done.cues[i],
    ]),
  );
  stdout.writeln(
    'segments=${segments.length} asrCues=${asrCues.length} '
    'final=${done.cues.length} matched=${done.result.matchedCues}/'
    '${done.result.totalCues} window=${probe.best?.key} timing=$timing '
    'align=${sw.elapsedMilliseconds}ms',
  );
}
