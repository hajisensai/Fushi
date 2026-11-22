/// 生成字幕要用的两类本机模型在 app 层的接缝：
///
/// - [VideoSubtitleAsrModelPort]：视频用的识别模型（`mixedAudio` 包；日语 Parakeet、
///   普通话 X-ASR zipformer，按 [VideoSubtitleLanguage] 选）；音乐库歌词用 `song`
///   （同一个包 + 人声分离模型）；
/// - [VideoSubtitleMossPort]：MOSS（audio.cpp 运行库 + MOSS-Transcribe-Diarize 权重）。
///
/// 视频页面板、设置页与桌面 CLI 都经它们读状态 / 触发下载；生产实现只转调
/// `asr_host.dart` 的装配（[createAsrTranscriptionService] / [appMossProvisionStatus] /
/// [appEnsureMossProvisioned]）——下载器、缓存目录、固定版本与哈希都在那边，本文件
/// 不重复任何一项。测试注入 fake。
library;

import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrAccelerationPreference,
        AsrAudioProfile,
        AsrLanguage,
        AsrTranscribePlan,
        AsrTranscriptionService,
        ModelDownloadEvent;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart'
    show MossBackendPreference;

import 'package:fushi/src/asr_host/asr_host.dart'
    show
        createAsrTranscriptionService,
        MossProvisionStatus,
        MossUnavailableCode,
        appDeleteMossProvisioned,
        appEnsureMossProvisioned,
        appMossProvisionedDiskBytes,
        appMossProvisionStatus;
import 'package:fushi/src/asr_host/shared_model_downloads.dart'
    show asrDownloadKeyFor, kMossDownloadKey, sharedModelDownloads;

/// 生成字幕用的识别模型（按 [VideoSubtitleLanguage] 与素材）：是否已下载 + 下载。
///
/// `audioProfile` 只收 `mixedAudio`（视频）与 `song`（音乐库歌词：混音那个包 + 人声
/// 分离模型）。
abstract interface class VideoSubtitleAsrModelPort {
  Future<bool> isReady({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
    AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
  });

  /// 下载缺失的模型文件；事件流结束 = 下载完。失败以异常结束流。
  ///
  /// 下载归全应用单飞登记表（`sharedModelDownloads`），不归调用页面：取消订阅
  /// （关弹层）不停下载；已在下载时再调只是挂上去看进度，不另起第二条写者。
  Stream<ModelDownloadEvent> download({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
    AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
  });

  /// 接回进行中的下载（别处 / 之前那次弹层发起的）；没在下载时为 null。
  Stream<ModelDownloadEvent>? resumeDownload({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
    AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
  });
}

/// 生产实现：与视频页「语音转写」同一套转录服务装配。
class AppVideoSubtitleAsrModelPort implements VideoSubtitleAsrModelPort {
  const AppVideoSubtitleAsrModelPort();

  static AsrTranscriptionService _service(AsrAudioProfile profile) =>
      createAsrTranscriptionService(audioProfile: profile);

  static Future<AsrTranscribePlan> _plan(
    AsrTranscriptionService service,
    AsrLanguage language,
  ) => service.plan(
    language: language,
    preference: AsrAccelerationPreference.auto,
  );

  @override
  Future<bool> isReady({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
    AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
  }) async =>
      (await _plan(_service(audioProfile), language.asrLanguage)).modelReady;

  static String _key(VideoSubtitleLanguage language, AsrAudioProfile profile) =>
      asrDownloadKeyFor(language.asrLanguage, profile);

  @override
  Stream<ModelDownloadEvent> download({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
    AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
  }) {
    Stream<ModelDownloadEvent> mixed() => sharedModelDownloads.join(
      _key(language, AsrAudioProfile.mixedAudio),
      () => _downloadMissing(language.asrLanguage, AsrAudioProfile.mixedAudio),
    );
    if (!audioProfile.separatesVocals) return mixed();
    // 歌曲 = 混音那个包 + 分离模型：先挂到混音那条单飞上把识别文件下完（视频页同时
    // 在下也只有一个写者），再只补分离模型（识别文件已就绪，下载器跳过）。
    return sharedModelDownloads.join(_key(language, audioProfile), () async* {
      yield* mixed();
      yield* _downloadMissing(language.asrLanguage, audioProfile);
    });
  }

  @override
  Stream<ModelDownloadEvent>? resumeDownload({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
    AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
  }) =>
      (audioProfile.separatesVocals
          ? sharedModelDownloads.attach(_key(language, audioProfile))
          : null) ??
      sharedModelDownloads.attach(_key(language, AsrAudioProfile.mixedAudio));

  static Stream<ModelDownloadEvent> _downloadMissing(
    AsrLanguage language,
    AsrAudioProfile profile,
  ) async* {
    final AsrTranscriptionService service = _service(profile);
    final AsrTranscribePlan plan = await _plan(service, language);
    if (plan.modelReady) return;
    yield* service.downloadModel(
      language: plan.language,
      variant: plan.variant,
    );
  }
}

/// MOSS 用不上的原因：分类（UI 出文案）+ 排查原文。
class VideoSubtitleMossProblem {
  const VideoSubtitleMossProblem({this.code, required this.reason});

  final MossUnavailableCode? code;
  final String reason;
}

/// MOSS 在本机的就绪状态（UI 用的最小形状）。
class VideoSubtitleMossState {
  const VideoSubtitleMossState({
    required this.ready,
    this.totalBytes = 0,
    this.obtainedBytes = 0,
    this.unavailableReason,
    this.unavailableCode,
  });

  /// 运行库与权重都已就位。
  final bool ready;

  /// 全部要下载的字节数（0 = 未知）。
  final int totalBytes;

  /// 已经在盘上的字节数。
  final int obtainedBytes;

  /// 本机根本用不了 MOSS 时的原因（平台 / 后端没有可用构建）；null = 可以下载。
  final String? unavailableReason;
  final MossUnavailableCode? unavailableCode;

  int get remainingBytes {
    final int left = totalBytes - obtainedBytes;
    return left < 0 ? 0 : left;
  }
}

/// MOSS 状态与下载的接缝。
abstract interface class VideoSubtitleMossPort {
  Future<VideoSubtitleMossState> status(MossBackendPreference backend);

  /// 下载缺失的运行库与权重；事件流结束 = 下载完。失败以异常结束流。
  ///
  /// 与 [VideoSubtitleAsrModelPort.download] 同一套单飞语义：取消订阅不停下载，
  /// 已在下载时只是挂上去。
  Stream<ModelDownloadEvent> ensure(MossBackendPreference backend);

  /// 接回进行中的 MOSS 下载；没在下载时为 null。
  Stream<ModelDownloadEvent>? resumeEnsure();

  /// 本机已落盘的全部 MOSS 文件（所有后端的运行库 + 权重）占的字节。
  Future<int> diskBytes();

  /// 删除本机全部 MOSS 运行库与权重，返回释放的字节数。
  Future<int> delete();
}

/// 生产实现：转调 `asr_host.dart` 的 MOSS 装配。
class AppVideoSubtitleMossPort implements VideoSubtitleMossPort {
  const AppVideoSubtitleMossPort();

  @override
  Future<VideoSubtitleMossState> status(MossBackendPreference backend) async {
    final MossProvisionStatus s = await appMossProvisionStatus(backend);
    return VideoSubtitleMossState(
      ready: s.ready,
      totalBytes: s.totalBytes,
      obtainedBytes: s.obtainedBytes,
      // 判定本机用不了（平台 / 显卡 / 该后端没有构建）时没有可下载的东西；缺运行库 /
      // 缺权重不算「用不了」，给下载。
      unavailableReason: s.supported
          ? null
          : (s.decision.reason ?? s.decision.code?.name ?? 'unsupported'),
      unavailableCode: s.supported ? null : s.decision.code,
    );
  }

  @override
  Stream<ModelDownloadEvent> ensure(MossBackendPreference backend) =>
      sharedModelDownloads.join(
        kMossDownloadKey,
        () => appEnsureMossProvisioned(backend),
      );

  @override
  Stream<ModelDownloadEvent>? resumeEnsure() =>
      sharedModelDownloads.attach(kMossDownloadKey);

  @override
  Future<int> diskBytes() => appMossProvisionedDiskBytes();

  @override
  Future<int> delete() => appDeleteMossProvisioned();
}
