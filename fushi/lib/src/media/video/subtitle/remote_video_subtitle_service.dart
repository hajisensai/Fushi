/// 互联远端视频的「生成日语字幕」：整条管线在**放视频的那台 host** 上跑（host 任务
/// `kind=video_subtitle`，`VideoSubtitleHostJobRunner`），本机只提交、轮询、取回 SRT。
///
/// - 识别、专名表、AI 校对都用 host 自己的模型与 AI 指派；host 没指派「字幕校对」
///   时它直接拒绝（400），报错原样给用户，不在本机悄悄改成不校对。
/// - 老 host 的 capability 里没有 `video_subtitle`：[RemoteVideoSubtitleJobStatus.unsupported]，
///   面板给「host 版本不支持」，不发任务。
/// - host 播放列表（一行 `video_books` 带 `playlistJson`）的第 N 集：任务带
///   `episode=N`，host 按集解析那一集的文件、字幕写在那一集旁。老 host 不认 `episode`
///   （会静默跑第 0 集），所以只有 capability 声明 `acceptsEpisode` 才发；否则
///   [RemoteVideoSubtitleJobStatus.episodeUnsupported]，不发任务。
/// - 远端原盘会话的 title（盘在 host 上，本机没有文件）：host 库里有这条 title 的行就按
///   它的 `videoId` 提交；没有（菜单里的特典等）就用同盘一行当锚点、带 `discTitle`
///   （相对盘根的 `BDMV/PLAYLIST/<名>.mpls`），host 按（盘, title）定位，产物落 host 的
///   `disc_out`、随任务产物取回。老 host 不认 `discTitle`（会静默跑锚点那一行），所以
///   只有 capability 声明 `acceptsDiscTitle` 才发；否则
///   [RemoteVideoSubtitleJobStatus.discTitleUnsupported]，不发任务。会话正放多角度 title
///   的非第 1 个角度时 `discTitle` 是角度成员路径（`00001.a2.mpls`），还要 host 声明
///   `acceptsDiscTitleAngle`（老 host 读不到这个虚拟路径），否则同样
///   [RemoteVideoSubtitleJobStatus.discTitleUnsupported]。DVD title
///   （`VIDEO_TS/TITLE_nn.dvdtitle`）要 `acceptsDiscTitleDvd`，它的角度成员路径
///   （`TITLE_nn.a2.dvdtitle`）再要 `acceptsDiscTitleDvdAngle`，缺哪个都同样不发。
/// - 从播放页发起的单集带播放器当前音轨（`audioTrack`，0 起的音轨序号 = ffmpeg
///   `0:a:N`；远端直传播放的就是 host 那份文件 / 那条 title，播放器的音轨序号与 host
///   ffmpeg 的音频流相对序号同口径），host 识别那条轨。老 host 不认 `audioTrack`（会
///   静默按识别语言挑），capability 没声明 `acceptsAudioTrack` 时不带它照常发——这是
///   降级、不是错结果，面板如实提示「将按语言自动选择音轨」。
/// - 整季（远端合集）：wire 上的远端视频只带合集**名**、不带 host 的合集 id，所以按
///   成员逐集提交 `videoId` 任务。host 侧 `SubtitleWorkContextLoader.forBook` 会把合集
///   成员解析到同一个作品键（`collection:<host 合集 id>`），各集共用 host 上的同一张
///   专名表（第一集生成，后面的复用）。已有 `.ja.srt` 的成员跳过。
/// - 语言：host 的 capability 在 `languages` 里列出认的 `language` 取值时，面板给语言
///   选择、任务带 `language`；没列的 host 只发日语任务（老 host 不认 `language`，会静默
///   按日语跑），选了别的语言就是 [RemoteVideoSubtitleJobStatus.languageUnsupported]，
///   不发任务。任务键与整季的「已有字幕跳过」都按语言分
///   （[RemoteVideoSubtitleTarget.forLanguage]）；整季各集另带 `skipExisting`，host 上
///   已有所选语言字幕、但列表没报出来的集由 host 跳过（`skippedExistingSubtitle`）。
/// - 产物：host 库视频会在 host 那边视频旁导出（`<视频名>.ja.srt`，视频有别的 ASS 时
///   另有套了它样式的 `.ja.ass`）；本机把取回的字幕（有 ASS 取 ASS）复制进
///   `video_subtitles/`，由视频页按「远端视频加外挂字幕」同一条路加载。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/media/video/bluray/bluray_angle.dart'
    show parseBlurayAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show parseDvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show isDvdTitlePath;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_host_job_runner.dart'
    show kVideoSubtitleJobKind, kVideoSubtitleSummaryOutput;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleStage;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart'
    show AudioTrackFacts;
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 和 host 打交道的接缝（生产实现 [InterconnectVideoSubtitleHostPort]，测试注入 fake）。
abstract interface class RemoteVideoSubtitleHostPort {
  /// 放视频的那台 host 的任务能力；null = 连不上 / 没配对。
  Future<HostJobTarget?> probe();

  /// 提交一个 `video_subtitle` 任务并跟到终态（取消订阅 = 远端取消）。
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  });
}

/// 生产实现：[InterconnectJobClient]（与有声书「在互联 host 上转录」同一个客户端）。
class InterconnectVideoSubtitleHostPort implements RemoteVideoSubtitleHostPort {
  InterconnectVideoSubtitleHostPort({
    required this.client,
    required this.activeBaseUrl,
  });

  final InterconnectJobClient client;

  /// 互联当前连着的 host 地址（远端视频就来自它）；null = 还没连上。
  final String? Function() activeBaseUrl;

  @override
  Future<HostJobTarget?> probe() async {
    final String? baseUrl = activeBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) return null;
    return client.probeHost(baseUrl);
  }

  @override
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  }) => client.run(
    target: target,
    kind: kVideoSubtitleJobKind,
    params: params,
    inputs: const <File>[],
    outputDir: outputDir,
  );
}

/// 远端的一集（`RemoteVideoInfo.id` = host 的 `video_books.book_uid`）。
@immutable
class RemoteVideoSubtitleEpisode {
  const RemoteVideoSubtitleEpisode({
    required this.videoId,
    required this.title,
    this.episodeIndex = 0,
    this.discTitle,
    this.audioTrack,
  }) : assert(
         discTitle == null || episodeIndex == 0,
         'episodeIndex and discTitle are exclusive',
       ),
       assert(audioTrack == null || audioTrack >= 0, 'audioTrack >= 0');

  final String videoId;

  /// host 上这一行播放列表的集下标（0 = 主视频 / 单视频），与播放端点的
  /// `?episode=` 同口径。同一个播放列表的各集共用 [videoId]，靠它区分。
  final int episodeIndex;
  final String title;

  /// 远端原盘会话：[videoId] 那一行所在蓝光盘上的另一条 title（相对盘根，
  /// `BDMV/PLAYLIST/<名>.mpls`）；null = 就是 [videoId] 那一行（的第 [episodeIndex] 集）。
  final String? discTitle;

  /// 从播放页发起时播放器当前的音轨（0 起的音轨序号，ffmpeg `0:a:N`，即
  /// `VideoPlayerController.currentAudioStreamIndex`）：host 识别这条轨（任务参数
  /// `audioTrack`）。null = 没有播放上下文（整季 / 合集页）或跟随默认，host 按识别语言挑。
  final int? audioTrack;

  /// (videoId, 集下标 / 盘上 title) 的稳定标识：任务键、落盘名都按它分。
  String get key => discTitle != null
      ? '$videoId@$discTitle'
      : episodeIndex == 0
      ? videoId
      : '$videoId#$episodeIndex';

  /// 这一集是不是 host 上的 ([videoId], [index])（不是盘上另一条 title）。
  bool matches(String videoId, int index) =>
      this.videoId == videoId && episodeIndex == index && discTitle == null;

  /// 这一集是不是 host 上 ([videoId], [discTitle]) 那条原盘 title（[discTitle] 为 null
  /// = [videoId] 那一行本身）。
  bool matchesDiscTitle(String videoId, String? discTitle) =>
      this.videoId == videoId &&
      episodeIndex == 0 &&
      this.discTitle == discTitle;
}

/// 整季的一个远端成员与 host 报的它当前的字幕文件名（`RemoteVideoInfo.subtitleFileName`）。
@immutable
class RemoteVideoSubtitleSeasonMember {
  const RemoteVideoSubtitleSeasonMember({
    required this.episode,
    this.subtitleFileName,
  });

  final RemoteVideoSubtitleEpisode episode;
  final String? subtitleFileName;

  /// 已有 [language] 的字幕（`<视频名>.<tag>.srt`），整季时跳过。host 只报它学习语言
  /// 那一条，所以这里只能认出一部分；漏掉的由 host 按 `skipExisting` 再跳过。
  bool hasSubtitle(VideoSubtitleLanguage language) =>
      subtitleFileName?.toLowerCase().endsWith('.${language.tag}.srt') ?? false;
}

/// 一次远端生成的目标。
@immutable
class RemoteVideoSubtitleTarget {
  const RemoteVideoSubtitleTarget({
    required this.title,
    required this.episodes,
    this.wholeSeason = false,
    this.skippedExisting = const <String>[],
    this.audioLanguages = const <String>[],
    this.originalLanguage,
  }) : _seasonMembers = null,
       language = VideoSubtitleLanguage.japanese;

  /// 整季（远端合集）：[members] 里已有 [language] 字幕的成员跳过、只列标题，其余逐集
  /// 提交。换语言用 [forLanguage]。
  RemoteVideoSubtitleTarget.season({
    required this.title,
    required List<RemoteVideoSubtitleSeasonMember> members,
    this.language = VideoSubtitleLanguage.japanese,
    this.audioLanguages = const <String>[],
    this.originalLanguage,
  }) : wholeSeason = true,
       _seasonMembers = members,
       episodes = <RemoteVideoSubtitleEpisode>[
         for (final RemoteVideoSubtitleSeasonMember m in members)
           if (!m.hasSubtitle(language)) m.episode,
       ],
       skippedExisting = <String>[
         for (final RemoteVideoSubtitleSeasonMember m in members)
           if (m.hasSubtitle(language)) m.episode.title,
       ];

  /// 整季目标的全部成员；null = 不是按成员建的（单集 / 调用方自己算好了跳过）。
  final List<RemoteVideoSubtitleSeasonMember>? _seasonMembers;

  /// 「已有字幕跳过」按的语言（只对 [RemoteVideoSubtitleTarget.season] 有意义）。
  final VideoSubtitleLanguage language;

  /// 生成 [next] 语言时的目标：整季按 [next] 重算跳过哪些成员；其它目标原样。
  RemoteVideoSubtitleTarget forLanguage(VideoSubtitleLanguage next) {
    final List<RemoteVideoSubtitleSeasonMember>? members = _seasonMembers;
    if (members == null || next == language) return this;
    return RemoteVideoSubtitleTarget.season(
      title: title,
      members: members,
      language: next,
      audioLanguages: audioLanguages,
      originalLanguage: originalLanguage,
    );
  }

  /// 播放器当前这份片源的音轨语言标签（发起端是播放页时才有；远端直传播放的就是 host
  /// 上那份文件，标签与 host ffprobe 读到的同源）。面板猜语言初值用。
  final List<String> audioLanguages;

  /// 刮削的作品原语言（合集页 / 播放页认得出作品时才有）。面板猜语言初值用。
  final String? originalLanguage;

  /// 面板语言初值与来由：与本机面板同一套证据排序（[resolveVideoSubtitleLanguage]：
  /// 音轨标签 → 作品原语言 → 日语）。远端没有逐集的内容语言可读（host 不在 wire 上报），
  /// 也不在本机 ffprobe host 的文件，所以只用发起端已经握在手里的证据。
  VideoSubtitleLanguageGuess get languageGuess => resolveVideoSubtitleLanguage(
    audioTracks: <AudioTrackFacts>[
      for (int i = 0; i < audioLanguages.length; i++)
        AudioTrackFacts(index: i, language: audioLanguages[i]),
    ],
    originalLanguage: originalLanguage,
  );

  final String title;
  final List<RemoteVideoSubtitleEpisode> episodes;
  final bool wholeSeason;

  /// 整季：已有日语字幕、不提交的成员标题。
  final List<String> skippedExisting;

  String get key =>
      'remote:${episodes.map((RemoteVideoSubtitleEpisode e) => e.key).join('|')}';

  /// 有没有 host 播放列表第 2 集起的集（要 host 声明 `acceptsEpisode`）。
  bool get needsEpisodeSupport =>
      episodes.any((RemoteVideoSubtitleEpisode e) => e.episodeIndex > 0);

  /// 有没有要 host 按（盘, title）定位的原盘 title（要 host 声明 `acceptsDiscTitle`）。
  bool get needsDiscTitleSupport =>
      episodes.any((RemoteVideoSubtitleEpisode e) => e.discTitle != null);

  /// 有没有按多角度 title 的角度成员路径定位的原盘 title（要 host 声明
  /// `acceptsDiscTitleAngle`）。
  bool get needsDiscTitleAngleSupport => episodes.any(
    (RemoteVideoSubtitleEpisode e) =>
        e.discTitle != null && parseBlurayAnglePath(e.discTitle!) != null,
  );

  /// 有没有要 host 识别指定音轨的集（要 host 声明 `acceptsAudioTrack`；不声明时降级成
  /// 按识别语言挑，不拦任务）。
  bool get wantsAudioTrack =>
      episodes.any((RemoteVideoSubtitleEpisode e) => e.audioTrack != null);

  /// 有没有按 DVD title（`VIDEO_TS/TITLE_nn.dvdtitle`）定位的原盘 title（要 host 声明
  /// `acceptsDiscTitleDvd`）。
  bool get needsDiscTitleDvdSupport => episodes.any(
    (RemoteVideoSubtitleEpisode e) =>
        e.discTitle != null && isDvdTitlePath(e.discTitle!),
  );

  /// 有没有按 DVD 多角度 title 的角度成员路径（`VIDEO_TS/TITLE_nn.aK.dvdtitle`）定位的
  /// 原盘 title（要 host 声明 `acceptsDiscTitleDvdAngle`）。
  bool get needsDiscTitleDvdAngleSupport => episodes.any(
    (RemoteVideoSubtitleEpisode e) =>
        e.discTitle != null && parseDvdTitleAnglePath(e.discTitle!) != null,
  );

  /// host [target] 认不认这个目标里的全部原盘 title 形态（`discTitle` 本身、蓝光角度成员、
  /// DVD title、DVD 角度成员各要各的能力位）。不认就不发任务
  /// （[RemoteVideoSubtitleJobStatus.discTitleUnsupported]），面板同一判据。
  bool discTitlesSupportedBy(HostJobTarget target) =>
      !(needsDiscTitleSupport && !hostAcceptsVideoSubtitleDiscTitle(target)) &&
      !(needsDiscTitleAngleSupport &&
          !hostAcceptsVideoSubtitleDiscTitleAngle(target)) &&
      !(needsDiscTitleDvdSupport &&
          !hostAcceptsVideoSubtitleDiscTitleDvd(target)) &&
      !(needsDiscTitleDvdAngleSupport &&
          !hostAcceptsVideoSubtitleDiscTitleDvdAngle(target));
}

/// 远端任务的选项（AI 提供商是 host 自己的，不在这里）。
@immutable
class RemoteVideoSubtitleOptions {
  const RemoteVideoSubtitleOptions({
    this.proofread = false,
    this.segmenter = VideoSubtitleSegmenterMode.auto,
    this.mossBackend = MossBackendPreference.auto,
    this.frames = false,
    this.language = VideoSubtitleLanguage.japanese,
  });

  final bool proofread;

  /// 识别 / 校对的语言。日语以外要 host 在 capability 的 `languages` 里列出
  /// （[hostAcceptsVideoSubtitleLanguage]）。
  final VideoSubtitleLanguage language;

  /// 画面参考：host 的 AI 校对每批附上它那边这个视频的画面（host 的提供商能收图时
  /// 才生效；老 host 不认这个参数，照常纯文字校对）。
  final bool frames;
  final VideoSubtitleSegmenterMode segmenter;
  final MossBackendPreference mossBackend;
}

enum RemoteVideoSubtitleJobStatus {
  /// 正在问 host 支不支持。
  probing,
  running,
  succeeded,

  /// host 版本不支持 `video_subtitle`。
  unsupported,

  /// host 支持 `video_subtitle`，但版本太老、不认播放列表的集下标（capability 没有
  /// `acceptsEpisode`）：发过去会静默跑第 1 集，所以不发。
  episodeUnsupported,

  /// host 支持 `video_subtitle`，但版本太老、不认按（盘, title）定位（capability 没有
  /// `acceptsDiscTitle`）：发过去会静默跑锚点那一行，所以不发。
  discTitleUnsupported,

  /// 选了日语以外的语言，而 host 没在 capability 的 `languages` 里列出它（老 host
  /// 不认 `language`，发过去会静默按日语跑），所以不发。
  languageUnsupported,

  /// 连不上放视频的 host。
  unreachable,

  /// host 报错（[RemoteVideoSubtitleJob.error] 是 host 的原话）。
  failed,
  cancelled,
}

/// 一集在远端任务里的进度与结果。
class RemoteVideoSubtitleEpisodeProgress {
  RemoteVideoSubtitleEpisodeProgress(this.episode);

  final RemoteVideoSubtitleEpisode episode;

  /// 当前阶段（从 host 的进度文本 `<阶段>: <消息>` 解析）；null = 还没轮到。
  VideoSubtitleStage? stage;
  String? message;
  double progress = 0;

  /// 取回并复制进 `video_subtitles/` 的字幕（有套样式的 ASS 取 ASS，否则 SRT）；
  /// 没导出为 null。
  File? subtitle;

  /// host summary 里这一集的状态（`exported` / `skippedSong` …）与原因。
  String? status;
  String? reason;
  bool done = false;
}

/// 一次远端生成任务。
class RemoteVideoSubtitleJob extends ChangeNotifier {
  RemoteVideoSubtitleJob._(this.target, this.options, this._order)
    : episodes = <RemoteVideoSubtitleEpisodeProgress>[
        for (final RemoteVideoSubtitleEpisode e in target.episodes)
          RemoteVideoSubtitleEpisodeProgress(e),
      ];

  final RemoteVideoSubtitleTarget target;
  final RemoteVideoSubtitleOptions options;
  final List<RemoteVideoSubtitleEpisodeProgress> episodes;
  final Completer<void> _done = Completer<void>();

  /// 本进程里第几个起的任务（比较「最近一次」）。
  final int _order;

  RemoteVideoSubtitleJobStatus status = RemoteVideoSubtitleJobStatus.probing;

  /// 执行的 host（显示名）。
  String? hostLabel;

  /// host 的报错原话（[RemoteVideoSubtitleJobStatus.failed]）。
  String? error;

  /// 正在跑的那一集下标。
  int current = 0;

  bool _cancelRequested = false;
  StreamSubscription<HostJobEvent>? _subscription;

  /// 正在跑的那一集的收尾：订阅被取消后流不再发任何事件，靠它把这一集结束掉。
  void Function()? _onCancel;

  bool get isRunning =>
      status == RemoteVideoSubtitleJobStatus.probing ||
      status == RemoteVideoSubtitleJobStatus.running;
  bool get cancelRequested => _cancelRequested;
  Future<void> get done => _done.future;

  /// 取消：断开订阅，客户端随即 DELETE 远端任务（host 的管线缓存保留，重提交即续）。
  void cancel() {
    if (!isRunning || _cancelRequested) return;
    _cancelRequested = true;
    unawaited(_subscription?.cancel());
    _onCancel?.call();
    notifyListeners();
  }

  void _changed() => notifyListeners();

  void _finish(RemoteVideoSubtitleJobStatus next) {
    status = next;
    if (!_done.isCompleted) _done.complete();
    notifyListeners();
  }
}

/// host 进度文本 `<阶段>: <消息>` → 阶段（认不出 null）。
VideoSubtitleStage? parseRemoteVideoSubtitleStage(String? message) {
  if (message == null) return null;
  final int colon = message.indexOf(':');
  final String name = (colon < 0 ? message : message.substring(0, colon))
      .trim();
  for (final VideoSubtitleStage s in VideoSubtitleStage.values) {
    if (s.name == name) return s;
  }
  return null;
}

/// host 的 `video_subtitle` 能力里有没有 `acceptsEpisode`（认播放列表集下标）。老 host
/// 没有这个位：它不校验未知参数，收到 `episode` 会照第 0 集跑完并把结果当第 N 集回。
bool hostAcceptsVideoSubtitleEpisode(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  return entry is Map && entry['acceptsEpisode'] == true;
}

/// host 的 `video_subtitle` 能力里有没有 `acceptsDiscTitle`（认按盘 + title 定位）。老
/// host 没有这个位：它不校验未知参数，收到 `discTitle` 会照 `videoId` 那一行跑。
bool hostAcceptsVideoSubtitleDiscTitle(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  return entry is Map && entry['acceptsDiscTitle'] == true;
}

/// host 的 `video_subtitle` 能力里有没有 `acceptsDiscTitleAngle`（`discTitle` 认多角度
/// title 的角度成员路径 `00001.a2.mpls`）。老 host 没有这个位：它读不到这个虚拟路径。
bool hostAcceptsVideoSubtitleDiscTitleAngle(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  return entry is Map && entry['acceptsDiscTitleAngle'] == true;
}

/// host 的 `video_subtitle` 能力里有没有 `acceptsDiscTitleDvd`（`discTitle` 认 DVD title
/// `VIDEO_TS/TITLE_nn.dvdtitle`，经 `dvdvideo` demuxer 按 title 读）。老 host 没有这个位：
/// 它判 DVD title 读不到。
bool hostAcceptsVideoSubtitleDiscTitleDvd(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  return entry is Map && entry['acceptsDiscTitleDvd'] == true;
}

/// host 的 `video_subtitle` 能力里有没有 `acceptsDiscTitleDvdAngle`（`discTitle` 认 DVD
/// 多角度 title 的角度成员路径 `VIDEO_TS/TITLE_nn.aK.dvdtitle`，按该角度读）。只有
/// `acceptsDiscTitleDvd` + `acceptsDiscTitleAngle` 的 host 认不出这种形态（只会报找不到）。
bool hostAcceptsVideoSubtitleDiscTitleDvdAngle(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  return entry is Map && entry['acceptsDiscTitleDvdAngle'] == true;
}

/// host 的 `video_subtitle` 能力里有没有 `acceptsAudioTrack`（认 `audioTrack`，识别指定
/// 音轨）。老 host 没有这个位：它不校验未知参数，收到 `audioTrack` 会静默按识别语言挑，
/// 所以提交方不带它、并在面板上说明将按语言选轨。
bool hostAcceptsVideoSubtitleAudioTrack(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  return entry is Map && entry['acceptsAudioTrack'] == true;
}

/// host 在 `video_subtitle` 能力的 `languages` 里列出的语言；没列（老 host）为空。
List<VideoSubtitleLanguage> hostVideoSubtitleLanguages(HostJobTarget target) {
  final Object? entry = target.capability[kVideoSubtitleJobKind];
  final Object? raw = entry is Map ? entry['languages'] : null;
  if (raw is! List) return const <VideoSubtitleLanguage>[];
  return <VideoSubtitleLanguage>[
    for (final VideoSubtitleLanguage l in VideoSubtitleLanguage.values)
      if (raw.contains(l.tag)) l,
  ];
}

/// host 能不能跑 [language] 的任务：日语一向能（不带 `language` 即日语）；其它语言要
/// host 在 `languages` 里列出——老 host 不校验未知参数，收到 `language` 会静默按日语跑。
bool hostAcceptsVideoSubtitleLanguage(
  HostJobTarget target,
  VideoSubtitleLanguage language,
) =>
    language == VideoSubtitleLanguage.japanese ||
    hostVideoSubtitleLanguages(target).contains(language);

/// host 报错的原话：HTTP 错误体是 `{"error": "..."}` 时取 `error`，否则原样。
String remoteVideoSubtitleErrorText(Object error) {
  if (error is HostJobRemoteException) {
    final String? detail = error.detail;
    if (detail == null || detail.trim().isEmpty) return error.code;
    try {
      final Object? decoded = jsonDecode(detail);
      if (decoded is Map) {
        final Object? message = decoded['message'] ?? decoded['error'];
        if (message is String && message.trim().isNotEmpty) return message;
      }
    } on FormatException {
      // 不是 JSON：原样。
    }
    return detail;
  }
  return '$error';
}

/// 远端生成的编排（进程内一份，面板重开能接回）。
class RemoteVideoSubtitleService {
  RemoteVideoSubtitleService({
    required this.host,
    Future<Directory> Function()? workRoot,
    Future<Directory> Function()? subtitlesDir,
  }) : _workRoot = workRoot ?? _defaultWorkRoot,
       _subtitlesDir = subtitlesDir ?? AppPaths.videoSubtitlesDirectory;

  final RemoteVideoSubtitleHostPort host;
  final Future<Directory> Function() _workRoot;
  final Future<Directory> Function() _subtitlesDir;

  static Future<Directory> _defaultWorkRoot() async => Directory(
    p.join(Directory.systemTemp.path, 'fushi_remote_subtitle_jobs'),
  );

  /// 按（目标, 语言）记的最近一次任务：同一集的日语与普通话是两件事，互不接回。
  final Map<String, RemoteVideoSubtitleJob> _latest =
      <String, RemoteVideoSubtitleJob>{};
  RemoteVideoSubtitleJob? _active;
  int _seq = 0;
  int _jobOrder = 0;

  RemoteVideoSubtitleJob? get activeJob => _active;

  static String _jobKey(
    RemoteVideoSubtitleTarget target,
    VideoSubtitleLanguage language,
  ) => '${target.forLanguage(language).key}|${language.tag}';

  /// [target] 在 [language] 上最近一次任务；[language] 为 null 时取各语言里最近起的
  /// 那一个（面板打开时据此接回并恢复语言）。
  RemoteVideoSubtitleJob? latestJobFor(
    RemoteVideoSubtitleTarget target, {
    VideoSubtitleLanguage? language,
  }) {
    if (language != null) return _latest[_jobKey(target, language)];
    RemoteVideoSubtitleJob? latest;
    for (final VideoSubtitleLanguage l in VideoSubtitleLanguage.values) {
      final RemoteVideoSubtitleJob? job = _latest[_jobKey(target, l)];
      if (job != null && (latest == null || job._order > latest._order)) {
        latest = job;
      }
    }
    return latest;
  }

  /// 只问 host 支不支持（面板打开时显示用）。
  Future<HostJobTarget?> probe() => host.probe();

  /// 起任务并立即返回。已有远端任务在跑抛 [StateError]（面板先接回它）。
  RemoteVideoSubtitleJob start(
    RemoteVideoSubtitleTarget target,
    RemoteVideoSubtitleOptions options,
  ) {
    final RemoteVideoSubtitleJob? active = _active;
    if (active != null && active.isRunning) {
      throw StateError('remote subtitle job already running');
    }
    final RemoteVideoSubtitleJob job = RemoteVideoSubtitleJob._(
      target,
      options,
      _jobOrder++,
    );
    _active = job;
    _latest[_jobKey(target, options.language)] = job;
    unawaited(_run(job));
    return job;
  }

  Future<void> _run(RemoteVideoSubtitleJob job) async {
    try {
      final HostJobTarget? target = await host.probe();
      if (job.cancelRequested) {
        job._finish(RemoteVideoSubtitleJobStatus.cancelled);
        return;
      }
      if (target == null) {
        job._finish(RemoteVideoSubtitleJobStatus.unreachable);
        return;
      }
      job.hostLabel = target.label;
      if (!target.supports(kVideoSubtitleJobKind)) {
        job._finish(RemoteVideoSubtitleJobStatus.unsupported);
        return;
      }
      if (job.target.needsEpisodeSupport &&
          !hostAcceptsVideoSubtitleEpisode(target)) {
        job._finish(RemoteVideoSubtitleJobStatus.episodeUnsupported);
        return;
      }
      if (!job.target.discTitlesSupportedBy(target)) {
        job._finish(RemoteVideoSubtitleJobStatus.discTitleUnsupported);
        return;
      }
      if (!hostAcceptsVideoSubtitleLanguage(target, job.options.language)) {
        job._finish(RemoteVideoSubtitleJobStatus.languageUnsupported);
        return;
      }
      job.status = RemoteVideoSubtitleJobStatus.running;
      job._changed();
      final Directory root = await _workRoot();
      for (int i = 0; i < job.episodes.length; i++) {
        if (job.cancelRequested) break;
        job.current = i;
        final RemoteVideoSubtitleEpisodeProgress e = job.episodes[i];
        final Directory out = Directory(
          p.join(
            root.path,
            '${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
          ),
        );
        // 这一集的产物临时目录不论成功、失败、取消还是取回时抛错都要删，且删完才收尾
        // 任务（BUG-5018）：字幕已复制进 `video_subtitles/`，留着只会在系统临时目录里
        // 越积越多。
        final _RemoteEpisodeOutcome outcome;
        try {
          outcome = await _runEpisode(job, target, e, out);
          if (outcome is _RemoteEpisodeExported) {
            await _collect(target, e, outcome.outputs);
            e.done = true;
            job._changed();
          }
        } finally {
          await _deleteWorkDir(out);
        }
        switch (outcome) {
          case _RemoteEpisodeExported():
            break;
          case _RemoteEpisodeEnded(:final RemoteVideoSubtitleJobStatus status):
            job._finish(status);
            return;
        }
      }
      job._finish(
        job.cancelRequested
            ? RemoteVideoSubtitleJobStatus.cancelled
            : RemoteVideoSubtitleJobStatus.succeeded,
      );
    } catch (error) {
      job.error = remoteVideoSubtitleErrorText(error);
      job._finish(RemoteVideoSubtitleJobStatus.failed);
    } finally {
      if (identical(_active, job)) _active = null;
    }
  }

  /// 删一集的产物临时目录。删不掉（文件被占用等）只进错误日志：任务的成败由 host
  /// 与取回决定，不因清理失败改判；残留随系统临时目录清理。
  Future<void> _deleteWorkDir(Directory out) async {
    try {
      if (await out.exists()) await out.delete(recursive: true);
    } on FileSystemException catch (error, stack) {
      ErrorLogService.instance.log(
        'video.subtitleRemote.cleanup',
        error,
        stack,
      );
    }
  }

  /// 跑一集：成功给产物；失败（[RemoteVideoSubtitleJob.error] 已填）/ 取消给终态，
  /// 由 [_run] 清掉临时目录后收尾。
  Future<_RemoteEpisodeOutcome> _runEpisode(
    RemoteVideoSubtitleJob job,
    HostJobTarget target,
    RemoteVideoSubtitleEpisodeProgress e,
    Directory out,
  ) {
    final Completer<_RemoteEpisodeOutcome> result =
        Completer<_RemoteEpisodeOutcome>();
    job._onCancel = () {
      if (result.isCompleted) return;
      result.complete(
        const _RemoteEpisodeEnded(RemoteVideoSubtitleJobStatus.cancelled),
      );
    };
    final Stream<HostJobEvent> events = host.run(
      target: target,
      params: <String, Object?>{
        'videoId': e.episode.videoId,
        if (e.episode.episodeIndex > 0) 'episode': e.episode.episodeIndex,
        'discTitle': ?e.episode.discTitle,
        // 老 host 不认（会按语言挑）：不带，降级由面板提示。
        if (hostAcceptsVideoSubtitleAudioTrack(target))
          'audioTrack': ?e.episode.audioTrack,
        'proofread': job.options.proofread,
        'segmenter': job.options.segmenter.name,
        'mossBackend': job.options.mossBackend.name,
        if (job.options.proofread && job.options.frames) 'frames': true,
        // 整季：本机只能按列表的 `subtitleFileName` 预先跳过，而它只报 host 学习语言
        // 那一条（`pickSidecar`），别的语言已有的字幕看不到——交给 host 再按所选语言的
        // `<视频名>.<后缀>.srt` 判一次（老 host 不认，照常生成）。
        if (job.target.wholeSeason) 'skipExisting': true,
        // 只发给声明了 `languages` 的 host（上面已拦掉不认所选语言的）；老 host 不带，
        // 按默认日语跑。
        if (hostVideoSubtitleLanguages(target).isNotEmpty)
          'language': job.options.language.tag,
      },
      outputDir: out,
    );
    job._subscription = events.listen(
      (HostJobEvent event) {
        switch (event) {
          case HostJobUploading():
            break;
          case HostJobRunning(:final double progress, :final String? message):
            e
              ..progress = progress
              ..message = message
              ..stage = parseRemoteVideoSubtitleStage(message) ?? e.stage;
            job._changed();
          case HostJobDone(:final Map<String, File> outputs):
            if (!result.isCompleted) {
              result.complete(_RemoteEpisodeExported(outputs));
            }
        }
      },
      onError: (Object error) {
        if (result.isCompleted) return;
        final bool cancelled =
            job.cancelRequested ||
            (error is HostJobRemoteException && error.code == 'cancelled');
        if (!cancelled) job.error = remoteVideoSubtitleErrorText(error);
        result.complete(
          _RemoteEpisodeEnded(
            cancelled
                ? RemoteVideoSubtitleJobStatus.cancelled
                : RemoteVideoSubtitleJobStatus.failed,
          ),
        );
      },
      onDone: () {
        if (result.isCompleted) return;
        // 流没给结果就结束了（不该发生）：按失败收尾，不让任务挂住。
        job.error = t.video_subtitle_ai_remote_result_missing;
        result.complete(
          const _RemoteEpisodeEnded(RemoteVideoSubtitleJobStatus.failed),
        );
      },
      cancelOnError: true,
    );
    return result.future.whenComplete(() {
      job._onCancel = null;
    });
  }

  /// 读 summary.json 记下这一集的去向，把导出的字幕（有 ASS 取 ASS，否则 SRT）复制进
  /// `video_subtitles/`。
  Future<void> _collect(
    HostJobTarget target,
    RemoteVideoSubtitleEpisodeProgress e,
    Map<String, File> outputs,
  ) async {
    String? outputName;
    final File? summary = outputs[kVideoSubtitleSummaryOutput];
    if (summary != null && summary.existsSync()) {
      try {
        final Object? decoded = jsonDecode(await summary.readAsString());
        final Object? list = decoded is Map ? decoded['episodes'] : null;
        if (list is List && list.isNotEmpty && list.first is Map) {
          final Map<Object?, Object?> first =
              list.first as Map<Object?, Object?>;
          e
            ..status = first['status'] as String?
            ..reason = first['reason'] as String?;
          // 套了参考样式的 ASS 优先（颜色 / 位置），没有再取 SRT。
          outputName =
              first['styledOutput'] as String? ?? first['output'] as String?;
        }
      } on FormatException {
        // summary 坏了：退回按扩展名找 SRT。
      }
    }
    File? srt = outputName == null ? null : outputs[outputName];
    srt ??= outputs.values
        .where((File f) => f.path.toLowerCase().endsWith('.srt'))
        .firstOrNull;
    if (srt == null || !srt.existsSync()) return;
    final Directory dir = await _subtitlesDir();
    await dir.create(recursive: true);
    final String key = sha256
        .convert(utf8.encode('${target.baseUrl}|${e.episode.key}'))
        .toString()
        .substring(0, 12);
    final File dest = File(
      p.join(dir.path, 'host-$key-${p.basename(srt.path)}'),
    );
    await srt.copy(dest.path);
    e
      ..subtitle = dest
      ..status ??= 'exported';
  }
}

/// 一集远端任务的去向（[RemoteVideoSubtitleService._runEpisode]）。
sealed class _RemoteEpisodeOutcome {
  const _RemoteEpisodeOutcome();
}

/// host 跑完、给了产物。
final class _RemoteEpisodeExported extends _RemoteEpisodeOutcome {
  const _RemoteEpisodeExported(this.outputs);

  final Map<String, File> outputs;
}

/// 这一集以 [status]（失败 / 取消）结束，整个任务随之结束。
final class _RemoteEpisodeEnded extends _RemoteEpisodeOutcome {
  const _RemoteEpisodeEnded(this.status);

  final RemoteVideoSubtitleJobStatus status;
}

/// 进程内共用的实例：面板 / 合集页 / 视频页共用任务表（重开面板接回同一个任务）。
/// 远端视频都来自互联当前连着的 host（[InterconnectSyncBackend.instance]），任务就
/// 打到那一台。只收库（互联凭据在库里），不收 AppModel：服务本体再 import AppModel 就会把它
/// 连同远端字幕面板拖进 lib/ 的 import 大环（`test/build/import_cycle_guard_test.dart`）。
RemoteVideoSubtitleService appRemoteVideoSubtitleService(
  FushiDatabase database,
) => _sharedRemote ??= RemoteVideoSubtitleService(
  host: InterconnectVideoSubtitleHostPort(
    client: InterconnectJobClient(repo: SyncRepository(database)),
    activeBaseUrl: () => InterconnectSyncBackend.instance.resolvedHostBaseUrl,
  ),
);

RemoteVideoSubtitleService? _sharedRemote;
