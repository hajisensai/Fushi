/// 作品图谱 L2：OP / ED 声纹识别的编排（docs/specs/2026-10-24-cross-media-links.md §2）。
///
/// 分工（「Rust 胖核心、Flutter 薄 UI」）：
/// - **解码**走统一 FFmpeg 后端（[resolveFfmpegBackend]，BD `.mpls` / DVD title 由它
///   透明处理），把音轨解成 11025 Hz 单声道 s16le 的临时 raw 文件——Rust 侧不引第二份
///   FFmpeg；
/// - **声纹 + 对齐**在 native/fushi_music（[AudioFingerprinter]），后台 isolate 里一集
///   一次 `compute`、一对一次 `align`，PCM 不跨 isolate（isolate 自己读 raw 文件）；
/// - **结果**按集落 `video_theme_song_spans`（v127，设备本地缓存），没出现也落一行。
///
/// 解码与声纹都经接口注入（[ThemeSongAudioDecoder] / [ThemeSongFingerprintEngine]），
/// 编排逻辑可以在没有 FFmpeg / 原生库的单测里跑。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

/// 把一段音轨解成 [kAudioFingerprintSampleRate] 单声道 s16le raw 文件。
abstract interface class ThemeSongAudioDecoder {
  /// [startMs] / [durationMs] 给了时只解这一段（CUE 虚拟曲目）。失败抛
  /// [ThemeSongDecodeException]。
  Future<void> decodeToRawPcm({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  });
}

/// 解码失败（文件读不了 / 没有音轨 / FFmpeg 报错）。只影响这一集或这一首，编排照常
/// 往下走，并且**不写缓存**——下次再试（可能只是 U 盘没插）。
final class ThemeSongDecodeException implements Exception {
  const ThemeSongDecodeException(this.input, this.detail);

  final String input;
  final String detail;

  @override
  String toString() => 'ThemeSongDecodeException($input): $detail';
}

/// 统一 FFmpeg 后端实现。
class FfmpegThemeSongAudioDecoder implements ThemeSongAudioDecoder {
  const FfmpegThemeSongAudioDecoder({
    this.timeout = const Duration(minutes: 10),
  });

  /// 单次解码上限。BD 原盘一集（约 7 GB、24 bit LPCM）本机实测约 20 s。
  final Duration timeout;

  /// 解码参数（纯函数，测试钉死）。
  static List<String> argsFor({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) => <String>[
    '-y',
    '-v',
    'error',
    if (startMs != null && startMs > 0) ...<String>[
      '-ss',
      (startMs / 1000).toStringAsFixed(3),
    ],
    '-i',
    input,
    if (durationMs != null && durationMs > 0) ...<String>[
      '-t',
      (durationMs / 1000).toStringAsFixed(3),
    ],
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-ac',
    '1',
    '-ar',
    '$kAudioFingerprintSampleRate',
    '-f',
    's16le',
    output,
  ];

  @override
  Future<void> decodeToRawPcm({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) async {
    final FfmpegRunResult r = await resolveFfmpegBackend().run(
      argsFor(
        input: input,
        output: output,
        startMs: startMs,
        durationMs: durationMs,
      ),
      timeout,
    );
    if (r.returnCode != 0) {
      throw ThemeSongDecodeException(input, r.output.trim());
    }
    if (!File(output).existsSync() || File(output).lengthSync() == 0) {
      throw ThemeSongDecodeException(input, 'no audio decoded');
    }
  }
}

/// 声纹 + 对齐。
abstract interface class ThemeSongFingerprintEngine {
  /// 声纹算法版本（缓存失效判据）。
  int get version;

  /// raw PCM 文件 → 声纹。
  Future<Uint32List> fingerprintRawPcm(String path);

  Future<AudioFingerprintMatch?> align(Uint32List needle, Uint32List haystack);
}

/// native/fushi_music 实现：两个调用都在后台 isolate（一集声纹约 250 ms）。
class NativeThemeSongFingerprintEngine implements ThemeSongFingerprintEngine {
  const NativeThemeSongFingerprintEngine();

  @override
  int get version => AudioFingerprinter.instance.version;

  @override
  Future<Uint32List> fingerprintRawPcm(String path) => Isolate.run(
    () => AudioFingerprinter.instance.computeRawPcmFile(path),
    debugName: 'theme-song-fingerprint',
  );

  @override
  Future<AudioFingerprintMatch?> align(
    Uint32List needle,
    Uint32List haystack,
  ) => Isolate.run(
    () => AudioFingerprinter.instance.align(needle, haystack),
    debugName: 'theme-song-align',
  );
}

/// 一次识别的统计（日志 / 测试用）。
class ThemeSongDetectionReport {
  int episodesCompared = 0;
  int episodesFromCache = 0;
  int hits = 0;
  int decodeFailures = 0;

  @override
  String toString() =>
      'ThemeSongDetectionReport(compared: $episodesCompared, cached: '
      '$episodesFromCache, hits: $hits, decodeFailures: $decodeFailures)';
}

/// 文件的（大小, 修改时刻毫秒）。读不到（被挪走 / 盘没插）返回 null。
typedef ThemeSongFileStat = ({int size, int modifiedAt})? Function(String path);

({int size, int modifiedAt})? _defaultFileStat(String path) {
  final FileStat stat = FileStat.statSync(path);
  if (stat.type == FileSystemEntityType.notFound) return null;
  return (size: stat.size, modifiedAt: stat.modified.millisecondsSinceEpoch);
}

/// 识别编排。串行执行（解码是磁盘密集型，一次一集），同一集的请求合并。
class ThemeSongDetector {
  ThemeSongDetector({
    required this.database,
    ThemeSongAudioDecoder? decoder,
    ThemeSongFingerprintEngine? engine,
    Directory? workDirectory,
    ThemeSongFileStat? fileStat,
    int Function()? clock,
    this.minMatch = const Duration(seconds: 15),
    this.minConfidence = 0.5,
  }) : decoder = decoder ?? const FfmpegThemeSongAudioDecoder(),
       engine = engine ?? const NativeThemeSongFingerprintEngine(),
       _workDirectory = workDirectory,
       _fileStat = fileStat ?? _defaultFileStat,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase database;
  final ThemeSongAudioDecoder decoder;
  final ThemeSongFingerprintEngine engine;
  final Directory? _workDirectory;
  final ThemeSongFileStat _fileStat;
  final int Function() _clock;

  /// 命中段短于它视为没出现（OP / ED 的 TV size 约 90 s，15 s 足以排除偶然相似的
  /// 几小节 BGM）。
  final Duration minMatch;

  /// 置信度低于它视为没出现。
  final double minConfidence;

  /// 歌曲声纹缓存（一次识别会话内，一首歌只解码一次）。
  final Map<String, Uint32List> _songPrints = <String, Uint32List>{};

  Future<void> _tail = Future<void>.value();

  Future<Directory> _workDir() async {
    final Directory dir =
        _workDirectory ??
        Directory(p.join(Directory.systemTemp.path, 'fushi_theme_song'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 串行化：所有识别排进同一条队列。
  Future<T> _serial<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// 识别所有已确认主题曲连接覆盖的集（缓存仍有效的跳过）。[onlyBookUid] /
  /// [onlyTrackUid] 缩小范围（视频页只识别当前视频、曲目页只识别这一首）。
  Future<ThemeSongDetectionReport> detect({
    String? onlyBookUid,
    String? onlyTrackUid,
    int? onlyEpisodeIndex,
  }) => _serial(() async {
    final ThemeSongDetectionReport report = ThemeSongDetectionReport();
    final List<ThemeSongPlan> plans = await loadThemeSongPlans(
      database,
      onlyBookUid: onlyBookUid,
      onlyTrackUid: onlyTrackUid,
    );
    // 按集归并：同一集被多条连接（OP + ED、曲目 + 专辑）覆盖时只解码一次，所有候选歌
    // 对同一份声纹比对。
    final Map<
      String,
      ({ThemeSongEpisode episode, Map<String, ThemeSongSong> songs})
    >
    byEpisode =
        <
          String,
          ({ThemeSongEpisode episode, Map<String, ThemeSongSong> songs})
        >{};
    for (final ThemeSongPlan plan in plans) {
      for (final ThemeSongEpisode episode in plan.episodes) {
        if (onlyEpisodeIndex != null &&
            episode.episodeIndex != onlyEpisodeIndex) {
          continue;
        }
        final ({ThemeSongEpisode episode, Map<String, ThemeSongSong> songs})
        slot = byEpisode.putIfAbsent(
          '${episode.bookUid}\u0000${episode.episodeIndex}',
          () => (episode: episode, songs: <String, ThemeSongSong>{}),
        );
        for (final ThemeSongSong s in plan.songs) {
          slot.songs[s.trackUid] = s;
        }
      }
    }
    for (final ({ThemeSongEpisode episode, Map<String, ThemeSongSong> songs})
        slot
        in byEpisode.values) {
      await _detectEpisode(slot.songs.values.toList(), slot.episode, report);
    }
    return report;
  });

  Future<void> _detectEpisode(
    List<ThemeSongSong> songs,
    ThemeSongEpisode episode,
    ThemeSongDetectionReport report,
  ) async {
    final ({int size, int modifiedAt})? stat = _fileStat(episode.path);
    if (stat == null) return;
    final int version = engine.version;
    final Map<String, VideoThemeSongSpanRow> cached =
        <String, VideoThemeSongSpanRow>{
          for (final VideoThemeSongSpanRow r
              in await database.themeSongSpansForEpisode(episode.key))
            r.trackUid: r,
        };
    bool fresh(VideoThemeSongSpanRow? r) =>
        r != null &&
        r.fileSizeBytes == stat.size &&
        r.fileModifiedAt == stat.modifiedAt &&
        r.detectorVersion == version;
    final List<ThemeSongSong> pending = <ThemeSongSong>[
      for (final ThemeSongSong s in songs)
        if (!fresh(cached[s.trackUid])) s,
    ];
    if (pending.isEmpty) {
      report.episodesFromCache++;
      return;
    }
    final Directory work = await _workDir();
    final String raw = p.join(
      work.path,
      'ep_${episode.bookUid.hashCode.toUnsigned(32)}_${episode.episodeIndex}.s16le',
    );
    final Uint32List haystack;
    try {
      await decoder.decodeToRawPcm(input: episode.path, output: raw);
      haystack = await engine.fingerprintRawPcm(raw);
    } on ThemeSongDecodeException {
      report.decodeFailures++;
      return;
    } finally {
      _deleteQuietly(raw);
    }
    report.episodesCompared++;
    for (final ThemeSongSong song in pending) {
      final Uint32List? needle = await _songPrint(song, work, report);
      if (needle == null) continue;
      final AudioFingerprintMatch? m = await engine.align(needle, haystack);
      final bool hit =
          m != null &&
          m.confidence >= minConfidence &&
          m.haystackEnd - m.haystackStart >= minMatch;
      if (hit) report.hits++;
      final int start = hit
          ? m.haystackStart.inMilliseconds.clamp(0, 1 << 40)
          : 0;
      final int end = hit ? m.haystackEnd.inMilliseconds : 0;
      await database.upsertThemeSongSpan(
        VideoThemeSongSpansCompanion.insert(
          bookUid: episode.bookUid,
          episodeIndex: episode.episodeIndex,
          trackUid: song.trackUid,
          fileSizeBytes: stat.size,
          fileModifiedAt: stat.modifiedAt,
          detectorVersion: version,
          startMs: Value<int?>(hit && end > start ? start : null),
          endMs: Value<int?>(hit && end > start ? end : null),
          confidence: Value<double?>(hit && end > start ? m.confidence : null),
          detectedAt: _clock(),
        ),
      );
    }
  }

  Future<Uint32List?> _songPrint(
    ThemeSongSong song,
    Directory work,
    ThemeSongDetectionReport report,
  ) async {
    final Uint32List? hit = _songPrints[song.trackUid];
    if (hit != null) return hit;
    final String raw = p.join(
      work.path,
      'song_${song.trackUid.hashCode.toUnsigned(32)}.s16le',
    );
    try {
      final int? start = song.cueStartMs;
      final int? end = song.cueEndMs;
      await decoder.decodeToRawPcm(
        input: song.path,
        output: raw,
        startMs: start,
        durationMs: start != null && end != null && end > start
            ? end - start
            : null,
      );
      return _songPrints[song.trackUid] = await engine.fingerprintRawPcm(raw);
    } on ThemeSongDecodeException {
      report.decodeFailures++;
      return null;
    } finally {
      _deleteQuietly(raw);
    }
  }

  static void _deleteQuietly(String path) {
    final File f = File(path);
    // 临时文件不存在就不用删；删不掉（被占用）留给系统临时目录清理，不影响结果。
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } on FileSystemException {
        return;
      }
    }
  }

  /// MV 偏移（音乐方案 §8.3 第 1 条）：本地音频在 MV 视频音轨上的偏移——MV 时间 =
  /// 音频时间 + 返回值。没对上返回 null。
  Future<Duration?> mvOffset({
    required ThemeSongSong audio,
    required String mvPath,
  }) async => (await mvAlignment(audio: audio, mvPath: mvPath))?.offset;

  /// 同 [mvOffset]，但返回完整对齐结果（置信度 / 命中段，MV 匹配要按置信度排序与判定）。
  /// 置信度低于 [minConfidence] 视为没对上。
  Future<AudioFingerprintMatch?> mvAlignment({
    required ThemeSongSong audio,
    required String mvPath,
  }) => _serial(() async {
    final Directory work = await _workDir();
    final ThemeSongDetectionReport report = ThemeSongDetectionReport();
    final Uint32List? needle = await _songPrint(audio, work, report);
    if (needle == null) return null;
    final String raw = p.join(
      work.path,
      'mv_${mvPath.hashCode.toUnsigned(32)}.s16le',
    );
    final Uint32List haystack;
    try {
      await decoder.decodeToRawPcm(input: mvPath, output: raw);
      haystack = await engine.fingerprintRawPcm(raw);
    } on ThemeSongDecodeException {
      return null;
    } finally {
      _deleteQuietly(raw);
    }
    final AudioFingerprintMatch? m = await engine.align(needle, haystack);
    if (m == null || m.confidence < minConfidence) return null;
    return m;
  });
}

/// 进程内共享的识别器（按数据库实例）。视频页、曲目页、连接编辑器都经它排队，
/// 保证同一时刻只有一路解码。
final Expando<ThemeSongDetector> _detectors = Expando<ThemeSongDetector>(
  'theme-song-detector',
);

ThemeSongDetector themeSongDetectorFor(FushiDatabase db) =>
    _detectors[db] ??= ThemeSongDetector(database: db);
