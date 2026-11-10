/// 在线音源插件曲目 → 本机可转写的音频副本（反馈 NXOjldMQZd：插件曲目也能生成日语字幕）。
///
/// 插件曲目的播放路径是 `fushi-music-plugin://<插件>/<曲目>` 占位，不是文件；字幕管线
/// （`VideoSubtitlePipeline`）的任务身份、时长探测、证据收集、导出位置全都按「本机媒体
/// 文件」建模，流地址又是短时效的、带防盗链请求头。所以不把 URL 塞进管线，而是在开管线
/// 之前向插件取一次流（与播放、制卡同一个真相源 [resolveMusicPluginStream]），用 ffmpeg
/// 直接解码成转写要的 16 kHz 单声道 WAV 落到应用自有目录，管线照本机文件处理：
///
/// - 位置：`<数据根>/asr_jobs/music_subtitles/plugin_audio/<trackUid>.wav`。文件名按
///   曲目身份，管线任务键（文件名 + 字节数）因而每首各不相同；同一首重生成时重新取到的
///   是同样长度的 WAV，命中同一个任务目录，已有识别稿直接复用。
/// - 只是转写的中间产物：登记完歌词就删（`MusicAsrSubtitleSink.stagedAudio`），任务
///   失败 / 取消时留着，下一次直接用、不重下。
/// - 只给试听片段（[MusicPluginStream.isTrial]）的曲目由 [resolveMusicPluginStream] 拒掉：
///   转写半首没有意义。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show buildFfmpegRemoteInputArgs, ffmpegRemoteInputFor;
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// `<数据根>/asr_jobs/music_subtitles/plugin_audio`：与音乐字幕导出目录
/// （`asr_jobs/music_subtitles/out`）同级。布局只在这里写一次。
Directory musicPluginAsrAudioRootUnder(Directory supportRoot) => Directory(
  p.join(supportRoot.path, 'asr_jobs', 'music_subtitles', 'plugin_audio'),
);

/// 这首插件曲目的转写音频副本。
File musicPluginAsrAudioFileIn(Directory root, String trackUid) =>
    File(p.join(root.path, '$trackUid.wav'));

/// 取流解码的卡死判据：已处理媒体时间这么久不推进就强杀（与管线抽音轨同一口径）。
const Duration kMusicPluginAsrAudioStallTimeout = Duration(minutes: 2);

/// 不支持观察式运行的后端（测试替身 / 未知后端）的总时限。
const Duration kMusicPluginAsrAudioTimeout = Duration(hours: 1);

/// 一个合法 WAV 至少有 44 字节头；不比它长的就是空产物。
const int _kWavHeaderBytes = 44;

/// 取不到这首的音频（插件报错 / 只给试听 / ffmpeg 解码失败）；[message] 直接给用户看。
final class MusicPluginAsrAudioUnavailable implements Exception {
  const MusicPluginAsrAudioUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用户取消了取音频。
final class MusicPluginAsrAudioCancelled implements Exception {
  const MusicPluginAsrAudioCancelled();

  @override
  String toString() => 'cancelled';
}

/// 流 → 16 kHz 单声道 PCM WAV 的 ffmpeg 参数。远端输入参数（UA / Referer / 其余请求头 /
/// 断线重连 / app 代理）与制卡截音频共用 [buildFfmpegRemoteInputArgs]，不另写一套。
List<String> musicPluginAsrAudioArgs({
  required MusicPluginStream stream,
  required String outputPath,
}) => <String>[
  '-y',
  '-v',
  'error',
  ...buildFfmpegRemoteInputArgs(stream.url, httpHeaders: stream.headers),
  '-i',
  ffmpegRemoteInputFor(stream.url),
  '-vn',
  '-map_chapters',
  '-1',
  '-ac',
  '1',
  '-ar',
  '16000',
  '-c:a',
  'pcm_s16le',
  '-f',
  'wav',
  outputPath,
];

/// 把插件曲目的音频取到本机（[stage]）。
class MusicPluginAsrAudioStager {
  MusicPluginAsrAudioStager({
    required this.root,
    MusicPluginStreamResolver? resolver,
    FfmpegBackend Function()? backend,
  }) : _resolver = resolver ?? resolveMusicPluginStream,
       _backend = backend ?? resolveFfmpegBackend;

  /// 副本目录（[musicPluginAsrAudioRootUnder]）。
  final Directory root;
  final MusicPluginStreamResolver _resolver;
  final FfmpegBackend Function() _backend;

  /// 这首的副本路径（不管在不在）。
  File fileFor(String trackUid) => musicPluginAsrAudioFileIn(root, trackUid);

  /// 取 [item]（插件曲目）的音频到 [fileFor]。已有完整副本（上次任务失败 / 取消留下的）
  /// 直接返回。[onProgress] 给 0~1（曲目时长未知时给 null = 不定态）。
  ///
  /// 失败抛 [MusicPluginAsrAudioUnavailable]；[cancel] 完成即强杀 ffmpeg 并抛
  /// [MusicPluginAsrAudioCancelled]。
  Future<File> stage(
    MusicPlayItem item, {
    required void Function(double? fraction) onProgress,
    required Future<void> cancel,
  }) async {
    if (!isMusicPluginPath(item.path)) {
      throw MusicPluginAsrAudioUnavailable('not a plugin track: ${item.path}');
    }
    final File out = fileFor(item.trackUid);
    if (await out.exists() && await out.length() > _kWavHeaderBytes) {
      onProgress(1);
      return out;
    }
    bool cancelled = false;
    unawaited(cancel.then((_) => cancelled = true));
    onProgress(null);
    final MusicPluginStream stream;
    try {
      stream = await _resolver(item.path);
    } on MusicPluginStreamUnavailable catch (e) {
      throw MusicPluginAsrAudioUnavailable(e.message);
    }
    if (cancelled) throw const MusicPluginAsrAudioCancelled();
    await root.create(recursive: true);
    final File part = File('${out.path}.part');
    final List<String> args = musicPluginAsrAudioArgs(
      stream: stream,
      outputPath: part.path,
    );
    final int? durationMs = item.durationMs;
    final FfmpegBackend backend = _backend();
    final FfmpegRunResult result = switch (backend) {
      final FfmpegWatchedRunner watched => await watched.runWatched(
        args,
        FfmpegWatch(
          stallTimeout: kMusicPluginAsrAudioStallTimeout,
          onProgress: durationMs == null || durationMs <= 0
              ? null
              : (Duration processed) => onProgress(
                  (processed.inMilliseconds / durationMs).clamp(0.0, 1.0),
                ),
          cancel: cancel,
        ),
      ),
      _ => await backend.run(args, kMusicPluginAsrAudioTimeout),
    };
    final bool ok =
        !cancelled &&
        result.returnCode == 0 &&
        await part.exists() &&
        await part.length() > _kWavHeaderBytes;
    if (!ok) {
      if (await part.exists()) await part.delete();
      if (cancelled) throw const MusicPluginAsrAudioCancelled();
      final List<String> lines = result.output.trim().split('\n');
      throw MusicPluginAsrAudioUnavailable(
        'audio download failed (exit ${result.returnCode}): ${lines.last}',
      );
    }
    if (await out.exists()) await out.delete();
    await part.rename(out.path);
    onProgress(1);
    return out;
  }
}
