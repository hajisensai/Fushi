/// 「制作有声书」的分章与编码：章节分组、ffconcat 清单、cue 时间轴、续跑用的章清单
/// sidecar，以及一章逐句音频 → 一个 m4a 的 ffmpeg 调用。
///
/// 除 [encodeTtsChapterAudio] 外都是纯函数，单测直接覆盖。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// 成品里的一章 = 一个音频文件。
class TtsRenderChapter {
  const TtsRenderChapter({
    required this.fileIndex,
    required this.section,
    required this.planIndices,
  });

  /// 成品音频列表里的下标（= cue 的 `audioFileIndex`）。
  final int fileIndex;

  /// EPUB spine 下标。
  final int section;

  /// 本章各句在整书计划里的下标（计划顺序）。
  final List<int> planIndices;

  /// 工作目录 / 持久目录里的文件名主干（`tts_000`）。
  String get stem => ttsRenderFileStem(fileIndex);
}

String ttsRenderFileStem(int fileIndex) =>
    'tts_${fileIndex.toString().padLeft(3, '0')}';

/// 计划 → 按章分组（保持计划顺序）。[sections] 为空 = 全书，否则只留这些章。
List<TtsRenderChapter> groupTtsRenderChapters(
  List<TtsPlanSentence> sentences, {
  Set<int> sections = const <int>{},
}) {
  final List<TtsRenderChapter> chapters = <TtsRenderChapter>[];
  int? currentSection;
  List<int> current = <int>[];
  void flush() {
    if (current.isEmpty || currentSection == null) return;
    chapters.add(
      TtsRenderChapter(
        fileIndex: chapters.length,
        section: currentSection,
        planIndices: List<int>.unmodifiable(current),
      ),
    );
    current = <int>[];
  }

  for (int i = 0; i < sentences.length; i++) {
    final int section = sentences[i].section;
    if (sections.isNotEmpty && !sections.contains(section)) continue;
    if (section != currentSection) {
      flush();
      currentSection = section;
    }
    current.add(i);
  }
  flush();
  return chapters;
}

/// concat demuxer 清单。每个文件带 `duration`：demuxer 用它（而不是自己探测的时长）
/// 推下一个文件的时间戳起点，配合编码端的 `aresample=async` 让成品时间轴与按缓存时长
/// 累加出来的 cue 时间轴一致（MP3 的编码延迟 / 帧填充不会逐句累积成漂移）。
///
/// 路径转正斜杠、按 concat 的单引号规则转义（`'` → `'\''`），配 `-safe 0` 使用。
/// 不在末尾重复最后一个文件（那是图片序列的写法，音频会多出一段）。
String buildTtsConcatList(List<({String path, int durationMs})> entries) {
  String quote(String path) {
    final String normalized = path.replaceAll('\\', '/');
    return "'${normalized.replaceAll("'", r"'\''")}'";
  }

  final StringBuffer buffer = StringBuffer('ffconcat version 1.0\n');
  for (final ({String path, int durationMs}) entry in entries) {
    buffer
      ..writeln('file ${quote(entry.path)}')
      ..writeln('duration ${(entry.durationMs / 1000).toStringAsFixed(3)}');
  }
  return buffer.toString();
}

/// 一章的 cue（时间相对本章文件）。[durationsMs] 与 [TtsRenderChapter.planIndices]
/// 一一对应，句与句首尾相接。
List<AudioCue> buildTtsChapterCues({
  required String bookKey,
  required List<TtsPlanSentence> sentences,
  required TtsRenderChapter chapter,
  required List<int> durationsMs,
}) {
  if (durationsMs.length != chapter.planIndices.length) {
    throw ArgumentError.value(
      durationsMs.length,
      'durationsMs',
      'expected ${chapter.planIndices.length} durations',
    );
  }
  final List<AudioCue> cues = <AudioCue>[];
  int cursor = 0;
  for (int k = 0; k < chapter.planIndices.length; k++) {
    final int index = chapter.planIndices[k];
    final TtsPlanSentence s = sentences[index];
    final int end = cursor + durationsMs[k];
    cues.add(
      AudioCue()
        ..bookKey = bookKey
        ..chapterHref = s.href
        ..sentenceIndex = index
        ..text = s.text
        ..textFragmentId = SubtitleRematchCodec.encodeHit(
          sectionIndex: s.section,
          normCharStart: s.matchStart,
          normCharEnd: s.matchEnd,
        )
        ..startMs = cursor
        ..endMs = end
        ..audioFileIndex = chapter.fileIndex,
    );
    cursor = end;
  }
  return cues;
}

/// 逐文件 cue → 单时间轴副本（写 SRT 用；文件 i 的起点 = 前面各文件时长之和）。
/// 文件时长取各文件 cue 的最大 `endMs`，与播放器 / 进度换算同一口径
/// （[audiobookFileDurationsFromCues]）。
List<AudioCue> ttsCuesOnSingleTimeline(List<AudioCue> perFileCues) {
  final List<int> durations = audiobookFileDurationsFromCues(perFileCues);
  final List<int> offsets = List<int>.filled(durations.length, 0);
  for (int i = 1; i < durations.length; i++) {
    offsets[i] = offsets[i - 1] + durations[i - 1];
  }
  return <AudioCue>[
    for (final AudioCue c in perFileCues)
      AudioCue()
        ..bookKey = c.bookKey
        ..chapterHref = c.chapterHref
        ..sentenceIndex = c.sentenceIndex
        ..text = c.text
        ..textFragmentId = c.textFragmentId
        ..startMs = c.startMs + offsets[c.audioFileIndex]
        ..endMs = c.endMs + offsets[c.audioFileIndex]
        ..audioFileIndex = 0,
  ];
}

/// 已编码一章的 sidecar：按序的缓存键 + 每句时长。键序一致才算同一章（续跑跳过
/// 重编码与重合成——缓存里的逐句音频这时可能早被淘汰了，时长只能从这里取）。
class TtsChapterManifest {
  const TtsChapterManifest({
    required this.section,
    required this.keys,
    required this.durationsMs,
  });

  static const int _version = 1;

  final int section;
  final List<String> keys;
  final List<int> durationsMs;

  bool matches(int section, List<String> keys) {
    if (section != this.section || keys.length != this.keys.length) {
      return false;
    }
    for (int i = 0; i < keys.length; i++) {
      if (keys[i] != this.keys[i]) return false;
    }
    return true;
  }

  String encode() => jsonEncode(<String, Object?>{
    'v': _version,
    'section': section,
    'keys': keys,
    'durationsMs': durationsMs,
  });

  /// 解析失败 / 版本不符 / 长度不一致返回 null（调用方当作没编码过）。
  static TtsChapterManifest? decode(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final Object? v = json['v'], section = json['section'];
    final Object? keys = json['keys'], durations = json['durationsMs'];
    if (v != _version ||
        section is! int ||
        keys is! List ||
        durations is! List) {
      return null;
    }
    final List<String> k = <String>[
      for (final Object? e in keys)
        if (e is String) e,
    ];
    final List<int> d = <int>[
      for (final Object? e in durations)
        if (e is int && e > 0) e,
    ];
    if (k.length != keys.length || d.length != durations.length) return null;
    if (k.length != d.length) return null;
    return TtsChapterManifest(section: section, keys: k, durationsMs: d);
  }
}

/// 读一章已编码成品的 sidecar；成品或 sidecar 缺失 / 损坏返回 null。
Future<TtsChapterManifest?> readTtsChapterManifest(
  Directory workDir,
  TtsRenderChapter chapter,
) async {
  final File audio = File(p.join(workDir.path, '${chapter.stem}.m4a'));
  final File sidecar = File(p.join(workDir.path, '${chapter.stem}.json'));
  if (!await audio.exists() || await audio.length() == 0) return null;
  if (!await sidecar.exists()) return null;
  return TtsChapterManifest.decode(await sidecar.readAsString());
}

/// 一章编码的 ffmpeg 参数。桌面 ffmpeg-min 没有 ipod 封装器，`.m4a` 必须显式
/// `-f mp4`；`aresample=async=1:min_hard_comp=0.01` 按清单时间戳补静音 / 丢样本，
/// 让成品时间轴贴住 [buildTtsConcatList] 的 `duration`。
List<String> buildTtsChapterEncodeArgs({
  required String listPath,
  required String outputPath,
}) => <String>[
  '-y',
  '-f',
  'concat',
  '-safe',
  '0',
  '-i',
  listPath,
  '-vn',
  '-af',
  'aresample=async=1:min_hard_comp=0.010:first_pts=0',
  '-c:a',
  'aac',
  '-b:a',
  '96k',
  '-f',
  'mp4',
  outputPath,
];

/// 一章编码没进度多久算卡死。
const Duration kTtsEncodeStallTimeout = Duration(seconds: 90);

/// 把 [entries] 编码成 [outputPath]（先写同目录临时文件，成功后改名）。
///
/// 取消抛 [TtsRenderCancelled]；失败抛 `TtsRenderFailure('encode_failed')`，
/// 失败摘要（退出码 + stderr 摘要）先交给 [onFailure] 记日志。
Future<void> encodeTtsChapterAudio({
  required FfmpegBackend backend,
  required List<({String path, int durationMs})> entries,
  required String outputPath,
  required TtsRenderCancelToken cancel,
  required void Function(String summary) onFailure,
}) async {
  cancel.throwIfCancelled();
  final String listPath = p.setExtension(outputPath, '.ffconcat');
  final String partPath = '${p.withoutExtension(outputPath)}.part.m4a';
  final File list = File(listPath);
  final File part = File(partPath);
  await list.parent.create(recursive: true);
  await list.writeAsString(buildTtsConcatList(entries), flush: true);

  final Completer<void> cancelled = Completer<void>();
  cancel.onCancel(() {
    if (!cancelled.isCompleted) cancelled.complete();
  });
  final List<String> args = buildTtsChapterEncodeArgs(
    listPath: listPath,
    outputPath: partPath,
  );
  int totalMs = 0;
  for (final ({String path, int durationMs}) e in entries) {
    totalMs += e.durationMs;
  }
  try {
    final FfmpegRunResult result = switch (backend) {
      final FfmpegWatchedRunner watched => await watched.runWatched(
        args,
        FfmpegWatch(
          stallTimeout: kTtsEncodeStallTimeout,
          cancel: cancelled.future,
        ),
      ),
      // 不支持观察式运行的后端（测试替身 / 未知后端）：按时长给总预算。
      final FfmpegBackend plain => await plain.run(
        args,
        kTtsEncodeStallTimeout + Duration(milliseconds: totalMs ~/ 2),
      ),
    };
    cancel.throwIfCancelled();
    if (!result.isSuccess || !await part.exists() || await part.length() == 0) {
      onFailure(result.failureSummary);
      throw const TtsRenderFailure('encode_failed');
    }
    final File out = File(outputPath);
    if (await out.exists()) await out.delete();
    await part.rename(outputPath);
  } finally {
    if (await part.exists()) await part.delete();
    if (await list.exists()) await list.delete();
  }
}
