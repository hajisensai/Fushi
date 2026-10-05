import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_page.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/utils.dart';

/// OCR 导入漫画向导：选**裸图片文件夹**（无 `.mokuro`）→ 校验 → 选引擎（内置 ONNX /
/// 外部 mokuro CLI）→ 跑整卷 OCR（逐页进度 + 取消）→ 产物无缝落库 → 成功返回
/// 新建 `EpubBooks.bookKey`（`format='manga'`，第三种书，复用整套书架/进度/删除管线）。
///
/// 服务与外部 runner 均经**构造参数注入**（不 `ref.read` provider），故本文件与并行编写
/// 的 `manga_ocr_service_impl.dart` 解耦——widget 测试注 fake 即可独立编译/通过。
/// `ConsumerStatefulWidget` 仅为在「选文件夹」时读 [appProvider] 走真实路径目录选择器。
class MangaOcrWizardDialog extends ConsumerStatefulWidget {
  const MangaOcrWizardDialog({
    required this.engines,
    required this.db,
    this.lensDisclosureGate,
    this.importOverride,
    this.initialImageDir,
    this.existingBook,
    this.startPage = 0,
    this.onlyMissing = true,
    this.launchInBackground = false,
    this.resolveEngines,
    super.key,
  });

  /// 四个引擎的 runner + 默认引擎偏好，**整套必填**。
  ///
  /// 拆成一个对象而不是四个可选参数，是因为「某个入口漏传某个 runner」编译期
  /// 无痕、运行期只表现为选项少一个（BUG-1418）。生产装配一律走
  /// [MangaOcrWizardEngines.resolve]。
  final MangaOcrWizardEngines engines;

  /// 目标数据库（漫画行写入此处；导入器读取须为同一实例）。
  final FushiDatabase db;

  final GoogleLensDisclosureGate? lensDisclosureGate;

  /// 落库注入口（测试用）：null = 走真实 [MangaImporter]。
  final MangaOcrImportRunner? importOverride;

  /// 预选图片目录（测试用，跳过真实目录选择器）。
  final String? initialImageDir;

  /// 已导入的漫画。非 null 时直接对这本书做整卷 OCR，不创建重复书籍。
  final EpubBookRow? existingBook;

  /// 阅读器触发时优先从当前 0-based 页开始，扫到末页后再补首页。
  final int startPage;

  /// 仅补齐无 OCR 块的页面并复用逐页缓存。
  final bool onlyMissing;

  /// 已导入漫画由阅读器持有任务时，选好引擎后立即关闭向导并返回后台任务。
  final bool launchInBackground;

  /// 从「OCR 设置」页返回后重新装配引擎依赖集。[engines] 是打开向导时的快照
  /// （外部 mokuro 路径 / 引擎偏好都在 `resolve()` 里读了一次），用户在设置页里
  /// 刚配好的路径不重新装配就探不到。null（测试直连 engines）= 只重探不重装。
  final MangaOcrWizardEngines Function(BuildContext context)? resolveEngines;

  @override
  ConsumerState<MangaOcrWizardDialog> createState() =>
      _MangaOcrWizardDialogState();
}

/// 落库回调签名：把 OCR 产物（内置=`manga.json` / 外部=`.mokuro`）落库，返回 bookKey。
typedef MangaOcrImportRunner = Future<String> Function({
  required String path,
  required bool external,
  String? title,
});

/// 向导所处阶段。
enum _WizardStage { pick, configure, running, importing }

class _MangaOcrWizardDialogState extends ConsumerState<MangaOcrWizardDialog> {
  final TextEditingController _titleCtrl = TextEditingController();

  _WizardStage _stage = _WizardStage.pick;

  /// 当前引擎依赖集；初值是 [MangaOcrWizardDialog.engines]，从设置页返回后可被
  /// [MangaOcrWizardDialog.resolveEngines] 换成新装配。
  late MangaOcrWizardEngines _engines = widget.engines;

  /// Lens 识别语言（主子标签）。初值来自偏好；仅 Lens 引擎显示选择器。
  late String _lensLanguage =
      normalizeLensLanguage(_engines.initialLensLanguage);
  String? _imageDir;
  MangaOcrFolderStatus? _folderStatus;

  bool _builtinAvailable = false;

  /// 本机能跑本地 ONNX（不论模型下没下）。向导提供模型选择时，本地段只看这个：
  /// 没下的模型要能先选中、再在向导里下，而不是整段置灰让人去设置页找。
  bool _builtinSupported = false;

  /// 本机模型的后台下载登记表（与设置页 / 存储页同一份）。
  MangaOcrModelDownloads? _downloads;
  bool _modelWasDownloading = false;
  bool _externalAvailable = false;
  bool _remoteAvailable = false;

  /// 探到了已配对主机，但它明确报模型未下载：选项保留、置灰、下方说明原因。
  bool _remoteModelsMissing = false;
  bool _lensAvailable = false;
  bool _systemAvailable = false;
  MangaOcrRemoteTarget? _remoteTarget;
  bool _checkingEngines = false;
  MangaOcrEngineId _engine = MangaOcrEngineId.localOnnx;

  // 进度。
  bool _indeterminate = true;

  /// 远程引擎的两阶段展示：true = 正在上传页面，false = 远端识别中。
  bool _remoteUploading = false;
  int _pagesDone = 0;
  int _pagesTotal = 0;
  String? _error;
  String? _createdBookKey;
  String? _managedImageDir;

  StreamSubscription<Object>? _runSub;

  /// 向导是否提供本机模型选择（生产装配都提供；测试直连 engines 时不提供）。
  bool get _offersModelChoice =>
      _engines.localModel != null && _engines.modelServiceFor != null;

  @override
  void initState() {
    super.initState();
    if (_offersModelChoice) {
      _downloads = ref.read(mangaOcrModelDownloadsProvider);
      _modelWasDownloading = _modelDownloading;
      _downloads!.addListener(_onModelDownloadsChanged);
    }
    final EpubBookRow? existingBook = widget.existingBook;
    if (existingBook != null) {
      _imageDir = existingBook.extractDir;
      _managedImageDir = existingBook.extractDir;
      _createdBookKey = existingBook.bookKey;
      _titleCtrl.text = existingBook.title;
      _folderStatus = checkOcrFolder(existingBook.extractDir);
      _stage = _folderStatus == MangaOcrFolderStatus.valid
          ? _WizardStage.configure
          : _WizardStage.pick;
      if (_folderStatus == MangaOcrFolderStatus.valid) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_refreshEngines());
        });
      }
      return;
    }
    final String? initial = widget.initialImageDir;
    if (initial != null) {
      _imageDir = initial;
      _folderStatus = checkOcrFolder(initial);
      _stage = _folderStatus == MangaOcrFolderStatus.valid
          ? _WizardStage.configure
          : _WizardStage.pick;
      if (_folderStatus == MangaOcrFolderStatus.valid) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_refreshEngines());
        });
      }
    }
  }

  bool get _modelDownloading {
    final MangaOcrLocalModel? model = _engines.localModel;
    return model != null && (_downloads?.isActive(model) ?? false);
  }

  /// 模型下完（或失败 / 取消）后重探：下好了本地引擎就能开跑。下载本身归全局
  /// 登记表，关掉向导照跑。
  void _onModelDownloadsChanged() {
    if (!mounted) return;
    final bool downloading = _modelDownloading;
    final bool finished = _modelWasDownloading && !downloading;
    _modelWasDownloading = downloading;
    setState(() {});
    if (finished) unawaited(_refreshEngines(keepEngine: true));
  }

  Future<void> _selectLocalModel(MangaOcrLocalModel model) async {
    if (model == _engines.localModel) return;
    await _engines.localModelSetter?.call(model.key);
    if (!mounted) return;
    setState(() {
      _engines = _engines.withLocalModel(model);
      _modelWasDownloading = _modelDownloading;
    });
    await _refreshEngines(keepEngine: true);
  }

  void _downloadLocalModel() {
    final MangaOcrLocalModel? model = _engines.localModel;
    if (model == null) return;
    _downloads?.start(model, _engines.service);
  }

  @override
  void dispose() {
    _downloads?.removeListener(_onModelDownloadsChanged);
    _runSub?.cancel();
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final AppModel appModel = ref.read(appProvider);
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel: appModel,
    );
    if (dir == null || !mounted) return;
    final MangaOcrFolderStatus status = checkOcrFolder(dir);
    setState(() {
      _imageDir = dir;
      _folderStatus = status;
      _error = null;
      _stage = status == MangaOcrFolderStatus.valid
          ? _WizardStage.configure
          : _WizardStage.pick;
    });
    if (status == MangaOcrFolderStatus.valid) {
      await _refreshEngines();
    }
  }

  /// 探测各引擎的可用性（内置模型 / 系统 OCR / 外部 mokuro / 配对主机），据此
  /// 决定默认引擎与可选项。系统 OCR 必须在这一次探测里：auto 的默认引擎要看它，
  /// 单独异步探测的话，没下本地模型的 Apple 设备打开向导永远默认不到 Vision。
  Future<void> _refreshEngines({bool keepEngine = false}) async {
    if (!mounted) return;
    setState(() => _checkingEngines = true);
    // 探测与能力表在 `manga_ocr_engine_probe.dart`：下载完成钩子的自动 OCR 读的是
    // 同一份判据，向导这里只剩「把结果摆进状态」。
    final MangaOcrEngineAvailability availability =
        await probeMangaOcrEngines(_engines);
    if (!mounted) return;
    setState(() {
      _builtinAvailable = availability.builtinReady;
      _builtinSupported = availability.builtinSupported;
      _externalAvailable = availability.externalReady;
      _remoteAvailable = availability.remoteUsable;
      _remoteModelsMissing = availability.remoteModelsMissing;
      _remoteTarget = availability.remoteTarget;
      _lensAvailable = availability.lensOffered;
      _systemAvailable = availability.systemOcrReady;
      _checkingEngines = false;
      // 用户在向导里换了模型 / 下完模型后的重探：保留用户选的引擎段。
      if (keepEngine) return;
      final String preferenceKey = _engines.initialEnginePreference ??
          MangaOcrEnginePreference.auto.key;
      final MangaOcrEnginePreference preference =
          MangaOcrEnginePreferenceKey.fromKey(preferenceKey);
      _engine = resolveMangaOcrEngine(
            preference: preference,
            hasExistingMetadata: false,
            capabilities: availability.capabilities,
          ) ??
          preference.explicitEngine ??
          MangaOcrEngineId.localOnnx;
    });
  }

  /// 构造本次任务的输入。编排本身在 `manga_ocr_job_stream.dart`——对话框只负责
  /// 「选参数」，跑任务的能力不该被绑在一个 widget 的 State 上。
  MangaOcrJobSpec _jobSpec(String dir, {MangaOcrPageFocus? focus}) =>
      MangaOcrJobSpec(
        engine: _engine,
        engines: _engines,
        imageDirPath: dir,
        lensLanguage: _lensLanguage,
        startPage: widget.startPage,
        onlyMissing: widget.onlyMissing,
        volumeTitle: _title,
        remoteTarget: _remoteTarget,
        focus: focus,
      );


  bool get _selectedEngineAvailable {
    switch (_engine) {
      case MangaOcrEngineId.localOnnx:
        return _builtinAvailable;
      case MangaOcrEngineId.systemOcr:
        return _systemAvailable;
      case MangaOcrEngineId.googleLens:
        return _lensAvailable;
      case MangaOcrEngineId.externalMokuro:
        return _externalAvailable;
      case MangaOcrEngineId.pairedHost:
        return _remoteAvailable;
    }
  }

  bool get _canRun =>
      _stage == _WizardStage.configure &&
      _folderStatus == MangaOcrFolderStatus.valid &&
      _selectedEngineAvailable;

  String? get _title {
    final String t = _titleCtrl.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _run() async {
    if (!_canRun) return;
    if (_engine == MangaOcrEngineId.googleLens) {
      final GoogleLensDisclosureGate gate =
          widget.lensDisclosureGate ?? ensureGoogleLensDisclosure;
      if (!await gate(context) || !mounted) {
        return;
      }
    }
    String dir = _imageDir!;
    if (widget.importOverride == null) {
      try {
        dir = await _ensureReadableImport();
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _stage = _WizardStage.configure;
          _error = '${t.manga_ocr_wizard_failed}: $error';
        });
        return;
      }
    }
    if (!mounted) return;
    if (widget.launchInBackground) {
      final String? bookKey = _createdBookKey;
      if (bookKey == null) {
        setState(() => _error = t.manga_ocr_wizard_failed);
        return;
      }
      // 后台任务可能被阅读器接回：给它一条改道通道，读者翻页时跟着读者走。
      final MangaOcrPageFocus focus = MangaOcrPageFocus();
      final MangaOcrJobSpec spec = _jobSpec(dir, focus: focus);
      Navigator.pop(
        context,
        MangaOcrBackgroundJob(
          bookKey: bookKey,
          managedDirectory: dir,
          engine: _engine,
          events: mangaOcrBackgroundEvents(spec),
          focus: focus,
          follower: mangaOcrJobFollower(spec),
        ),
      );
      return;
    }
    setState(() {
      _stage = _WizardStage.running;
      _error = null;
      _indeterminate = true;
      _remoteUploading = false;
      _pagesDone = 0;
      _pagesTotal = 0;
    });
    switch (_engine) {
      case MangaOcrEngineId.localOnnx:
        _runBuiltin(dir);
      case MangaOcrEngineId.systemOcr:
        _runSystem(dir);
      case MangaOcrEngineId.googleLens:
        _runLens(dir);
      case MangaOcrEngineId.externalMokuro:
        _runExternal(dir);
      case MangaOcrEngineId.pairedHost:
        _runRemote(dir);
    }
  }

  Future<String> _ensureReadableImport() async {
    final String? existing = _managedImageDir;
    if (existing != null) return existing;
    setState(() {
      _stage = _WizardStage.importing;
      _error = null;
    });
    final String bookKey = await MangaImporter.importFromImageFolder(
      db: widget.db,
      imageDirPath: _imageDir!,
      title: _title,
    );
    final EpubBookRow? row = await widget.db.getEpubBook(bookKey);
    if (row == null) {
      throw StateError('Imported manga row was not found');
    }
    _createdBookKey = bookKey;
    _managedImageDir = row.extractDir;
    return row.extractDir;
  }

  Future<void> _importWithoutOcr() async {
    if (_folderStatus != MangaOcrFolderStatus.valid) return;
    final NavigatorState navigator = Navigator.of(context);
    try {
      await _ensureReadableImport();
      if (!mounted) return;
      navigator.pop(_createdBookKey);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _WizardStage.configure;
        _error = '${t.manga_ocr_wizard_failed}: $error';
      });
    }
  }

  void _runSystem(String dir) {
    _runSub = _engines.systemOcrRunner!
        .ocrFolder(
      imageDirPath: dir,
      volumeTitle: _title,
      startPage: widget.startPage,
      onlyMissing: widget.onlyMissing,
      language: _lensLanguage,
    )
        .listen(
      (MangaOcrVolumeEvent event) {
        if (!mounted) return;
        if (event.finished) {
          unawaited(_onOcrFinished(event.mangaJsonPath!, external: false));
        } else {
          setState(() {
            _indeterminate = event.pagesTotal <= 0;
            _pagesDone = event.pagesDone;
            _pagesTotal = event.pagesTotal;
          });
        }
      },
      onError: (Object error) => _onOcrError(error),
    );
  }

  void _runLens(String dir) {
    _runSub = _engines.lensRunner!
        .ocrFolder(
      imageDirPath: dir,
      volumeTitle: _title,
      startPage: widget.startPage,
      onlyMissing: widget.onlyMissing,
      language: _lensLanguage,
    )
        .listen(
      (MangaOcrVolumeEvent event) {
        if (!mounted) return;
        if (event.finished) {
          unawaited(_onOcrFinished(event.mangaJsonPath!, external: false));
        } else {
          setState(() {
            _indeterminate = event.pagesTotal <= 0;
            _pagesDone = event.pagesDone;
            _pagesTotal = event.pagesTotal;
          });
        }
      },
      onError: (Object error) => _onOcrError(error),
    );
  }

  void _runBuiltin(String dir) {
    _runSub = _engines.service
        .ocrFolder(
          imageDirPath: dir,
          volumeTitle: _title,
          startPage: widget.startPage,
        )
        .listen(
      (MangaOcrVolumeEvent event) {
        if (!mounted) return;
        if (event.finished) {
          unawaited(_onOcrFinished(event.mangaJsonPath!, external: false));
        } else {
          setState(() {
            _indeterminate = event.pagesTotal <= 0;
            _pagesDone = event.pagesDone;
            _pagesTotal = event.pagesTotal;
          });
        }
      },
      onError: (Object e) => _onOcrError(e),
    );
  }

  void _runExternal(String dir) {
    _runSub = _engines.externalRunner!.run(dir).listen(
      (MokuroRunEvent event) {
        if (!mounted) return;
        if (event.finished) {
          unawaited(_onOcrFinished(event.mokuroPath!, external: true));
        } else if (event.isRunning) {
          setState(() => _indeterminate = true);
        } else {
          setState(() {
            _indeterminate = event.total <= 0;
            _pagesDone = event.done;
            _pagesTotal = event.total;
          });
        }
      },
      onError: (Object e) => _onOcrError(_mokuroErrorMessage(e)),
    );
  }

  /// 漫画 P3：已配对主机代跑。上传/远端两阶段进度分别展示；完成事件携带的
  /// manga.json 已由 client 写到 `<所选文件夹>/manga_ocr_out/manga.json`，与内置
  /// 引擎产物同布局，落库走同一条 `importFromMangaJson` 路径。
  void _runRemote(String dir) {
    final MangaOcrRemoteTarget? target = _remoteTarget;
    if (target == null) {
      _onOcrError(t.manga_remote_ocr_no_host);
      return;
    }
    _runSub = _engines.remoteRunner!
        .run(target: target, imageDirPath: dir, volumeTitle: _title)
        .listen(
      (MangaOcrRemoteEvent event) {
        if (!mounted) return;
        if (event.finished) {
          unawaited(_onOcrFinished(event.mangaJsonPath!, external: false));
        } else {
          setState(() {
            _remoteUploading = event.uploading;
            _indeterminate = event.total <= 0;
            _pagesDone = event.done;
            _pagesTotal = event.total;
          });
        }
      },
      onError: (Object e) => _onOcrError(_remoteErrorMessage(e)),
    );
  }

  /// 外部 mokuro 失败 → 本地化文案；原始异常（含启动失败的底层原因）进日志。
  ///
  /// 2026-10 体验优化：runner 原先抛写死的中文句子。
  String _mokuroErrorMessage(Object e) {
    ErrorLogService.instance.log('MangaOcrWizard.externalMokuro', e);
    if (e is! MokuroRunnerException) return '$e';
    return switch (e.code) {
      MokuroRunnerErrorCode.notFound => t.manga_ocr_mokuro_not_found,
      MokuroRunnerErrorCode.timeout => t.manga_ocr_mokuro_timeout,
      MokuroRunnerErrorCode.launchFailed => t.manga_ocr_mokuro_launch_failed,
      MokuroRunnerErrorCode.nonZeroExit =>
        t.manga_ocr_mokuro_exit_code(code: e.exitCode ?? '?'),
      MokuroRunnerErrorCode.noOutput => t.manga_ocr_mokuro_no_output,
    };
  }

  /// 远程失败 → 本地化可读文案（机器可读 code 映射；未知归入通用失败 + 详情）。
  String _remoteErrorMessage(Object e) {
    if (e is MangaOcrRemoteException) {
      switch (e.code) {
        case 'models_not_ready':
          return t.manga_remote_ocr_not_ready;
        case 'not_supported':
          return t.manga_remote_ocr_unsupported;
        case 'no_host':
        case 'auth':
          return t.manga_remote_ocr_no_host;
        case 'cancelled':
          return t.manga_remote_ocr_cancelled;
        case 'no_pages':
          return t.manga_ocr_wizard_no_images;
        default:
          // _onOcrError 已统一加 manga_ocr_wizard_failed 前缀，这里只给原因。
          final String? detail = e.detail;
          return detail == null || detail.isEmpty
              ? t.manga_remote_ocr_failed
              : detail;
      }
    }
    return '$e';
  }

  Future<void> _onOcrFinished(String path, {required bool external}) async {
    // 从 onData 回调里 cancel 自身订阅：不 await（await 会在部分实现下卡住微任务，
    // 拖住后续落库），流本就在收尾，fire-and-forget 即可。
    unawaited(_runSub?.cancel());
    _runSub = null;
    if (!mounted) return;
    setState(() => _stage = _WizardStage.importing);
    try {
      final String? createdBookKey = _createdBookKey;
      if (createdBookKey != null) {
        await _applyOcrToManagedBook(path, external: external);
        if (!mounted) return;
        // 书已在库，这条路径只把 OCR 结果贴回去，没有导入动作 —— 用 OCR 文案。
        FushiToast.show(
          msg: t.manga_ocr_done,
          severity: ToastSeverity.success,
        );
        Navigator.pop(context, createdBookKey);
        return;
      }
      final MangaOcrImportRunner runner =
          widget.importOverride ?? _defaultImport;
      final String bookKey =
          await runner(path: path, external: external, title: _title);
      if (!mounted) return;
      FushiToast.show(
        msg: t.manga_ocr_wizard_done,
        severity: ToastSeverity.success,
      );
      Navigator.pop(context, bookKey);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _WizardStage.configure;
        _error = '${t.manga_ocr_wizard_failed}: $e';
      });
    }
  }

  Future<void> _applyOcrToManagedBook(
    String resultPath, {
    required bool external,
  }) async {
    final String? managedDir = _managedImageDir;
    if (managedDir == null) {
      throw StateError('Managed manga directory is missing');
    }
    final String source = await File(resultPath).readAsString();
    final MokuroPayload payload =
        external ? parseMokuro(source) : parseMangaJson(source);
    if (payload.images.isEmpty) {
      throw const MangaImportException('OCR result has no pages');
    }
    // 整份覆写：不进 per-path 写锁就会整段吞掉在线几何回填刚落盘的改动
    // （两者写的是同一个 `<书目录>/manga.json`）。
    final String target = p.join(managedDir, MangaStorage.kMangaJsonFileName);
    await runExclusiveOnMangaJson<void>(
      target,
      () => writeMangaJsonAtomically(target, payload),
    );
  }

  void _onOcrError(Object e) {
    if (!mounted) return;
    setState(() {
      _stage = _WizardStage.configure;
      _error = '${t.manga_ocr_wizard_failed}: $e';
    });
  }

  /// 默认落库：内置/远程产物是 `manga.json`（[MangaImporter.importFromMangaJson]，
  /// 页 `url` 相对所选图片文件夹而非 `manga_ocr_out/`，须显式传 imageRootPath），
  /// 外部产物是 `.mokuro`（[MangaImporter.importFromMokuroPath]）。
  Future<String> _defaultImport({
    required String path,
    required bool external,
    String? title,
  }) {
    if (external) {
      return MangaImporter.importFromMokuroPath(
        db: widget.db,
        mokuroPath: path,
        title: title,
      );
    }
    return MangaImporter.importFromMangaJson(
      db: widget.db,
      mangaJsonPath: path,
      imageRootPath: _managedImageDir ?? _imageDir,
      title: title,
    );
  }

  void _cancelRun() {
    // fire-and-forget 取消（cancel 会请求中止底层 OCR）；UI 立即回到 configure，
    // 不 await 取消完成（await 会在部分流实现下卡住微任务、拖住状态回退）。
    unawaited(_runSub?.cancel());
    _runSub = null;
    setState(() {
      _stage = _WizardStage.configure;
      _indeterminate = true;
      _remoteUploading = false;
      _pagesDone = 0;
      _pagesTotal = 0;
    });
  }

  /// running/importing 阶段的状态行文案（远程引擎的上传/远端两阶段单列）。
  String _busyLabel() {
    if (_stage == _WizardStage.importing) return t.manga_ocr_wizard_importing;
    if (_engine == MangaOcrEngineId.pairedHost) {
      if (_remoteUploading && _pagesTotal > 0) {
        return t.manga_remote_ocr_uploading(
            done: _pagesDone, total: _pagesTotal);
      }
      return _pagesTotal > 0
          ? t.manga_ocr_wizard_page_progress(
              done: _pagesDone, total: _pagesTotal)
          : t.manga_remote_ocr_running;
    }
    return _pagesTotal > 0
        ? t.manga_ocr_wizard_page_progress(done: _pagesDone, total: _pagesTotal)
        : t.manga_ocr_wizard_running;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool busy =
        _stage == _WizardStage.running || _stage == _WizardStage.importing;
    // 外框走统一 ImportDialogFrame（审计 §1-K：与书/有声书/视频导入同一 chrome）；
    // 向导内容与阶段化动作按钮不变。
    return ImportDialogFrame(
      leadingIcon: Icons.document_scanner_outlined,
      // 已入库的书是「识别」不是「导入」：阅读器的「重新识别本卷」和作品页的
      // 识别入口都走这里，标题再叫「OCR 导入漫画」就是在说另一件事。
      title: widget.existingBook != null
          ? t.manga_ocr_wizard_title_book
          : t.manga_ocr_wizard_title,
      body: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _folderRow(busy),
            if (_folderStatus == MangaOcrFolderStatus.noImages)
              _errorText(theme, t.manga_ocr_wizard_no_images),
            if (_folderStatus == MangaOcrFolderStatus.hasMokuro)
              _errorText(theme, t.manga_ocr_wizard_has_mokuro),
            // 已入库且每页都有 OCR（mokuro.moe 下载的卷天生如此）：说清「不需要」，
            // 而不是让用户对着一个禁用的按钮猜。
            if (_folderStatus == MangaOcrFolderStatus.alreadyOcred)
              _errorText(theme, t.manga_ocr_wizard_already_ocred),
            if (_folderStatus == MangaOcrFolderStatus.valid) ...<Widget>[
              const SizedBox(height: 12),
              _engineSelector(busy),
              if (_engine == MangaOcrEngineId.localOnnx &&
                  _offersModelChoice &&
                  _builtinSupported &&
                  !_checkingEngines) ...<Widget>[
                const SizedBox(height: 12),
                _localModelSelector(theme, busy),
              ],
              if (_engine == MangaOcrEngineId.googleLens &&
                  _lensAvailable) ...<Widget>[
                const SizedBox(height: 12),
                _lensLanguageSelector(busy),
              ],
              const SizedBox(height: 12),
              FushiTextFieldControl(
                controller: _titleCtrl,
                enabled: !busy && widget.existingBook == null,
                decoration: InputDecoration(
                  labelText: t.manga_ocr_wizard_title_label,
                  isDense: true,
                ),
              ),
            ],
            if (_error != null) _errorText(theme, _error!),
            if (busy) ...<Widget>[
              const SizedBox(height: 16),
              FushiLinearProgressIndicator(
                value: _indeterminate || _pagesTotal <= 0
                    ? null
                    : (_pagesDone / _pagesTotal).clamp(0.0, 1.0),
              ),
              const SizedBox(height: 8),
              Text(
                _busyLabel(),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: _buildActions(busy),
    );
  }

  Widget _folderRow(bool busy) {
    if (widget.existingBook != null) {
      return FushiListItem(
        padding: EdgeInsets.zero,
        leading: const FushiIcon(Icons.menu_book_outlined),
        title: Text(widget.existingBook!.title),
        subtitle: Text(p.basename(widget.existingBook!.extractDir)),
      );
    }
    return FushiOutlinedButton.icon(
      onPressed: busy ? null : _pickFolder,
      icon: const FushiIcon(Icons.folder_open_outlined),
      label: Text(
        _imageDir == null
            ? t.manga_ocr_wizard_pick_folder
            : p.basename(_imageDir!),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _engineSelector(bool busy) {
    if (_checkingEngines) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: FushiLinearProgressIndicator(),
      );
    }
    final ThemeData theme = Theme.of(context);
    // 主机模型未下载：在选项层就说清原因，而不是让用户传完整卷才在 start 阶段
    // 撞 models_not_ready（TODO-2635）。与 §_folderStatus 的说明式提示同款纪律。
    final Widget? remoteReason = _remoteModelsMissing
        ? _errorText(theme, t.manga_remote_ocr_not_ready)
        : null;
    final bool localSelectable = _offersModelChoice
        ? _builtinSupported
        : _builtinAvailable;
    if (!localSelectable &&
        !_systemAvailable &&
        !_lensAvailable &&
        !_externalAvailable &&
        !_remoteAvailable) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _errorText(theme, t.manga_ocr_engine_none),
          if (remoteReason != null) remoteReason,
        ],
      );
    }
    final List<ButtonSegment<MangaOcrEngineId>> segments =
        <ButtonSegment<MangaOcrEngineId>>[
      ButtonSegment<MangaOcrEngineId>(
        value: MangaOcrEngineId.localOnnx,
        enabled: localSelectable,
        label: Text(t.manga_ocr_engine_local_onnx),
      ),
      // 系统 OCR 排在本地模型之后、Lens 之前：它离线且零下载，但识别竖排
      // 气泡明显更弱，不该抢在真正好用的引擎前面。
      ButtonSegment<MangaOcrEngineId>(
        value: MangaOcrEngineId.systemOcr,
        enabled: _systemAvailable,
        label: Text(t.manga_ocr_engine_system),
      ),
      ButtonSegment<MangaOcrEngineId>(
        value: MangaOcrEngineId.googleLens,
        enabled: _lensAvailable,
        label: Text(t.manga_ocr_engine_google_lens),
      ),
      ButtonSegment<MangaOcrEngineId>(
        value: MangaOcrEngineId.externalMokuro,
        enabled: _externalAvailable,
        label: Text(t.manga_ocr_engine_external),
      ),
      // 与另外三个引擎同构：始终保留 segment，不可用时置灰而非隐藏。否则持久化的
      // pairedHost 偏好在主机暂时离线时会变成「selected 不在 segments 里」的死状态。
      ButtonSegment<MangaOcrEngineId>(
        value: MangaOcrEngineId.pairedHost,
        enabled: _remoteAvailable,
        label: Text(t.manga_remote_ocr_engine),
      ),
    ];
    // 只有一个可用引擎时无需选择器，直接省略（仍已在 _refreshEngines 选好）。
    if (segments.length < 2) return remoteReason ?? const SizedBox.shrink();
    final Widget selector = Align(
      alignment: Alignment.centerLeft,
      child: FushiSegmentedButton<MangaOcrEngineId>(
        showSelectedIcon: false,
        segments: segments,
        selected: <MangaOcrEngineId>{_engine},
        onSelectionChanged: busy
            ? null
            : (Set<MangaOcrEngineId> s) => setState(() => _engine = s.first),
      ),
    );
    if (remoteReason == null) return selector;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[selector, remoteReason],
    );
  }

  /// 本机模型下拉 + 所选模型未下载时的下载入口。
  ///
  /// 下拉里不逐个标「已下载」：那要对每个模型递归统计目录，每开一次向导白扫几百
  /// MB 到 GB 级的模型文件。选中后下面的状态行就说清楚了。
  ///
  /// 换模型写回全局模型偏好（与设置页引擎下拉同一份）；逐页缓存按模型签名分
  /// 目录，换模型重跑一定真正重算。
  Widget _localModelSelector(ThemeData theme, bool busy) {
    final MangaOcrLocalModel selected = _engines.localModel!;
    final MangaOcrModelDownloadProgress? progress =
        _downloads?.progressOf(selected);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiDropdownButtonFormField<MangaOcrLocalModel>(
          key: const ValueKey<String>('manga_ocr_wizard_local_model'),
          initialValue: selected,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t.manga_ocr_local_model,
            isDense: true,
          ),
          items: <DropdownMenuItem<MangaOcrLocalModel>>[
            for (final MangaOcrLocalModel model
                in platformMangaOcrLocalModels())
              DropdownMenuItem<MangaOcrLocalModel>(
                value: model,
                child: Text(
                  localModelLabel(model),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: busy
              ? null
              : (MangaOcrLocalModel? model) {
                  if (model != null) unawaited(_selectLocalModel(model));
                },
        ),
        if (progress != null) ...<Widget>[
          const SizedBox(height: 8),
          FushiLinearProgressIndicator(
            key: const ValueKey<String>('manga_ocr_wizard_model_progress'),
          ),
          const SizedBox(height: 4),
          Text(
            t.manga_ocr_download_background_hint,
            style: theme.textTheme.bodySmall,
          ),
        ] else if (!_builtinAvailable) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.manga_ocr_model_status_missing,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('manga_ocr_wizard_model_download'),
                onPressed: busy ? null : _downloadLocalModel,
                icon: const FushiIcon(Icons.download_outlined, size: 18),
                label: Text(t.manga_ocr_download),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Lens 识别语言下拉。选项存主子标签，显示语言自称名（无需翻译）。
  Widget _lensLanguageSelector(bool busy) {
    final List<DropdownMenuItem<String>> items = <DropdownMenuItem<String>>[
      for (final (String tag, String label) in kGoogleLensLanguageOptions)
        DropdownMenuItem<String>(value: tag, child: Text(label)),
      // 偏好里存了列表外的语言（未来扩充/手改）时保留原值，避免选中项失效。
      if (!kGoogleLensLanguageOptions
          .any(((String, String) option) => option.$1 == _lensLanguage))
        DropdownMenuItem<String>(
          value: _lensLanguage,
          child: Text(_lensLanguage),
        ),
    ];
    return FushiDropdownButtonFormField<String>(
      initialValue: _lensLanguage,
      items: items,
      onChanged: busy
          ? null
          : (String? value) {
              if (value == null) return;
              setState(() => _lensLanguage = value);
              _engines.lensLanguageSetter?.call(value);
            },
      decoration: InputDecoration(
        labelText: t.manga_ocr_lens_language_label,
        isDense: true,
      ),
    );
  }

  Widget _errorText(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        message,
        style: TextStyle(color: theme.colorScheme.error),
      ),
    );
  }

  Future<void> _openOcrSettings() async {
    await MangaOcrSettingsPage.push(context);
    if (!mounted) return;
    final MangaOcrWizardEngines Function(BuildContext)? resolve =
        widget.resolveEngines;
    if (resolve != null) _engines = resolve(context);
    await _refreshEngines();
  }

  List<Widget> _buildActions(bool busy) {
    if (_stage == _WizardStage.running) {
      return <Widget>[
        FushiTextButton(
          onPressed: _cancelRun,
          child: Text(t.dialog_cancel),
        ),
      ];
    }
    return <Widget>[
      // 引擎不可用 / 想换引擎：直达「漫画 OCR」设置，返回后重探——刚下完的模型、
      // 刚配好的 mokuro 路径立刻能选，不必关掉向导重开。
      FushiTextButton.icon(
        key: const ValueKey<String>('manga_ocr_wizard_settings'),
        onPressed: busy ? null : () => unawaited(_openOcrSettings()),
        icon: const FushiIcon(Icons.tune_outlined, size: 18),
        label: Text(t.manga_ocr_settings_open),
      ),
      FushiTextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(t.dialog_cancel),
      ),
      if (widget.existingBook == null)
        FushiOutlinedButton(
          onPressed: _folderStatus == MangaOcrFolderStatus.valid && !busy
              ? () => unawaited(_importWithoutOcr())
              : null,
          child: Text(t.manga_import_direct),
        ),
      FushiFilledButton(
        onPressed: _canRun && !busy ? () => unawaited(_run()) : null,
        child: Text(t.manga_ocr_wizard_run),
      ),
    ];
  }
}

/// 图片文件夹 / 已入库书目录的校验结果。
enum MangaOcrFolderStatus {
  /// 有图、无 `.mokuro`——可 OCR。已入库的书则是「至少一页还没有 OCR 块」。
  valid,

  /// 无任何图片。
  noImages,

  /// 已有 `.mokuro`——应走普通导入而非 OCR。
  hasMokuro,

  /// 已入库的书每一页都已有 OCR 块——没有可补的页，再跑只会用较差的引擎结果
  /// 覆盖掉现成数据（mokuro.moe 下载的卷天生如此：站点已给 `.mokuro`）。
  alreadyOcred,

  /// 目录不存在。
  notFound,
}

/// 纯校验：目录须存在、含图片、且**不含** `.mokuro`（有则提示直接普通导入）。
/// 无平台通道、无 async，便于单测与即时禁用 Run 按钮。
///
/// 两种输入分开判：
/// - **已入库书目录**（含 `manga.json`，即 `EpubBooks.extractDir`）：真相是
///   `manga.json` 的页表，不是目录里躺着什么文件。页图落在 `images/<destRel>`，
///   而 destRel 保留源子目录结构，深度不固定；按文件扫描去猜「有没有图 / 有没有
///   OCR」既够不着深层页图，也认不出已存在的 OCR（书里的 OCR 数据在 manga.json
///   里，不叫 `.mokuro`）。mokuro.moe 下载的卷正是两条都踩：能正常阅读的书被判成
///   「此文件夹中没有找到图片」。
/// - **裸图片文件夹**（用户自选）：仍按文件扫描，只是改用与 OCR 引擎同一个枚举器
///   [enumerateMangaPages]，避免「向导说有图、引擎说没页」这类两套规则漂移。
MangaOcrFolderStatus checkOcrFolder(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) return MangaOcrFolderStatus.notFound;

  final File mangaJson = File(p.join(dirPath, MangaStorage.kMangaJsonFileName));
  if (mangaJson.existsSync()) return _checkImportedBookDir(mangaJson);

  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync();
  } catch (_) {
    return MangaOcrFolderStatus.notFound;
  }
  for (final FileSystemEntity entity in entries) {
    if (entity is File && p.extension(entity.path).toLowerCase() == '.mokuro') {
      return MangaOcrFolderStatus.hasMokuro;
    }
  }
  return enumerateMangaPages(dir).isEmpty
      ? MangaOcrFolderStatus.noImages
      : MangaOcrFolderStatus.valid;
}

/// 已入库书目录的判定：页数与 OCR 完成度都以 `manga.json` 为准。
///
/// 每页都有 OCR 块 → [MangaOcrFolderStatus.alreadyOcred]（无可补的页）；有页缺块
/// → [MangaOcrFolderStatus.valid]（可补齐）。manga.json 读不动时退回文件扫描——
/// 「元数据坏了」不等于「没有图片」。
MangaOcrFolderStatus _checkImportedBookDir(File mangaJson) {
  final MokuroPayload payload;
  try {
    payload = parseMangaJson(mangaJson.readAsStringSync());
  } catch (_) {
    return enumerateMangaPages(mangaJson.parent).isEmpty
        ? MangaOcrFolderStatus.noImages
        : MangaOcrFolderStatus.valid;
  }
  if (payload.images.isEmpty) return MangaOcrFolderStatus.noImages;
  final bool everyPageOcred =
      payload.images.every((MokuroImage page) => page.blocks.isNotEmpty);
  return everyPageOcred
      ? MangaOcrFolderStatus.alreadyOcred
      : MangaOcrFolderStatus.valid;
}
