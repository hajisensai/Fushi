import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/import/import_dialog_frame.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart';
import 'package:hibiki/src/media/manga/external_mokuro_runner.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
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
  MangaOcrRemoteTarget? _remoteTarget;
  bool _checkingEngines = false;
  MangaOcrEngine _engine = MangaOcrEngine.builtin;

  // 进度。
  bool _indeterminate = true;

  /// 远程引擎的两阶段展示：true = 正在上传页面，false = 远端识别中。
  bool _remoteUploading = false;
  int _pagesDone = 0;
  int _pagesTotal = 0;
  String? _error;

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
      _checkingEngines = false;
      // 默认引擎：内置就绪优先内置，其次外部，最后已配对主机。
      if (builtin) {
        _engine = MangaOcrEngine.builtin;
      } else if (external) {
        _engine = MangaOcrEngine.external;
      } else if (remote != null) {
        _engine = MangaOcrEngine.remote;
      }
    });
  }

  bool get _canRun =>
      _stage == _WizardStage.configure &&
      _folderStatus == MangaOcrFolderStatus.valid &&
      (_builtinAvailable || _externalAvailable || _remoteAvailable);

  String? get _title {
    final String t = _titleCtrl.text.trim();
    return t.isEmpty ? null : t;
  }

  void _run() {
    if (!_canRun) return;
    final String dir = _imageDir!;
    setState(() {
      _stage = _WizardStage.running;
      _error = null;
      _indeterminate = true;
      _remoteUploading = false;
      _pagesDone = 0;
      _pagesTotal = 0;
    });
    switch (_engine) {
      case MangaOcrEngine.builtin:
        _runBuiltin(dir);
      case MangaOcrEngine.external:
        _runExternal(dir);
      case MangaOcrEngine.remote:
        _runRemote(dir);
    }
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
      imageRootPath: _imageDir,
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
    if (_engine == MangaOcrEngine.remote) {
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
      title: t.manga_ocr_wizard_title,
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
    if (!_builtinAvailable && !_externalAvailable && !_remoteAvailable) {
      return _errorText(Theme.of(context), t.manga_ocr_engine_none);
    }
    final List<ButtonSegment<MangaOcrEngine>> segments =
        <ButtonSegment<MangaOcrEngine>>[
      if (_builtinAvailable)
        ButtonSegment<MangaOcrEngine>(
          value: MangaOcrEngine.builtin,
          label: Text(t.manga_ocr_engine_builtin),
        ),
      if (_externalAvailable)
        ButtonSegment<MangaOcrEngine>(
          value: MangaOcrEngine.external,
          label: Text(t.manga_ocr_engine_external),
        ),
      if (_remoteAvailable)
        ButtonSegment<MangaOcrEngine>(
          value: MangaOcrEngine.remote,
          label: Text(t.manga_remote_ocr_engine),
        ),
    ];
    // 只有一个可用引擎时无需选择器，直接省略（仍已在 _refreshEngines 选好）。
    if (segments.length < 2) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<MangaOcrEngine>(
        showSelectedIcon: false,
        segments: segments,
        selected: <MangaOcrEngine>{_engine},
        onSelectionChanged: busy
            ? null
            : (Set<MangaOcrEngine> s) => setState(() => _engine = s.first),
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
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(t.dialog_cancel),
      ),
      FilledButton(
        onPressed: _canRun && !busy ? _run : null,
        child: Text(t.manga_ocr_wizard_run),
      ),
    ];
  }
}

/// OCR 引擎选择。remote = 漫画 P3 已配对主机代跑（互联）。
enum MangaOcrEngine { builtin, external, remote }

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
