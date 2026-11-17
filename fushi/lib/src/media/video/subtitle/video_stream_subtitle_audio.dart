/// 在线流（非互联远端：在线视频源、粘贴的流 / YouTube、音乐 MV、媒体服务器、云盘流）→
/// 本机可转写的整集音频副本，供「生成字幕」完整管线当输入。
///
/// 管线（`VideoSubtitlePipeline`）的任务身份、时长探测、证据收集、导出位置全按「本机媒体
/// 文件」建模，在线流的地址又短时效、要带防盗链头。所以不把 URL 塞进管线，而是开管线
/// 之前把这一集的音频用 ffmpeg 拉成本机文件，管线照本机文件处理（与音乐插件曲目
/// `music_plugin_asr_audio.dart` 同一思路）：
///
/// - 位置：`<文档>/video_subtitles/stream_audio/<标题> [<键>].m4a`。键按「来源 + 视频 id +
///   集下标 + 音轨」派生，文件名稳定，管线任务键（文件名 + 字节数）因而稳定：中途取消 /
///   失败后再开，识别稿与 AI 校对进度照常续上。归在存储页「字幕」类目（`video_subtitles`）
///   下，用户在存储页能看到、能清。
/// - 只是转写的中间产物：字幕登记后由落点删掉（[VideoStreamSubtitleSink]），任务失败 /
///   取消时留着，下次直接用、不重拉。
/// - 拉取有进度（ffmpeg `-progress` 的已处理媒体时间 / 片长）、可取消，卡死判据是「已处理
///   时间这么久不推进」（[FfmpegWatch.stallTimeout]），不是按片长估一个总时限。
/// - 地址由调用方在开拉前现取（[VideoStreamSubtitleAudioPrepare]，见
///   `RemoteVideoSubtitleAudioRefresh`）：短 TTL 的签名链接不能沿用起播时那一条。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_frame_reference.dart'
    show SubtitleFrameSource, kSubtitleReferenceFrameWidth;
import 'package:fushi_engine/media/video/video_clip_exporter.dart'
    show resolveAudioMapIndex;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show
        buildFfmpegRemoteInputArgs,
        extractVideoFrameViaFfmpeg,
        ffmpegRemoteInputFor;
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_mpv_config.dart'
    show isNetworkStreamUri;
import 'package:fushi/src/storage/app_paths.dart';

/// 播放页当前这一集的整集音频从哪条地址读：播放器正从外挂 / 分离音轨出声
/// （[miningAudioSource]：YouTube audio-only 流、扩展的外挂音轨）就读那条，否则读视频流
/// 本身（[miningSource]）。不是网络流（本机文件 / 空）返回 null。
({String url, bool audioOnly})? currentVideoStreamSubtitleAudio({
  required String? miningSource,
  required String? miningAudioSource,
}) {
  if (miningAudioSource != null && isNetworkStreamUri(miningAudioSource)) {
    return (url: miningAudioSource, audioOnly: true);
  }
  if (miningSource != null && isNetworkStreamUri(miningSource)) {
    return (url: miningSource, audioOnly: false);
  }
  return null;
}

/// 播放页这一集能不能把整集音频拉到本机跑字幕管线：是远端视频、不是互联 host 的视频
/// （[hasHostTarget]：那些由 host 自己裁音频 / 跑管线），且当前播放的是网络流。
bool videoStreamSubtitleAudioAvailable({
  required bool isRemote,
  required bool hasHostTarget,
  required String? miningSource,
  required String? miningAudioSource,
}) =>
    isRemote &&
    !hasHostTarget &&
    currentVideoStreamSubtitleAudio(
          miningSource: miningSource,
          miningAudioSource: miningAudioSource,
        ) !=
        null;

/// `<文档>/video_subtitles/stream_audio`：在线流整集音频副本的目录。
Directory videoStreamSubtitleAudioRootUnder(Directory subtitlesDirectory) =>
    Directory(p.join(subtitlesDirectory.path, 'stream_audio'));

/// `<文档>/video_subtitles/generated`：在线流生成字幕的导出目录（流没有「媒体旁」）。
Directory videoStreamSubtitleExportDirUnder(Directory subtitlesDirectory) =>
    Directory(p.join(subtitlesDirectory.path, 'generated'));

/// 一集在线流整集音频的身份键：来源 + 视频 id + 集下标 + 音轨。与地址无关（地址会过期、
/// 本地中继端口随进程变）。
String videoStreamSubtitleAudioKey({
  required String sourceId,
  required String videoId,
  required int episode,
  required String audioTrack,
}) => sha256
    .convert(utf8.encode('$sourceId|$videoId|$episode|$audioTrack'))
    .toString()
    .substring(0, 16);

/// 标题进文件名时的上限（字符）：导出字幕名 = 音频主名 + `.<语言>.srt`，字幕轨菜单里
/// 显示的就是它，太长没意义，也容易撞路径长度上限。
const int _kTitleMaxChars = 60;

/// 这一集的整集音频副本：`<标题> [<键>].m4a`。标题只为了导出字幕的文件名让人认得出，
/// 身份全在键里。
File videoStreamSubtitleAudioFileIn(
  Directory root, {
  required String key,
  required String title,
}) {
  String name = safeWindowsFileName(title).trim();
  if (name.length > _kTitleMaxChars) {
    name = name.substring(0, _kTitleMaxChars).trim();
  }
  if (name.isEmpty) name = 'stream';
  return File(p.join(root.path, '$name [$key].m4a'));
}

/// 开拉时已就绪的输入：[url] 已改写成 ffmpeg 直接读的形式（需要时已登记本机中继）。
@immutable
class VideoStreamSubtitleAudioInput {
  const VideoStreamSubtitleAudioInput({
    required this.url,
    this.headers = const <String, String>{},
    this.audioStreamIndex,
    this.audioStreamCount,
  });

  final String url;
  final Map<String, String> headers;

  /// 播放器当前音轨（纯音频流为 null：只有一条）。
  final int? audioStreamIndex;
  final int? audioStreamCount;
}

/// 开拉前现取输入（刷新签名地址、登记中继）。
typedef VideoStreamSubtitleAudioPrepare =
    Future<VideoStreamSubtitleAudioInput> Function();

/// 流 → 单声道 64k AAC（`.m4a`）的 ffmpeg 参数。与 host 裁整集音轨同规格（波形 / 互相关 /
/// 16 kHz 转录都绰绰有余，24 分钟一集约 11 MB）。远端输入参数（UA / Referer / 其余请求头 /
/// 断线重连 / 中继代理）与制卡截音频共用 [buildFfmpegRemoteInputArgs]，不另写一套。
List<String> videoStreamSubtitleAudioArgs({
  required VideoStreamSubtitleAudioInput input,
  required String outputPath,
}) {
  final int? map = resolveAudioMapIndex(
    audioStreamIndex: input.audioStreamIndex,
    audioStreamCount: input.audioStreamCount,
  );
  return <String>[
    '-y',
    '-v',
    'error',
    ...buildFfmpegRemoteInputArgs(input.url, httpHeaders: input.headers),
    '-i',
    ffmpegRemoteInputFor(input.url),
    '-vn',
    '-sn',
    '-dn',
    '-map_chapters',
    '-1',
    // 尾随 '?'：越界音轨映射降级回退默认轨而非硬失败（与制卡同口径，BUG-345）。
    if (map != null) ...<String>['-map', '0:a:$map?'],
    '-ac',
    '1',
    '-c:a',
    'aac',
    '-b:a',
    '64k',
    // 写到 `.part` 再改名：扩展名认不出容器，显式给。
    '-f',
    'mp4',
    outputPath,
  ];
}

/// 拉流的卡死判据：已处理媒体时间这么久不推进就强杀（与管线抽音轨同一口径）。
const Duration kVideoStreamSubtitleAudioStallTimeout = Duration(minutes: 2);

/// 不支持观察式运行的后端（测试替身 / 未知后端）的总时限。
const Duration kVideoStreamSubtitleAudioTimeout = Duration(hours: 3);

/// 拉不到这一集的音频（取流失败 / ffmpeg 失败）；[message] 是给用户看的原因摘要。
final class VideoStreamSubtitleAudioUnavailable implements Exception {
  const VideoStreamSubtitleAudioUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用户取消了拉取。
final class VideoStreamSubtitleAudioCancelled implements Exception {
  const VideoStreamSubtitleAudioCancelled();

  @override
  String toString() => 'cancelled';
}

/// 一次在途的拉取：进度（0~1；片长未知时 null = 不定态）、取消、结果。同一集同时只有
/// 一次在途，第二个入口（工作台内嵌面板与播放器菜单同时点）拿到的是同一个对象。
class VideoStreamSubtitleAudioStaging {
  VideoStreamSubtitleAudioStaging._(this.key);

  final String key;
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
  final Completer<void> _cancel = Completer<void>();
  late final Future<File> done;

  bool get cancelRequested => _cancel.isCompleted;

  /// 强杀 ffmpeg（取流阶段则在取完后放弃）；[done] 以 [VideoStreamSubtitleAudioCancelled]
  /// 结束。
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }
}

/// 把在线流的整集音频拉到本机（[start]）。
class VideoStreamSubtitleAudioStager {
  VideoStreamSubtitleAudioStager({
    required this.root,
    FfmpegBackend Function()? backend,
  }) : _backend = backend ?? resolveFfmpegBackend;

  /// 副本目录（[videoStreamSubtitleAudioRootUnder]）。
  final Future<Directory> Function() root;
  final FfmpegBackend Function() _backend;

  final Map<String, VideoStreamSubtitleAudioStaging> _inflight =
      <String, VideoStreamSubtitleAudioStaging>{};

  /// 这一集已经拉好的副本；没有返回 null。
  Future<File?> existing({required String key, required String title}) async {
    final File out = videoStreamSubtitleAudioFileIn(
      await root(),
      key: key,
      title: title,
    );
    return await out.exists() && await out.length() > 0 ? out : null;
  }

  /// 这一集正在拉的那一次（没有为 null）。
  VideoStreamSubtitleAudioStaging? inflight(String key) => _inflight[key];

  /// 拉这一集（[key] / [title] 见 [videoStreamSubtitleAudioFileIn]）。已有完整副本直接
  /// 完成；同一集已在拉就返回那一次。[prepare] 在真正开拉前调用一次（现取地址）；
  /// [durationMs] 是片长（进度分母，≤0 时进度不定）。
  ///
  /// [VideoStreamSubtitleAudioStaging.done] 失败抛 [VideoStreamSubtitleAudioUnavailable]；
  /// 取消抛 [VideoStreamSubtitleAudioCancelled]。
  VideoStreamSubtitleAudioStaging start({
    required String key,
    required String title,
    required int durationMs,
    required VideoStreamSubtitleAudioPrepare prepare,
  }) {
    final VideoStreamSubtitleAudioStaging? running = _inflight[key];
    if (running != null) return running;
    final VideoStreamSubtitleAudioStaging staging =
        VideoStreamSubtitleAudioStaging._(key);
    _inflight[key] = staging;
    staging.done = _run(
      staging,
      title: title,
      durationMs: durationMs,
      prepare: prepare,
    ).whenComplete(() => _inflight.remove(key));
    return staging;
  }

  Future<File> _run(
    VideoStreamSubtitleAudioStaging staging, {
    required String title,
    required int durationMs,
    required VideoStreamSubtitleAudioPrepare prepare,
  }) async {
    final Directory dir = await root();
    final File out = videoStreamSubtitleAudioFileIn(
      dir,
      key: staging.key,
      title: title,
    );
    if (await out.exists() && await out.length() > 0) {
      staging.progress.value = 1;
      return out;
    }
    final VideoStreamSubtitleAudioInput input;
    try {
      input = await prepare();
    } on Exception catch (e) {
      if (staging.cancelRequested) {
        throw const VideoStreamSubtitleAudioCancelled();
      }
      throw VideoStreamSubtitleAudioUnavailable(e.toString());
    }
    if (staging.cancelRequested) {
      throw const VideoStreamSubtitleAudioCancelled();
    }
    await dir.create(recursive: true);
    final File part = File('${out.path}.part');
    final List<String> args = videoStreamSubtitleAudioArgs(
      input: input,
      outputPath: part.path,
    );
    final FfmpegBackend backend = _backend();
    final FfmpegRunResult result = switch (backend) {
      final FfmpegWatchedRunner watched => await watched.runWatched(
        args,
        FfmpegWatch(
          stallTimeout: kVideoStreamSubtitleAudioStallTimeout,
          onProgress: durationMs <= 0
              ? null
              : (Duration processed) => staging.progress.value =
                    (processed.inMilliseconds / durationMs).clamp(0.0, 1.0),
          cancel: staging._cancel.future,
        ),
      ),
      _ => await backend.run(args, kVideoStreamSubtitleAudioTimeout),
    };
    final bool ok =
        !staging.cancelRequested &&
        result.returnCode == 0 &&
        await part.exists() &&
        await part.length() > 0;
    if (!ok) {
      if (await part.exists()) await part.delete();
      if (staging.cancelRequested) {
        throw const VideoStreamSubtitleAudioCancelled();
      }
      final List<String> lines = result.output.trim().split('\n');
      throw VideoStreamSubtitleAudioUnavailable(
        'ffmpeg exit ${result.returnCode}: ${lines.last}',
      );
    }
    if (await out.exists()) await out.delete();
    await part.rename(out.path);
    staging.progress.value = 1;
    return out;
  }
}

/// 进程内共用的拉取器：同一集同时只有一次在途（工作台内嵌面板、播放器菜单、本机转录 /
/// 重定时都经它），重开播放页也能接上还在拉的那一次。副本放
/// `<文档>/video_subtitles/stream_audio`。
final VideoStreamSubtitleAudioStager appVideoStreamSubtitleAudioStager =
    VideoStreamSubtitleAudioStager(
      root: () async => videoStreamSubtitleAudioRootUnder(
        await AppPaths.videoSubtitlesDirectory(),
      ),
    );

/// 在线流的「参考画面」取帧：副本只有音频，画面从播放中的视频流里按时间点抽一帧（缩到
/// [kSubtitleReferenceFrameWidth] 宽的 JPEG）。[input] 第一次取帧时调用一次（登记中继、
/// 解析 HLS master），之后各帧复用；取不到的帧返回 null，由管线跳过（与本机取帧同口径）。
SubtitleFrameSource videoStreamSubtitleFrameSource({
  required Future<String> Function() input,
  Map<String, String> headers = const <String, String>{},
}) {
  Future<String>? resolved;
  return (String _, int atMs) async {
    final String url = await (resolved ??= input());
    final Directory tmp = await Directory.systemTemp.createTemp(
      'fushi_stream_subtitle_frame_',
    );
    try {
      final String? produced = await extractVideoFrameViaFfmpeg(
        inputPath: ffmpegRemoteInputFor(url),
        outputPath: p.join(tmp.path, 'frame.jpg'),
        atSeconds: atMs / 1000,
        scaleWidth: kSubtitleReferenceFrameWidth,
        httpHeaders: headers,
        // 定位落在片尾之后 / 链接已过期是预期内的结果：记诊断，不算错误。
        diagnosticOnly: true,
      );
      if (produced == null) return null;
      return await File(produced).readAsBytes();
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // 临时目录删不掉不影响结果，留给系统清理。
      }
    }
  };
}
