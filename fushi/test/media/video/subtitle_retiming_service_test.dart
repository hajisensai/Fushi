import 'dart:io';

import 'package:fushi/src/media/video/subtitle_retiming_service.dart';
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

AudioCue _cue(String text, int startMs, int endMs) {
  final AudioCue cue = AudioCue();
  cue.bookKey = 'video';
  cue.chapterHref = '';
  cue.sentenceIndex = 0;
  cue.textFragmentId = '';
  cue.text = text;
  cue.startMs = startMs;
  cue.endMs = endMs;
  cue.audioFileIndex = 0;
  return cue;
}

/// 造一份 SRT 文本（当 ASR 转录产物用）。
String _srt(List<(String, int, int)> rows) {
  String stamp(int ms) {
    final int h = ms ~/ 3600000;
    final int m = (ms % 3600000) ~/ 60000;
    final int s = (ms % 60000) ~/ 1000;
    final int rest = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')},${rest.toString().padLeft(3, '0')}';
  }

  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < rows.length; i++) {
    final (String text, int start, int end) = rows[i];
    buf.writeln('${i + 1}');
    buf.writeln('${stamp(start)} --> ${stamp(end)}');
    buf.writeln(text);
    buf.writeln();
  }
  return buf.toString();
}

void main() {
  group('retimingCuesFromAudioCues', () {
    test('保留正常 cue 并按剔除后的次序重编 1-based 序号', () {
      final RetimingInputCues input = retimingCuesFromAudioCues(<AudioCue>[
        _cue('первый', 0, 1000),
        _cue('second', 2000, 3000),
      ]);

      expect(input.droppedCount, 0);
      expect(input.cues.map((SubtitleCue c) => c.index), <int>[1, 2]);
      expect(input.cues.first.text, 'первый');
      expect(input.cues.last.startMs, 2000);
    });

    test('剔掉退化 cue：空正文 / 零长 / 逆序 / 负起点，并如实计数', () {
      final RetimingInputCues input = retimingCuesFromAudioCues(<AudioCue>[
        _cue('keep', 0, 1000),
        _cue('   ', 1000, 2000), // 空白正文
        _cue('zero', 2000, 2000), // 零长
        _cue('reversed', 4000, 3000), // 逆序
        _cue('negative', -5, 100), // 负起点
        _cue('tail', 5000, 6000),
      ]);

      expect(input.droppedCount, 4);
      expect(
          input.cues.map((SubtitleCue c) => c.text), <String>['keep', 'tail']);
      // 序号必须连续，否则渲染出的 SRT 序号会有洞。
      expect(input.cues.map((SubtitleCue c) => c.index), <int>[1, 2]);
    });

    test('全部退化时判空，调用方据此不跑对轴', () {
      expect(retimingCuesFromAudioCues(<AudioCue>[_cue('', 0, 0)]).isEmpty,
          isTrue);
      expect(retimingCuesFromAudioCues(<AudioCue>[]).isEmpty, isTrue);
    });
  });

  group('retimedSubtitleFileName', () {
    test('剥掉原扩展名，产出 .retimed.srt', () {
      expect(retimedSubtitleFileName('ep01.zh.ass'), 'ep01.zh.retimed.srt');
      expect(retimedSubtitleFileName('movie.mkv'), 'movie.retimed.srt');
      expect(retimedSubtitleFileName('nodots'), 'nodots.retimed.srt');
    });

    test('档名被占用时补序号，不覆盖上一次的结果', () {
      expect(
        retimedSubtitleFileName('ep01.mkv',
            taken: <String>{'ep01.retimed.srt'}),
        'ep01.retimed-2.srt',
      );
      expect(
        retimedSubtitleFileName(
          'ep01.mkv',
          taken: <String>{'ep01.retimed.srt', 'ep01.retimed-2.srt'},
        ),
        'ep01.retimed-3.srt',
      );
    });

    test('空名兜底，不产出以点开头的档名', () {
      expect(retimedSubtitleFileName('   '), 'subtitle.retimed.srt');
      expect(retimedSubtitleFileName('.srt'), 'srt.retimed.srt');
    });
  });

  group('retimedSubtitleSummary', () {
    RetimedSubtitleFile file(Map<String, Object?> stats) => RetimedSubtitleFile(
          path: 'x.srt',
          cueCount: 0,
          droppedInputCues: 0,
          stats: stats,
        );

    test('命中率取整成百分比', () {
      final summary = retimedSubtitleSummary(
        file(<String, Object?>{
          'inputCues': 8,
          'matchedCues': 3,
          'medianShiftMs': -420,
        }),
      );
      expect(summary.matched, 3);
      expect(summary.total, 8);
      expect(summary.percent, 38); // 37.5 -> 38
      expect(summary.medianShiftMs, -420);
    });

    test('缺失或类型不对的统计按 0 处理，不抛也不除零', () {
      final summary = retimedSubtitleSummary(
        file(<String, Object?>{'inputCues': 'oops'}),
      );
      expect(summary.total, 0);
      expect(summary.percent, 0);
      expect(summary.medianShiftMs, 0);
    });
  });

  group('AsrRetimingTranscription.fromTranscriptSrt', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_retime_');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('文件不存在返回 null', () async {
      expect(
        await AsrRetimingTranscription.fromTranscriptSrt(
          p.join(dir.path, 'missing.srt'),
        ),
        isNull,
      );
    });

    test('非法 SRT 返回 null 而不是抛', () async {
      final File file = File(p.join(dir.path, 'bad.srt'));
      await file.writeAsString('这不是字幕');
      expect(
        await AsrRetimingTranscription.fromTranscriptSrt(file.path),
        isNull,
      );
    });

    test('合法 SRT 读出 cue；没有 sidecar 时 tokenTimings 为 null', () async {
      final File file = File(p.join(dir.path, 'ok.srt'));
      await file.writeAsString(_srt(<(String, int, int)>[
        ('hello there', 1200, 2200),
        ('second line', 3200, 4200),
      ]));

      final AsrRetimingTranscription? transcription =
          await AsrRetimingTranscription.fromTranscriptSrt(file.path);

      expect(transcription, isNotNull);
      expect(transcription!.cues.length, 2);
      expect(transcription.cues.first.startMs, 1200);
      expect(transcription.tokenTimings, isNull);
    });
  });

  group('retimeVideoSubtitleToFile', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_retime_out_');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<String> writeTranscript(List<(String, int, int)> rows) async {
      final File file = File(p.join(dir.path, 'transcript.srt'));
      await file.writeAsString(_srt(rows));
      return file.path;
    }

    test('按 ASR 锚点把整体偏掉的字幕拉回来，并落一份新档', () async {
      // 字幕整体早了 2 秒；ASR 转录给出真实时间。
      const List<String> lines = <String>[
        'the quick brown fox jumps',
        'over the lazy dog again',
        'pack my box with five dozen',
      ];
      final String transcript = await writeTranscript(<(String, int, int)>[
        (lines[0], 10000, 12000),
        (lines[1], 14000, 16000),
        (lines[2], 18000, 20000),
      ]);

      final RetimedSubtitleFile? out = await retimeVideoSubtitleToFile(
        subtitleCues: <AudioCue>[
          _cue(lines[0], 8000, 10000),
          _cue(lines[1], 12000, 14000),
          _cue(lines[2], 16000, 18000),
        ],
        transcriptSrtPath: transcript,
        outputDirectory: dir,
        baseName: 'ep01.mkv',
      );

      expect(out, isNotNull);
      expect(p.basename(out!.path), 'ep01.retimed.srt');
      expect(File(out.path).existsSync(), isTrue);
      expect(out.droppedInputCues, 0);
      expect(out.matchedCues, greaterThan(0));

      final List<SubtitleCue> written =
          parseRetimingSubtitles(await File(out.path).readAsString());
      expect(written.length, 3);
      // 正文一个字都不许动。
      expect(written.map((SubtitleCue c) => c.text), lines);
      // 时间被拉到了转录给的位置（允许算法在锚点上留少量余量）。
      expect((written.first.startMs - 10000).abs(), lessThan(500));
      expect((written.last.startMs - 18000).abs(), lessThan(500));
    });

    test('转录读不出来时返回 null，不留半份档', () async {
      final File bad = File(p.join(dir.path, 'bad.srt'));
      await bad.writeAsString('nonsense');

      final RetimedSubtitleFile? out = await retimeVideoSubtitleToFile(
        subtitleCues: <AudioCue>[_cue('hello there', 0, 1000)],
        transcriptSrtPath: bad.path,
        outputDirectory: dir,
        baseName: 'ep01.mkv',
      );

      expect(out, isNull);
      expect(
        dir.listSync().where(
            (FileSystemEntity e) => p.basename(e.path).contains('retimed')),
        isEmpty,
      );
    });

    test('输入 cue 全退化时不跑对轴', () async {
      final String transcript = await writeTranscript(
          <(String, int, int)>[('anything at all', 0, 1000)]);

      expect(
        await retimeVideoSubtitleToFile(
          subtitleCues: <AudioCue>[_cue('  ', 0, 1000)],
          transcriptSrtPath: transcript,
          outputDirectory: dir,
          baseName: 'ep01.mkv',
        ),
        isNull,
      );
    });

    test('同一部片跑两次留下两份档，不覆盖上一次', () async {
      const String line = 'the quick brown fox jumps';
      final String transcript =
          await writeTranscript(<(String, int, int)>[(line, 10000, 12000)]);
      final List<AudioCue> cues = <AudioCue>[_cue(line, 8000, 10000)];

      final RetimedSubtitleFile? first = await retimeVideoSubtitleToFile(
        subtitleCues: cues,
        transcriptSrtPath: transcript,
        outputDirectory: dir,
        baseName: 'ep01.mkv',
      );
      final RetimedSubtitleFile? second = await retimeVideoSubtitleToFile(
        subtitleCues: cues,
        transcriptSrtPath: transcript,
        outputDirectory: dir,
        baseName: 'ep01.mkv',
      );

      expect(p.basename(first!.path), 'ep01.retimed.srt');
      expect(p.basename(second!.path), 'ep01.retimed-2.srt');
      expect(File(first.path).existsSync(), isTrue);
    });
  });
}
