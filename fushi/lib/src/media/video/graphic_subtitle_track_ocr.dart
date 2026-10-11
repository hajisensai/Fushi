/// 整轨图形字幕（PGS / VobSub / DVB）→ 文字 SRT：抽轨 → 解码位图 cue → 逐条 OCR（低置信度
/// 交 AI，与漫画同一开关）→ 合并相邻同文 → 写 SRT。生成的 SRT 当普通外挂文字字幕加载，
/// 播放中即可直接点字查词，不必暂停。
///
/// 抽轨与解码（纯 Dart，无头服务端回传整轨也用同一份）住在引擎
/// `package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart`，
/// 这里只留 OCR 与 SRT 这一层，并把引擎侧的抽取 / 解码 API 一并导出给 app 调用方。
library;

import 'dart:async';

import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';

export 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
export 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart'
    show BitmapSubtitleCodec, bitmapSubtitleCodecOf;
export 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_input.dart';
export 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart';

/// 一条识别出文字的字幕。
class GraphicSubtitleTextCue {
  const GraphicSubtitleTextCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

/// 一页 OCR 结果 → 字幕文字：块内各行直接拼接，块之间换行。
String graphicSubtitleTextOf(MokuroImage image) => image.blocks
    .map((MokuroBlock b) => b.lines.join().trim())
    .where((String s) => s.isNotEmpty)
    .join('\n');

/// 边看边识别往播放器里刷新文字字幕的最小间隔：每次刷新都会重置控制器的当前句状态，
/// 不逐条刷，攒一小批再换。
const Duration kGraphicSubtitleLivePublishInterval = Duration(
  milliseconds: 1500,
);

/// 边看边识别时下一条该识别的 cue：优先「还没播完」的第一条未开始识别的 cue（离播放头
/// 最近的将要出现的字幕先有字），播放头之后全开始了再回头补前面的。都开始了返回 null。
int? pickNextGraphicSubtitleCue(
  List<BitmapSubtitleCue> cues,
  Set<int> startedStarts,
  int positionMs,
) {
  int? firstPending;
  for (int i = 0; i < cues.length; i++) {
    if (startedStarts.contains(cues[i].startMs)) continue;
    if (cues[i].endMs > positionMs) return i;
    firstPending ??= i;
  }
  return firstPending;
}

List<GraphicSubtitleTextCue> _collectRecognized(
  List<BitmapSubtitleCue> cues,
  Map<int, String> texts,
) => <GraphicSubtitleTextCue>[
  for (final BitmapSubtitleCue cue in cues)
    if (texts[cue.startMs] case final String text)
      GraphicSubtitleTextCue(
        startMs: cue.startMs,
        endMs: cue.endMs,
        text: text,
      ),
];

/// 边抽轨边识别（边看边 OCR）：抽轨进程还在写载荷时就按 [snapshot]（通常是
/// [readGraphicSubtitleTrackInBackground]）反复读出已落盘的 cue，按
/// [pickNextGraphicSubtitleCue] 的顺序（播放头附近优先）识别，同时在途
/// [GraphicSubtitleOcrSession.subtitleParallelism] 条；每有一条出字（本地结果，或
/// 大模型重读回来的新文字）就把「目前已识别的全部 cue」（按时间升序）交给
/// [onRecognized]，页面据此把字幕实时补进可点 overlay。编码无关：PGS / VobSub / DVB 的
/// cue 都是 [BitmapSubtitleCue]。
///
/// - [sourceComplete] 为假时最后一条 cue 不识别：它可能还没收尾（解码器给没有结束信号的
///   尾 cue 兜底时长，后续包会改它的结束时间）。其余 cue 的起止由自身的结束信号或后一个
///   包决定，不会因文件继续增长而改变，所以按起点认身份、识别过的不再重做；
/// - 识别追上抽轨时等 [sourceDone] 或 [pollInterval] 再读；
/// - 本地全部识别完后等大模型重读收尾（[onAiProgress] 报进度），再返回最终文字；
/// - [isCancelled] 为真 / 会话关闭返回 null；识别不可用抛 [GraphicSubtitleOcrUnavailable]。
///
/// [render] 把 cue 渲染成像素（默认后台 isolate；测试可注入同步实现）。
/// 返回全部识别结果（升序）。[onProgress] 报 (已识别, 目前已知总数)。
Future<List<GraphicSubtitleTextCue>?> recognizeGraphicSubtitleCuesLive({
  required Future<List<BitmapSubtitleCue>> Function() snapshot,
  required bool Function() sourceComplete,
  required Future<void> sourceDone,
  required GraphicSubtitleOcrSession session,
  required int Function() positionMs,
  required bool Function() isCancelled,
  void Function(List<GraphicSubtitleTextCue> recognized)? onRecognized,
  void Function(int done, int known)? onProgress,
  void Function(int done, int total)? onAiProgress,
  void Function(Object error, StackTrace stack)? onRefineError,
  Future<BitmapSubtitleImage> Function(BitmapSubtitleCue cue)? render,
  Duration pollInterval = const Duration(milliseconds: 800),
  Duration resnapshotEvery = const Duration(seconds: 2),
}) async {
  final Future<BitmapSubtitleImage> Function(BitmapSubtitleCue cue) renderCue =
      render ?? renderGraphicSubtitleCueInBackground;
  final int parallelism = await session.subtitleParallelism();
  final Map<int, String> texts = <int, String>{};
  final Set<int> started = <int>{};
  int recognized = 0;
  int inFlight = 0;
  bool closed = false;
  Object? failure;
  StackTrace? failureStack;
  Completer<void>? changed;
  void signal() {
    final Completer<void>? c = changed;
    changed = null;
    c?.complete();
  }

  List<BitmapSubtitleCue> latest = const <BitmapSubtitleCue>[];
  void emit() => onRecognized?.call(_collectRecognized(latest, texts));

  void launch(BitmapSubtitleCue cue) {
    final int start = cue.startMs;
    started.add(start);
    inFlight++;
    unawaited(() async {
      try {
        final BitmapSubtitleImage image = await renderCue(cue);
        if (isCancelled()) return;
        final String? text = await session.recognizeSubtitleImage(
          image,
          onRefined: (String refined) {
            if (isCancelled()) return;
            texts[start] = refined;
            emit();
          },
          onRefineError: onRefineError,
        );
        if (text == null) {
          closed = true;
          return;
        }
        if (isCancelled()) return;
        // 大模型可能比本地慢一步也可能先到（同图去重）：已有重读文字就不回退。
        texts.putIfAbsent(start, () => text);
        recognized++;
        onProgress?.call(recognized, latest.length);
        emit();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      } finally {
        inFlight--;
        signal();
      }
    }());
  }

  Future<void> waitChange() => (changed ??= Completer<void>()).future;

  Future<void> drainInFlight() async {
    while (inFlight > 0) {
      await waitChange();
    }
  }

  while (true) {
    if (isCancelled() || closed) {
      await drainInFlight();
      return null;
    }
    if (failure != null) {
      await drainInFlight();
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    // 先读完成标志再读文件：标志为真时读到的必然是完整产物。
    final bool complete = sourceComplete();
    final List<BitmapSubtitleCue> all = await snapshot();
    if (isCancelled()) continue;
    latest = complete || all.isEmpty ? all : all.sublist(0, all.length - 1);
    final Stopwatch sw = Stopwatch()..start();
    bool progressed = false;
    while (complete || sw.elapsed < resnapshotEvery) {
      if (isCancelled() || closed || failure != null) break;
      while (inFlight < parallelism) {
        final int? i = pickNextGraphicSubtitleCue(
          latest,
          started,
          positionMs(),
        );
        if (i == null) break;
        launch(latest[i]);
        progressed = true;
      }
      if (inFlight == 0) break;
      await waitChange();
    }
    if (isCancelled() || closed || failure != null) continue;
    if (complete && inFlight == 0) break;
    if (!progressed && inFlight == 0) {
      await Future.any(<Future<void>>[
        sourceDone,
        Future<void>.delayed(pollInterval),
      ]);
    }
  }
  await session.drainSubtitleRefinements(onProgress: onAiProgress);
  if (isCancelled() || session.isClosed) return null;
  return _collectRecognized(latest, texts);
}

/// 合并相邻同文：跳过空文字；时间上首尾相接（间隔 ≤ [joinGapMs]）且文字相同的相邻
/// cue 合并成一条（PGS 常把同一句拆成多次显示：淡入淡出、换位置）。
List<GraphicSubtitleTextCue> mergeGraphicSubtitleTextCues(
  List<GraphicSubtitleTextCue> cues, {
  int joinGapMs = 50,
}) {
  final List<GraphicSubtitleTextCue> merged = <GraphicSubtitleTextCue>[];
  for (final GraphicSubtitleTextCue cue in cues) {
    if (cue.text.trim().isEmpty || cue.endMs <= cue.startMs) continue;
    final GraphicSubtitleTextCue? last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.text == cue.text &&
        cue.startMs - last.endMs <= joinGapMs) {
      merged[merged.length - 1] = GraphicSubtitleTextCue(
        startMs: last.startMs,
        endMs: cue.endMs > last.endMs ? cue.endMs : last.endMs,
        text: last.text,
      );
      continue;
    }
    merged.add(cue);
  }
  return merged;
}

/// 识别结果 → 可点 overlay 用的 cue（合并规则与 SRT 相同，边看边识别实时喂播放器）。
List<AudioCue> graphicSubtitleAudioCues(List<GraphicSubtitleTextCue> cues) {
  final List<GraphicSubtitleTextCue> merged = mergeGraphicSubtitleTextCues(
    cues,
  );
  return <AudioCue>[
    for (int i = 0; i < merged.length; i++)
      AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = i
        ..textFragmentId = ''
        ..text = merged[i].text
        ..startMs = merged[i].startMs
        ..endMs = merged[i].endMs
        ..audioFileIndex = 0,
  ];
}

/// 生成 SRT（相邻同文合并见 [mergeGraphicSubtitleTextCues]）。
String buildGraphicSubtitleSrt(
  List<GraphicSubtitleTextCue> cues, {
  int joinGapMs = 50,
}) {
  final List<GraphicSubtitleTextCue> merged = mergeGraphicSubtitleTextCues(
    cues,
    joinGapMs: joinGapMs,
  );
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < merged.length; i++) {
    final GraphicSubtitleTextCue c = merged[i];
    sb
      ..writeln(i + 1)
      ..writeln('${_srtTime(c.startMs)} --> ${_srtTime(c.endMs)}')
      ..writeln(c.text)
      ..writeln();
  }
  return sb.toString();
}

String _srtTime(int ms) {
  String two(int v) => v.toString().padLeft(2, '0');
  final int h = ms ~/ 3600000;
  final int m = (ms ~/ 60000) % 60;
  final int s = (ms ~/ 1000) % 60;
  return '${two(h)}:${two(m)}:${two(s)},${(ms % 1000).toString().padLeft(3, '0')}';
}
