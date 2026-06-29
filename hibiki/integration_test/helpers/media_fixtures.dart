// 程序化生成有声书 / 视频 / 字幕测试素材的生成器。
//
// 设计目标：seed / e2e 测试不依赖用户私人文件，全部素材按确定性算法生成。
// - 纯 Dart 部分（[buildSampleCues] + 4 种字幕文本生成 + [buildAudiobookEpubBytes]）
//   无副作用、无设备依赖，可在 `flutter test` 下用真实 parser 做 roundtrip 断言。
// - 音视频部分（[generateSilentAudio] / [generateTestVideo]）走项目自带的
//   ffmpeg 后端（[resolveFfmpegBackend]）；CI 无 ffmpeg，仅保证编译，真实产出
//   由真机 e2e 验证。
//
// 字幕格式严格对齐各 parser（见 packages/hibiki_audio/lib/src/parsers/）：
// 时间码一律输出 3 位毫秒，落进各 parser `\d{1,3}` + `padRight(3,'0')` 的
// 接受区间，保证 ms 级精确 roundtrip（ASS/LRC 的 2 位厘秒精度也接受 3 位）。

import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 与各 parser 共用的默认章节标识（`srt://default`）。
const String kFixtureChapterHref = SrtParser.defaultChapter;

/// 一组确定性的日文示例句（无逗号 / 无 `-->` / 无 `{}` / 无 `\N`，
/// 对四种字幕格式都安全，不会被任一 parser 的标签剥离或分隔逻辑改写）。
const List<String> _kSampleSentences = <String>[
  '吾輩は猫である。',
  '名前はまだない。',
  'どこで生れたかとんと見当がつかぬ。',
  '何でも薄暗いじめじめした所で泣いていた事だけは記憶している。',
  '吾輩はここで始めて人間というものを見た。',
];

/// 构造一组示例 cue，供字幕生成与有声书播种共用。
///
/// 每条 cue 时长 2000ms，句间留 500ms 间隙：start_i = i*2500，end_i = start_i+2000。
/// 起止单调递增、时长为正，文本循环取自 [_kSampleSentences]。
List<AudioCue> buildSampleCues({
  required String bookKey,
  String chapterHref = kFixtureChapterHref,
  int count = 5,
}) {
  const int cueDurationMs = 2000;
  const int gapMs = 500;
  final List<AudioCue> cues = <AudioCue>[];
  for (int i = 0; i < count; i++) {
    final int startMs = i * (cueDurationMs + gapMs);
    cues.add(AudioCue()
      ..bookKey = bookKey
      ..chapterHref = chapterHref
      ..sentenceIndex = i
      ..textFragmentId = '[data-cue-id="$i"]'
      ..text = _kSampleSentences[i % _kSampleSentences.length]
      ..startMs = startMs
      ..endMs = startMs + cueDurationMs
      ..audioFileIndex = 0);
  }
  return cues;
}

/// 把 cue 列表生成 SubRip（.srt）文本，时间码 `HH:MM:SS,mmm`。
String cuesToSrt(List<AudioCue> cues) {
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < cues.length; i++) {
    final AudioCue c = cues[i];
    sb.writeln(i + 1);
    sb.writeln('${_srtTimecode(c.startMs)} --> ${_srtTimecode(c.endMs)}');
    sb.writeln(c.text);
    sb.writeln();
  }
  return sb.toString();
}

/// 把 cue 列表生成 WebVTT（.vtt）文本，时间码 `HH:MM:SS.mmm`。
String cuesToVtt(List<AudioCue> cues) {
  final StringBuffer sb = StringBuffer();
  sb.writeln('WEBVTT');
  sb.writeln();
  for (int i = 0; i < cues.length; i++) {
    final AudioCue c = cues[i];
    sb.writeln(i + 1);
    sb.writeln('${_vttTimecode(c.startMs)} --> ${_vttTimecode(c.endMs)}');
    sb.writeln(c.text);
    sb.writeln();
  }
  return sb.toString();
}

/// 把 cue 列表生成 LRC（歌词）文本，时间标签 `[MM:SS.mmm]`。
///
/// LRC 不携带 endMs（由下一条 startMs 推导），故只写入每条 cue 的 start。
String cuesToLrc(List<AudioCue> cues) {
  final StringBuffer sb = StringBuffer();
  sb.writeln('[ti:Hibiki Fixture]');
  sb.writeln('[ar:Hibiki]');
  sb.writeln();
  for (final AudioCue c in cues) {
    sb.writeln('[${_lrcTimecode(c.startMs)}]${c.text}');
  }
  return sb.toString();
}

/// 把 cue 列表生成 ASS（Advanced SubStation Alpha）文本。
///
/// 时间码 `H:MM:SS.mmm`（输出 3 位小数，落进 AssParser `\d{1,3}` 接受区间，
/// `padRight(3,'0')` 对 3 位是 no-op，保证 ms 精确 roundtrip）。
String cuesToAss(List<AudioCue> cues) {
  final StringBuffer sb = StringBuffer();
  sb.writeln('[Script Info]');
  sb.writeln('Title: Hibiki Fixture');
  sb.writeln('ScriptType: v4.00+');
  sb.writeln();
  sb.writeln('[V4+ Styles]');
  sb.writeln('Format: Name, Fontname, Fontsize');
  sb.writeln('Style: Default,Arial,20');
  sb.writeln();
  sb.writeln('[Events]');
  sb.writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');
  for (final AudioCue c in cues) {
    sb.writeln(
      'Dialogue: 0,${_assTimecode(c.startMs)},${_assTimecode(c.endMs)},'
      'Default,,0,0,0,,${c.text}',
    );
  }
  return sb.toString();
}

/// 用项目的 [CuesToEpub] 把 cue 列表打包成 EPUB3 字节（带
/// `data-cue-id/data-start/data-end`，供有声书高亮定位）。薄封装，写临时文件
/// 再读回字节（[CuesToEpub.convert] 只产出 [File]）。
Future<Uint8List> buildAudiobookEpubBytes({
  required String title,
  required List<AudioCue> cues,
}) async {
  final Directory dir = await Directory.systemTemp.createTemp('hibiki_fixture');
  try {
    final String outPath = '${dir.path}/fixture.epub';
    final File epub = await CuesToEpub.convert(
      title: title,
      cues: cues,
      outputPath: outPath,
    );
    return await epub.readAsBytes();
  } finally {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}

/// 用 ffmpeg 造一段静音 AAC 音频（`anullsrc`），返回产出文件。
///
/// 失败时抛 [StateError]（带 ffmpeg 失败摘要），调用方按需捕获。
Future<File> generateSilentAudio({
  required String outPath,
  Duration duration = const Duration(seconds: 3),
}) async {
  final int seconds = _ffmpegDurationSeconds(duration);
  final FfmpegBackend backend = resolveFfmpegBackend();
  final List<String> args = <String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=mono',
    '-t',
    '$seconds',
    '-c:a',
    'aac',
    outPath,
  ];
  final FfmpegRunResult result =
      await backend.run(args, const Duration(seconds: 60));
  if (!result.isSuccess) {
    throw StateError('generateSilentAudio failed: ${result.failureSummary}');
  }
  return File(outPath);
}

/// 用 ffmpeg 造一段测试视频（`testsrc` 画面 + `anullsrc` 静音轨）。
///
/// 视频编码 mpeg4（需完整 ffmpeg；捆绑/系统 PATH 上的 ffmpeg 均可），
/// 音频 aac。失败时抛 [StateError]。
Future<File> generateTestVideo({
  required String outPath,
  Duration duration = const Duration(seconds: 2),
}) async {
  final int seconds = _ffmpegDurationSeconds(duration);
  final FfmpegBackend backend = resolveFfmpegBackend();
  final List<String> args = <String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=320x240:rate=10',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=mono',
    '-t',
    '$seconds',
    '-c:v',
    'mpeg4',
    '-c:a',
    'aac',
    outPath,
  ];
  final FfmpegRunResult result =
      await backend.run(args, const Duration(seconds: 120));
  if (!result.isSuccess) {
    throw StateError('generateTestVideo failed: ${result.failureSummary}');
  }
  return File(outPath);
}

// ── 时间码格式化 ────────────────────────────────────────────────────────────

int _ffmpegDurationSeconds(Duration duration) {
  final int s = duration.inSeconds;
  return s > 0 ? s : 1;
}

/// SRT：`HH:MM:SS,mmm`。
String _srtTimecode(int ms) {
  final _Hms t = _Hms.fromMs(ms);
  return '${_p2(t.h)}:${_p2(t.m)}:${_p2(t.s)},${_p3(t.ms)}';
}

/// VTT：`HH:MM:SS.mmm`。
String _vttTimecode(int ms) {
  final _Hms t = _Hms.fromMs(ms);
  return '${_p2(t.h)}:${_p2(t.m)}:${_p2(t.s)}.${_p3(t.ms)}';
}

/// LRC：`MM:SS.mmm`（小时折进分钟）。
String _lrcTimecode(int ms) {
  final _Hms t = _Hms.fromMs(ms);
  final int totalMinutes = t.h * 60 + t.m;
  return '${_p2(totalMinutes)}:${_p2(t.s)}.${_p3(t.ms)}';
}

/// ASS：`H:MM:SS.mmm`（小时不补零，与 ASS 惯例一致）。
String _assTimecode(int ms) {
  final _Hms t = _Hms.fromMs(ms);
  return '${t.h}:${_p2(t.m)}:${_p2(t.s)}.${_p3(t.ms)}';
}

String _p2(int v) => v.toString().padLeft(2, '0');
String _p3(int v) => v.toString().padLeft(3, '0');

/// 毫秒拆成 时:分:秒.毫秒。
class _Hms {
  const _Hms(this.h, this.m, this.s, this.ms);

  final int h;
  final int m;
  final int s;
  final int ms;

  factory _Hms.fromMs(int totalMs) {
    final int h = totalMs ~/ 3600000;
    final int m = (totalMs % 3600000) ~/ 60000;
    final int s = (totalMs % 60000) ~/ 1000;
    final int ms = totalMs % 1000;
    return _Hms(h, m, s, ms);
  }
}
