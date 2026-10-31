/// 「设备端转录生成字幕」弹层：模型下载 → 装载引擎 → 转录进度（可暂停 / 续跑）
/// → 返回生成的 SRT 路径给导入对话框。
///
/// 与重跑匹配的 sheet 同一套外壳：桌面 [FushiDialogFrame] + [showAppDialog]，
/// 移动端 [adaptiveModalSheet]。转录本体跑在 [AsrTranscriptionService] 装配出的
/// 任务里；弹层被关掉时请求在下一个检查点暂停并释放会话，进度留在磁盘。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/asr_host/shared_model_downloads.dart'
    show asrDownloadKeyFor, sharedModelDownloads;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatFailure;
import 'package:fushi_engine/asr/asr_transcript_proofreader.dart';
import 'package:fushi_engine/asr/cloud_whisper_transcription_service.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show preferredTranscriptExportPath;
import 'package:fushi_engine/media/audiobook/audiobook_text_coverage.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart'
    show SubtitleAiRequestFailure;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/asr_host/asr_ai_hosts.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/asr_host/apple_speech_transcription_service.dart';
import 'package:fushi/src/asr_host/asr_engine_options.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';
import 'package:fushi/src/asr_host/gpu_acceleration.dart';
import 'package:fushi/src/asr_host/gpu_runtime_pack.dart';
import 'package:fushi/src/media/audiobook/asr_local_model_dialog.dart';
import 'package:fushi/src/media/audiobook/asr_pipeline_progress.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

/// 打开转录弹层。返回生成的 SRT 绝对路径；用户关闭 / 暂停 / 失败时返回 null。
///
/// [languageGetter] / [languageSetter] 是「上次选的语音语言」偏好的读写口
/// （存 [AsrLanguage.tag]）；null 时从 [appProvider] 取 [AppModel] 接线，测试注 fake。
///
/// [languageHint]：书本身的语言（EPUB `dc:language` 经 [asrLanguageHintFromBookLanguage]
/// 换算）。有 hint 时语言初值用 hint、不写回偏好；用户手动切换时才写回。没 hint
/// 沿用偏好。
Future<String?> showAsrTranscribeSheet({
  required BuildContext context,
  required List<String> audioPaths,
  AsrTranscriptionService? service,
  AsrLanguage? languageHint,
  Future<String?> Function({
    required String fileName,
    required String? initialDirectory,
  })?
  saveFilePicker,
  String Function()? languageGetter,
  Future<void> Function(String tag)? languageSetter,
  InterconnectJobClient? remoteClient,
  AsrModelCatalog Function()? catalogGetter,
  Future<void> Function(AsrModelCatalog catalog)? catalogSetter,
  Future<String?> Function()? directoryPicker,
  AsrTranscriptionService Function()? cloudService,
  AsrProofreadHost? proofreadHost,
}) {
  final AsrTranscriptionService effective =
      service ?? createAsrTranscriptionService();
  String Function() getter = languageGetter ?? () => '';
  Future<void> Function(String) setter = languageSetter ?? (String _) async {};
  AppModel? appModel;
  if (languageGetter == null ||
      languageSetter == null ||
      remoteClient == null ||
      cloudService == null ||
      proofreadHost == null) {
    try {
      appModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
    } catch (_) {
      // 测试/无 ProviderScope 的宿主：没有 app 模型就没有远程 host 与语言记忆。
    }
  }
  if (appModel != null) {
    final AppModel model = appModel;
    getter = languageGetter ?? () => model.asrTranscribeLanguage;
    setter = languageSetter ?? model.setAsrTranscribeLanguage;
  }
  // 「在互联 host 上运行」：已配对 host 宣告 jobs.kinds 含 asr 时面板多一个运行位置。
  final InterconnectJobClient? remote =
      remoteClient ??
      (appModel == null
          ? null
          : InterconnectJobClient(repo: SyncRepository(appModel.database)));
  // 云端转录 / AI 校对：提供商按 AI 设置里的功能指派现取（见 asr_ai_hosts.dart）。
  // 没有 app 模型或偏好仓库还没就绪（测试宿主 / 启动早期）就两样都不提供。
  final AppModel? model = appModel != null && appModel.isPreferencesReady
      ? appModel
      : null;
  final AsrTranscriptionService Function()? cloud =
      cloudService ??
      (model == null
          ? null
          : () => createAppCloudTranscriptionService(model.prefsRepo));
  final AsrProofreadHost? proofread =
      proofreadHost ??
      (model == null ? null : appAsrProofreadHost(model.prefsRepo));
  Widget build(BuildContext ctx) => AsrTranscribeSheet(
    audioPaths: audioPaths,
    service: effective,
    saveFilePicker: saveFilePicker,
    languageHint: languageHint,
    languageGetter: getter,
    languageSetter: setter,
    remoteClient: remote,
    catalogGetter: catalogGetter,
    catalogSetter: catalogSetter,
    directoryPicker: directoryPicker,
    cloudService: cloud,
    proofreadHost: proofread,
  );
  if (isDesktopPlatform) {
    return showAppDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 520,
        maxHeightFactor: 0.8,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<String>(
    context: context,
    showDragHandle: true,
    builder: build,
  );
}

/// 语音语言的用户可见名（转录弹层下拉与设置页模型行共用）：母语写法，与界面
/// 语言选择器同一惯例（`FushiLocalisations.localeNames`），不走 i18n。
String asrLanguageLabel(AsrLanguage language) => language.nativeName;

/// 纯函数：由书的语言标签（EPUB `dc:language`，如 `ja-JP` / `en_GB` / `EN` /
/// `zh-HK`）推转录弹层的语言初值，规则见 [AsrLanguage.fromBookLanguage]；空 /
/// 空白 / 没有对应语音模型的语言返回 null，调用方回退到「上次选择」偏好。
AsrLanguage? asrLanguageHintFromBookLanguage(String? bookLanguage) =>
    AsrLanguage.fromBookLanguage(bookLanguage);

/// 字幕 / 对齐文件行被点击时的来源选择。
enum SubtitleSourceChoice {
  /// 打开文件选择器挑现成字幕。
  pickFile,

  /// 用设备端语音模型从已选音频转录生成。
  transcribe,
}

/// 纯函数：字幕行点击要不要先弹「字幕来源」选择。只有本机能转录**且**已选了音频时
/// 转录才是一个可用选项，否则多一步选择只是打扰——直接进文件选择器。
bool shouldOfferSubtitleSourceChooser({
  required bool asrSupported,
  required bool hasAudio,
}) => asrSupported && hasAudio;

/// 「只选了音频、没有书（EPUB 等）也没有字幕」时导入对话框给的提醒。
enum AudioOnlyImportHint {
  /// 不是只有音频的情形，不提醒。
  none,

  /// 本机能转录：直接转录音频生成字幕，导入时据此自动生成书籍。
  transcribeToBook,

  /// 本机不能转录：选一个字幕文件，导入时据此自动生成书籍。
  pickSubtitleToBook,
}

/// 纯函数：书导入对话框要不要提醒「没有书也能导入——转录 / 选字幕即可生成书籍」。
/// 只在已选音频、既没选书也没选字幕时提醒；能不能转录决定给哪条出路。
AudioOnlyImportHint audioOnlyImportHint({
  required bool hasBook,
  required bool hasSubtitle,
  required bool hasAudio,
  required bool asrSupported,
}) {
  if (hasBook || hasSubtitle || !hasAudio) return AudioOnlyImportHint.none;
  return asrSupported
      ? AudioOnlyImportHint.transcribeToBook
      : AudioOnlyImportHint.pickSubtitleToBook;
}

/// 弹「字幕来源」选择：选现成文件 / 设备端转录。关闭返回 null。
///
/// 放在这里而不是各导入对话框里：书导入（字幕行）与附加有声书（对齐文件行）两个
/// 入口共用同一份文案与顺序，转录入口不再只是行尾一枚无字图标（用户点了行本身
/// 找不到转录——那是文件选择器直接弹出来的）。
Future<SubtitleSourceChoice?> showSubtitleSourceChooser({
  required BuildContext context,
}) {
  Widget build(BuildContext ctx) => const _SubtitleSourceChooser();
  if (isDesktopPlatform) {
    return showAppDialog<SubtitleSourceChoice>(
      context: context,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 440,
        maxHeightFactor: 0.6,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<SubtitleSourceChoice>(
    context: context,
    showDragHandle: true,
    builder: build,
  );
}

/// 字幕 / 对齐文件行尾的「本地 | 转录」分段（M3E）：两种来源是并列的概念，
/// 用带字的分段代替两枚无字图标（用户 10-16：「转录入口藏太深了」）。点一段就
/// 走那条来源；选中态是当前文件的来源（[current]，null = 还没有）。点已选中的
/// 一段等于再走一次（重新选文件 / 重新转录）。
class SubtitleSourceSegments extends StatelessWidget {
  const SubtitleSourceSegments({
    required this.current,
    required this.onChoose,
    this.enabled = true,
    super.key,
  });

  final SubtitleSourceChoice? current;
  final bool enabled;
  final void Function(SubtitleSourceChoice choice) onChoose;

  @override
  Widget build(BuildContext context) {
    final SubtitleSourceChoice? selected = current;
    return FushiSegmentedButton<SubtitleSourceChoice>(
      key: const ValueKey<String>('subtitle-source-segments'),
      segments: <ButtonSegment<SubtitleSourceChoice>>[
        ButtonSegment<SubtitleSourceChoice>(
          value: SubtitleSourceChoice.pickFile,
          icon: const FushiIcon(FushiIcons.folderOpen, size: 18),
          label: Text(t.import_subtitle_source_local),
        ),
        ButtonSegment<SubtitleSourceChoice>(
          value: SubtitleSourceChoice.transcribe,
          icon: const FushiIcon(FushiIcons.voice, size: 18),
          label: Text(t.import_subtitle_source_transcribe),
        ),
      ],
      selected: <SubtitleSourceChoice>{?selected},
      emptySelectionAllowed: true,
      expandedInsets: EdgeInsets.zero,
      showSelectedIcon: false,
      onSelectionChanged: !enabled
          ? null
          : (Set<SubtitleSourceChoice> s) =>
                onChoose(s.isEmpty ? selected! : s.first),
    );
  }
}

class _SubtitleSourceChooser extends StatelessWidget {
  const _SubtitleSourceChooser();

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[
      FushiListItem(
        leading: const FushiListLeadingIcon(FushiIcons.subtitles),
        title: Text(t.srt_import_pick_subtitle_files),
        trailing: const FushiIcon(FushiIcons.chevronRight),
        onTap: () => Navigator.pop(context, SubtitleSourceChoice.pickFile),
      ),
      FushiListItem(
        leading: const FushiListLeadingIcon(
          FushiIcons.voice,
          shape: FushiLeadingShape.cookie,
          tone: FushiCardTone.primary,
        ),
        title: Text(t.audiobook_transcribe_action),
        subtitle: Text(t.audiobook_subtitle_source_transcribe_hint),
        trailing: const FushiIcon(FushiIcons.chevronRight),
        onTap: () => Navigator.pop(context, SubtitleSourceChoice.transcribe),
      ),
    ];
    return FushiModalSheetFrame(
      title: t.audiobook_subtitle_source_title,
      leadingIcon: FushiIcons.subtitles,
      bodyPadding: const EdgeInsets.symmetric(horizontal: 16),
      // 两个来源作分段卡（首尾大圆角、行间 2），错峰进场。
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: FushiGroupedListItem(
                  index: i,
                  count: rows.length,
                  child: rows[i],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// 导出转录产物：桌面走存盘对话框（默认文件名 = 首个音频同名 `.srt`、起始目录 =
/// 音频所在目录），移动端走系统分享。返回是否真的导出了（用户取消返回 false）。
/// [saveFilePicker] 可注入，测试里替换掉真的平台对话框。
///
/// 拷的是 [srtPath] 旁的对齐版 `transcript.aligned.srt`（「使用字幕」跑过正文匹配
/// 后才有：命中 cue 已换成带标点的正文原文），没有才回退原始听写稿
/// （[preferredTranscriptExportPath]）。原始 `transcript.srt` 永不覆盖。
Future<bool> exportTranscribedSrt({
  required String srtPath,
  required List<String> audioPaths,
  Future<String?> Function({
    required String fileName,
    required String? initialDirectory,
  })?
  saveFilePicker,
  bool? desktop,
}) async {
  srtPath = preferredTranscriptExportPath(srtPath);
  final String suggestedName = suggestedTranscriptFileName(audioPaths);
  if (desktop ?? isDesktopPlatform) {
    final String? initialDirectory = audioPaths.isEmpty
        ? null
        : File(audioPaths.first).parent.path;
    final Future<String?> Function({
      required String fileName,
      required String? initialDirectory,
    })
    pick =
        saveFilePicker ??
        ({required String fileName, required String? initialDirectory}) =>
            FilePicker.platform.saveFile(
              dialogTitle: t.audiobook_transcribe_export,
              fileName: fileName,
              initialDirectory: initialDirectory,
              type: FileType.custom,
              allowedExtensions: const <String>['srt'],
            );
    final String? savePath = await pick(
      fileName: suggestedName,
      initialDirectory: initialDirectory,
    );
    if (savePath == null || savePath.trim().isEmpty) return false;
    await File(srtPath).copy(savePath);
    return true;
  }
  await FushiShare.shareFiles(<XFile>[
    XFile(srtPath, mimeType: 'application/x-subrip', name: suggestedName),
  ], subject: suggestedName);
  return true;
}

/// 纯函数：导出用的默认文件名——首个音频去扩展名 + `.srt`；多文件有声书取首个
/// （单时间轴 SRT 本来就是整本一份）。没有音频时退回固定名。
String suggestedTranscriptFileName(List<String> audioPaths) {
  if (audioPaths.isEmpty) return 'transcript.srt';
  return '${p.basenameWithoutExtension(audioPaths.first)}.srt';
}

/// 纯函数：运行中那行「编码器为什么落在 CPU」的文案；没回退返回 null。
///
/// [probeError] 非 null（计划阶段 EP 探测抛过错）时，引擎加载时问的是同一个运行时，
/// 它的 `fallbackReason` 就是那次探测的异常原文（探测失败时引擎只向 ORT 请求 CPU，
/// 会话层不会再有别的回退），
/// 给可读的说明而不是原文（反馈 eEnV5gBn1K）。其余回退（GPU 会话被 ORT 拒绝）
/// 的 `code: message` 照旧展示——那是用户能拿去对照显卡 / 驱动的线索。
String? asrEncoderFallbackLine(
  OnnxProviderResolution resolution, {
  required String? probeError,
}) {
  if (!resolution.didFallBack) return null;
  if (probeError != null) return t.audiobook_transcribe_probe_failed_hint;
  return t.audiobook_transcribe_fallback(
    reason: resolution.fallbackReason ?? '',
  );
}

/// 默认的目录读取口（`asrModelCatalog` 是 getter，取不到函数引用）。
AsrModelCatalog _readAsrModelCatalog() => asrModelCatalog;

enum _Phase {
  checking,
  needDownload,
  downloading,
  ready,
  loading,
  running,
  pausing,
  paused,
  finished,

  /// 转录已完成，正在用 AI 校对转录稿（完成后回到 [finished]）。
  proofreading,
  error,
}

@visibleForTesting
class AsrTranscribeSheet extends StatefulWidget {
  const AsrTranscribeSheet({
    required this.audioPaths,
    this.saveFilePicker,
    required this.service,
    this.languageHint,
    this.languageGetter,
    this.languageSetter,
    this.remoteClient,
    AsrModelCatalog Function()? catalogGetter,
    Future<void> Function(AsrModelCatalog catalog)? catalogSetter,
    this.directoryPicker,
    this.systemSpeechService,
    this.cloudService,
    this.proofreadHost,
    super.key,
  }) : catalogGetter = catalogGetter ?? _readAsrModelCatalog,
       catalogSetter = catalogSetter ?? saveAsrModelCatalog;

  final List<String> audioPaths;

  /// 测试注入：替换桌面端的存盘对话框。null = 真的 `FilePicker.saveFile`。
  final Future<String?> Function({
    required String fileName,
    required String? initialDirectory,
  })?
  saveFilePicker;
  final AsrTranscriptionService service;

  /// 书本身的语言推出的初值（见 [showAsrTranscribeSheet]）；优先于 [languageGetter]，
  /// 且不写回偏好。
  final AsrLanguage? languageHint;

  /// 「上次选的语音语言」偏好读取（[AsrLanguage.tag]）；null / 不认识的标签
  /// 一律回退日语。
  final String Function()? languageGetter;

  /// 切换语言后写回偏好（[AsrLanguage.tag]）；null = 不记忆。
  final Future<void> Function(String tag)? languageSetter;

  /// 互联通用任务客户端；null = 不提供「在 host 上运行」。
  final InterconnectJobClient? remoteClient;

  /// 模型目录（每语言选了谁 + 自带包）的读写口。默认读写本进程的那份并落盘；
  /// widget 测试注入内存实现，不碰数据根。
  final AsrModelCatalog Function() catalogGetter;
  final Future<void> Function(AsrModelCatalog catalog) catalogSetter;

  /// 「手动指定模型」用的目录选择器；null = 真的系统对话框。
  final Future<String?> Function()? directoryPicker;

  /// 选中「系统语音识别」时用哪个服务；null = 真的 [AppleSpeechTranscriptionService]。
  /// 测试注入 fake，免得 widget 测试去碰 method channel。
  final AsrTranscriptionService Function()? systemSpeechService;

  /// 云端转录服务（生产是 [createAppCloudTranscriptionService]）；null = 下拉里
  /// 不出「云端转录」这一项。
  final AsrTranscriptionService Function()? cloudService;

  /// 转录稿 AI 校对（生产是 [appAsrProofreadHost]）；null = 完成态不出「AI 校对」。
  final AsrProofreadHost? proofreadHost;

  @override
  State<AsrTranscribeSheet> createState() => _AsrTranscribeSheetState();
}

class _AsrTranscribeSheetState extends State<AsrTranscribeSheet> {
  /// 当前生效的转录服务。选中系统语音时换成另一份实现（见 [_serviceFor]）——
  /// 弹层其余部分只与「一个 AsrTranscriptionService」对话，不知道底下是谁。
  late AsrTranscriptionService _service = widget.service;

  /// 弹层服务的素材（视频 / 有声书）：取注入的那份服务的断言，**不取 [_service]**
  /// ——选中系统语音时 [_service] 换成另一份实现，素材却没变。选包、记选择、报
  /// 模型名都按它：同一语言在视频与有声书上默认是两个包（日语：Parakeet /
  /// ReazonSpeech）。
  AsrAudioProfile get _profile => widget.service.audioProfile;

  /// 本机有没有系统语音（OS ≥ 26 且原生侧在）。探完才决定下拉里出不出那一项。
  bool _systemSpeechAvailable = false;

  _Phase _phase = _Phase.checking;
  AsrAccelerationPreference _preference = AsrAccelerationPreference.auto;
  AsrLanguage _language = AsrLanguage.japanese;
  AsrTranscribePlan? _plan;

  /// 最近一次探测到的 GPU EP。「仅 CPU」档不探测（计划里为空），所以要记住上一次
  /// 的结果——否则切到 CPU 后 DirectML / CUDA 两个选项会凭空消失、切不回来。
  Set<OnnxExecutionProvider> _knownGpuProviders =
      const <OnnxExecutionProvider>{};
  String? _finishedSrt;
  String? _error;

  /// 本轮里引擎丢弃过一个读不出图的模型文件（见 [_failWith]）。只用来在「需要
  /// 下载」那一阶段多说一句为什么又要下载，不参与阶段判定。
  bool _modelDiscarded = false;

  /// 完成态下用户改过「加速 / 运行位置」：现成结果不是按眼下这组选项转出来的。
  /// 状态卡据此提示「点重新转录」，页脚把「放弃进度」换成「重新转录」
  /// （BUG-3138：完成态曾把选项全锁死，加速分段看着能点、点了没反应）。
  /// 语言 / 模型不进这面旗：换它们会按新语言 / 新引擎重新规划，有现成结果就是
  /// 那一组自己的结果。
  bool _optionsChangedSinceResult = false;

  /// 本弹层里下过模型。没下过 = 模型本来就在，阶段轨把「下载模型」画成跳过。
  bool _downloadedModelHere = false;

  /// 失败发生在哪个阶段（阶段轨标红那一格）；null = 还没进流水线就失败了。
  AsrPipelineStage? _failedStage;

  /// 现成结果上次跑「使用字幕」后的正文覆盖情况（转录产物旁的 sidecar）；
  /// null = 还没匹配过正文。
  AudiobookTextCoverage? _lastCoverage;

  // 下载进度。
  int _downloadReceived = 0;
  int _downloadTotal = 0;
  String _downloadFile = '';
  StreamSubscription<ModelDownloadEvent>? _downloadSub;

  /// 模型已就绪、但这台机器该用的 GPU 环境还没装（Windows；老用户的模型是在
  /// GPU 环境改为按需下载之前下的）。null = 没有要补的。
  GpuRuntimeOffer? _gpuOffer;

  /// 这台机器的显卡（Windows）：决定「加速」里露不露 CUDA / DirectML——按显卡
  /// 能不能跑，而不是按环境装没装（没装时选它就给下载）。
  GpuDetection? _gpuDetection;

  /// 选中的 GPU 环境已装好，但本进程绑定的是另一份 ORT core：重启后生效。
  bool _gpuRestartRequired = false;

  // 转录进度。
  AsrRunningTranscription? _running;
  StreamSubscription<AsrTranscribeEvent>? _runSub;
  AsrTranscribeProgress? _progress;
  AsrTranscribeResult? _result;

  /// 本次「开始」到拿到结果的墙钟（含装模型 / 远端上传）。只在本 sheet 里跑过
  /// 一轮才有值——上一轮会话留下的完成产物没有可信的耗时，不显示。
  Stopwatch? _runClock;
  Duration? _elapsedTotal;
  OnnxProviderResolution? _resolution;

  /// 云端转录服务实例：弹层生命周期内只建一次（换引擎来回切不重建）。
  late final AsrTranscriptionService? _cloudService = widget.cloudService
      ?.call();

  // AI 校对。
  int _proofreadDone = 0;
  int _proofreadTotal = 0;
  SubtitleCancelSource? _proofreadCancel;

  /// 当前结果有校对前的原稿备份（可「还原原稿」）。
  bool _hasProofreadBackup = false;

  /// 最近一次校对 / 还原的结果说明，显示在完成态状态卡里；换结果时清掉。
  String? _proofreadNote;

  /// 远程 host（能力位含 asr）；null = 只有本机。
  HostJobTarget? _remoteTarget;
  bool _runRemote = false;
  StreamSubscription<HostJobEvent>? _remoteSub;
  String? _remoteStatus;
  double? _remoteProgress;

  @override
  void initState() {
    super.initState();
    _language =
        widget.languageHint ??
        AsrLanguage.fromTag(widget.languageGetter?.call()) ??
        AsrLanguage.japanese;
    _service = _serviceFor(_selectedEngineId());
    unawaited(_probeSystemSpeech());
    _refreshPlan();
    _probeRemote();
    unawaited(_loadGpuPreference());
  }

  /// Windows：弹层「加速」与设置页的 GPU 环境偏好是同一个选择——启动时选哪份
  /// ORT core 只认那份偏好，所以这里读它作初值、改动时写回（[_setPreference]）。
  Future<void> _loadGpuPreference() async {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        !isGpuRuntimeSupported) {
      return;
    }
    try {
      final GpuDetection detection = await detectGpu();
      final GpuRuntimePreference stored = await readGpuRuntimePreference();
      if (!mounted) return;
      setState(() {
        _gpuDetection = detection;
        if (_preference == AsrAccelerationPreference.auto) {
          _preference = switch (stored) {
            GpuRuntimePreference.auto => AsrAccelerationPreference.auto,
            GpuRuntimePreference.cuda => AsrAccelerationPreference.cuda,
            GpuRuntimePreference.directml => AsrAccelerationPreference.directml,
            GpuRuntimePreference.off => AsrAccelerationPreference.cpuOnly,
          };
        }
      });
      if (_preference != AsrAccelerationPreference.auto) {
        await _refreshPlan(keepPhase: true);
      }
    } on Object catch (error) {
      debugPrint('[Fushi] GPU preference load failed: $error');
    }
  }

  /// 「加速」分段改动：弹层只换计划，不回到「检查中」——整块状态卡 / 底栏
  /// 换一遍会让弹层高度跳一下（用户 10-16：「点击加速选项这个框会抖一下」）。
  Future<void> _setPreference(AsrAccelerationPreference preference) async {
    if (preference == _preference) return;
    if (_phase == _Phase.finished) _optionsChangedSinceResult = true;
    setState(() => _preference = preference);
    if (defaultTargetPlatform == TargetPlatform.windows &&
        isGpuRuntimeSupported) {
      final GpuRuntimePreference? gpu = switch (preference) {
        AsrAccelerationPreference.auto => GpuRuntimePreference.auto,
        AsrAccelerationPreference.cuda => GpuRuntimePreference.cuda,
        AsrAccelerationPreference.directml => GpuRuntimePreference.directml,
        // 「仅 CPU」只管这一次转录，不替用户把 GPU 环境整体关掉。
        _ => null,
      };
      if (gpu != null) {
        try {
          await writeGpuRuntimePreference(gpu);
        } on Object catch (error) {
          debugPrint('[Fushi] GPU preference write failed: $error');
        }
      }
    }
    await _refreshPlan(keepPhase: true);
  }

  @override
  void dispose() {
    // 关弹层 = 放弃在途的 AI 校对（原稿未动：校对只在整份完成后才写回）。
    _proofreadCancel?.cancel();
    _downloadSub?.cancel();
    _remoteSub?.cancel();
    // 关闭弹层不等于取消：请求在下一个检查点暂停，暂停后释放会话；进度已落盘。
    final AsrRunningTranscription? running = _running;
    final StreamSubscription<AsrTranscribeEvent>? sub = _runSub;
    if (running != null && sub != null) {
      running.requestPause();
      sub.onDone(() => running.dispose());
      sub.onError((Object _, StackTrace __) => running.dispose());
      sub.onData((AsrTranscribeEvent _) {});
    } else {
      _runSub?.cancel();
      _running?.dispose();
    }
    super.dispose();
  }

  /// [keepPhase]：只是换了选项（加速），保持当前阶段与界面不动，结果回来再
  /// 原地更新。
  Future<void> _refreshPlan({bool keepPhase = false}) async {
    final AsrAccelerationPreference preference = _preference;
    if (!keepPhase) {
      setState(() {
        _phase = _Phase.checking;
        _error = null;
        _failedStage = null;
      });
    }
    try {
      final AsrLanguage language = _language;
      final AsrAccelerationPreference planned = _runnablePreference();
      AsrTranscribePlan plan = await _service.plan(
        language: language,
        preference: planned,
      );
      if (plan.availableProviders.isNotEmpty) {
        _knownGpuProviders = plan.availableProviders;
        // 首轮还不知道本进程有哪些 GPU EP 时按「自动」规划；现在知道选中的
        // 那个其实能跑，就按它重来一次。
        final AsrAccelerationPreference runnable = _runnablePreference();
        if (runnable != planned) {
          plan = await _service.plan(language: language, preference: runnable);
        }
      }
      final String? probeError = plan.probeError;
      if (probeError != null) {
        // 界面只显示可读的说明（[_appendProbeHint]），原文留给日志排查。
        debugPrint(
          '[Fushi] ASR GPU probe failed, planning for CPU: $probeError',
        );
      }
      final String? finished = await _service.finishedSrtPath(
        widget.audioPaths,
        language,
      );
      final AsrJobState? existing = await _service.existingState(
        widget.audioPaths,
        language,
      );
      final AudiobookTextCoverage? coverage = finished == null
          ? null
          : readAsrCoverageSidecarSync(finished);
      final GpuRuntimeOffer? gpuOffer = await _probeGpuOffer(plan);
      final bool restart = gpuOffer == null && await _probeGpuRestart(plan);
      // 等待期间用户又切了语言 / 加速：这份结果已经过期，丢掉（新一轮
      // _refreshPlan 会带着新选项再来）。
      if (language != _language || preference != _preference) return;
      if (!mounted) return;
      if (keepPhase && _phase != _Phase.checking && _phase != _Phase.error) {
        // 只换了选项：已完成 / 已暂停 / 进行中等阶段保持，界面原地更新。
        setState(() {
          _plan = plan;
          _gpuOffer = gpuOffer;
          _gpuRestartRequired = restart;
          if (plan.availableProviders.isNotEmpty) {
            _knownGpuProviders = plan.availableProviders;
          }
        });
        return;
      }
      setState(() {
        _plan = plan;
        _gpuOffer = gpuOffer;
        _gpuRestartRequired = restart;
        if (plan.availableProviders.isNotEmpty) {
          _knownGpuProviders = plan.availableProviders;
        }
        _finishedSrt = finished;
        _lastCoverage = coverage;
        _hasProofreadBackup =
            finished != null && asrTranscriptHasProofreadBackup(finished);
        if (finished != null) {
          _phase = _Phase.finished;
        } else if (!plan.modelReady) {
          _phase = _Phase.needDownload;
        } else if (existing != null && !existing.finished) {
          _phase = _Phase.paused;
        } else {
          _phase = _Phase.ready;
        }
      });
    } catch (e) {
      if (!mounted) return;
      _failWith(e);
    }
  }

  /// 失败的统一落点：先分辨「模型文件本身读不出图」这一类。
  ///
  /// 引擎判定某个清单文件装不起来时会把它删掉再抛
  /// `AsrModelFileUnusableException`（上游 fushi_asr_core）。但整本转录跑在后台
  /// isolate，错误跨边界只剩字符串——`asr_transcribe_isolate.dart` 统一压成
  /// `StateError(文本)`，用户从前看到的 `Bad state: PlatformException(ORT_ERROR,
  /// ... Protobuf parsing failed)` 就是这么来的——所以这里只能按文本判据识别，
  /// 用的是上游那个纯函数。
  ///
  /// 识别到就**直接重新规划**，不为这条路径新造阶段：坏档已经不在磁盘上，
  /// `plan.modelReady` 自然是 false，界面落回既有的「需要下载」阶段，那儿本来
  /// 就有下载按钮和进度条，用户点一下就把模型重新取回来了。
  ///
  /// 一轮里只自愈一次（[_modelDiscarded] 兼作闸门）：`_refreshPlan` 失败时也走
  /// 这里，两边互相调用，不设闸门的话「规划本身报同类错误」会转成死循环。第二
  /// 次就老老实实落错误态，把原文给出去。
  void _failWith(Object error) {
    // 云端转录的失败是 AI 调用层的脱敏短码（鉴权 / 额度 / 限流 / 网络 / 协议不对），
    // 按 AI 模块同一份映射给文案，不把 `AiChatFailure: unauthorized` 原样甩给用户。
    final String text = error is AiChatFailure
        ? aiFailureText(error.message)
        : '$error';
    if (!_modelDiscarded && isOnnxUnreadableModelFailure(text)) {
      _modelDiscarded = true;
      _refreshPlan();
      return;
    }
    setState(() {
      _failedStage = _stageForPhase(_phase);
      _phase = _Phase.error;
      _error = text;
    });
  }

  /// 弹层阶段 → 阶段轨上的格（只用来记失败落在哪一格）。
  AsrPipelineStage? _stageForPhase(_Phase phase) => switch (phase) {
    _Phase.needDownload || _Phase.downloading => AsrPipelineStage.downloadModel,
    _Phase.loading => AsrPipelineStage.loadModel,
    _Phase.running ||
    _Phase.pausing ||
    _Phase.paused ||
    _Phase.proofreading => AsrPipelineStage.transcribe,
    _Phase.error => _failedStage,
    _Phase.checking || _Phase.ready || _Phase.finished => null,
  };

  Future<void> _startDownload() async {
    final AsrTranscribePlan? plan = _plan;
    if (plan == null) return;
    // 下模型阶段顺带把这台机器显卡对应的 GPU 环境一起下（Windows；已装 / 显卡
    // 不行 / 偏好关时为 null）。
    final GpuRuntimeStore? gpu = await gpuRuntimeToDownloadForUi();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.downloading;
      _downloadedModelHere = true;
      _downloadTotal = plan.totalModelBytes + (gpu?.pendingDownloadBytes ?? 0);
      _downloadReceived = plan.obtainedModelBytes;
      _downloadFile = '';
    });
    // 逐文件事件：把「之前文件」的字节累计起来展示总进度。
    int completedBytes = 0;
    String lastFile = '';
    int lastFileTotal = 0;
    _downloadSub =
        withGpuRuntimeDownload(
          // 单飞（kZZmXQBv7E）：同一个包在设置页 / 视频字幕弹层 / 另一次弹层里已在
          // 下时只挂上去，不另起写者；关弹层只摘监听，下载继续。
          sharedModelDownloads.join(
            asrDownloadKeyFor(plan.language, _service.audioProfile),
            () => _service.downloadModel(
              language: plan.language,
              variant: plan.variant,
            ),
          ),
          gpu,
          onGpuRuntimeError: (Object error) => FushiToast.show(
            msg: t.audiobook_transcribe_gpu_failed(reason: '$error'),
            severity: ToastSeverity.warning,
          ),
        ).listen(
          (ModelDownloadEvent e) {
            if (e.fileName != lastFile) {
              completedBytes += lastFileTotal;
              lastFile = e.fileName;
              lastFileTotal = e.totalBytes;
            }
            if (!mounted) return;
            setState(() {
              _downloadFile = e.fileName;
              _downloadReceived = completedBytes + e.receivedBytes;
            });
          },
          onError: (Object e, StackTrace _) {
            if (!mounted) return;
            _failWith(e);
          },
          onDone: () {
            if (!mounted) return;
            _refreshPlan();
          },
        );
  }

  /// 模型已就绪时问一下有没有该补的 GPU 环境。只在 Windows（按
  /// `defaultTargetPlatform`，widget 测试可覆盖）；查询失败按「没有」——它只是
  /// 个提示，不能把弹层拖进错误态。
  Future<GpuRuntimeOffer?> _probeGpuOffer(AsrTranscribePlan plan) async {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        !plan.modelReady ||
        _systemSpeech ||
        _preference == AsrAccelerationPreference.cpuOnly) {
      return null;
    }
    try {
      return await gpuRuntimeOffer();
    } on Object catch (error) {
      debugPrint('[Fushi] GPU runtime offer check failed: $error');
      return null;
    }
  }

  /// 实际交给引擎的加速偏好：选了 CUDA / DirectML 但本进程还用不了（环境没下、
  /// 或这次启动绑定的是另一份 ORT core）时按「自动」跑——引擎对不可用的显式
  /// EP 直接抛 UnsupportedError，弹层曾因此落进错误态（10-16）。缺的环境由
  /// 「加速」下的下载按钮 / 「重启后生效」提示交代。
  AsrAccelerationPreference _runnablePreference() {
    final OnnxExecutionProvider? ep = switch (_preference) {
      AsrAccelerationPreference.cuda => OnnxExecutionProvider.cuda,
      AsrAccelerationPreference.directml => OnnxExecutionProvider.directml,
      _ => null,
    };
    if (ep == null || _knownGpuProviders.contains(ep)) return _preference;
    return AsrAccelerationPreference.auto;
  }

  /// 选中的 GPU 环境已装好却没在本进程生效（ORT 已绑定了另一份 core）。
  Future<bool> _probeGpuRestart(AsrTranscribePlan plan) async {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        !isGpuRuntimeSupported ||
        !plan.modelReady ||
        _systemSpeech ||
        _preference == AsrAccelerationPreference.cpuOnly) {
      return false;
    }
    try {
      return (await gpuAccelerationStatus()).restartRequired;
    } on Object catch (error) {
      debugPrint('[Fushi] GPU status check failed: $error');
      return false;
    }
  }

  /// 只补 GPU 环境（模型已就绪），走和模型下载同一个进度阶段。
  void _startGpuDownload() {
    final GpuRuntimeOffer? offer = _gpuOffer;
    if (offer == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _downloadTotal = offer.store.pendingDownloadBytes;
      _downloadReceived = 0;
      _downloadFile = '';
    });
    int completedBytes = 0;
    String lastFile = '';
    int lastFileTotal = 0;
    _downloadSub =
        withGpuRuntimeDownload(
          const Stream<ModelDownloadEvent>.empty(),
          offer.store,
          onGpuRuntimeError: (Object error) => FushiToast.show(
            msg: t.audiobook_transcribe_gpu_failed(reason: '$error'),
            severity: ToastSeverity.warning,
          ),
        ).listen(
          (ModelDownloadEvent e) {
            if (e.done) return;
            if (e.fileName != lastFile) {
              completedBytes += lastFileTotal;
              lastFile = e.fileName;
              lastFileTotal = e.totalBytes;
            }
            if (!mounted) return;
            setState(() {
              _downloadFile = e.fileName;
              _downloadReceived = completedBytes + e.receivedBytes;
            });
          },
          onDone: () {
            if (!mounted) return;
            _refreshPlan();
          },
        );
  }

  String _gpuKindLabel(GpuRuntimeKind kind) => switch (kind) {
    GpuRuntimeKind.cuda => t.audiobook_transcribe_accel_cuda,
    GpuRuntimeKind.directml => t.audiobook_transcribe_accel_directml,
  };

  Future<void> _startTranscription() async {
    _optionsChangedSinceResult = false;
    _runClock = Stopwatch()..start();
    _elapsedTotal = null;
    if (_runRemote && _remoteTarget != null && !_cloudEngine) {
      return _startRemoteTranscription();
    }
    final AsrTranscribePlan? plan = _plan;
    if (plan == null) return;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _result = null;
    });
    try {
      final AsrRunningTranscription running = await _service.start(
        audioPaths: widget.audioPaths,
        language: plan.language,
        variant: plan.variant,
        preference: _runnablePreference(),
      );
      if (!mounted) {
        await running.dispose();
        return;
      }
      _running = running;
      setState(() {
        _resolution = running.encoderResolution;
        _phase = _Phase.running;
      });
      _runSub = running.run().listen(
        (AsrTranscribeEvent e) {
          if (!mounted) return;
          switch (e) {
            case AsrTranscribeProgressEvent(
              progress: final AsrTranscribeProgress p,
            ):
              setState(() => _progress = p);
            case AsrTranscribePausedEvent(
              progress: final AsrTranscribeProgress p,
            ):
              setState(() {
                _progress = p;
                _phase = _Phase.paused;
              });
            case AsrTranscribeFinishedEvent(
              result: final AsrTranscribeResult r,
            ):
              setState(() {
                _result = r;
                _finishedSrt = r.srtPath;
                _lastCoverage = null;
                _hasProofreadBackup = asrTranscriptHasProofreadBackup(
                  r.srtPath,
                );
                _proofreadNote = null;
                _elapsedTotal = _runClock?.elapsed;
                _phase = _Phase.finished;
              });
          }
        },
        onError: (Object e, StackTrace _) async {
          await _releaseRunning();
          if (!mounted) return;
          _failWith(e);
        },
        onDone: () async {
          await _releaseRunning();
        },
      );
    } catch (e) {
      if (!mounted) return;
      _failWith(e);
    }
  }

  Future<void> _releaseRunning() async {
    final AsrRunningTranscription? running = _running;
    _running = null;
    _runSub = null;
    await running?.dispose();
  }

  void _pause() {
    if (_runRemote) {
      // 远端任务没有暂停：取消订阅 = 远端 DELETE，回到就绪态。
      _remoteSub?.cancel();
      _remoteSub = null;
      setState(() => _phase = _Phase.ready);
      return;
    }
    _running?.requestPause();
    setState(() => _phase = _Phase.pausing);
  }

  Future<void> _probeRemote() async {
    final InterconnectJobClient? client = widget.remoteClient;
    if (client == null || widget.audioPaths.length != 1) return;
    try {
      final HostJobTarget? target = await client.probe('asr');
      if (!mounted) return;
      setState(() => _remoteTarget = target);
    } catch (_) {
      // 探测失败 = 没有可用 host；本机路径不受影响。
    }
  }

  Future<void> _startRemoteTranscription() async {
    final HostJobTarget? target = _remoteTarget;
    final InterconnectJobClient? client = widget.remoteClient;
    if (target == null || client == null) return;
    if (!target.asrModelReady(_language.tag)) {
      setState(() {
        _phase = _Phase.error;
        _error = t.audiobook_transcribe_remote_model_missing(
          device: target.label,
        );
      });
      return;
    }
    final Directory jobDir = await widget.service.jobDirFor(
      widget.audioPaths,
      _language,
    );
    await jobDir.create(recursive: true);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _result = null;
      _remoteProgress = null;
      _remoteStatus = t.audiobook_transcribe_remote_uploading(
        device: target.label,
        done: 0,
        total: widget.audioPaths.length,
      );
    });
    _remoteSub = client
        .run(
          target: target,
          kind: 'asr',
          params: <String, Object?>{'language': _language.tag},
          inputs: widget.audioPaths.map(File.new).toList(growable: false),
          outputDir: jobDir,
        )
        .listen(
          (HostJobEvent e) async {
            if (!mounted) return;
            switch (e) {
              case HostJobUploading(
                done: final int done,
                total: final int total,
              ):
                setState(() {
                  _phase = _Phase.loading;
                  _remoteStatus = t.audiobook_transcribe_remote_uploading(
                    device: target.label,
                    done: done,
                    total: total,
                  );
                });
              case HostJobRunning(progress: final double progress):
                setState(() {
                  _phase = _Phase.running;
                  _remoteProgress = progress;
                  _remoteStatus = t.audiobook_transcribe_remote_running(
                    device: target.label,
                    percent: (progress * 100).toStringAsFixed(0),
                  );
                });
              case HostJobDone(outputs: final Map<String, File> outputs):
                final File? srt = outputs[AsrJobFiles.srt];
                // 补一份 state.json：本机链路靠它识别「这是 ASR 产物目录」（token
                // 时间 sidecar 就在旁边）；modelId 记 host 名，便于事后追溯。
                final AsrJobState state = AsrJobState.fresh(
                  widget.audioPaths,
                  modelId: 'remote:${target.label}',
                ).copyWith(finished: true);
                await File(
                  p.join(jobDir.path, AsrJobFiles.state),
                ).writeAsString(jsonEncode(state.toJson()), flush: true);
                if (!mounted) return;
                setState(() {
                  _finishedSrt = srt?.path;
                  _lastCoverage = null;
                  _remoteProgress = 1;
                  _elapsedTotal = srt == null ? null : _runClock?.elapsed;
                  _phase = srt == null ? _Phase.error : _Phase.finished;
                  if (srt == null) _error = 'no subtitle in remote result';
                });
            }
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _failedStage = _stageForPhase(_phase);
              _phase = _Phase.error;
              _error = '$error';
            });
          },
        );
  }

  /// 切换语音语言：记住选择，再按新语言包重新规划（模型是否就绪 / 该语言下这组
  /// 音频有没有进行中或已完成的任务都随语言变）。
  void _changeLanguage(AsrLanguage language) {
    if (language == _language) return;
    _language = language;
    _optionsChangedSinceResult = false;
    _result = null;
    _elapsedTotal = null;
    _progress = null;
    unawaited(widget.languageSetter?.call(language.tag));
    _refreshPlan();
  }

  /// 这门语言当前能选哪些引擎（ONNX 包在前，系统语音在后）。
  List<AsrEngineOption> _engineOptions() => asrEngineOptions(
    language: _language,
    registry: asrModelRegistry,
    systemSpeechAvailable: _systemSpeechAvailable,
    systemSpeechLabel: t.audiobook_transcribe_engine_system,
    profile: _profile,
    cloudLabel: _cloudService == null
        ? null
        : t.audiobook_transcribe_engine_cloud,
  );

  /// 当前选中的引擎 id。
  String? _selectedEngineId() => selectedAsrEngineId(
    language: _language,
    catalog: widget.catalogGetter(),
    options: _engineOptions(),
    profile: _profile,
  );

  /// 按选中的引擎给出服务实例。ONNX 走注入进来的那份（生产是
  /// `createAsrTranscriptionService()`，测试是 fake）；系统语音走另一份实现。
  AsrTranscriptionService _serviceFor(String? engineId) {
    if (engineId == kCloudWhisperEngineId) {
      return _cloudService ?? widget.service;
    }
    if (engineId != kAppleSpeechEngineId) return widget.service;
    final AsrTranscriptionService Function()? factory =
        widget.systemSpeechService;
    return factory != null ? factory() : AppleSpeechTranscriptionService();
  }

  /// 探本机有没有系统语音。探不到（非 Apple、OS < 26、原生侧没实现）就当没有——
  /// 让一个点了必报错的选项出现在下拉里比不出现更糟。
  Future<void> _probeSystemSpeech() async {
    bool available = false;
    try {
      final AsrTranscriptionService probe = _serviceFor(kAppleSpeechEngineId);
      if (probe is AppleSpeechTranscriptionService) {
        available = await probe.isAvailable();
      }
    } catch (_) {
      available = false;
    }
    if (!mounted || available == _systemSpeechAvailable) return;
    setState(() => _systemSpeechAvailable = available);
  }

  /// 下拉每项的副标题：模型定位 + 平台适配度 + int8 全套大小。
  ///
  /// 定位排第一：只报「轻量 / 大模型」会让用户把大的读成更好的，而专用包在自己
  /// 那门语言上比通用的 Omnilingual 更准（见 [AsrModelScope]）。
  ///
  /// 「多大」用 int8 那套：它是手机与无 GPU 桌面实际会下的一套，也是两套里小的
  /// 那个——把大的报给用户会让「Omnilingual 在手机上要 4 GB」这种吓人的数字出现在
  /// 一个根本不会下 fp32 的设备上。
  String _modelSubtitle(AsrEngineOption option) {
    if (option.isCloud) {
      final String? name = _cloudProviderName;
      return name == null
          ? t.audiobook_transcribe_engine_cloud_unset
          : t.audiobook_transcribe_engine_cloud_hint(name: name);
    }
    final AsrModelPack? pack = option.pack;
    // 系统语音没有包、没有大小可报——说清它的真实代价（系统会下自己的语言资产），
    // 别编一个字节数，也别吹成零下载。
    if (pack == null) return t.audiobook_transcribe_engine_system_hint;
    final String scope = switch (asrModelScopeFor(pack)) {
      AsrModelScope.dedicated => t.audiobook_transcribe_model_scope_dedicated,
      AsrModelScope.multilingual =>
        t.audiobook_transcribe_model_scope_multilingual,
    };
    final String fit = switch (asrModelFitFor(pack, mobile: _isMobile)) {
      AsrModelFit.light => t.audiobook_transcribe_model_fit_light,
      AsrModelFit.desktop => t.audiobook_transcribe_model_fit_desktop,
      AsrModelFit.heavyOnMobile =>
        t.audiobook_transcribe_model_fit_heavy_mobile,
    };
    final String size = FushiByteFormat.bytes(
      pack.totalBytes(AsrEncoderVariant.int8),
    );
    final bool custom = pack.id.startsWith(kAsrCustomPackIdPrefix);
    final String badge = custom
        ? ' · ${t.audiobook_transcribe_model_custom_badge}'
        : '';
    return '$scope · $fit · $size$badge';
  }

  /// 当前选中的是不是系统语音引擎。
  bool get _systemSpeech => _selectedEngineId() == kAppleSpeechEngineId;

  /// 当前选中的是不是云端转录。
  bool get _cloudEngine =>
      _cloudService != null && _selectedEngineId() == kCloudWhisperEngineId;

  /// 云端转录当前指派的提供商名；null = 没在 AI 设置里指派（或配不全）。
  /// 每次现取：用户开着弹层去设置里配好，回来就能用。
  String? get _cloudProviderName {
    final AsrTranscriptionService? cloud = _cloudService;
    return cloud is CloudWhisperTranscriptionService
        ? cloud.provider?.displayName
        : null;
  }

  /// 选了云端转录但还没指派提供商：不给「开始」，状态卡说清去哪里配。
  bool get _cloudUnconfigured => _cloudEngine && _cloudProviderName == null;

  /// 就绪行里那段「用哪个模型跑」的描述。
  ///
  /// 系统语音没有变体（fp32 / int8 是 ONNX 编码器的概念），报变体等于报一个假事实，
  /// 所以只报引擎名。
  String _readyEngineLabel(AsrTranscribePlan plan) {
    if (_systemSpeech) return t.audiobook_transcribe_engine_system;
    if (_cloudEngine) {
      final String? name = _cloudProviderName;
      return name == null
          ? t.audiobook_transcribe_engine_cloud
          : '${t.audiobook_transcribe_engine_cloud} · $name';
    }
    return '${asrModelPackFor(plan.language, profile: _profile).displayName} · '
        '${_variantLabel(plan.variant)}';
  }

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 换模型：记住选择（每语言 × 素材一条），再按新包重新规划。
  ///
  /// 模型换了就是另一套磁盘目录与另一个任务哈希（任务 id 含包 id），所以进行中的
  /// 进度不会被顶掉，切回去还在。
  Future<void> _changeEngine(String engineId) async {
    if (_selectedEngineId() == engineId) return;
    _optionsChangedSinceResult = false;
    // 先换服务再重新规划：plan / 就绪判定 / 任务目录全由服务决定，顺序反了会用
    // 旧引擎去查新引擎的任务。
    setState(() => _service = _serviceFor(engineId));
    await _updateCatalog(
      widget.catalogGetter().withChoice(_language, engineId, profile: _profile),
    );
  }

  /// 手动指定一个本地模型：认好之后接进目录并**顺手选中**——用户刚指了它，还要再
  /// 去下拉里选一次是多余的一步。
  Future<void> _addLocalModel() async {
    final AsrModelPack? pack = await showAsrLocalModelDialog(
      context: context,
      language: _language,
      directoryPicker: widget.directoryPicker,
    );
    if (pack == null || !mounted) return;
    // withLocalPack 而不是 withCustomPack：id 由显示名派生，两个不同文件夹很容易
    // 撞上同一个 id，撞了要加后缀而不是把先前那份覆盖掉（连同指向它的选择）。
    final ({AsrModelCatalog catalog, AsrModelPack pack}) added = widget
        .catalogGetter()
        .withLocalPack(pack);
    await _updateCatalog(
      added.catalog.withChoice(_language, added.pack.id, profile: _profile),
    );
    if (!mounted) return;
    FushiToast.show(
      msg: t.audiobook_transcribe_model_custom_added(
        name: added.pack.displayName,
      ),
      severity: ToastSeverity.success,
    );
  }

  /// 落盘 + 装进本进程，然后重新规划。写盘失败不改本进程状态（见
  /// `saveAsrModelCatalog`），所以这里把错误显示出来而不是当作已生效。
  Future<void> _updateCatalog(AsrModelCatalog catalog) async {
    try {
      await widget.catalogSetter(catalog);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = '$error';
      });
      return;
    }
    if (!mounted) return;
    _result = null;
    _elapsedTotal = null;
    _progress = null;
    await _refreshPlan();
  }

  /// 把转录产物导出到用户指定位置（桌面存盘 / 移动端分享）。产物文件本身留在
  /// 任务目录里，导出只是拷一份，之后仍可「使用字幕」。
  Future<void> _export() async {
    final String? srt = _finishedSrt;
    if (srt == null) return;
    final bool exported = await exportTranscribedSrt(
      srtPath: srt,
      audioPaths: widget.audioPaths,
      saveFilePicker: widget.saveFilePicker,
    );
    if (!exported || !mounted || !isDesktopPlatform) return;
    FushiToast.show(
      msg: t.audiobook_transcribe_export_saved,
      severity: ToastSeverity.success,
    );
  }

  Future<void> _discard() async {
    await _service.discard(widget.audioPaths, _language);
    if (!mounted) return;
    _result = null;
    _elapsedTotal = null;
    _finishedSrt = null;
    _progress = null;
    _optionsChangedSinceResult = false;
    _proofreadNote = null;
    _hasProofreadBackup = false;
    await _refreshPlan();
  }

  /// 用 AI 校对完成的转录稿（修错字、补标点；行数与时间轴不变）。整份校对完才写回
  /// （原稿留备份），失败 / 关弹层时字幕不动。
  Future<void> _proofread() async {
    final AsrProofreadHost? host = widget.proofreadHost;
    final String? srt = _finishedSrt;
    if (host == null || srt == null) return;
    if (host.providerName() == null) {
      setState(() => _proofreadNote = t.audiobook_transcribe_proofread_unset);
      return;
    }
    final SubtitleCancelSource cancel = SubtitleCancelSource();
    _proofreadCancel = cancel;
    setState(() {
      _phase = _Phase.proofreading;
      _proofreadDone = 0;
      _proofreadTotal = 0;
      _proofreadNote = null;
    });
    String note;
    try {
      final AsrTranscriptProofreadFileOutcome outcome = await host.run(
        srtPath: srt,
        languageTag: _language.tag,
        cancel: cancel,
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _proofreadDone = done;
            _proofreadTotal = total;
          });
        },
      );
      note = t.audiobook_transcribe_proofread_done(
        changed: outcome.changedCues,
        skipped: outcome.skippedBatches,
      );
    } on SubtitlePipelineCancelled {
      return;
    } on SubtitleAiRequestFailure catch (failure) {
      note = t.audiobook_transcribe_proofread_failed(
        reason: aiFailureText(failure.reason),
      );
    } on Object catch (error) {
      note = t.audiobook_transcribe_proofread_failed(reason: '$error');
    } finally {
      if (identical(_proofreadCancel, cancel)) _proofreadCancel = null;
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.finished;
      _proofreadNote = note;
      _hasProofreadBackup = asrTranscriptHasProofreadBackup(srt);
    });
  }

  /// 把 AI 校对前的原稿还原回去（备份仍保留，可再校对）。
  Future<void> _restoreOriginal() async {
    final String? srt = _finishedSrt;
    if (srt == null) return;
    final bool restored = await restoreAsrTranscriptOriginal(srt);
    if (!mounted || !restored) return;
    setState(() => _proofreadNote = t.audiobook_transcribe_proofread_restored);
  }

  /// 按眼下的选项重新转录：放掉现成结果再直接开跑（BUG-3138）。新选项需要先下载
  /// 模型时停在下载态，由用户点下载。
  Future<void> _retranscribe() async {
    await _discard();
    if (!mounted || _phase != _Phase.ready) return;
    await _startTranscription();
  }

  // ── 展示 ───────────────────────────────────────────────────────────────────

  String _providerLabel(OnnxExecutionProvider p) => switch (p) {
    OnnxExecutionProvider.cuda => 'CUDA (GPU)',
    OnnxExecutionProvider.directml => 'DirectML (GPU)',
    OnnxExecutionProvider.coreml => 'CoreML',
    OnnxExecutionProvider.cpu => 'CPU',
  };

  String _variantLabel(AsrEncoderVariant v) => switch (v) {
    AsrEncoderVariant.fp32 => 'fp32 · GPU',
    AsrEncoderVariant.int8 => 'int8 · CPU',
  };

  static String _fmtDuration(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes % 60;
    final int s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String _statusLine() {
    if (_runRemote &&
        _remoteStatus != null &&
        (_phase == _Phase.loading || _phase == _Phase.running)) {
      return _remoteStatus!;
    }
    final AsrTranscribePlan? plan = _plan;
    switch (_phase) {
      case _Phase.checking:
        return t.audiobook_transcribe_preparing;
      case _Phase.needDownload:
        final StringBuffer sb = StringBuffer(
          t.audiobook_transcribe_model_download_needed(
            size: FushiByteFormat.bytes(plan?.bytesToDownload),
          ),
        );
        // 是「装不起来被清掉」才退回下载的，得说清楚——否则用户刚下完的模型又
        // 要求下载一遍，看起来像下载没生效。
        if (_modelDiscarded) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_model_discarded);
        }
        _appendProbeHint(sb, plan);
        return sb.toString();
      case _Phase.downloading:
        return t.audiobook_transcribe_model_downloading(
          name: _downloadFile,
          received: FushiByteFormat.bytes(_downloadReceived),
          total: FushiByteFormat.bytes(_downloadTotal),
        );
      case _Phase.ready:
      case _Phase.paused:
        // 就绪行报的是**当前引擎**的名字。不能再直接问 `asrModelPackFor(language)`
        // ——那只答得出 ONNX 包，选中系统语音时会报出一个根本没在跑的模型名。
        final String ready = t.audiobook_transcribe_model_ready(
          variant: plan == null ? '' : _readyEngineLabel(plan),
        );
        final StringBuffer sb = StringBuffer(ready);
        if (_cloudUnconfigured) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_engine_cloud_unset);
        }
        if (_systemSpeech) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_engine_system_no_pause);
        }
        if (_phase == _Phase.paused) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_paused_hint);
        }
        final GpuRuntimeOffer? offer = _gpuOffer;
        if (offer != null && !_runRemote) {
          final String name = _gpuKindLabel(offer.store.environment.kind);
          sb
            ..writeln()
            ..write(
              offer.effective == null
                  ? t.audiobook_transcribe_gpu_offer_cpu(name: name)
                  : t.audiobook_transcribe_gpu_offer_faster(name: name),
            );
        }
        if (_gpuRestartRequired && offer == null && !_runRemote) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_gpu_restart);
        }
        _appendProbeHint(sb, plan);
        return sb.toString();
      case _Phase.loading:
        return t.audiobook_transcribe_preparing;
      case _Phase.running:
      case _Phase.pausing:
        final AsrTranscribeProgress? p = _progress;
        final StringBuffer sb = StringBuffer();
        final OnnxProviderResolution? r = _resolution;
        if (r != null) {
          // 静态融合图（GPU 桶）真在跑时告诉用户——它是「为什么这么快 / 为什么
          // 显存涨了」的答案；桶建失败回退动态会话时这里自然不显示。
          final bool staticGraph = (p?.decodeStats?.staticBatches ?? 0) > 0;
          sb.writeln(
            staticGraph
                ? t.audiobook_transcribe_running_on_static(
                    provider: _providerLabel(r.effective),
                  )
                : t.audiobook_transcribe_running_on(
                    provider: _providerLabel(r.effective),
                  ),
          );
          final String? fallback = asrEncoderFallbackLine(
            r,
            probeError: _plan?.probeError,
          );
          if (fallback != null) sb.writeln(fallback);
        }
        if (p != null) {
          sb.writeln(
            t.audiobook_transcribe_progress(
              done: _fmtDuration(Duration(milliseconds: p.processedMs)),
              total: _fmtDuration(Duration(milliseconds: p.totalMs)),
              file: p.fileIndex + 1,
              files: p.filesTotal,
            ),
          );
          final double? rtf = p.rtf;
          final Duration? eta = p.eta;
          sb.write(
            t.audiobook_transcribe_speed(
              elapsed: _fmtDuration(p.elapsed),
              eta: eta == null ? '—' : _fmtDuration(eta),
              speed: rtf == null || rtf <= 0
                  ? '—'
                  : (1 / rtf).toStringAsFixed(1),
            ),
          );
        }
        if (_phase == _Phase.pausing) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_pausing);
        }
        return sb.toString().trimRight();
      case _Phase.finished:
        final AsrTranscribeResult? r = _result;
        final StringBuffer sb = StringBuffer(
          r != null
              ? t.audiobook_transcribe_done(
                  cues: r.cueCount,
                  segments: r.segmentCount,
                )
              : t.audiobook_transcribe_result_name,
        );
        final Duration? elapsed = _elapsedTotal;
        if (elapsed != null) {
          sb
            ..writeln()
            ..write(
              t.audiobook_transcribe_elapsed_total(
                elapsed: _fmtDuration(elapsed),
              ),
            );
        }
        // 匹配正文 / 入库在「使用字幕」之后由导入链路跑；还没跑过时说清楚，
        // 阶段轨后两格空着不是卡住了。
        if (_lastCoverage == null) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_match_after_use);
        }
        sb
          ..writeln()
          ..write(
            _optionsChangedSinceResult
                ? t.audiobook_transcribe_options_changed_hint
                : t.audiobook_transcribe_retranscribe_hint,
          );
        if (widget.proofreadHost != null) {
          sb
            ..writeln()
            ..write(_proofreadNote ?? t.audiobook_transcribe_proofread_hint);
        }
        return sb.toString();
      case _Phase.proofreading:
        return t.audiobook_transcribe_proofread_running(
          done: _proofreadDone,
          total: _proofreadTotal == 0 ? '—' : '$_proofreadTotal',
        );
      case _Phase.error:
        final String error = _error ?? '';
        final String failed = t.audiobook_transcribe_failed(error: error);
        // 音频文件本身只能解出一部分（损坏 / 没下完）：原文是 ffmpeg 细节，先给一句
        // 用户能照着做的话。转录在后台 isolate 跑，这里只剩文本，按引擎的稳定标记认。
        return isAsrIncompleteAudioFailure(error)
            ? '${t.audiobook_transcribe_audio_incomplete}\n$failed'
            : failed;
    }
  }

  /// 计划阶段 EP 探测抛错过：推荐的「int8 · CPU」不是本机没有 GPU，而是探测失败——
  /// 追加一行说明，用户才知道整本按 CPU 速度跑是降级而非常态。
  ///
  /// 只给用户能读懂的那句话，不拼异常原文（反馈 eEnV5gBn1K：面板上直接出现了
  /// `Invalid argument(s): Provider WEBGPU is not a valid OrtProvider.`）。原文是
  /// 排查线索，由 [_refreshPlan] 写进日志，CLI / 控制通道的 `probeError` 字段也照旧带着。
  static void _appendProbeHint(StringBuffer sb, AsrTranscribePlan? plan) {
    if (plan?.probeError == null) return;
    sb
      ..writeln()
      ..write(t.audiobook_transcribe_probe_failed_hint);
  }

  /// 阶段轨五格（纯由弹层状态推出）。匹配正文 / 入库发生在「使用字幕」之后的
  /// 导入链路里：有上次匹配留下的覆盖情况才画成已完成，否则留空。
  List<AsrStageState> _pipelineStates() {
    final Set<AsrPipelineStage> skipped = <AsrPipelineStage>{
      if (!_downloadedModelHere || _runRemote) AsrPipelineStage.downloadModel,
    };
    const Set<AsrPipelineStage> transcribed = <AsrPipelineStage>{
      AsrPipelineStage.downloadModel,
      AsrPipelineStage.loadModel,
      AsrPipelineStage.transcribe,
    };
    switch (_phase) {
      case _Phase.checking:
        return asrPipelineStates();
      case _Phase.needDownload:
      case _Phase.downloading:
        return asrPipelineStates(current: AsrPipelineStage.downloadModel);
      case _Phase.ready:
        return asrPipelineStates(
          completed: const <AsrPipelineStage>{AsrPipelineStage.downloadModel},
          skipped: skipped,
        );
      case _Phase.loading:
        return asrPipelineStates(
          current: AsrPipelineStage.loadModel,
          skipped: skipped,
        );
      case _Phase.running:
      case _Phase.pausing:
      case _Phase.paused:
      // AI 校对是在转录稿上再加工一遍（还没到匹配正文），转录格仍算进行中。
      case _Phase.proofreading:
        return asrPipelineStates(
          current: AsrPipelineStage.transcribe,
          skipped: skipped,
        );
      case _Phase.finished:
        return _lastCoverage != null
            ? asrPipelineStates(allDone: true, skipped: skipped)
            : asrPipelineStates(completed: transcribed, skipped: skipped);
      case _Phase.error:
        final AsrPipelineStage? failed = _failedStage;
        return failed == null
            ? asrPipelineStates()
            : asrPipelineStates(
                current: failed,
                skipped: skipped,
                failed: true,
              );
    }
  }

  double? _progressValue() {
    switch (_phase) {
      case _Phase.downloading:
        return _downloadTotal > 0
            ? (_downloadReceived / _downloadTotal).clamp(0.0, 1.0)
            : null;
      case _Phase.running:
      case _Phase.pausing:
        return _runRemote ? _remoteProgress : _progress?.fraction;
      case _Phase.finished:
        return 1;
      case _Phase.proofreading:
        return _proofreadTotal > 0
            ? (_proofreadDone / _proofreadTotal).clamp(0.0, 1.0)
            : null;
      case _Phase.checking:
      case _Phase.loading:
        return null;
      case _Phase.needDownload:
      case _Phase.ready:
      case _Phase.paused:
      case _Phase.error:
        return 0;
    }
  }

  bool get _busy =>
      _phase == _Phase.checking ||
      _phase == _Phase.downloading ||
      _phase == _Phase.loading ||
      _phase == _Phase.running ||
      _phase == _Phase.pausing ||
      _phase == _Phase.proofreading;

  /// 完成态也能改（BUG-3138）：改了只是让现成结果过期，由「重新转录」生效。
  bool get _canChangePreference =>
      _phase == _Phase.needDownload ||
      _phase == _Phase.ready ||
      _phase == _Phase.paused ||
      _phase == _Phase.error ||
      _phase == _Phase.finished;

  /// 状态卡的 M3E tonal 色块：失败 error、完成 tertiary、进行中 primary、
  /// 其余（待下载 / 就绪 / 已暂停 / 检查中）中性。
  FushiCardTone _statusTone() {
    switch (_phase) {
      case _Phase.error:
        return FushiCardTone.error;
      case _Phase.finished:
        return FushiCardTone.tertiary;
      case _Phase.downloading:
      case _Phase.loading:
      case _Phase.running:
      case _Phase.pausing:
      case _Phase.proofreading:
        return FushiCardTone.primary;
      case _Phase.checking:
      case _Phase.needDownload:
      case _Phase.ready:
      case _Phase.paused:
        return FushiCardTone.neutral;
    }
  }

  IconData _statusIcon() {
    switch (_phase) {
      case _Phase.error:
        return FushiIcons.error;
      case _Phase.finished:
        return FushiIcons.success;
      case _Phase.downloading:
        return FushiIcons.downloading;
      case _Phase.running:
        return FushiIcons.voice;
      case _Phase.proofreading:
        return FushiIcons.aiAssistant;
      case _Phase.pausing:
      case _Phase.paused:
        return FushiIcons.pause;
      case _Phase.needDownload:
        return FushiIcons.cloudDownload;
      case _Phase.ready:
        return FushiIcons.check;
      case _Phase.checking:
      case _Phase.loading:
        return FushiIcons.pending;
    }
  }

  /// 一个选项分段：标题 + 控件，作为分段卡里的一格（首尾大圆角、行间 2）。
  Widget _optionSegment(
    BuildContext context, {
    required int index,
    required int count,
    required String label,
    required Widget child,
  }) {
    return FushiStaggeredEntrance(
      index: index,
      child: FushiGroupedListItem(
        index: index,
        count: count,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(label, style: context.fushiType.titleSmallEmphasized),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final bool showProgressBar =
        _phase == _Phase.downloading ||
        _phase == _Phase.running ||
        _phase == _Phase.pausing ||
        _phase == _Phase.loading ||
        _phase == _Phase.checking ||
        _phase == _Phase.proofreading;
    final List<(String, Widget)> options = <(String, Widget)>[
      (
        t.audiobook_transcribe_language_label,
        // 语言多到分段按钮放不下（8 种起步），改下拉；每项副标题是该语言的模型名。
        GamepadMenuDropdown<AsrLanguage>(
          key: const ValueKey<String>('asr-transcribe-language'),
          entries: <GamepadDropdownEntry<AsrLanguage>>[
            for (final AsrLanguage language in AsrLanguage.values)
              (value: language, label: asrLanguageLabel(language)),
          ],
          selected: _language,
          enabled: _canChangePreference,
          entrySubtitle: (AsrLanguage language) =>
              asrModelPackFor(language, profile: _profile).displayName,
          onChanged: _changeLanguage,
        ),
      ),
      (
        t.audiobook_transcribe_model_label,
        // 模型：这门语言下注册表里认得的包。第一项就是当前生效的那个
        // （`asrModelPackFor` 同样取「第一个服务它的包」），所以不另算选中项。
        // 下拉与「手动指定」同一行：弹层本来就长（语言 / 模型 / 加速 / 状态 /
        // 进度条），模型区多占一行会把「加速」整段挤出首屏。
        Builder(
          builder: (BuildContext ctx) {
            final List<AsrEngineOption> engineOptions = _engineOptions();
            return Row(
              children: <Widget>[
                Expanded(
                  child: GamepadMenuDropdown<String>(
                    key: const ValueKey<String>('asr-transcribe-model'),
                    entries: <GamepadDropdownEntry<String>>[
                      for (final AsrEngineOption option in engineOptions)
                        (value: option.id, label: option.label),
                    ],
                    selected: _selectedEngineId(),
                    enabled: _canChangePreference && engineOptions.length > 1,
                    entrySubtitle: (String id) => _modelSubtitle(
                      engineOptions.firstWhere(
                        (AsrEngineOption o) => o.id == id,
                      ),
                    ),
                    onChanged: _changeEngine,
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                FushiIconButtonControl.filledTonal(
                  key: const ValueKey<String>('asr-transcribe-model-add'),
                  tooltip: t.audiobook_transcribe_model_custom_add,
                  icon: const FushiIcon(FushiIcons.folderOpen),
                  // 选中系统语音时接入本地 ONNX 模型没有意义（那是另一个引擎的
                  // 东西）——留着可点会让用户以为接进来就能给系统语音用。
                  onPressed:
                      _canChangePreference &&
                          _selectedEngineId() != kAppleSpeechEngineId &&
                          !_cloudEngine
                      ? _addLocalModel
                      : null,
                ),
              ],
            );
          },
        ),
      ),
      (
        t.audiobook_transcribe_accel_label,
        _accelerationControl(
          FushiSegmentedButton<AsrAccelerationPreference>(
            segments: <ButtonSegment<AsrAccelerationPreference>>[
              ButtonSegment<AsrAccelerationPreference>(
                value: AsrAccelerationPreference.auto,
                label: Text(t.audiobook_transcribe_accel_auto),
              ),
              ButtonSegment<AsrAccelerationPreference>(
                value: AsrAccelerationPreference.cpuOnly,
                label: Text(t.audiobook_transcribe_accel_cpu),
              ),
              // 上游只在 macOS 接受 coreml（别的平台 plan() 直接抛
              // UnsupportedError），auto 在 macOS 仍走 INT8 CPU，CoreML 是显式
              // 选项——按 defaultTargetPlatform 露出，widget 测试可覆盖。
              if (defaultTargetPlatform == TargetPlatform.macOS)
                ButtonSegment<AsrAccelerationPreference>(
                  value: AsrAccelerationPreference.coreml,
                  label: Text(t.audiobook_transcribe_accel_coreml),
                ),
              // Windows 的两个 GPU 后端都是显式可选：显卡老 / 驱动不合适时用户能自己
              // 退到 DirectML 或 CPU；CUDA 只在运行库已下载并注册成功（探测到）时
              // 出现。「自动」仍是 CUDA > DirectML > CPU。
              if (defaultTargetPlatform == TargetPlatform.windows &&
                  (_knownGpuProviders.contains(
                        OnnxExecutionProvider.directml,
                      ) ||
                      (_gpuDetection?.hasHardwareAdapter ?? false)))
                ButtonSegment<AsrAccelerationPreference>(
                  value: AsrAccelerationPreference.directml,
                  label: Text(t.audiobook_transcribe_accel_directml),
                ),
              if (defaultTargetPlatform == TargetPlatform.windows &&
                  (_knownGpuProviders.contains(OnnxExecutionProvider.cuda) ||
                      (_gpuDetection != null &&
                          isCudaEligible(_gpuDetection!.cuda))))
                ButtonSegment<AsrAccelerationPreference>(
                  value: AsrAccelerationPreference.cuda,
                  label: Text(t.audiobook_transcribe_accel_cuda),
                ),
            ],
            selected: <AsrAccelerationPreference>{_preference},
            showSelectedIcon: false,
            // 不能改时传 null：分段按钮按禁用态画。曾经传一个空回调，按钮看着能点、
            // 点了没反应（BUG-3138）。云端转录不在本机算，加速无从谈起。
            onSelectionChanged: !_canChangePreference || _cloudEngine
                ? null
                : (Set<AsrAccelerationPreference> s) =>
                      unawaited(_setPreference(s.first)),
          ),
          tokens,
        ),
      ),
      // 云端转录本来就不在本机跑：不给「在互联 host 上运行」。
      if (_remoteTarget != null && !_cloudEngine)
        (
          t.audiobook_transcribe_run_location,
          GamepadMenuDropdown<bool>(
            key: const ValueKey<String>('asr-transcribe-run-location'),
            entries: <GamepadDropdownEntry<bool>>[
              (value: false, label: t.audiobook_transcribe_run_local),
              (
                value: true,
                label: t.audiobook_transcribe_run_remote(
                  device: _remoteTarget!.label,
                ),
              ),
            ],
            selected: _runRemote,
            enabled: _canChangePreference,
            onChanged: (bool v) => setState(() {
              if (v == _runRemote) return;
              if (_phase == _Phase.finished) _optionsChangedSinceResult = true;
              _runRemote = v;
            }),
          ),
        ),
    ];
    // 状态卡：tonal 色块随阶段变色，进行中在卡内出波浪进度。
    final Widget statusCard = FushiStaggeredEntrance(
      index: options.length,
      child: FushiCard(
        key: const ValueKey<String>('asr-transcribe-status-card'),
        tone: _statusTone(),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AsrPipelineStageRail(
              states: _pipelineStates(),
              foreground: fushiCardToneColors(
                context,
                _statusTone(),
              )?.onContainer,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiIcon(_statusIcon(), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _statusLine(),
                    key: const ValueKey<String>('asr-transcribe-status'),
                    // 色块上的字跟卡片配对前景（fushiType 自带页面
                    // 前景，HBK-AUDIT-022）。
                    style: context.fushiType.bodyMedium.tabular.copyWith(
                      color: fushiCardToneColors(
                        context,
                        _statusTone(),
                      )?.onContainer,
                    ),
                  ),
                ),
              ],
            ),
            FushiAnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: _phase == _Phase.finished && _lastCoverage != null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8, left: 32),
                      child: AsrCoverageSummary(
                        coverage: _lastCoverage!,
                        caption: t.audiobook_transcribe_coverage_last,
                        foreground: fushiCardToneColors(
                          context,
                          _statusTone(),
                        )?.onContainer,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: showProgressBar
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      // 百分比与补间都在 AsrSmoothedProgressBar 里：数值原样取引擎
                      // （下载字节 / 已转录时长 / 远端回报），不定态不显示百分比。
                      child: AsrSmoothedProgressBar(
                        value: _progressValue(),
                        foreground: fushiCardToneColors(
                          context,
                          _statusTone(),
                        )?.onContainer,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
    // 屏幕够高时状态卡钉在底栏、不随正文滚动：选项多时正文区要滚，状态卡曾被
    // 滚动区截掉一半、看着像压在按钮下面（10-16）。矮屏（手机横屏、小窗）
    // 标题 + 底栏会把弹层撑爆，那时仍放回正文末尾随正文滚动。
    final bool pinStatus = MediaQuery.sizeOf(context).height >= 720;
    return FushiModalSheetFrame(
      title: t.audiobook_transcribe_title,
      leadingIcon: FushiIcons.voice,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(t.audiobook_transcribe_intro, style: tokens.type.metadata),
            SizedBox(height: tokens.spacing.rowVertical),
            for (int i = 0; i < options.length; i++)
              _optionSegment(
                context,
                index: i,
                count: options.length,
                label: options[i].$1,
                child: options[i].$2,
              ),
            if (!pinStatus) ...<Widget>[
              SizedBox(height: tokens.spacing.rowVertical),
              statusCard,
            ],
          ],
        ),
      ),
      footer: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (pinStatus) ...<Widget>[
              statusCard,
              SizedBox(height: tokens.spacing.rowVertical),
            ],
            // Wrap 而不是 Row：完成态有三个按钮，窄窗/移动端一行放不下会横向溢出。
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: _footerButtons(context, tokens),
            ),
          ],
        ),
      ),
    );
  }

  /// 「加速」一栏：分段 + 选中的 GPU 环境还没装时紧跟一个下载按钮（模型已就绪
  /// 的老用户、或在这里新选了 CUDA / DirectML 的人）。放在选项旁边而不是底栏：
  /// 底栏在「已完成」阶段已有三个动作，下载入口挤在那儿用户看不到（10-16）。
  Widget _accelerationControl(Widget segments, FushiDesignTokens tokens) {
    final GpuRuntimeOffer? offer = _gpuOffer;
    final bool showOffer =
        offer != null &&
        !_runRemote &&
        _phase != _Phase.downloading &&
        _phase != _Phase.running &&
        _phase != _Phase.pausing &&
        _phase != _Phase.loading;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        segments,
        FushiAnimatedSize(
          duration: context.fushiMotion.spatialDefault.duration,
          curve: context.fushiMotion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: showOffer
              ? Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FushiOutlinedButton.icon(
                      key: const ValueKey<String>(
                        'asr-transcribe-gpu-download',
                      ),
                      icon: const FushiIcon(FushiIcons.download, size: 18),
                      label: Text(
                        t.audiobook_transcribe_gpu_download(
                          name: _gpuKindLabel(offer.store.environment.kind),
                          size: FushiByteFormat.bytes(
                            offer.store.pendingDownloadBytes,
                          ),
                        ),
                      ),
                      onPressed: _canChangePreference
                          ? _startGpuDownload
                          : null,
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  List<Widget> _footerButtons(BuildContext context, FushiDesignTokens tokens) {
    final List<Widget> buttons = <Widget>[];
    void add(Widget w) => buttons.add(w);
    add(
      FushiTextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t.cancel),
      ),
    );
    switch (_phase) {
      case _Phase.needDownload:
        // 选了远端 host 就不需要本机模型：直接给「开始」。
        add(
          _runRemote && _remoteTarget != null
              ? FushiFilledButton.icon(
                  icon: const FushiIcon(FushiIcons.play, size: 18),
                  label: Text(t.audiobook_transcribe_start),
                  onPressed: _startTranscription,
                )
              : FushiFilledButton.icon(
                  icon: const FushiIcon(FushiIcons.download, size: 18),
                  label: Text(t.audiobook_transcribe_model_download),
                  onPressed: () => unawaited(_startDownload()),
                ),
        );
      case _Phase.ready:
        add(
          FushiFilledButton.icon(
            icon: const FushiIcon(FushiIcons.play, size: 18),
            label: Text(t.audiobook_transcribe_start),
            onPressed: _cloudUnconfigured ? null : _startTranscription,
          ),
        );
      case _Phase.paused:
        add(
          FushiTextButton(
            onPressed: _discard,
            child: Text(t.audiobook_transcribe_discard),
          ),
        );
        add(
          FushiFilledButton.icon(
            icon: const FushiIcon(FushiIcons.play, size: 18),
            label: Text(t.audiobook_transcribe_resume),
            onPressed: _startTranscription,
          ),
        );
      case _Phase.running:
        add(
          FushiFilledButton.icon(
            icon: const FushiIcon(FushiIcons.pause, size: 18),
            label: Text(t.audiobook_transcribe_pause),
            onPressed: _pause,
          ),
        );
      case _Phase.finished:
        // 改过选项：主动作是「按新选项重新转录」；没改过仍给「放弃进度」。
        add(
          _optionsChangedSinceResult
              ? FushiTextButton(
                  key: const ValueKey<String>('asr-transcribe-retranscribe'),
                  onPressed: _retranscribe,
                  child: Text(t.audiobook_transcribe_retranscribe),
                )
              : FushiTextButton(
                  onPressed: _discard,
                  child: Text(t.audiobook_transcribe_discard),
                ),
        );
        if (_hasProofreadBackup) {
          add(
            FushiTextButton(
              key: const ValueKey<String>('asr-transcribe-proofread-restore'),
              onPressed: _finishedSrt == null ? null : _restoreOriginal,
              child: Text(t.audiobook_transcribe_proofread_restore),
            ),
          );
        }
        if (widget.proofreadHost != null) {
          add(
            FushiOutlinedButton.icon(
              key: const ValueKey<String>('asr-transcribe-proofread'),
              icon: const FushiIcon(FushiIcons.aiAssistant, size: 18),
              label: Text(t.audiobook_transcribe_proofread),
              onPressed: _finishedSrt == null ? null : _proofread,
            ),
          );
        }
        add(
          FushiOutlinedButton.icon(
            icon: const FushiIcon(FushiIcons.save, size: 18),
            label: Text(t.audiobook_transcribe_export),
            onPressed: _finishedSrt == null ? null : _export,
          ),
        );
        add(
          FushiFilledButton.icon(
            icon: const FushiIcon(FushiIcons.check, size: 18),
            label: Text(t.audiobook_transcribe_use_result),
            onPressed: _finishedSrt == null
                ? null
                : () => Navigator.pop(context, _finishedSrt),
          ),
        );
      case _Phase.error:
        add(
          FushiFilledButton.icon(
            icon: const FushiIcon(FushiIcons.refresh, size: 18),
            label: Text(t.audiobook_transcribe_resume),
            onPressed: _refreshPlan,
          ),
        );
      case _Phase.checking:
      case _Phase.downloading:
      case _Phase.loading:
      case _Phase.pausing:
      case _Phase.proofreading:
        break;
    }
    if (_busy && _phase != _Phase.running) {
      // 忙碌态给一个不可点的占位，避免按钮区跳动。
      add(
        const SizedBox(
          width: 18,
          height: 18,
          child: FushiCircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return buttons;
  }
}
