import 'dart:async';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_engine.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_package.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_package.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';
import 'package:fushi/src/asr_host/asr_model_downloads.dart';
import 'package:fushi/src/media/audiobook/asr_models_settings_section.dart'
    show asrModelDownloads, listedAsrModelPacks;
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart'
    show AudiobookSpeedSlider;
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart'
    show ttsProviderLabel;
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart'
    show
        deleteOrphanedTtsReferenceAudio,
        newTtsPresetId,
        ttsDefaultParams,
        ttsPresetsAfterDelete;
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/ops/ctl_settings_wire.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 「设置 › 模型」里 OCR / 语音转录 / 语音合成的模型文件与朗读声音的控制通道路由
/// （CLI 侧见 `packages/fushi_cli/lib/src/commands/settings_model_commands.dart`）。
///
/// - `/api/admin/models`：三类模型文件的状态 / 下载 / 取消 / 删除。
///   - `asr/<包 id 或语言>`：与设置页同一套（[AsrModelDownloads]）——变体取
///     `plan(auto)` 的推荐，状态 / 下载 / 删除都**按包**开目录（同一语言的几个包
///     互不串），下载顺带装 Windows 的 GPU 环境，删除走 `AsrModelStore.deleteAll`；
///     手动接入的本地包只「移除接入」（`withoutCustomPack`），不碰用户的文件；
///   - `ocr/<模型 key>`：下载归全应用的 [MangaOcrModelDownloads] 登记表（与设置页
///     同一份进度，离开 CLI 照跑），删除走 `MangaOcrService.deleteModels`；
///   - `gpt-sovits/local`：本机 GPT-SoVITS 整合包（`GptSovitsLocalEngine.install` /
///     `remove` / `useExisting`），进度读 installer 的同一组字段。
///   - `irodori/local`：本机官方 Irodori-TTS-Server（`IrodoriLocalEngine.install` /
///     `remove` / `start` / `stop`），与部署页同一个引擎对象、同一份进度。
/// - `/api/admin/voices`：朗读声音预设（`TtsPresetStore`，与朗读声音设置页同一份）。
///
/// ASR / OCR 下载都归全应用登记表（`asrModelDownloads` / `MangaOcrModelDownloads`），
/// 设置页与 CLI 看到同一份进度与最近一次失败原因。
List<CtlRoute> buildSettingsModelCtlRoutes(OpContext context) {
  final _CtlModelState state = _CtlModelState(context);
  return <CtlRoute>[
    CtlRoute.get('/api/admin/models', (CtlCall call) => state.listAll()),
    CtlRoute.get(
      '/api/admin/models/:kind/:id',
      (CtlCall call) => state.status(call.params['kind']!, call.params['id']!),
    ),
    CtlRoute.post(
      '/api/admin/models/:kind/:id/download',
      (CtlCall call) =>
          state.download(call.params['kind']!, call.params['id']!, call),
    ),
    CtlRoute.post(
      '/api/admin/models/:kind/:id/cancel',
      (CtlCall call) => state.cancel(call.params['kind']!, call.params['id']!),
    ),
    CtlRoute.post(
      '/api/admin/models/:kind/:id/link',
      (CtlCall call) =>
          state.link(call.params['kind']!, call.params['id']!, call),
    ),
    CtlRoute.post(
      '/api/admin/models/:kind/:id/start',
      (CtlCall call) =>
          state.startServer(call.params['kind']!, call.params['id']!),
    ),
    CtlRoute.post(
      '/api/admin/models/:kind/:id/stop',
      (CtlCall call) =>
          state.stopServer(call.params['kind']!, call.params['id']!),
    ),
    // 不放在 /api/admin/voices/ 下：与 PUT /api/admin/voices/:id 同形会互相遮挡。
    CtlRoute.put(
      '/api/admin/tts/speed',
      (CtlCall call) => state.setVoiceSpeed(call),
    ),
    CtlRoute.delete(
      '/api/admin/models/:kind/:id',
      (CtlCall call) =>
          state.delete(call.params['kind']!, call.params['id']!, call),
    ),
    CtlRoute.get('/api/admin/voices', (CtlCall call) async => state.voices()),
    CtlRoute.get(
      '/api/admin/voices/engines',
      (CtlCall call) async => state.engines(),
    ),
    CtlRoute.post('/api/admin/voices', (CtlCall call) => state.addVoice(call)),
    CtlRoute.put(
      '/api/admin/voices/:id',
      (CtlCall call) => state.updateVoice(call.params['id']!, call),
    ),
    CtlRoute.post(
      '/api/admin/voices/:id/activate',
      (CtlCall call) => state.activateVoice(call.params['id']!),
    ),
    CtlRoute.delete(
      '/api/admin/voices/:id',
      (CtlCall call) => state.deleteVoice(call.params['id']!, call),
    ),
    CtlRoute.get(
      '/api/admin/voices/:id/voices',
      (CtlCall call) => state.listProviderVoices(call.params['id']!),
    ),
  ];
}

/// 模型类别（路径第一段）。
abstract final class CtlModelKind {
  static const String asr = 'asr';
  static const String ocr = 'ocr';
  static const String gptSovits = 'gpt-sovits';
  static const String irodori = 'irodori';
  static const List<String> all = <String>[asr, ocr, gptSovits, irodori];
}

class _CtlModelState {
  _CtlModelState(this.context);

  final OpContext context;
  AsrTranscriptionService? _asrService;

  /// ASR 下载与设置页共用的全局登记表（进度 / 取消 / 失败原因两边互相可见）。
  AsrModelDownloads get _asrDownloads => asrModelDownloads;

  /// 本机 GPT-SoVITS 最近一次 CLI 发起的安装结果（installer 自己只记步骤）。
  String? _gptSovitsLastError;

  AsrTranscriptionService get _asr =>
      _asrService ??= createAsrTranscriptionService();

  TtsServices get _tts => TtsServices.of(context.appModel.prefsRepo);

  // ── 总览 / 分派 ───────────────────────────────────────────────────────────

  Future<Object?> listAll() async => <String, Object?>{
    'asr': <String, Object?>{
      'supported': isAsrSupported,
      'packs': <Map<String, Object?>>[
        if (isAsrSupported)
          for (final AsrModelPack pack in listedAsrModelPacks())
            await _asrJson(pack),
      ],
    },
    'ocr': <String, Object?>{
      'supported': createMangaOcrService().isSupportedPlatform,
      'models': <Map<String, Object?>>[
        for (final MangaOcrLocalModel model in platformMangaOcrLocalModels())
          await _ocrJson(model),
      ],
    },
    'gptSovits': _gptSovitsJson(),
    'irodori': _irodoriJson(),
  };

  String _requireKind(String kind) {
    final String lower = kind.trim().toLowerCase();
    if (lower == 'gptsovits' || lower == 'gpt_sovits' || lower == 'tts') {
      return CtlModelKind.gptSovits;
    }
    if (lower == 'irodori-tts' || lower == 'irodori_tts') {
      return CtlModelKind.irodori;
    }
    if (!CtlModelKind.all.contains(lower)) {
      throw CtlFailure.notFound(
        '没有模型类别「$kind」；可选：${CtlModelKind.all.join(' | ')}',
      );
    }
    return lower;
  }

  Future<Object?> status(String kind, String id) async {
    switch (_requireKind(kind)) {
      case CtlModelKind.asr:
        return _asrJson(_requireAsrPack(id));
      case CtlModelKind.ocr:
        return _ocrJson(_requireOcrModel(id));
      case CtlModelKind.irodori:
        _requireLocalId(CtlModelKind.irodori, id);
        return _irodoriJson();
      default:
        _requireGptSovitsId(id);
        return _gptSovitsJson();
    }
  }

  Future<Object?> download(String kind, String id, CtlCall call) async {
    switch (_requireKind(kind)) {
      case CtlModelKind.asr:
        return _downloadAsr(_requireAsrPack(id));
      case CtlModelKind.ocr:
        return _downloadOcr(_requireOcrModel(id));
      case CtlModelKind.irodori:
        _requireLocalId(CtlModelKind.irodori, id);
        return _installIrodori(call);
      default:
        _requireGptSovitsId(id);
        return _installGptSovits(call);
    }
  }

  Future<Object?> cancel(String kind, String id) async {
    switch (_requireKind(kind)) {
      case CtlModelKind.asr:
        final AsrModelPack pack = _requireAsrPack(id);
        if (!_asrDownloads.isActive(pack.id)) {
          throw CtlFailure.conflict('${pack.displayName} 没有进行中的下载');
        }
        // 已落盘的 `.part` 留着，下次下载由下载器 Range 续上（与设置页同语义）。
        await _asrDownloads.cancel(pack.id);
        return _asrJson(pack);
      case CtlModelKind.ocr:
        final MangaOcrLocalModel model = _requireOcrModel(id);
        if (!_ocrDownloads.isActive(model)) {
          throw CtlFailure.conflict('${model.key} 没有进行中的下载');
        }
        await _ocrDownloads.cancel(model);
        return _ocrJson(model);
      case CtlModelKind.irodori:
        _requireLocalId(CtlModelKind.irodori, id);
        final IrodoriLocalEngine engine = _requireIrodoriSupported();
        if (!engine.installer.isBusy) {
          throw const CtlFailure.conflict('本机 Irodori-TTS 没有进行中的安装');
        }
        engine.installer.cancel();
        return _irodoriJson();
      default:
        _requireGptSovitsId(id);
        final GptSovitsLocalEngine engine = _requireGptSovitsSupported();
        if (!engine.installer.isBusy) {
          throw const CtlFailure.conflict('本机 GPT-SoVITS 没有进行中的安装');
        }
        engine.installer.cancel();
        return _gptSovitsJson();
    }
  }

  Future<Object?> link(String kind, String id, CtlCall call) async {
    if (_requireKind(kind) != CtlModelKind.gptSovits) {
      throw const CtlFailure.badRequest('只有 gpt-sovits 支持指向已有目录');
    }
    _requireGptSovitsId(id);
    final GptSovitsLocalEngine engine = _requireGptSovitsSupported();
    final String dir = call.requireString('dir');
    if (!p.isAbsolute(dir)) throw CtlFailure.badRequest('dir 必须是绝对路径：$dir');
    if (engine.installer.isBusy) {
      throw const CtlFailure.conflict('正在安装，先取消（models cancel gpt-sovits）');
    }
    if (!await engine.useExisting(dir)) {
      throw CtlFailure.rejected(
        '$dir 不是可用的 GPT-SoVITS 整合包（缺 runtime/python.exe 或 api_v2.py）',
      );
    }
    return _gptSovitsJson();
  }

  Future<Object?> delete(String kind, String id, CtlCall call) async {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('删除模型需要 confirm=true');
    }
    switch (_requireKind(kind)) {
      case CtlModelKind.asr:
        return _deleteAsr(_requireAsrPack(id));
      case CtlModelKind.ocr:
        final MangaOcrLocalModel model = _requireOcrModel(id);
        if (_ocrDownloads.isActive(model)) {
          throw CtlFailure.conflict('${model.key} 正在下载，先取消');
        }
        final int freed = await createMangaOcrService(
          localModel: model,
        ).deleteModels();
        return <String, Object?>{...await _ocrJson(model), 'freedBytes': freed};
      case CtlModelKind.irodori:
        _requireLocalId(CtlModelKind.irodori, id);
        final IrodoriLocalEngine engine = _requireIrodoriSupported();
        final bool deleteFiles = engine.canDeleteFiles;
        final String? dir = engine.settings.dir;
        await engine.remove(deleteFiles: deleteFiles);
        return <String, Object?>{
          ..._irodoriJson(),
          'removed': dir,
          'filesDeleted': deleteFiles,
        };
      default:
        _requireGptSovitsId(id);
        final GptSovitsLocalEngine engine = _requireGptSovitsSupported();
        // 与设置页同一判据：只有 app 装进专属子目录的才真删文件，用户自己的
        // 整合包只「移除」（忘掉路径）。
        final bool deleteFiles = engine.canDeleteFiles;
        final String? dir = engine.settings.dir;
        await engine.remove(deleteFiles: deleteFiles);
        return <String, Object?>{
          ..._gptSovitsJson(),
          'removed': dir,
          'filesDeleted': deleteFiles,
        };
    }
  }

  // ── ASR ──────────────────────────────────────────────────────────────────

  AsrModelPack _requireAsrPack(String id) {
    if (!isAsrSupported) {
      throw const CtlFailure.unsupported('本机没有可用的 ONNX Runtime，不能用语音转录');
    }
    final String needle = id.trim();
    final List<AsrModelPack> packs = listedAsrModelPacks();
    for (final AsrModelPack pack in packs) {
      if (pack.id == needle) return pack;
    }
    // 语言标签：先找以它为主语言的包，再找服务它的多语言包。
    final String lower = needle.toLowerCase();
    for (final AsrModelPack pack in packs) {
      if (pack.language.tag.toLowerCase() == lower) return pack;
    }
    for (final AsrModelPack pack in packs) {
      if (pack.languages.any((AsrLanguage l) => l.tag.toLowerCase() == lower)) {
        return pack;
      }
    }
    throw CtlFailure.notFound(
      '没有语音转录模型「$id」；可选：${packs.map((AsrModelPack p) => p.id).join(' | ')}',
    );
  }

  Future<AsrTranscribePlan> _planOf(AsrModelPack pack) =>
      _asrDownloads.planFor(_asr, pack);

  Future<Map<String, Object?>> _asrJson(AsrModelPack pack) async {
    final AsrModelDownloadProgress? progress = _asrDownloads.progressOf(
      pack.id,
    );
    final String? lastError = _asrDownloads.lastErrorOf(pack.id);
    final String? gpuError = _asrDownloads.lastGpuRuntimeErrorOf(pack.id);
    Map<String, Object?> status;
    try {
      final AsrTranscribePlan plan = await _planOf(pack);
      final AsrModelStatus s = plan.modelStatus;
      status = <String, Object?>{
        'ready': s.ready,
        'diskBytes': s.diskBytes,
        'totalBytes': s.totalBytes,
        'obtainedBytes': s.obtainedBytes,
        'variant': plan.variant.name,
        'provider': plan.expectedProvider.name,
        if (plan.probeError != null) 'probeError': plan.probeError,
      };
    } catch (e) {
      status = <String, Object?>{'error': '$e'};
    }
    return <String, Object?>{
      'kind': CtlModelKind.asr,
      'id': pack.id,
      'name': pack.displayName,
      'languages': <String>[for (final AsrLanguage l in pack.languages) l.tag],
      'linked': localAsrModelDirectory(pack) != null,
      ...status,
      if (progress != null)
        'download': <String, Object?>{
          'state': progress.cancelling ? 'cancelling' : 'downloading',
          'receivedBytes': progress.receivedBytes,
          'totalBytes': progress.totalBytes,
          'file': progress.currentFile,
        }
      else if (lastError != null)
        'download': <String, Object?>{'state': 'failed', 'error': lastError},
      if (gpuError != null) 'gpuRuntimeError': gpuError,
    };
  }

  Future<Object?> _downloadAsr(AsrModelPack pack) async {
    if (_asrDownloads.isActive(pack.id)) {
      throw CtlFailure.conflict(
        '${pack.displayName} 已在下载（models status asr ${pack.id}）',
      );
    }
    if (localAsrModelDirectory(pack) != null) {
      throw CtlFailure.rejected('${pack.displayName} 是手动接入的本地模型，不需要下载');
    }
    final AsrTranscribePlan plan = await _planOf(pack);
    if (plan.modelStatus.ready) {
      return <String, Object?>{...await _asrJson(pack), 'alreadyReady': true};
    }
    if (!_asrDownloads.start(pack, plan: plan)) {
      throw CtlFailure.conflict(
        '${pack.displayName} 已在下载（models status asr ${pack.id}）',
      );
    }
    return <String, Object?>{...await _asrJson(pack), 'started': true};
  }

  Future<Object?> _deleteAsr(AsrModelPack pack) async {
    if (_asrDownloads.isActive(pack.id)) {
      throw CtlFailure.conflict('${pack.displayName} 正在下载，先取消');
    }
    // 手动接入的本地模型：它的「模型目录」就是用户自己的文件夹，deleteAll 会把
    // 用户的文件真删掉。与设置页同一处理——只移除接入，文件一个不碰。
    if (localAsrModelDirectory(pack) != null) {
      await saveAsrModelCatalog(asrModelCatalog.withoutCustomPack(pack.id));
      return <String, Object?>{
        'kind': CtlModelKind.asr,
        'id': pack.id,
        'detached': true,
        'freedBytes': 0,
      };
    }
    final AsrModelStore store = await _asrDownloads.openPackStore(pack);
    final int freed = await store.deleteAll();
    return <String, Object?>{...await _asrJson(pack), 'freedBytes': freed};
  }

  // ── OCR ──────────────────────────────────────────────────────────────────

  MangaOcrModelDownloads get _ocrDownloads =>
      context.ref.read(mangaOcrModelDownloadsProvider);

  MangaOcrLocalModel _requireOcrModel(String id) {
    final String needle = id.trim().toLowerCase();
    final List<MangaOcrLocalModel> models = platformMangaOcrLocalModels();
    for (final MangaOcrLocalModel model in models) {
      if (model.key == needle ||
          model.name.toLowerCase() == needle ||
          (needle == 'default' && model == kDefaultMangaOcrLocalModel)) {
        if (!createMangaOcrService(localModel: model).isSupportedPlatform) {
          throw const CtlFailure.unsupported('本机没有可用的 ONNX Runtime，不能用本地 OCR');
        }
        return model;
      }
    }
    throw CtlFailure.notFound(
      '没有 OCR 模型「$id」；可选：${models.map((MangaOcrLocalModel m) => m.key).join(' | ')}',
    );
  }

  Future<Map<String, Object?>> _ocrJson(MangaOcrLocalModel model) async {
    final MangaOcrService service = createMangaOcrService(localModel: model);
    final MangaOcrModelDownloadProgress? progress = _ocrDownloads.progressOf(
      model,
    );
    Map<String, Object?> status;
    try {
      final MangaOcrModelStatus s = await service.modelStatus();
      status = <String, Object?>{
        'ready': s.allReady,
        'diskBytes': s.diskBytes,
        'totalBytes': s.totalBytes,
        'obtainedBytes': s.obtainedBytes,
      };
    } catch (e) {
      status = <String, Object?>{'error': '$e'};
    }
    return <String, Object?>{
      'kind': CtlModelKind.ocr,
      'id': model.key,
      'name': localModelLabel(model),
      ...status,
      if (progress != null)
        'download': <String, Object?>{
          'state': progress.cancelling ? 'cancelling' : 'downloading',
          'receivedBytes': progress.receivedBytes,
          'totalBytes': status['totalBytes'],
          'file': progress.currentFile,
        }
      else if (_ocrDownloads.lastErrorOf(model) case final String error)
        'download': <String, Object?>{'state': 'failed', 'error': error},
    };
  }

  Future<Object?> _downloadOcr(MangaOcrLocalModel model) async {
    final MangaOcrService service = createMangaOcrService(localModel: model);
    final MangaOcrModelStatus status = await service.modelStatus();
    if (status.allReady) {
      return <String, Object?>{...await _ocrJson(model), 'alreadyReady': true};
    }
    if (!_ocrDownloads.start(model, service)) {
      throw CtlFailure.conflict(
        '${model.key} 已在下载（models status ocr ${model.key}）',
      );
    }
    return <String, Object?>{...await _ocrJson(model), 'started': true};
  }

  // ── 本机 GPT-SoVITS ─────────────────────────────────────────────────────

  /// 手动启动本机服务（与部署页「启动」同一个 `engine.start`，同时解除自动拉起的
  /// 失败暂停）。服务起来或失败后才返回。
  Future<Object?> startServer(String kind, String id) async {
    final String resolved = _requireKind(kind);
    if (resolved == CtlModelKind.irodori) return _startIrodori(id);
    if (resolved != CtlModelKind.gptSovits) {
      throw const CtlFailure.badRequest('只有 gpt-sovits 有本机服务可起停');
    }
    _requireGptSovitsId(id);
    final GptSovitsLocalEngine engine = _requireGptSovitsSupported();
    if (!engine.isInstalled) {
      throw const CtlFailure.rejected(
        '本机 GPT-SoVITS 还没装（models download gpt-sovits 或 models link）',
      );
    }
    if (engine.installer.isBusy) {
      throw const CtlFailure.conflict('正在安装，装完再启动');
    }
    final bool ok = await engine.start();
    if (!ok) {
      throw CtlFailure(
        422,
        'start_failed',
        '服务没有起来（${engine.server.failure?.name ?? engine.server.phase.name}）；'
            '日志尾：${engine.server.logTail.reversed.take(20).toList().reversed.join(' | ')}',
      );
    }
    return _gptSovitsJson();
  }

  Future<Object?> stopServer(String kind, String id) async {
    final String resolved = _requireKind(kind);
    if (resolved == CtlModelKind.irodori) {
      _requireLocalId(CtlModelKind.irodori, id);
      await _requireIrodoriSupported().stop();
      return _irodoriJson();
    }
    if (resolved != CtlModelKind.gptSovits) {
      throw const CtlFailure.badRequest('只有 gpt-sovits 有本机服务可起停');
    }
    _requireGptSovitsId(id);
    await _requireGptSovitsSupported().stop();
    return _gptSovitsJson();
  }

  void _requireGptSovitsId(String id) {
    final String lower = id.trim().toLowerCase();
    if (lower != 'local' && lower != 'default') {
      throw CtlFailure.notFound('gpt-sovits 只有 local 一个（收到「$id」）');
    }
  }

  GptSovitsLocalEngine _requireGptSovitsSupported() {
    final GptSovitsLocalEngine engine = _tts.localGptSovits;
    if (!engine.isSupported) {
      throw const CtlFailure.unsupported('本机 GPT-SoVITS 整合包只有 Windows 版');
    }
    return engine;
  }

  Map<String, Object?> _gptSovitsJson() {
    if (!GptSovitsLocalEngine.platformSupported) {
      return <String, Object?>{
        'kind': CtlModelKind.gptSovits,
        'supported': false,
      };
    }
    final GptSovitsLocalEngine engine = _tts.localGptSovits;
    final GptSovitsLocalSettings settings = engine.settings;
    final GptSovitsInstaller installer = engine.installer;
    return <String, Object?>{
      'kind': CtlModelKind.gptSovits,
      'id': 'local',
      'supported': engine.isSupported,
      'ready': engine.isInstalled,
      'dir': settings.dir,
      'owned': settings.owned,
      'canDeleteFiles': engine.canDeleteFiles,
      'source': settings.source.name,
      'port': settings.port,
      'endpoint': engine.endpoint,
      'server': engine.server.phase.name,
      if (engine.server.failure != null)
        'serverFailure': engine.server.failure!.name,
      'download': <String, Object?>{
        'state': installer.step.name,
        'receivedBytes': installer.receivedBytes,
        'totalBytes': installer.totalBytes,
        'extractedEntries': installer.extractedEntries,
        if (installer.package != null) 'package': installer.package!.name,
        if (installer.failure != null) 'failure': installer.failure!.name,
        if (_gptSovitsLastError != null) 'error': _gptSovitsLastError,
      },
    };
  }

  Future<Object?> _installGptSovits(CtlCall call) async {
    final GptSovitsLocalEngine engine = _requireGptSovitsSupported();
    if (engine.installer.isBusy) {
      throw const CtlFailure.conflict('已在安装（models status gpt-sovits）');
    }
    final String? sourceRaw = call.optString('source');
    if (sourceRaw != null) {
      final GptSovitsPackageSource source = switch (sourceRaw.toLowerCase()) {
        'hf' || 'huggingface' => GptSovitsPackageSource.huggingFace,
        'ms' || 'modelscope' => GptSovitsPackageSource.modelScope,
        _ => throw CtlFailure.badRequest('--source 只能是 hf / ms，收到「$sourceRaw」'),
      };
      await engine.setSource(source);
    }
    final String? variantRaw = call.optString('variant');
    final GptSovitsPackageVariant variant = variantRaw == null
        // 与本机部署页同一默认：按 nvidia-smi 报的显卡挑变体。
        ? gptSovitsVariantForGpu(await detectNvidiaGpuName())
        : GptSovitsPackageVariant.values.firstWhere(
            (GptSovitsPackageVariant v) =>
                v.name.toLowerCase() == variantRaw.toLowerCase(),
            orElse: () => throw CtlFailure.badRequest(
              '--variant 只能是 '
              '${GptSovitsPackageVariant.values.map((GptSovitsPackageVariant v) => v.name).join(' / ')}',
            ),
          );
    final String? dirRaw = call.optString('dir');
    if (dirRaw != null && !p.isAbsolute(dirRaw)) {
      throw CtlFailure.badRequest('dir 必须是绝对路径：$dirRaw');
    }
    final String installDir =
        dirRaw ??
        GptSovitsLocalEngine.defaultInstallDir(
          await enginePaths.supportRootDirectory(),
        );
    _gptSovitsLastError = null;
    // 安装是十几 GB 的长任务：后台跑，进度 / 失败原因经 models status 查。
    unawaited(_runGptSovitsInstall(engine, installDir, variant));
    return <String, Object?>{
      ..._gptSovitsJson(),
      'started': true,
      'installDir': installDir,
      'variant': variant.name,
    };
  }

  Future<void> _runGptSovitsInstall(
    GptSovitsLocalEngine engine,
    String installDir,
    GptSovitsPackageVariant variant,
  ) async {
    try {
      final bool ok = await engine.install(
        installDir: installDir,
        variant: variant,
      );
      if (!ok && engine.installer.step == GptSovitsInstallStep.failed) {
        _gptSovitsLastError =
            engine.installer.detail ?? engine.installer.failure?.name;
      }
    } catch (error, stack) {
      ErrorLogService.instance.log('CtlModels.gptSovitsInstall', error, stack);
      _gptSovitsLastError = '$error';
    }
  }

  // ── 本机 Irodori-TTS ─────────────────────────────────────────────────────

  /// 本机 Irodori-TTS 最近一次 CLI 发起的安装结果。
  String? _irodoriLastError;

  void _requireLocalId(String kind, String id) {
    final String lower = id.trim().toLowerCase();
    if (lower != 'local' && lower != 'default') {
      throw CtlFailure.notFound('$kind 只有 local 一个（收到「$id」）');
    }
  }

  IrodoriLocalEngine _requireIrodoriSupported() {
    final IrodoriLocalEngine engine = _tts.localIrodori;
    if (!engine.isSupported) {
      throw const CtlFailure.unsupported(
        '本机 Irodori-TTS 只支持 64 位 Windows / Apple 芯片 Mac / 64 位 Linux',
      );
    }
    return engine;
  }

  Map<String, Object?> _irodoriJson() {
    if (!IrodoriLocalEngine.platformSupported) {
      return <String, Object?>{
        'kind': CtlModelKind.irodori,
        'supported': false,
      };
    }
    final IrodoriLocalEngine engine = _tts.localIrodori;
    final IrodoriLocalSettings settings = engine.settings;
    final IrodoriInstaller installer = engine.installer;
    return <String, Object?>{
      'kind': CtlModelKind.irodori,
      'id': 'local',
      'supported': engine.isSupported,
      'ready': engine.isInstalled,
      'environmentReady': engine.environmentReady,
      'dir': settings.dir,
      'canDeleteFiles': engine.canDeleteFiles,
      'source': settings.source.name,
      'model': settings.model.name,
      'backend': (settings.backend ?? engine.installedBackend)?.name,
      'port': settings.port,
      'endpoint': engine.endpoint,
      'server': engine.server.phase.name,
      if (engine.server.failure != null)
        'serverFailure': engine.server.failure!.name,
      'download': <String, Object?>{
        'state': installer.step.name,
        'receivedBytes': installer.receivedBytes,
        'totalBytes': installer.totalBytes,
        if (installer.currentItem != null) 'item': installer.currentItem,
        if (installer.failure != null) 'failure': installer.failure!.name,
        if (_irodoriLastError != null) 'error': _irodoriLastError,
        if (installer.logTail.isNotEmpty) 'lastLog': installer.logTail.last,
      },
    };
  }

  Future<Object?> _installIrodori(CtlCall call) async {
    final IrodoriLocalEngine engine = _requireIrodoriSupported();
    if (engine.installer.isBusy) {
      throw const CtlFailure.conflict('已在安装（models status irodori）');
    }
    final String? sourceRaw = call.optString('source');
    if (sourceRaw != null) {
      await engine.setSource(switch (sourceRaw.toLowerCase()) {
        'hf' || 'huggingface' => IrodoriDownloadSource.huggingFace,
        'hf-mirror' || 'mirror' => IrodoriDownloadSource.hfMirror,
        _ => throw CtlFailure.badRequest(
          '--source 只能是 hf / hf-mirror，收到「$sourceRaw」',
        ),
      });
    }
    final String? modelRaw = call.optString('model');
    if (modelRaw != null) {
      await engine.setModel(switch (modelRaw.toLowerCase()) {
        'small' || 'v4.1-small' => IrodoriModelChoice.small,
        'mf' ||
        'small-mf' ||
        'v4.1-small-mf' => IrodoriModelChoice.smallMeanFlow,
        _ => throw CtlFailure.badRequest(
          '--model 只能是 small / mf，收到「$modelRaw」',
        ),
      });
    }
    final String? backendRaw = call.optString('backend');
    final List<IrodoriTorchBackend> allowed = irodoriBackendsFor(
      isMacOS: Platform.isMacOS,
      isLinux: Platform.isLinux,
    );
    final IrodoriTorchBackend backend;
    if (backendRaw != null) {
      backend = allowed.firstWhere(
        (IrodoriTorchBackend b) => b.name == backendRaw.toLowerCase(),
        orElse: () => throw CtlFailure.badRequest(
          '--backend 只能是 '
          '${allowed.map((IrodoriTorchBackend b) => b.name).join(' / ')}',
        ),
      );
      await engine.setBackend(backend);
    } else {
      // 与部署页同一默认：设置里选过的 → 已装的 → 按显卡推荐。
      backend =
          engine.settings.backend ??
          engine.installedBackend ??
          irodoriBackendFor(
            nvidiaGpu: Platform.isMacOS ? null : await detectNvidiaGpuName(),
            isMacOS: Platform.isMacOS,
          );
    }
    final String? dirRaw = call.optString('dir');
    if (dirRaw != null && !p.isAbsolute(dirRaw)) {
      throw CtlFailure.badRequest('dir 必须是绝对路径：$dirRaw');
    }
    final String? recorded = engine.settings.dir;
    if (dirRaw != null && recorded != null) {
      throw const CtlFailure.conflict('已有安装，换位置先删除（models rm irodori）');
    }
    final String installDir =
        dirRaw ??
        (recorded != null
            ? p.dirname(recorded)
            : IrodoriLocalEngine.defaultInstallDir(
                await enginePaths.supportRootDirectory(),
              ));
    _irodoriLastError = null;
    // 安装是数 GB 的长任务：后台跑，进度 / 失败原因经 models status 查。
    unawaited(_runIrodoriInstall(engine, installDir, backend));
    return <String, Object?>{
      ..._irodoriJson(),
      'started': true,
      'installDir': installDir,
      'backend': backend.name,
    };
  }

  Future<void> _runIrodoriInstall(
    IrodoriLocalEngine engine,
    String installDir,
    IrodoriTorchBackend backend,
  ) async {
    try {
      final bool ok = await engine.install(
        installDir: installDir,
        backend: backend,
      );
      if (!ok && engine.installer.step == IrodoriInstallStep.failed) {
        _irodoriLastError =
            engine.installer.detail ?? engine.installer.failure?.name;
      }
    } catch (error, stack) {
      ErrorLogService.instance.log('CtlModels.irodoriInstall', error, stack);
      _irodoriLastError = '$error';
    }
  }

  Future<Object?> _startIrodori(String id) async {
    _requireLocalId(CtlModelKind.irodori, id);
    final IrodoriLocalEngine engine = _requireIrodoriSupported();
    if (!engine.isInstalled) {
      throw const CtlFailure.rejected(
        '本机 Irodori-TTS 还没装好（models download irodori）',
      );
    }
    if (engine.installer.isBusy) {
      throw const CtlFailure.conflict('正在安装，装完再启动');
    }
    final bool ok = await engine.start();
    if (!ok) {
      throw CtlFailure(
        422,
        'start_failed',
        '服务没有起来（${engine.server.failure?.name ?? engine.server.phase.name}）；'
            '日志尾：${engine.server.logTail.reversed.take(20).toList().reversed.join(' | ')}',
      );
    }
    return _irodoriJson();
  }

  // ── 朗读声音 ─────────────────────────────────────────────────────────────

  Map<String, Object?> voices() {
    final TtsPresetStore store = _tts.store;
    final String? activeId = store.activePreset()?.id;
    return <String, Object?>{
      'activeId': activeId,
      'speed': store.speed,
      'voices': <Map<String, Object?>>[
        for (final TtsVoicePreset preset in store.loadPresets())
          ctlTtsPresetJson(
            preset,
            active: preset.id == activeId,
            descriptor: _tts.registry[preset.providerId],
          ),
      ],
    };
  }

  /// 朗读语速（与朗读播放器倍速同一个 `TtsPresetStore.setSpeed`；范围与有声书
  /// 倍速滑条一致）。正在朗读的会话下次开始时读到新值。
  Future<Object?> setVoiceSpeed(CtlCall call) async {
    final String? raw = call.optString('speed');
    final double? speed = raw == null ? null : double.tryParse(raw);
    if (speed == null || !speed.isFinite) {
      throw const CtlFailure.badRequest('speed 必须是数字（如 1.25）');
    }
    if (speed < AudiobookSpeedSlider.minSpeed ||
        speed > AudiobookSpeedSlider.maxSpeed) {
      throw CtlFailure.badRequest(
        '语速范围 ${AudiobookSpeedSlider.minSpeed}–${AudiobookSpeedSlider.maxSpeed}，收到 $speed',
      );
    }
    await _tts.store.setSpeed(AudiobookSpeedSlider.snap(speed));
    return voices();
  }

  Map<String, Object?> engines() => <String, Object?>{
    'engines': <Map<String, Object?>>[
      for (final TtsProviderDescriptor d in _tts.registry.available)
        <String, Object?>{
          'id': d.id,
          'name': ttsProviderLabel(d.id),
          'category': d.category.name,
          'params': <Map<String, Object?>>[
            for (final TtsParamSpec spec in d.params)
              <String, Object?>{
                'key': spec.key,
                'kind': spec.kind.name,
                'required': spec.required,
                if (spec.defaultValue != null) 'default': spec.defaultValue,
                if (spec.choices.isNotEmpty) 'choices': spec.choices,
              },
          ],
        },
    ],
  };

  TtsProviderDescriptor _requireEngine(String id) {
    final TtsProviderDescriptor? descriptor = _tts.registry[id];
    if (descriptor == null || !descriptor.isAvailable) {
      throw CtlFailure.notFound(
        '没有可用的朗读引擎「$id」；可选：'
        '${_tts.registry.available.map((TtsProviderDescriptor d) => d.id).join(' | ')}',
      );
    }
    return descriptor;
  }

  /// body 的 `params`（明文）+ `secrets`（来源须是 stdin / env）合成一组参数。
  ({Map<String, String> values, Set<String> secretKeys}) _paramsOf(
    CtlCall call,
  ) {
    final Map<String, String> values = <String, String>{};
    final Object? params = call.body['params'];
    if (params is Map) {
      params.forEach(
        (Object? k, Object? v) => values['$k'] = v == null ? '' : '$v',
      );
    } else if (params != null) {
      throw const CtlFailure.badRequest('params 必须是对象');
    }
    final Set<String> secretKeys = <String>{};
    final Object? secrets = call.body['secrets'];
    if (secrets is Map && secrets.isNotEmpty) {
      final String source = call.optString('secretSource') ?? 'argv';
      if (source != 'stdin' && source != 'env') {
        throw const CtlFailure.badRequest(
          '凭据只能经 --secret-stdin 或 --secret-from-env 传入，不能写在命令行里',
        );
      }
      secrets.forEach((Object? k, Object? v) {
        values['$k'] = v == null ? '' : '$v';
        secretKeys.add('$k');
      });
    } else if (secrets != null && secrets is! Map) {
      throw const CtlFailure.badRequest('secrets 必须是对象');
    }
    return (values: values, secretKeys: secretKeys);
  }

  Map<String, Object?> _voiceResult(String action, String id) {
    final TtsPresetStore store = _tts.store;
    final TtsVoicePreset preset = resolveCtlTtsPreset(store.loadPresets(), id);
    return <String, Object?>{
      'action': action,
      'voice': ctlTtsPresetJson(
        preset,
        active: preset.id == store.activePresetId,
        descriptor: _tts.registry[preset.providerId],
      ),
    };
  }

  Future<Object?> addVoice(CtlCall call) async {
    final TtsProviderDescriptor descriptor = _requireEngine(
      call.requireString('engine'),
    );
    final ({Map<String, String> values, Set<String> secretKeys}) input =
        _paramsOf(call);
    // 与朗读声音页「添加声音」同一起点：随机 id、引擎名作默认名、引擎声明的默认参数。
    final TtsVoicePreset preset = applyCtlTtsParams(
      TtsVoicePreset(
        id: newTtsPresetId(),
        providerId: descriptor.id,
        name: call.optString('name') ?? ttsProviderLabel(descriptor.id),
        params: ttsDefaultParams(descriptor),
      ),
      descriptor,
      input.values,
      secretSources: input.secretKeys,
    );
    final TtsPresetStore store = _tts.store;
    await store.savePresets(<TtsVoicePreset>[...store.loadPresets(), preset]);
    if (store.activePresetId == null || call.optBool('use') == true) {
      await store.setActivePresetId(preset.id);
    }
    return _voiceResult('已添加', preset.id);
  }

  Future<Object?> updateVoice(String ref, CtlCall call) async {
    final TtsPresetStore store = _tts.store;
    final List<TtsVoicePreset> presets = store.loadPresets();
    final TtsVoicePreset target = resolveCtlTtsPreset(presets, ref);
    final TtsProviderDescriptor descriptor = _requireEngine(target.providerId);
    final ({Map<String, String> values, Set<String> secretKeys}) input =
        _paramsOf(call);
    TtsVoicePreset updated = applyCtlTtsParams(
      target,
      descriptor,
      input.values,
      secretSources: input.secretKeys,
    );
    final String? name = call.optString('name');
    if (name != null) updated = updated.copyWith(name: name);
    // 「重新生成」：版本号进缓存键，旧缓存自然失效（与编辑页同一语义）。
    if (call.optBool('regenerate') == true) {
      updated = updated.copyWith(revision: updated.revision + 1);
    }
    await store.savePresets(<TtsVoicePreset>[
      for (final TtsVoicePreset preset in presets)
        preset.id == target.id ? updated : preset,
    ]);
    return _voiceResult('已更新', target.id);
  }

  Future<Object?> activateVoice(String ref) async {
    final TtsPresetStore store = _tts.store;
    final TtsVoicePreset target = resolveCtlTtsPreset(store.loadPresets(), ref);
    await store.setActivePresetId(target.id);
    return _voiceResult('已设为默认', target.id);
  }

  Future<Object?> deleteVoice(String ref, CtlCall call) async {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('删除声音需要 confirm=true');
    }
    final TtsPresetStore store = _tts.store;
    final List<TtsVoicePreset> presets = store.loadPresets();
    final TtsVoicePreset target = resolveCtlTtsPreset(presets, ref);
    final ({List<TtsVoicePreset> presets, String? activeId}) next =
        ttsPresetsAfterDelete(presets, store.activePresetId, target.id);
    await store.savePresets(next.presets);
    await store.setActivePresetId(next.activeId);
    await deleteOrphanedTtsReferenceAudio(target, next.presets);
    return <String, Object?>{
      'deleted': <String, Object?>{'id': target.id, 'name': target.name},
      'activeId': next.activeId,
    };
  }

  /// 引擎能列出的音色（Edge / 系统语音等；GPT-SoVITS 这类没有音色表的返回空）。
  Future<Object?> listProviderVoices(String ref) async {
    final TtsVoicePreset preset = resolveCtlTtsPreset(
      _tts.store.loadPresets(),
      ref,
    );
    final TtsProviderDescriptor descriptor = _requireEngine(preset.providerId);
    final TtsProvider provider = descriptor.create(preset, _tts.host);
    try {
      final List<TtsVoice> list = await provider.listVoices();
      return <String, Object?>{
        'voice': preset.id,
        'engine': descriptor.id,
        'voices': <Map<String, Object?>>[
          for (final TtsVoice v in list)
            <String, Object?>{
              'id': v.id,
              'name': v.displayName,
              'locale': v.locale,
              if (v.gender != null) 'gender': v.gender,
            },
        ],
      };
    } on SocketException catch (e) {
      throw CtlFailure.rejected('连不上朗读服务：${e.message}');
    } finally {
      await provider.dispose();
    }
  }
}
