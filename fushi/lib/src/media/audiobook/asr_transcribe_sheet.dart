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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show preferredTranscriptExportPath;
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/asr_host/apple_speech_transcription_service.dart';
import 'package:fushi/src/asr_host/asr_engine_options.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';
import 'package:fushi/src/media/audiobook/asr_local_model_dialog.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
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
  })? saveFilePicker,
  String Function()? languageGetter,
  Future<void> Function(String tag)? languageSetter,
  InterconnectJobClient? remoteClient,
  AsrModelCatalog Function()? catalogGetter,
  Future<void> Function(AsrModelCatalog catalog)? catalogSetter,
  Future<String?> Function()? directoryPicker,
}) {
  final AsrTranscriptionService effective =
      service ?? createAsrTranscriptionService();
  String Function() getter = languageGetter ?? () => '';
  Future<void> Function(String) setter = languageSetter ?? (String _) async {};
  AppModel? appModel;
  if (languageGetter == null ||
      languageSetter == null ||
      remoteClient == null) {
    try {
      appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
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
  final InterconnectJobClient? remote = remoteClient ??
      (appModel == null
          ? null
          : InterconnectJobClient(repo: SyncRepository(appModel.database)));
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
}) =>
    asrSupported && hasAudio;

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

class _SubtitleSourceChooser extends StatelessWidget {
  const _SubtitleSourceChooser();

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.audiobook_subtitle_source_title,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiListItem(
            leading: const Icon(Icons.subtitles_outlined),
            title: Text(t.srt_import_pick_subtitle_files),
            onTap: () => Navigator.pop(context, SubtitleSourceChoice.pickFile),
          ),
          FushiListItem(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: Text(t.audiobook_transcribe_action),
            subtitle: Text(t.audiobook_subtitle_source_transcribe_hint),
            onTap: () =>
                Navigator.pop(context, SubtitleSourceChoice.transcribe),
          ),
        ],
      ),
    );
  }
}

/// 导出转录产物：桌面走存盘对话框（默认文件名 = 首个音频同名 `.srt`、起始目录 =
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
  })? saveFilePicker,
  bool? desktop,
}) async {
  srtPath = preferredTranscriptExportPath(srtPath);
  final String suggestedName = suggestedTranscriptFileName(audioPaths);
  if (desktop ?? isDesktopPlatform) {
    final String? initialDirectory =
        audioPaths.isEmpty ? null : File(audioPaths.first).parent.path;
    final Future<String?> Function({
      required String fileName,
      required String? initialDirectory,
    }) pick = saveFilePicker ??
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
  await FushiShare.shareFiles(
    <XFile>[
      XFile(srtPath, mimeType: 'application/x-subrip', name: suggestedName)
    ],
    subject: suggestedName,
  );
  return true;
}

/// 纯函数：导出用的默认文件名——首个音频去扩展名 + `.srt`；多文件有声书取首个
/// （单时间轴 SRT 本来就是整本一份）。没有音频时退回固定名。
String suggestedTranscriptFileName(List<String> audioPaths) {
  if (audioPaths.isEmpty) return 'transcript.srt';
  return '${p.basenameWithoutExtension(audioPaths.first)}.srt';
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
    super.key,
  })  : catalogGetter = catalogGetter ?? _readAsrModelCatalog,
        catalogSetter = catalogSetter ?? saveAsrModelCatalog;

  final List<String> audioPaths;

  /// 测试注入：替换桌面端的存盘对话框。null = 真的 `FilePicker.saveFile`。
  final Future<String?> Function({
    required String fileName,
    required String? initialDirectory,
  })? saveFilePicker;
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

  @override
  State<AsrTranscribeSheet> createState() => _AsrTranscribeSheetState();
}

class _AsrTranscribeSheetState extends State<AsrTranscribeSheet> {
  /// 当前生效的转录服务。选中系统语音时换成另一份实现（见 [_serviceFor]）——
  /// 弹层其余部分只与「一个 AsrTranscriptionService」对话，不知道底下是谁。
  late AsrTranscriptionService _service = widget.service;

  /// 本机有没有系统语音（OS ≥ 26 且原生侧在）。探完才决定下拉里出不出那一项。
  bool _systemSpeechAvailable = false;

  _Phase _phase = _Phase.checking;
  AsrAccelerationPreference _preference = AsrAccelerationPreference.auto;
  AsrLanguage _language = AsrLanguage.japanese;
  AsrTranscribePlan? _plan;
  String? _finishedSrt;
  String? _error;

  /// 本轮里引擎丢弃过一个读不出图的模型文件（见 [_failWith]）。只用来在「需要
  /// 下载」那一阶段多说一句为什么又要下载，不参与阶段判定。
  bool _modelDiscarded = false;

  // 下载进度。
  int _downloadReceived = 0;
  int _downloadTotal = 0;
  String _downloadFile = '';
  StreamSubscription<ModelDownloadEvent>? _downloadSub;

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

  /// 远程 host（能力位含 asr）；null = 只有本机。
  HostJobTarget? _remoteTarget;
  bool _runRemote = false;
  StreamSubscription<HostJobEvent>? _remoteSub;
  String? _remoteStatus;
  double? _remoteProgress;

  @override
  void initState() {
    super.initState();
    _language = widget.languageHint ??
        AsrLanguage.fromTag(widget.languageGetter?.call()) ??
        AsrLanguage.japanese;
    _service = _serviceFor(_selectedEngineId());
    unawaited(_probeSystemSpeech());
    _refreshPlan();
    _probeRemote();
  }

  @override
  void dispose() {
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

  Future<void> _refreshPlan() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      final AsrLanguage language = _language;
      final AsrTranscribePlan plan = await _service.plan(
        language: language,
        preference: _preference,
      );
      final String? finished = await _service.finishedSrtPath(
        widget.audioPaths,
        language,
      );
      final AsrJobState? existing = await _service.existingState(
        widget.audioPaths,
        language,
      );
      // 等待期间用户又切了语言：这份结果已经过期，丢掉（新一轮 _refreshPlan 会
      // 带着新语言再来）。
      if (language != _language) return;
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _finishedSrt = finished;
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
    final String text = '$error';
    if (!_modelDiscarded && isOnnxUnreadableModelFailure(text)) {
      _modelDiscarded = true;
      _refreshPlan();
      return;
    }
    setState(() {
      _phase = _Phase.error;
      _error = text;
    });
  }

  void _startDownload() {
    final AsrTranscribePlan? plan = _plan;
    if (plan == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _downloadTotal = plan.totalModelBytes;
      _downloadReceived = plan.obtainedModelBytes;
      _downloadFile = '';
    });
    // 逐文件事件：把「之前文件」的字节累计起来展示总进度。
    int completedBytes = 0;
    String lastFile = '';
    int lastFileTotal = 0;
    _downloadSub = _service
        .downloadModel(language: plan.language, variant: plan.variant)
        .listen(
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

  Future<void> _startTranscription() async {
    _runClock = Stopwatch()..start();
    _elapsedTotal = null;
    if (_runRemote && _remoteTarget != null) return _startRemoteTranscription();
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
        preference: _preference,
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
    final Directory jobDir =
        await widget.service.jobDirFor(widget.audioPaths, _language);
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
          case HostJobUploading(done: final int done, total: final int total):
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
            await File(p.join(jobDir.path, AsrJobFiles.state))
                .writeAsString(jsonEncode(state.toJson()), flush: true);
            if (!mounted) return;
            setState(() {
              _finishedSrt = srt?.path;
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
      );

  /// 当前选中的引擎 id。
  String? _selectedEngineId() => selectedAsrEngineId(
        language: _language,
        catalog: widget.catalogGetter(),
        options: _engineOptions(),
      );

  /// 按选中的引擎给出服务实例。ONNX 走注入进来的那份（生产是
  /// `createAsrTranscriptionService()`，测试是 fake）；系统语音走另一份实现。
  AsrTranscriptionService _serviceFor(String? engineId) {
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
    final String size =
        FushiByteFormat.bytes(pack.totalBytes(AsrEncoderVariant.int8));
    final bool custom = pack.id.startsWith(kAsrCustomPackIdPrefix);
    final String badge =
        custom ? ' · ${t.audiobook_transcribe_model_custom_badge}' : '';
    return '$scope · $fit · $size$badge';
  }

  /// 当前选中的是不是系统语音引擎。
  bool get _systemSpeech => _selectedEngineId() == kAppleSpeechEngineId;

  /// 就绪行里那段「用哪个模型跑」的描述。
  ///
  /// 系统语音没有变体（fp32 / int8 是 ONNX 编码器的概念），报变体等于报一个假事实，
  /// 所以只报引擎名。
  String _readyEngineLabel(AsrTranscribePlan plan) {
    if (_systemSpeech) return t.audiobook_transcribe_engine_system;
    return '${asrModelPackFor(plan.language).displayName} · '
        '${_variantLabel(plan.variant)}';
  }

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 换模型：记住选择（每语言一条），再按新包重新规划。
  ///
  /// 模型换了就是另一套磁盘目录与另一个任务哈希（任务 id 含包 id），所以进行中的
  /// 进度不会被顶掉，切回去还在。
  Future<void> _changeEngine(String engineId) async {
    if (_selectedEngineId() == engineId) return;
    // 先换服务再重新规划：plan / 就绪判定 / 任务目录全由服务决定，顺序反了会用
    // 旧引擎去查新引擎的任务。
    setState(() => _service = _serviceFor(engineId));
    await _updateCatalog(
      widget.catalogGetter().withChoice(_language, engineId),
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
    final ({AsrModelCatalog catalog, AsrModelPack pack}) added =
        widget.catalogGetter().withLocalPack(pack);
    await _updateCatalog(added.catalog.withChoice(_language, added.pack.id));
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
    await _refreshPlan();
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
          if (r.didFallBack) {
            sb.writeln(
              t.audiobook_transcribe_fallback(reason: r.fallbackReason ?? ''),
            );
          }
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
              speed:
                  rtf == null || rtf <= 0 ? '—' : (1 / rtf).toStringAsFixed(1),
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
        return sb.toString();
      case _Phase.error:
        return t.audiobook_transcribe_failed(error: _error ?? '');
    }
  }

  /// 计划阶段 EP 探测抛错过：推荐的「int8 · CPU」不是本机没有 GPU，而是探测失败——
  /// 追加一行说明，用户才知道整本按 CPU 速度跑是降级而非常态。
  static void _appendProbeHint(StringBuffer sb, AsrTranscribePlan? plan) {
    final String? reason = plan?.probeError;
    if (reason == null) return;
    sb
      ..writeln()
      ..write(t.audiobook_transcribe_probe_failed(reason: reason));
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
      _phase == _Phase.pausing;

  bool get _canChangePreference =>
      _phase == _Phase.needDownload ||
      _phase == _Phase.ready ||
      _phase == _Phase.paused ||
      _phase == _Phase.error;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool showProgressBar = _phase == _Phase.downloading ||
        _phase == _Phase.running ||
        _phase == _Phase.pausing ||
        _phase == _Phase.loading ||
        _phase == _Phase.checking;
    return FushiModalSheetFrame(
      title: t.audiobook_transcribe_title,
      leadingIcon: Icons.record_voice_over_outlined,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.audiobook_transcribe_intro, style: tokens.type.metadata),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            t.audiobook_transcribe_language_label,
            style: tokens.type.listTitle,
          ),
          SizedBox(height: tokens.spacing.gap),
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
                asrModelPackFor(language).displayName,
            onChanged: _changeLanguage,
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            t.audiobook_transcribe_model_label,
            style: tokens.type.listTitle,
          ),
          SizedBox(height: tokens.spacing.gap),
          // 模型：这门语言下注册表里认得的包。第一项就是当前生效的那个
          // （`asrModelPackFor` 同样取「第一个服务它的包」），所以不另算选中项。
          // 下拉与「手动指定」同一行：弹层本来就长（语言 / 模型 / 加速 / 状态 /
          // 进度条），模型区多占一行会把「加速」整段挤出首屏。
          Builder(
            builder: (BuildContext ctx) {
              final List<AsrEngineOption> options = _engineOptions();
              return Row(
                children: <Widget>[
                  Expanded(
                    child: GamepadMenuDropdown<String>(
                      key: const ValueKey<String>('asr-transcribe-model'),
                      entries: <GamepadDropdownEntry<String>>[
                        for (final AsrEngineOption option in options)
                          (value: option.id, label: option.label),
                      ],
                      selected: _selectedEngineId(),
                      enabled: _canChangePreference && options.length > 1,
                      entrySubtitle: (String id) => _modelSubtitle(
                        options.firstWhere((AsrEngineOption o) => o.id == id),
                      ),
                      onChanged: _changeEngine,
                    ),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  IconButton(
                    key: const ValueKey<String>('asr-transcribe-model-add'),
                    tooltip: t.audiobook_transcribe_model_custom_add,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    // 选中系统语音时接入本地 ONNX 模型没有意义（那是另一个引擎的
                    // 东西）——留着可点会让用户以为接进来就能给系统语音用。
                    onPressed: _canChangePreference &&
                            _selectedEngineId() != kAppleSpeechEngineId
                        ? _addLocalModel
                        : null,
                  ),
                ],
              );
            },
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            t.audiobook_transcribe_accel_label,
            style: tokens.type.listTitle,
          ),
          SizedBox(height: tokens.spacing.gap),
          adaptiveSegmentedButton<AsrAccelerationPreference>(
            context: context,
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
            ],
            selected: <AsrAccelerationPreference>{_preference},
            onSelectionChanged: !_canChangePreference
                ? (Set<AsrAccelerationPreference> _) {}
                : (Set<AsrAccelerationPreference> s) {
                    _preference = s.first;
                    _refreshPlan();
                  },
          ),
          if (_remoteTarget != null) ...<Widget>[
            SizedBox(height: tokens.spacing.rowVertical),
            Text(
              t.audiobook_transcribe_run_location,
              style: tokens.type.listTitle,
            ),
            SizedBox(height: tokens.spacing.gap),
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
              onChanged: (bool v) => setState(() => _runRemote = v),
            ),
          ],
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            _statusLine(),
            key: const ValueKey<String>('asr-transcribe-status'),
            style: tokens.type.metadata,
          ),
          if (showProgressBar) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            LinearProgressIndicator(value: _progressValue()),
          ],
        ],
      ),
      // Wrap 而不是 Row：完成态有三个按钮，窄窗/移动端一行放不下会横向溢出。
      footer: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: _footerButtons(context, tokens),
      ),
    );
  }

  List<Widget> _footerButtons(BuildContext context, FushiDesignTokens tokens) {
    final List<Widget> buttons = <Widget>[];
    void add(Widget w) => buttons.add(w);

    add(
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t.cancel),
      ),
    );
    switch (_phase) {
      case _Phase.needDownload:
        // 选了远端 host 就不需要本机模型：直接给「开始」。
        add(
          _runRemote && _remoteTarget != null
              ? FilledButton.icon(
                  icon: const Icon(Icons.play_arrow_outlined, size: 18),
                  label: Text(t.audiobook_transcribe_start),
                  onPressed: _startTranscription,
                )
              : FilledButton.icon(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text(t.audiobook_transcribe_model_download),
                  onPressed: _startDownload,
                ),
        );
      case _Phase.ready:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_outlined, size: 18),
            label: Text(t.audiobook_transcribe_start),
            onPressed: _startTranscription,
          ),
        );
      case _Phase.paused:
        add(
          TextButton(
            onPressed: _discard,
            child: Text(t.audiobook_transcribe_discard),
          ),
        );
        add(
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_outlined, size: 18),
            label: Text(t.audiobook_transcribe_resume),
            onPressed: _startTranscription,
          ),
        );
      case _Phase.running:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.pause_outlined, size: 18),
            label: Text(t.audiobook_transcribe_pause),
            onPressed: _pause,
          ),
        );
      case _Phase.finished:
        add(
          TextButton(
            onPressed: _discard,
            child: Text(t.audiobook_transcribe_discard),
          ),
        );
        add(
          OutlinedButton.icon(
            icon: const Icon(Icons.save_alt_outlined, size: 18),
            label: Text(t.audiobook_transcribe_export),
            onPressed: _finishedSrt == null ? null : _export,
          ),
        );
        add(
          FilledButton.icon(
            icon: const Icon(Icons.check_outlined, size: 18),
            label: Text(t.audiobook_transcribe_use_result),
            onPressed: _finishedSrt == null
                ? null
                : () => Navigator.pop(context, _finishedSrt),
          ),
        );
      case _Phase.error:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.refresh_outlined, size: 18),
            label: Text(t.audiobook_transcribe_resume),
            onPressed: _refreshPlan,
          ),
        );
      case _Phase.checking:
      case _Phase.downloading:
      case _Phase.loading:
      case _Phase.pausing:
        break;
    }
    if (_busy && _phase != _Phase.running) {
      // 忙碌态给一个不可点的占位，避免按钮区跳动。
      add(
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return buttons;
  }
}
