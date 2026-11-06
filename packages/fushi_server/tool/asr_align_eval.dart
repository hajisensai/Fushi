// 离线评测驱动：把一份转录作业目录（transcript.srt + transcript.tokens.jsonl +
// state.json）喂进与 app 落库前完全相同的对齐收尾链（probe → match →
// finalizeAlignedCues），输出 transcript.aligned.srt。不碰数据库。
//
//   dart run tool/asr_align_eval.dart <epub> <作业目录> [extractDir]
import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final String epub = args[0];
  final String jobDir = args[1];
  final String extractDir = args.length > 2
      ? args[2]
      : p.join(Directory.systemTemp.path, 'asr_align_eval_$pid');
  final Stopwatch sw = Stopwatch()..start();
  final List<EpubSection> sections = epubSectionsFromBook(
    EpubParser.parseSyncFromPath(epub, extractDir),
  );
  final String srt = p.join(jobDir, 'transcript.srt');
  List<AudioCue> cues = await parseCuesForFormat(File(srt), 'eval', 0);
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
  stdout.writeln(
    'cues=${done.cues.length} matched=${done.result.matchedCues}/'
    '${done.result.totalCues} window=${probe.best?.key} timing=$timing '
    'elapsed=${sw.elapsedMilliseconds}ms',
  );
}
