/// 把一本已入库的有声书（EPUB 配音频，TTS 制作的或用户导入的都行）导出成单个
/// M4B：各音频文件 `-c copy` 拼接，章节标记来自 EPUB 目录（经 FFMETADATA），书名 /
/// 作者 / 封面写进元数据，旁边再写一份单时间轴 `.srt`。
///
/// 需要的 ffmpeg 能力（concat / ffmetadata 解封装、ipod 或 mp4 封装）先探测；缺了抛
/// `export_unsupported`（消息列出缺什么），不靠跑一遍失败再猜。封面只是锦上添花：
/// 格式不支持 / 没有 image2 解封装器时不嵌，不算失败。
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
import 'package:fushi/src/models/app_model.dart';
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

/// 导出要用到的 ffmpeg 能力。
class AudiobookExportCapabilities {
  const AudiobookExportCapabilities({
    required this.concat,
    required this.ffmetadata,
    required this.ipod,
    required this.mp4,
    required this.image2,
  });

  factory AudiobookExportCapabilities.parse({
    required String demuxers,
    required String muxers,
  }) => AudiobookExportCapabilities(
    concat: ffmpegFormatsListHas(demuxers, 'concat', demux: true),
    ffmetadata: ffmpegFormatsListHas(demuxers, 'ffmetadata', demux: true),
    ipod: ffmpegFormatsListHas(muxers, 'ipod', demux: false),
    mp4: ffmpegFormatsListHas(muxers, 'mp4', demux: false),
    image2: ffmpegFormatsListHas(demuxers, 'image2', demux: true),
  );

  final bool concat;
  final bool ffmetadata;
  final bool ipod;
  final bool mp4;

  /// 读封面图片（没有就不嵌封面）。
  final bool image2;

  /// 缺的必需能力（空 = 能导出）。
  List<String> get missing => <String>[
    if (!concat) 'concat demuxer',
    if (!ffmetadata) 'ffmetadata demuxer',
    if (!ipod && !mp4) 'ipod/mp4 muxer',
  ];
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

/// 导出的 ffmpeg 参数。
List<String> buildAudiobookExportArgs({
  required String listPath,
  required String metadataPath,
  required String? coverPath,
  required String muxer,
  required String outputPath,
}) => <String>[
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
  if (coverPath != null) ...<String>['-i', coverPath],
  '-map',
  '0:a',
  if (coverPath != null) ...<String>['-map', '2:v'],
  '-map_metadata',
  '1',
  '-map_chapters',
  '1',
  '-c',
  'copy',
  if (coverPath != null) ...<String>['-disposition:v:0', 'attached_pic'],
  '-f',
  muxer,
  outputPath,
];

const Set<String> _mp4FamilyExtensions = <String>{
  '.m4a',
  '.m4b',
  '.mp4',
  '.mov',
};

/// 导出 [bookKey] 的有声书为 [outputPath]（建议 `.m4b`），返回输出路径。旁边写
/// 同名 `.srt`。[onProgress] 报 0..1。
Future<String> exportTtsAudiobookM4b({
  required AppModel appModel,
  required String bookKey,
  required String outputPath,
  required void Function(double progress) onProgress,
}) async {
  final FushiDatabase db = appModel.database;
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
    ..sort((AudioCue a, AudioCue b) {
      final int byFile = a.audioFileIndex.compareTo(b.audioFileIndex);
      return byFile != 0 ? byFile : a.startMs.compareTo(b.startMs);
    });
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
  for (final String path in files) {
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
    if (duration == null || duration <= 0 || info.codec == null) {
      throw AudiobookExportFailure(
        'export_failed',
        'cannot read ${p.basename(path)}: ${probe.failureSummary}',
      );
    }
    durations.add(duration);
    final String sig = '${info.codec}/${info.sampleRate}/${info.channels}';
    if (signature != null && sig != signature) {
      throw AudiobookExportFailure(
        'export_unsupported',
        'audio files differ in format ($signature vs $sig)',
      );
    }
    signature = sig;
    codec = info.codec;
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
    final String? cover = caps.image2 ? _usableCover(row.coverPath) : null;
    // ipod 封装器只收 AAC / ALAC；MP3 等走通用 mp4（扩展名仍是 .m4b）。
    final bool ipodCodec = codec == 'aac' || codec == 'alac';
    final String muxer = caps.ipod && ipodCodec ? 'ipod' : 'mp4';
    final List<String> args = buildAudiobookExportArgs(
      listPath: listPath,
      metadataPath: metadataPath,
      coverPath: cover,
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

    final File srt = File(p.setExtension(outputPath, '.srt'));
    await srt.writeAsString(serializeAudioCuesToSrt(timeline), flush: true);
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

/// 能直接 `-c copy` 进 mp4 当封面的图片（JPEG / PNG）。
String? _usableCover(String? coverPath) {
  if (coverPath == null || coverPath.isEmpty) return null;
  final String ext = p.extension(coverPath).toLowerCase();
  if (ext != '.jpg' && ext != '.jpeg' && ext != '.png') return null;
  return File(coverPath).existsSync() ? coverPath : null;
}
