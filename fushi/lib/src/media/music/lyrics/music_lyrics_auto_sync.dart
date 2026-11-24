/// 纯文本歌词自动对时（拍板台 niQk_Ns4OV）：没有时间轴的歌词（Genius 这类来源只给纯文本）
/// 拿这首歌的本机 ASR 转录（音乐库「生成日语字幕」，歌曲档位先做人声分离）当时间参照，
/// 逐行定时间，结果存成本地 LRC（`music_lyrics` 的 `user` 行，`format = lrc`）。显示的仍是
/// 拿到的歌词原文，转录只当时钟。
///
/// 对齐算法（拖音、和声、重复段）在上游 `fushi-subtitles` 的 `alignLyricsToTranscript`；
/// 本文件只做装配：时间轴 ↔ 上游输入、上游结果 → LRC 原文。存取在 `MusicLyricsService`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show
        AlignedLyricsLine,
        LyricsAlignment,
        LyricsLineKind,
        RetimingTranscription,
        SubtitleCue,
        alignLyricsToTranscript;
import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_music/fushi_music.dart';

/// 对时结果的落库格式（`music_lyrics.format`）。
const String kMusicLyricsAutoSyncFormat = 'lrc';

/// 一次自动对时的结局。
enum MusicLyricsAutoSyncStatus {
  /// 对好并存成了本地 LRC（已是这首的手动指定）。
  synced,

  /// 这首还没有生成字幕（ASR 转录）：要先生成。
  needsTranscript,

  /// 转录与歌词对不上（多半不是同一首、没人声或识别全错），没存。
  unreliable,

  /// 没有可对的歌词行（当前歌词不是纯文本 / 全是段落标记）。
  noPlainLyrics,

  /// 转录落库后接着跑的对时出错（对齐超限、解析失败等），错误在 [MusicLyricsAutoSyncOutcome.error]。
  failed,
}

/// 一次自动对时的结果（界面据此提示）。
class MusicLyricsAutoSyncOutcome {
  const MusicLyricsAutoSyncOutcome(
    this.status, {
    this.lines = 0,
    this.anchoredLines = 0,
    this.error,
  });

  final MusicLyricsAutoSyncStatus status;

  /// 写进 LRC 的行数（[MusicLyricsAutoSyncStatus.synced] 时）。
  final int lines;

  /// 其中逐字对上、可信的行数。
  final int anchoredLines;

  /// [MusicLyricsAutoSyncStatus.failed] 时的错误说明。
  final String? error;
}

/// 后台对时（转录完成后才跑）的结果事件。
typedef MusicLyricsAutoSyncEvent = ({
  String trackUid,
  MusicLyricsAutoSyncOutcome outcome,
});

/// 纯函数：时间轴能不能拿来自动对时——没有时间（纯文本）且有字。
bool musicLyricsCanAutoSync(LyricTimeline? timeline) =>
    timeline != null &&
    timeline.timingQuality == LyricTimingQuality.unsynced &&
    timeline.lines.any((LyricLine l) => l.text.trim().isNotEmpty);

/// 纯函数：纯文本时间轴 → 要对的歌词行（主唱行原文；和声行也唱，一并保留）。
List<String> musicPlainLyricsLines(LyricTimeline plain) => <String>[
  for (final LyricLine l in plain.lines) l.text,
];

/// 纯函数：生成字幕（ASR）时间轴 → 上游对齐的转录输入。只取有字、有时长的行，按起点排。
RetimingTranscription musicTranscriptOf(LyricTimeline transcript) =>
    _Transcript(<SubtitleCue>[
      for (final (int i, LyricLine l) in (List<LyricLine>.of(
        transcript.lines,
      )..sort((LyricLine a, LyricLine b) => a.startMs - b.startMs)).indexed)
        if (l.text.trim().isNotEmpty && l.endMs > l.startMs)
          SubtitleCue(
            index: i + 1,
            startMs: l.startMs < 0 ? 0 : l.startMs,
            endMs: l.endMs,
            text: l.text,
          ),
    ]);

class _Transcript implements RetimingTranscription {
  const _Transcript(this.cues);

  @override
  final List<SubtitleCue> cues;

  // 生成字幕只落了 SRT / TTML，逐 token 时间在任务目录里、与切片后的行对不上：不用。
  @override
  List<AsrCueTokenTiming>? get tokenTimings => null;
}

/// 后台 isolate 里对齐（上游纯 Dart 算法）。
Future<LyricsAlignment> alignMusicPlainLyrics(
  LyricTimeline plain,
  LyricTimeline transcript, {
  int? durationMs,
}) => alignLyricsToTranscript(
  musicPlainLyricsLines(plain),
  musicTranscriptOf(transcript),
  durationMs: durationMs,
);

/// LRC 的一行：起点 + 原文。
typedef MusicLrcLine = ({int startMs, String text});

/// 纯函数：对齐结果里有时间的行（段落标记、空行不唱、不进 LRC）。
List<MusicLrcLine> musicAlignedLrcLines(LyricsAlignment alignment) =>
    <MusicLrcLine>[
      for (final AlignedLyricsLine l in alignment.lines)
        if (l.kind == LyricsLineKind.sung && l.startMs != null)
          (startMs: l.startMs!, text: l.text.trim()),
    ];

/// 纯函数：最后一行的终点（LRC 用一行空时间戳收尾，最后一句不会一直亮到曲终）。
int? musicAlignedLrcEndMs(LyricsAlignment alignment) {
  int? end;
  for (final AlignedLyricsLine l in alignment.lines) {
    if (l.kind == LyricsLineKind.sung && l.endMs != null) end = l.endMs;
  }
  return end;
}

/// 纯函数：写 LRC 原文。时间戳 `[mm:ss.xx]`（百分之一秒），起点严格递增（取整撞在同一
/// 百分秒上时往后挪一格）；[endMs] 非 null 时末尾补一行空时间戳。[title] / [artist] 写成
/// `[ti:]` / `[ar:]` 头。
String buildMusicLrc(
  List<MusicLrcLine> lines, {
  int? endMs,
  String? title,
  String? artist,
}) {
  final StringBuffer out = StringBuffer();
  final String? ti = _header(title);
  final String? ar = _header(artist);
  if (ti != null) out.writeln('[ti:$ti]');
  if (ar != null) out.writeln('[ar:$ar]');
  int previous = -1;
  for (final MusicLrcLine l in lines) {
    int cs = (l.startMs < 0 ? 0 : l.startMs) ~/ 10;
    if (cs <= previous) cs = previous + 1;
    previous = cs;
    out.writeln('${_stamp(cs)}${l.text.replaceAll(RegExp(r'[\r\n]+'), ' ')}');
  }
  if (endMs != null && lines.isNotEmpty) {
    int cs = endMs ~/ 10;
    if (cs <= previous) cs = previous + 1;
    out.writeln(_stamp(cs));
  }
  return out.toString();
}

String? _header(String? value) {
  final String? v = value
      ?.replaceAll(RegExp(r'[\r\n\[\]]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return v == null || v.isEmpty ? null : v;
}

String _stamp(int centiseconds) {
  final int m = centiseconds ~/ 6000;
  final int s = (centiseconds ~/ 100) % 60;
  final int c = centiseconds % 100;
  return '[${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      '.${c.toString().padLeft(2, '0')}]';
}

/// 纯函数：对齐结果 → LRC 原文字节（UTF-8）。没有一行有时间返回 null。
Uint8List? musicAlignedLrc(
  LyricsAlignment alignment, {
  String? title,
  String? artist,
}) {
  final List<MusicLrcLine> lines = musicAlignedLrcLines(alignment);
  if (lines.isEmpty) return null;
  return utf8.encode(
    buildMusicLrc(
      lines,
      endMs: musicAlignedLrcEndMs(alignment),
      title: title,
      artist: artist,
    ),
  );
}

/// 纯函数（字幕工作台逐行微调）：把一份逐行时间轴的第 [index] 行起点改成 [startMs]，夹在
/// 前一行起点之后、后一行起点之前（不改行序），重写成 LRC。[index] 越界或时间轴不是逐行
/// 时间返回 null。
Uint8List? musicLrcWithLineStart(
  LyricTimeline timeline,
  int index,
  int startMs, {
  String? title,
  String? artist,
}) {
  final List<LyricLine> lines = timeline.lines;
  if (index < 0 || index >= lines.length || !timeline.isSynced) return null;
  final int lo = index == 0 ? 0 : lines[index - 1].startMs + 10;
  final int? hi = index + 1 < lines.length
      ? lines[index + 1].startMs - 10
      : null;
  int start = startMs < lo ? lo : startMs;
  if (hi != null && start > hi) start = hi < lo ? lo : hi;
  final List<MusicLrcLine> out = <MusicLrcLine>[
    for (int i = 0; i < lines.length; i++)
      (startMs: i == index ? start : lines[i].startMs, text: lines[i].text),
  ];
  final int lastEnd = lines.last.endMs;
  return utf8.encode(
    buildMusicLrc(
      out,
      endMs: lastEnd > out.last.startMs ? lastEnd : null,
      title: title,
      artist: artist,
    ),
  );
}
