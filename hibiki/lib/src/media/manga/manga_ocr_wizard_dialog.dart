import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart';
import 'package:hibiki/src/media/manga/external_mokuro_runner.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
import 'package:hibiki/src/media/manga/manga_storage.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:hibiki/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/sync/interconnect_manga_ocr_client.dart';
import 'package:hibiki/utils.dart';

/// OCR 导入漫画向导：选**裸图片文件夹**（无 `.mokuro`）→ 校验 → 选引擎（内置 ONNX /
/// 外部 mokuro CLI）→ 跑整卷 OCR（逐页进度 + 取消）→ 产物无缝落库 → 成功返回
/// 新建 `EpubBooks.bookKey`（`format='manga'`，第三种书，复用整套书架/进度/删除管线）。
///
/// 服务与外部 runner 均经**构造参数注入**（不 `ref.read` provider），故本文件与并行编写
/// 的 `manga_ocr_service_impl.dart` 解耦——widget 测试注 fake 即可独立编译/通过。
/// `ConsumerStatefulWidget` 仅为在「选文件夹」时读 [appProvider] 走真实路径目录选择器。
class MangaOcrWizardDialog extends ConsumerStatefulWidget {
  const MangaOcrWizardDialog({
    required this.service,
    required this.db,
    this.externalRunner,
    this.remoteRunner,
    this.lensRunner,
    this.lensDisclosureGate,
    this.initialEnginePreference,
    this.importOverride,
    this.initialImageDir,
    super.key,
  });

  /// 内置 OCR 服务（接口；真实现由 provider 注入，测试注 fake）。
  final MangaOcrService service;

  /// 目标数据库（漫画行写入此处；导入器读取须为同一实例）。
  final HibikiDatabase db;

  /// 外部 mokuro CLI 后备；null = 不提供外部引擎选项。
  final ExternalMokuroRunner? externalRunner;

  /// 漫画 P3：互联「已配对主机代跑 OCR」；null = 不提供远程引擎选项。仅当探测
  /// （probe）到具备 `mangaOcr.supported` 能力的已配对 host 时选项才显示。
  final MangaOcrRemoteRunner? remoteRunner;

  /// Google Lens whole-page runner. Null keeps Lens absent in isolated tests.
  final GoogleLensMangaOcrRunner? lensRunner;

  final GoogleLensDisclosureGate? lensDisclosureGate;

  /// Optional stable preference key for tests/callers; production reads AppModel.
  final String? initialEnginePreference;

  /// 落库注入口（测试用）：null = 走真实 [MangaImporter]。
  final MangaOcrImportRunner? importOverride;

  /// 预选图片目录（测试用，跳过真实目录选择器）。
  final String? initialImageDir;

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
  String? _imageDir;
  MangaOcrFolderStatus? _folderStatus;

  bool _builtinAvailable = false;
  bool _externalAvailable = false;
  bool _remoteAvailable = false;
  bool _lensAvailable = false;
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

  @override
  void initState() {
    super.initState();
    final String? initial = widget.initialImageDir;
    if (initial != null) {
      _imageDir = initial;
      _folderStatus = checkOcrFolder(initial);
      _stage = _folderStatus == MangaOcrFolderStatus.valid
          ? _WizardStage.configure
          : _WizardStage.pick;
      if (_folderStatus == MangaOcrFolderStatus.valid) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refreshEngines());
      }
    }
  }

  @override
  void dispose() {
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

  /// 探测两个引擎的可用性（内置模型是否就绪 / 外部 mokuro 是否探测到），据此
  /// 决定默认引擎与可选项。
  Future<void> _refreshEngines() async {
    if (!mounted) return;
    setState(() => _checkingEngines = true);
    bool builtin = false;
    if (widget.service.isSupportedPlatform) {
      try {
        final MangaOcrModelStatus status = await widget.service.modelStatus();
        builtin = status.allReady;
      } catch (_) {
        builtin = false;
      }
    }
    bool external = false;
    if (widget.externalRunner != null) {
      try {
        external = (await widget.externalRunner!.probe()) != null;
      } catch (_) {
        external = false;
      }
    }
    // 漫画 P3：探测已配对 host 的远程 OCR 能力（老 host 无 capabilities 字段 →
    // probe 回 null → 选项隐藏，零破坏）。
    MangaOcrRemoteTarget? remote;
    if (widget.remoteRunner != null) {
      try {
        remote = await widget.remoteRunner!.probe();
      } catch (_) {
        remote = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _builtinAvailable = builtin;
      _externalAvailable = external;
      _remoteAvailable = remote != null;
      _remoteTarget = remote;
      _lensAvailable = widget.lensRunner != null;
      _checkingEngines = false;
      final String preferenceKey =
          widget.initialEnginePreference ?? MangaOcrEnginePreference.auto.key;
      final MangaOcrEnginePreference preference =
          MangaOcrEnginePreferenceKey.fromKey(preferenceKey);
      _engine = resolveMangaOcrEngine(
            preference: preference,
            hasExistingMetadata: false,
            capabilities: <MangaOcrEngineCapability>[
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.localOnnx,
                supported: widget.service.isSupportedPlatform,
                ready: builtin,
                requiresNetwork: false,
                uploadsImages: false,
                supportsIncremental: true,
              ),
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.googleLens,
                supported: widget.lensRunner != null,
                ready: widget.lensRunner != null,
                requiresNetwork: true,
                uploadsImages: true,
                supportsIncremental: true,
              ),
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.externalMokuro,
                supported: widget.externalRunner != null,
                ready: external,
                requiresNetwork: false,
                uploadsImages: false,
                supportsIncremental: false,
              ),
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.pairedHost,
                supported: widget.remoteRunner != null,
                ready: remote != null,
                requiresNetwork: true,
                uploadsImages: true,
                supportsIncremental: true,
              ),
            ],
          ) ??
          preference.explicitEngine ??
          MangaOcrEngineId.localOnnx;
    });
  }

  bool get _selectedEngineAvailable {
    switch (_engine) {
      case MangaOcrEngineId.localOnnx:
        return _builtinAvailable;
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

  void _runLens(String dir) {
    _runSub = widget.lensRunner!
        .ocrFolder(imageDirPath: dir, volumeTitle: _title)
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
    _runSub =
        widget.service.ocrFolder(imageDirPath: dir, volumeTitle: _title).listen(
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
    _runSub = widget.externalRunner!.run(dir).listen(
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
      onError: (Object e) => _onOcrError(e),
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
    _runSub = widget.remoteRunner!
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
        HibikiToast.show(msg: t.manga_ocr_wizard_done);
        Navigator.pop(context, createdBookKey);
        return;
      }
      final MangaOcrImportRunner runner =
          widget.importOverride ?? _defaultImport;
      final String bookKey =
          await runner(path: path, external: external, title: _title);
      if (!mounted) return;
      HibikiToast.show(msg: t.manga_ocr_wizard_done);
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
    final File target =
        File(p.join(managedDir, MangaStorage.kMangaJsonFileName));
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(mangaPayloadToJson(payload)),
      flush: true,
    );
    if (target.existsSync()) {
      await target.delete();
    }
    await temporary.rename(target.path);
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
    return AlertDialog(
      title: Text(t.manga_ocr_wizard_title),
      content: SizedBox(
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
            if (_folderStatus == MangaOcrFolderStatus.valid) ...<Widget>[
              const SizedBox(height: 12),
              _engineSelector(busy),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtrl,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: t.manga_ocr_wizard_title_label,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            if (_error != null) _errorText(theme, _error!),
            if (busy) ...<Widget>[
              const SizedBox(height: 16),
              LinearProgressIndicator(
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
    return OutlinedButton.icon(
      onPressed: busy ? null : _pickFolder,
      icon: const Icon(Icons.folder_open_outlined),
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
        child: LinearProgressIndicator(),
      );
    }
    if (!_builtinAvailable &&
        !_lensAvailable &&
        !_externalAvailable &&
        !_remoteAvailable) {
      return _errorText(Theme.of(context), t.manga_ocr_engine_none);
    }
    final List<ButtonSegment<MangaOcrEngineId>> segments =
        <ButtonSegment<MangaOcrEngineId>>[
      ButtonSegment<MangaOcrEngineId>(
        value: MangaOcrEngineId.localOnnx,
        enabled: _builtinAvailable,
        label: Text(t.manga_ocr_engine_local_onnx),
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
      if (_remoteAvailable)
        ButtonSegment<MangaOcrEngineId>(
          value: MangaOcrEngineId.pairedHost,
          label: Text(t.manga_remote_ocr_engine),
        ),
    ];
    // 只有一个可用引擎时无需选择器，直接省略（仍已在 _refreshEngines 选好）。
    if (segments.length < 2) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<MangaOcrEngineId>(
        showSelectedIcon: false,
        segments: segments,
        selected: <MangaOcrEngineId>{_engine},
        onSelectionChanged: busy
            ? null
            : (Set<MangaOcrEngineId> s) => setState(() => _engine = s.first),
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

  List<Widget> _buildActions(bool busy) {
    if (_stage == _WizardStage.running) {
      return <Widget>[
        TextButton(
          onPressed: _cancelRun,
          child: Text(t.dialog_cancel),
        ),
      ];
    }
    return <Widget>[
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, _createdBookKey),
        child: Text(t.dialog_cancel),
      ),
      OutlinedButton(
        onPressed: _folderStatus == MangaOcrFolderStatus.valid && !busy
            ? () => unawaited(_importWithoutOcr())
            : null,
        child: Text(t.manga_import_direct),
      ),
      FilledButton(
        onPressed: _canRun && !busy ? () => unawaited(_run()) : null,
        child: Text(t.manga_ocr_wizard_run),
      ),
    ];
  }
}

/// 裸图片文件夹校验结果。
enum MangaOcrFolderStatus {
  /// 有图、无 `.mokuro`——可 OCR。
  valid,

  /// 无任何图片。
  noImages,

  /// 已有 `.mokuro`——应走普通导入而非 OCR。
  hasMokuro,

  /// 目录不存在。
  notFound,
}

/// 纯校验：目录须存在、含图片（一层深）、且**不含** `.mokuro`（有则提示直接普通导入）。
/// 无平台通道、无 async，便于单测与即时禁用 Run 按钮。
MangaOcrFolderStatus checkOcrFolder(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) return MangaOcrFolderStatus.notFound;
  bool hasImage = false;
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync();
  } catch (_) {
    return MangaOcrFolderStatus.notFound;
  }
  for (final FileSystemEntity entity in entries) {
    if (entity is File) {
      final String ext = p.extension(entity.path).toLowerCase();
      if (ext == '.mokuro') return MangaOcrFolderStatus.hasMokuro;
      if (kMangaImageExtensions.contains(ext)) hasImage = true;
    } else if (entity is Directory) {
      try {
        for (final FileSystemEntity sub in entity.listSync()) {
          if (sub is File &&
              kMangaImageExtensions
                  .contains(p.extension(sub.path).toLowerCase())) {
            hasImage = true;
            break;
          }
        }
      } catch (_) {
        // 无权限/瞬时 IO：跳过该子目录。
      }
    }
  }
  return hasImage ? MangaOcrFolderStatus.valid : MangaOcrFolderStatus.noImages;
}
