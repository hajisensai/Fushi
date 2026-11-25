/// 把一本已入库的有声书（EPUB 配音频，TTS 制作的或用户导入的都行）导出成单个
/// M4B：各音频文件 `-c copy` 拼接，章节标记来自 EPUB 目录（经 FFMETADATA），书名 /
/// 作者 / 封面写进元数据，单时间轴字幕作为 `mov_text` 字幕轨**封进 M4B 里**（反馈
/// iUtGmIlZiD：以前字幕另写一份旁挂 `.srt`、M4B 里既没有字幕也没有封面）。
///
/// 需要的 ffmpeg 能力（concat / ffmetadata / srt 解封装、mov_text 编码器、ipod 或 mp4
/// 封装）先探测；缺了抛 `export_unsupported`（消息列出缺什么），不靠跑一遍失败再猜
/// ——统一 FFmpeg 的能力下限 `tool/ffmpeg-unified/capabilities.json` 全平台都带这几样。
/// 封面优先用书库里的封面图（JPEG / PNG，需要 image2 解封装器）；书库没有可用封面时
/// 取第一个音频文件自带的封面（纯转录有声书的封面只在源音频里）。两处都没有才不嵌。
///
/// 播放页「导出当前字幕」（[buildAudiobookSubtitleSrt]）与这里共用同一套单时间轴：
/// 多文件书按探测出的真实文件时长累加偏移。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show serializeAudioCuesToSrt;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 导出失败。[code]：`export_unsupported`（本机 ffmpeg 缺能力 / 音频格式不一致，
/// [message] 说明缺什么）或 `export_failed`（其它失败）。
class AudiobookExportFailure implements Exception {
  const AudiobookExportFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AudiobookExportFailure($code: $message)';
}

/// 移动端分享导出的暂存目录名（在系统临时目录下，app 自管）。
const String kTtsAudiobookShareStagingDirName = 'fushi_m4b_share';

/// 准备一次移动端分享导出的暂存目录 [root]：先删掉上一次导出留下的整本 M4B 与
/// `.srt`，再建一个空目录给这一次用。
///
/// 这一次的文件不能在分享返回后立刻删：`FushiShare.shareFiles` 走非结果变体，
/// 面板**呈现**后 Future 就完成了，用户选中的目标 App 可能还在读文件。所以由 app
/// 自管这个固定目录、下一次导出前清旧的——任何时刻最多留一次导出的体积，而不是
/// 每导出一次就在临时目录里多留一整本书。
Future<Directory> prepareTtsAudiobookShareStagingDir(Directory root) async {
  if (await root.exists()) await root.delete(recursive: true);
  return root.create(recursive: true);
}

/// `ffmpeg -demuxers` / `-muxers` 的输出里有没有某个格式。行形如
/// ` D   concat   …` / `  E  mp4   …` / ` DE  matroska,webm  …`。
bool ffmpegFormatsListHas(String output, String format, {required bool demux}) {
  for (final String line in output.split('\n')) {
    final List<String> tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.length < 2) continue;
    final String flags = tokens[0];
    if (!RegExp(r'^[DE.d]{1,3}$').hasMatch(flags)) continue;
    int nameAt = 1;
    // 设备标记单独成列的写法（`D d dshow`）。
    if (tokens[1] == 'd' && tokens.length > 2) nameAt = 2;
    final String names = tokens[nameAt];
    if (names == '=') continue;
    if (!flags.contains(demux ? 'D' : 'E')) continue;
    if (names.split(',').contains(format)) return true;
  }
  return false;
}

/// `ffmpeg -encoders` 的输出里有没有某个编码器。行形如
/// ` S..... mov_text             3GPP Timed Text subtitle`（首列 6 位能力标记，
/// 首位是类型 V / A / S）；表头的 ` V..... = Video` 与 `------` 不算。
bool ffmpegEncodersListHas(String output, String encoder) {
  for (final String line in output.split('\n')) {
    final List<String> tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.length < 2) continue;
    if (!RegExp(r'^[VAS][A-Z.]{5}$').hasMatch(tokens[0])) continue;
    if (tokens[1] == '=') continue;
    if (tokens[1] == encoder) return true;
  }
  return false;
}

/// 导出要用到的 ffmpeg 能力。
class AudiobookExportCapabilities {
  const AudiobookExportCapabilities({
    required this.concat,
    required this.ffmetadata,
    required this.ipod,
    required this.mp4,
    required this.image2,
    required this.srt,
    required this.movText,
  });

  factory AudiobookExportCapabilities.parse({
    required String demuxers,
    required String muxers,
    required String encoders,
  }) => AudiobookExportCapabilities(
    concat: ffmpegFormatsListHas(demuxers, 'concat', demux: true),
    ffmetadata: ffmpegFormatsListHas(demuxers, 'ffmetadata', demux: true),
    ipod: ffmpegFormatsListHas(muxers, 'ipod', demux: false),
    mp4: ffmpegFormatsListHas(muxers, 'mp4', demux: false),
    image2: ffmpegFormatsListHas(demuxers, 'image2', demux: true),
    srt: ffmpegFormatsListHas(demuxers, 'srt', demux: true),
    movText: ffmpegEncodersListHas(encoders, 'mov_text'),
  );

  final bool concat;
  final bool ffmetadata;
  final bool ipod;
  final bool mp4;

  /// 读封面图片文件（没有就只能用音频文件自带的封面）。
  final bool image2;

  /// 读字幕：单时间轴 SRT 作为一路输入。
  final bool srt;

  /// MP4 系封装里的字幕轨只能是 `mov_text`（tx3g），SRT 不能直接 copy 进去。
  final bool movText;

  /// 缺的必需能力（空 = 能导出）。
  List<String> get missing => <String>[
    if (!concat) 'concat demuxer',
    if (!ffmetadata) 'ffmetadata demuxer',
    if (!ipod && !mp4) 'ipod/mp4 muxer',
    if (!srt) 'srt demuxer',
    if (!movText) 'mov_text encoder',
  ];
}

/// `ffmpeg -i <file>` 输出里第一路**封面**流（`(attached pic)` 且编码是 MJPEG /
/// PNG——MP4 封面只认这两种）的流下标；没有返回 null。行形如
/// `Stream #0:1[0x0](und): Video: mjpeg (Baseline), yuvj420p(pc), 600x600, 90k tbr,
/// 90k tbn (attached pic)`。
int? parseFfmpegAttachedPicStream(String output) {
  for (final String line in output.split('\n')) {
    if (!line.contains('(attached pic)')) continue;
    final RegExpMatch? m = RegExp(
      r'Stream #\d+:(\d+)[^:]*:\s*Video:\s*(mjpeg|png)\b',
    ).firstMatch(line);
    if (m != null) return int.parse(m.group(1)!);
  }
  return null;
}

/// `ffmpeg -i <file>` 输出里的时长与第一条音频流参数。
({int? durationMs, String? codec, int? sampleRate, String? channels})
parseFfmpegInputInfo(String output) {
  final RegExpMatch? d = RegExp(
    r'Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d+)',
  ).firstMatch(output);
  int? durationMs;
  if (d != null) {
    final String frac = d.group(4)!;
    durationMs =
        (int.parse(d.group(1)!) * 3600 +
                int.parse(d.group(2)!) * 60 +
                int.parse(d.group(3)!)) *
            1000 +
        (int.parse(frac) * 1000 / _pow10(frac.length)).round();
  }
  final RegExpMatch? a = RegExp(
    r'Stream #\d+:\d+[^:]*:\s*Audio:\s*([A-Za-z0-9_]+)[^\n]*?,\s*(\d+) Hz,\s*([^,\n]+)',
  ).firstMatch(output);
  return (
    durationMs: durationMs,
    codec: a?.group(1),
    sampleRate: a == null ? null : int.parse(a.group(2)!),
    channels: a?.group(3)?.trim(),
  );
}

int _pow10(int n) {
  int v = 1;
  for (int i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// M4B 的一个章节标记（单时间轴毫秒）。
class AudiobookExportChapter {
  const AudiobookExportChapter({
    required this.startMs,
    required this.endMs,
    required this.title,
  });

  final int startMs;
  final int endMs;
  final String title;
}

/// 由单时间轴 cue 生成章节：cue 换到另一个**有目录标题**的 spine 章时开新章；没有
/// 目录标题的 spine 文件（一个目录项拆成多个 xhtml、正文外的匹配残片）并入前一章。
/// 第一章从 0 开始，每章结束于下一章开始，最后一章结束于 [totalMs]。
List<AudiobookExportChapter> buildAudiobookExportChapters({
  required List<AudioCue> timelineCues,
  required int totalMs,
  required String? Function(String href) titleFor,
  required String fallbackTitle,
}) {
  final List<({int startMs, String title})> starts =
      <({int startMs, String title})>[];
  String? currentHref;
  for (final AudioCue cue in timelineCues) {
    if (cue.chapterHref == currentHref) continue;
    currentHref = cue.chapterHref;
    final String? title = titleFor(cue.chapterHref);
    if (title == null) {
      if (starts.isEmpty) starts.add((startMs: 0, title: fallbackTitle));
      continue;
    }
    if (starts.isNotEmpty && starts.last.title == title) continue;
    starts.add((startMs: starts.isEmpty ? 0 : cue.startMs, title: title));
  }
  if (starts.isEmpty) starts.add((startMs: 0, title: fallbackTitle));
  return <AudiobookExportChapter>[
    for (int i = 0; i < starts.length; i++)
      AudiobookExportChapter(
        startMs: starts[i].startMs,
        endMs: i + 1 < starts.length ? starts[i + 1].startMs : totalMs,
        title: starts[i].title,
      ),
  ];
}

/// FFMETADATA1 的值转义：`=` `;` `#` `\` 与换行前加反斜杠。
String escapeFfmetadata(String value) => value.replaceAllMapped(
  RegExp(r'[=;#\\\n]'),
  (Match m) => '\\${m.group(0)}',
);

/// FFMETADATA1 文本：全局元数据 + 每章一个 `[CHAPTER]`（时基毫秒）。
String buildFfmetadata({
  required String title,
  String? artist,
  required List<AudiobookExportChapter> chapters,
}) {
  final StringBuffer sb = StringBuffer(';FFMETADATA1\n')
    ..writeln('title=${escapeFfmetadata(title)}')
    ..writeln('album=${escapeFfmetadata(title)}')
    ..writeln('genre=Audiobook');
  if (artist != null && artist.trim().isNotEmpty) {
    sb
      ..writeln('artist=${escapeFfmetadata(artist.trim())}')
      ..writeln('album_artist=${escapeFfmetadata(artist.trim())}');
  }
  for (final AudiobookExportChapter c in chapters) {
    sb
      ..writeln()
      ..writeln('[CHAPTER]')
      ..writeln('TIMEBASE=1/1000')
      ..writeln('START=${c.startMs}')
      ..writeln('END=${c.endMs}')
      ..writeln('title=${escapeFfmetadata(c.title)}');
  }
  return sb.toString();
}

/// M4B 封面的来源：一张图片文件（[streamIndex] 为 null，取它的视频流），或某个
/// 音频文件里自带的封面流（[streamIndex] = 该文件里的流下标）。
class AudiobookExportCover {
  /// 书库里的封面图（JPEG / PNG）。
  const AudiobookExportCover.image(this.path) : streamIndex = null;

  /// 音频文件 [path] 里第 [streamIndex] 路流（`(attached pic)` 的 MJPEG / PNG）。
  const AudiobookExportCover.embedded(this.path, int this.streamIndex);

  final String path;
  final int? streamIndex;

  /// `-map` 的流选择（[input] 是它在 ffmpeg 输入里的下标）。
  String mapSpec(int input) =>
      streamIndex == null ? '$input:v:0' : '$input:$streamIndex';
}

/// 导出的 ffmpeg 参数。输入依次是：0 拼接清单、1 FFMETADATA、（有字幕时）字幕 SRT、
/// （有封面时）封面来源。字幕转 `mov_text` 封进去，音频与封面照旧 `-c copy`。
List<String> buildAudiobookExportArgs({
  required String listPath,
  required String metadataPath,
  required AudiobookExportCover? cover,
  required String? subtitlePath,
  required String muxer,
  required String outputPath,
}) {
  final int? subtitleInput = subtitlePath == null ? null : 2;
  final int? coverInput = cover == null ? null : (subtitlePath == null ? 2 : 3);
  return <String>[
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    listPath,
    '-f',
    'ffmetadata',
    '-i',
    metadataPath,
    if (subtitlePath != null) ...<String>['-f', 'srt', '-i', subtitlePath],
    if (cover != null) ...<String>['-i', cover.path],
    '-map',
    '0:a',
    if (subtitleInput != null) ...<String>['-map', '$subtitleInput:s:0'],
    if (cover != null && coverInput != null) ...<String>[
      '-map',
      cover.mapSpec(coverInput),
    ],
    '-map_metadata',
    '1',
    '-map_chapters',
    '1',
    '-c',
    'copy',
    if (subtitleInput != null) ...<String>['-c:s', 'mov_text'],
    if (cover != null) ...<String>['-disposition:v:0', 'attached_pic'],
    '-f',
    muxer,
    outputPath,
  ];
}

const Set<String> _mp4FamilyExtensions = <String>{
  '.m4a',
  '.m4b',
  '.mp4',
  '.mov',
};

/// 一个音频文件的探测结果：真实时长、音频流签名（编码 / 采样率 / 声道）与自带封面
/// 流下标（没有为 null）。
typedef AudiobookProbedAudio = ({
  int durationMs,
  String codec,
  String signature,
  int? attachedPicStream,
});

/// 探测一个音频文件。MP4 系取容器里的精确呈现时长（`ffmpeg -i` 的 Duration 只到
/// 10 毫秒且含编码器延迟）；读不出时长或音频流抛 `export_failed`。
Future<AudiobookProbedAudio> _probeAudioFile(
  FfmpegBackend backend,
  String path,
) async {
  final FfmpegRunResult probe = await _query(backend, <String>[
    '-hide_banner',
    '-i',
    path,
  ]);
  final ({int? durationMs, String? codec, int? sampleRate, String? channels})
  info = parseFfmpegInputInfo(probe.output);
  final int? exact =
      _mp4FamilyExtensions.contains(p.extension(path).toLowerCase())
      ? await readMp4PresentationDurationMs(path)
      : null;
  final int? duration = exact ?? info.durationMs;
  final String? codec = info.codec;
  if (duration == null || duration <= 0 || codec == null) {
    throw AudiobookExportFailure(
      'export_failed',
      'cannot read ${p.basename(path)}: ${probe.failureSummary}',
    );
  }
  return (
    durationMs: duration,
    codec: codec,
    signature: '$codec/${info.sampleRate}/${info.channels}',
    attachedPicStream: parseFfmpegAttachedPicStream(probe.output),
  );
}

/// 各音频文件的真实时长（毫秒，按 [files] 顺序），单时间轴的偏移按它累加。
Future<List<int>> probeAudiobookFileDurationsMs(List<String> files) async {
  final FfmpegBackend backend = resolveFfmpegBackend();
  return <int>[
    for (final String path in files)
      (await _probeAudioFile(backend, path)).durationMs,
  ];
}

/// 播放页「导出当前字幕」的 SRT 正文（反馈 iUtGmIlZiD）：[cues]（文件内时间）摆到
/// 整本单时间轴上再序列化——与 M4B 里封的字幕同一套时间轴。
///
/// 单文件书不需要文件时长；多文件书要 [audioPaths] 全在本地，按 [probeDurations]
/// （缺省 = [probeAudiobookFileDurationsMs]，真实时长）累加偏移。不用 cue 推出的
/// 「文件时长」：它止于每个文件的末句，片尾静音不在里面，拿它拼出的时间轴会让后面
/// 每个文件的字幕都提前。没有字幕 / cue 指向不存在的文件 / 文件不在本地时抛
/// `export_failed`。
Future<String> buildAudiobookSubtitleSrt({
  required List<AudioCue> cues,
  required List<String> audioPaths,
  Future<List<int>> Function(List<String> files)? probeDurations,
}) async {
  if (cues.isEmpty) {
    throw const AudiobookExportFailure('export_failed', 'no subtitles');
  }
  final List<AudioCue> sorted = List<AudioCue>.of(cues)..sort(_byFileThenStart);
  int lastFile = 0;
  for (final AudioCue cue in sorted) {
    if (cue.audioFileIndex < 0) {
      throw AudiobookExportFailure(
        'export_failed',
        'cue points at audio file ${cue.audioFileIndex}',
      );
    }
    if (cue.audioFileIndex > lastFile) lastFile = cue.audioFileIndex;
  }
  final List<int> durations;
  if (lastFile == 0) {
    durations = const <int>[0];
  } else {
    if (lastFile >= audioPaths.length) {
      throw AudiobookExportFailure(
        'export_failed',
        'cue points at audio file $lastFile of ${audioPaths.length}',
      );
    }
    final List<String> files = audioPaths.sublist(0, lastFile + 1);
    for (final String path in files) {
      if (!await File(path).exists()) {
        throw AudiobookExportFailure(
          'export_failed',
          'audio file missing: ${p.basename(path)}',
        );
      }
    }
    durations = await (probeDurations ?? probeAudiobookFileDurationsMs)(files);
  }
  return serializeAudioCuesToSrt(
    ttsCuesOnSingleTimeline(sorted, fileDurationsMs: durations),
  );
}

int _byFileThenStart(AudioCue a, AudioCue b) {
  final int byFile = a.audioFileIndex.compareTo(b.audioFileIndex);
  return byFile != 0 ? byFile : a.startMs.compareTo(b.startMs);
}

/// 导出 [bookKey] 的有声书为 [outputPath]（建议 `.m4b`），返回输出路径。字幕与
/// 封面都封在这一个文件里，不再旁写 `.srt`。[onProgress] 报 0..1。
Future<String> exportTtsAudiobookM4b({
  required FushiDatabase database,
  required String bookKey,
  required String outputPath,
  required void Function(double progress) onProgress,
}) async {
  final FushiDatabase db = database;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null) {
    throw const AudiobookExportFailure('export_failed', 'book not found');
  }
  final AudiobookRepository repo = AudiobookRepository(db);
  final Audiobook? audiobook = await repo.findByBookKey(bookKey);
  if (audiobook == null) {
    throw const AudiobookExportFailure('export_failed', 'no audiobook');
  }
  final List<String> files = await _audioFiles(audiobook);
  final List<AudioCue> cues = await repo.cuesForBook(bookKey)
    ..sort(_byFileThenStart);
  for (final AudioCue cue in cues) {
    if (cue.audioFileIndex < 0 || cue.audioFileIndex >= files.length) {
      throw AudiobookExportFailure(
        'export_failed',
        'cue points at audio file ${cue.audioFileIndex} of ${files.length}',
      );
    }
  }

  final FfmpegBackend backend = resolveFfmpegBackend();
  final AudiobookExportCapabilities caps = AudiobookExportCapabilities.parse(
    demuxers: (await _query(backend, <String>[
      '-hide_banner',
      '-demuxers',
    ])).output,
    muxers: (await _query(backend, <String>['-hide_banner', '-muxers'])).output,
    encoders: (await _query(backend, <String>[
      '-hide_banner',
      '-encoders',
    ])).output,
  );
  if (caps.missing.isNotEmpty) {
    throw AudiobookExportFailure(
      'export_unsupported',
      'ffmpeg lacks: ${caps.missing.join(', ')}',
    );
  }

  // 每个文件的时长与流参数：`-c copy` 拼接要求全部一致。
  final List<int> durations = <int>[];
  String? signature;
  String? codec;
  int? firstFileCoverStream;
  for (int i = 0; i < files.length; i++) {
    final AudiobookProbedAudio info = await _probeAudioFile(backend, files[i]);
    durations.add(info.durationMs);
    if (signature != null && info.signature != signature) {
      throw AudiobookExportFailure(
        'export_unsupported',
        'audio files differ in format ($signature vs ${info.signature})',
      );
    }
    signature = info.signature;
    codec = info.codec;
    if (i == 0) firstFileCoverStream = info.attachedPicStream;
  }
  int totalMs = 0;
  for (final int d in durations) {
    totalMs += d;
  }

  final List<AudioCue> timeline = ttsCuesOnSingleTimeline(
    cues,
    fileDurationsMs: durations,
  );
  final Map<int, String> tocTitles = <int, String>{};
  EpubBook? book;
  final ({EpubBookRow row, EpubBook book})? loaded = await loadEpubForStudio(
    db,
    bookKey,
  );
  if (loaded != null) {
    book = loaded.book;
    void walk(List<EpubTocItem> items) {
      for (final EpubTocItem item in items) {
        final int index = loaded.book.chapterIndexForHref(item.href);
        final String label = item.label.trim();
        if (index >= 0 && label.isNotEmpty) {
          tocTitles.putIfAbsent(index, () => label);
        }
        walk(item.children);
      }
    }

    walk(loaded.book.toc);
  }
  final List<AudiobookExportChapter> chapters = buildAudiobookExportChapters(
    timelineCues: timeline,
    totalMs: totalMs,
    titleFor: (String href) {
      final EpubBook? b = book;
      if (b == null) return null;
      return tocTitles[b.chapterIndexForHref(href)];
    },
    fallbackTitle: row.title,
  );

  final File output = File(outputPath);
  await output.parent.create(recursive: true);
  final Directory work = await Directory(
    output.parent.path,
  ).createTemp('.export_');
  final String partPath = p.join(
    output.parent.path,
    '${p.basenameWithoutExtension(outputPath)}.part${p.extension(outputPath)}',
  );
  try {
    final String listPath = p.join(work.path, 'files.ffconcat');
    await File(listPath).writeAsString(
      buildTtsConcatList(<({String path, int durationMs})>[
        for (int i = 0; i < files.length; i++)
          (path: files[i], durationMs: durations[i]),
      ]),
      flush: true,
    );
    final String metadataPath = p.join(work.path, 'metadata.txt');
    await File(metadataPath).writeAsString(
      buildFfmetadata(title: row.title, artist: row.author, chapters: chapters),
      flush: true,
    );
    // 字幕封进 M4B（mov_text 轨）；没有 cue 的书（只听不挂字幕）就不带字幕轨。
    String? subtitlePath;
    if (timeline.isNotEmpty) {
      subtitlePath = p.join(work.path, 'subtitles.srt');
      await File(
        subtitlePath,
      ).writeAsString(serializeAudioCuesToSrt(timeline), flush: true);
    }
    final AudiobookExportCover? cover = pickAudiobookExportCover(
      libraryCover: caps.image2 ? _usableCover(row.coverPath) : null,
      firstAudioPath: files.first,
      firstAudioCoverStream: firstFileCoverStream,
    );
    // ipod 封装器只收 AAC / ALAC；MP3 等走通用 mp4（扩展名仍是 .m4b）。
    final bool ipodCodec = codec == 'aac' || codec == 'alac';
    final String muxer = caps.ipod && ipodCodec ? 'ipod' : 'mp4';
    final List<String> args = buildAudiobookExportArgs(
      listPath: listPath,
      metadataPath: metadataPath,
      cover: cover,
      subtitlePath: subtitlePath,
      muxer: muxer,
      outputPath: partPath,
    );
    onProgress(0);
    void progress(Duration processed) {
      if (totalMs <= 0) return;
      onProgress((processed.inMilliseconds / totalMs).clamp(0.0, 1.0));
    }

    final FfmpegRunResult result = switch (backend) {
      final FfmpegWatchedRunner watched => await watched.runWatched(
        args,
        FfmpegWatch(
          stallTimeout: const Duration(seconds: 120),
          onProgress: progress,
        ),
      ),
      final FfmpegBackend plain => await plain.run(
        args,
        Duration(minutes: 5, milliseconds: totalMs ~/ 10),
      ),
    };
    final File part = File(partPath);
    if (!result.isSuccess || !await part.exists() || await part.length() == 0) {
      ErrorLogService.instance.log(
        'AudiobookExport($bookKey)',
        result.failureSummary,
        StackTrace.current,
      );
      throw AudiobookExportFailure('export_failed', result.failureSummary);
    }
    if (await output.exists()) await output.delete();
    await part.rename(outputPath);
    onProgress(1);
    return outputPath;
  } finally {
    final File part = File(partPath);
    if (await part.exists()) await part.delete();
    if (await work.exists()) await work.delete(recursive: true);
  }
}

Future<FfmpegRunResult> _query(FfmpegBackend backend, List<String> args) =>
    backend.runQuery(args, const Duration(seconds: 30));

/// 登记的音频路径必须全部还在（少一个文件，`audioFileIndex` 就全错位）；旧的
/// 目录模式按播放同一口径枚举。
Future<List<String>> _audioFiles(Audiobook audiobook) async {
  final List<String>? paths = audiobook.audioPaths;
  if (paths != null && paths.isNotEmpty) {
    for (final String path in paths) {
      if (!await File(path).exists()) {
        throw AudiobookExportFailure(
          'export_failed',
          'audio file missing: ${p.basename(path)}',
        );
      }
    }
    return List<String>.of(paths);
  }
  final List<File> files = await resolveAudiobookPlaybackFiles(
    audioPaths: paths,
    audioRoot: audiobook.audioRoot,
  );
  if (files.isEmpty) {
    throw const AudiobookExportFailure('export_failed', 'no audio files');
  }
  return <String>[for (final File f in files) f.path];
}

/// 选 M4B 封面：书库封面图优先（[libraryCover]，已过 [_usableCover] 与 image2
/// 检查）；没有就用第一个音频文件自带的封面流（[firstAudioCoverStream]，纯转录有声书
/// 的封面只在源音频里）；都没有返回 null。
AudiobookExportCover? pickAudiobookExportCover({
  required String? libraryCover,
  required String firstAudioPath,
  required int? firstAudioCoverStream,
}) {
  if (libraryCover != null) return AudiobookExportCover.image(libraryCover);
  if (firstAudioCoverStream != null) {
    return AudiobookExportCover.embedded(firstAudioPath, firstAudioCoverStream);
  }
  return null;
}

/// 能直接 `-c copy` 进 mp4 当封面的图片（JPEG / PNG）。
String? _usableCover(String? coverPath) {
  if (coverPath == null || coverPath.isEmpty) return null;
  final String ext = p.extension(coverPath).toLowerCase();
  if (ext != '.jpg' && ext != '.jpeg' && ext != '.png') return null;
  return File(coverPath).existsSync() ? coverPath : null;
}
