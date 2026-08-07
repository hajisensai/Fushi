import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_model_fingerprint.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/ocr_types.dart';
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
    super.key,
  });

  /// 四个引擎的 runner + 默认引擎偏好，**整套必填**。
  ///
  /// 拆成一个对象而不是四个可选参数，是因为「某个入口漏传某个 runner」编译期
  /// 无痕、运行期只表现为选项少一个（BUG-1418）。生产装配一律走
  /// [MangaOcrWizardEngines.resolve]。
  final MangaOcrWizardEngines engines;

  /// 目标数据库（漫画行写入此处；导入器读取须为同一实例）。
  final HibikiDatabase db;

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

  /// 探到了已配对主机，但它明确报模型未下载：选项保留、置灰、下方说明原因。
  bool _remoteModelsMissing = false;
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
        WidgetsBinding.instance.addPostFrameCallback((_) => _refreshEngines());
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
    if (widget.engines.service.isSupportedPlatform) {
      try {
        final MangaOcrModelStatus status =
            await widget.engines.service.modelStatus();
        builtin = status.allReady;
      } catch (_) {
        builtin = false;
      }
    }
    bool external = false;
    if (widget.engines.externalRunner != null) {
      try {
        external = (await widget.engines.externalRunner!.probe()) != null;
      } catch (_) {
        external = false;
      }
    }
    // 漫画 P3：探测已配对 host 的远程 OCR 能力（老 host 无 capabilities 字段 →
    // probe 回 null → 选项隐藏，零破坏）。host 报了「支持但模型未下载」时 probe
    // 仍返回 target，UI 据此置灰 + 说明原因（TODO-2635）。
    MangaOcrRemoteTarget? remote;
    if (widget.engines.remoteRunner != null) {
      try {
        remote = await widget.engines.remoteRunner!.probe();
      } catch (_) {
        remote = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _builtinAvailable = builtin;
      _externalAvailable = external;
      _remoteAvailable = remote?.capability.usable ?? false;
      _remoteModelsMissing = remote?.capability.modelsMissing ?? false;
      _remoteTarget = remote;
      _lensAvailable = widget.engines.lensRunner != null;
      _checkingEngines = false;
      final String preferenceKey = widget.engines.initialEnginePreference ??
          MangaOcrEnginePreference.auto.key;
      final MangaOcrEnginePreference preference =
          MangaOcrEnginePreferenceKey.fromKey(preferenceKey);
      _engine = resolveMangaOcrEngine(
            preference: preference,
            hasExistingMetadata: false,
            capabilities: <MangaOcrEngineCapability>[
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.localOnnx,
                supported: widget.engines.service.isSupportedPlatform,
                ready: builtin,
                requiresNetwork: false,
                uploadsImages: false,
                supportsIncremental: true,
              ),
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.googleLens,
                supported: widget.engines.lensRunner != null,
                ready: widget.engines.lensRunner != null,
                requiresNetwork: true,
                uploadsImages: true,
                supportsIncremental: true,
              ),
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.externalMokuro,
                supported: widget.engines.externalRunner != null,
                ready: external,
                requiresNetwork: false,
                uploadsImages: false,
                supportsIncremental: false,
              ),
              MangaOcrEngineCapability(
                id: MangaOcrEngineId.pairedHost,
                supported: widget.engines.remoteRunner != null,
                // 模型没下载的 host 不算 ready，auto 解析不得落到它上面。
                ready: remote?.capability.usable ?? false,
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

  Stream<MangaOcrBackgroundEvent> _backgroundEvents(String dir) {
    switch (_engine) {
      case MangaOcrEngineId.localOnnx:
        return _backgroundLocalEvents(dir);
      case MangaOcrEngineId.googleLens:
        return _backgroundLensEvents(dir);
      case MangaOcrEngineId.externalMokuro:
        return _backgroundExternalEvents(dir);
      case MangaOcrEngineId.pairedHost:
        return _backgroundRemoteEvents(dir);
    }
  }

  Stream<MangaOcrBackgroundEvent> _backgroundLocalEvents(String dir) async* {
    final List<MangaOcrPageFile> pages = enumerateMangaPages(Directory(dir));
    // 「整卷已缓存 → 直接产出、跳过 OCR」的探测必须与真实任务用同一个签名，
    // 否则换模型后会拿旧模型的缓存冒充新结果（BUG-1173）。
    final String engineSignature =
        await resolveInstalledLocalMangaOcrEngineSignature();
    final MangaOcrFilePageCache cache = MangaOcrFilePageCache(
      cacheDir: Directory(p.join(
        dir,
        kMangaOcrOutDirName,
        kMangaOcrPagesCacheDirName,
        engineSignature,
      )),
      pageNames: <String>[
        for (final MangaOcrPageFile page in pages) page.relativeUrl
      ],
      pageFiles: <File>[for (final MangaOcrPageFile page in pages) page.file],
    );
    final List<OcrPageResult> cachedResults = <OcrPageResult>[];
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final OcrPageResult? cached = await cache.read('manga_ocr', pageIndex);
      if (cached == null) {
        cachedResults.clear();
        break;
      }
      cachedResults.add(cached);
    }
    if (cachedResults.length == pages.length && pages.isNotEmpty) {
      final MokuroPayload generated =
          buildMangaPayloadFromResults(pages, cachedResults);
      final MokuroPayload payload = MokuroPayload(
        images: generated.images,
        ocr: MangaOcrMetadata(
          engine: 'local_onnx',
          engineSignature: engineSignature,
          schemaVersion: 1,
        ),
      );
      final String output = await _writeCachedOutput(dir, payload);
      for (int pageIndex = 0; pageIndex < payload.images.length; pageIndex++) {
        yield MangaOcrBackgroundEvent.progress(
          pagesDone: pageIndex + 1,
          pagesTotal: pages.length,
          pageIndex: pageIndex,
          page: payload.images[pageIndex],
        );
      }
      yield MangaOcrBackgroundEvent.finished(
        pagesTotal: pages.length,
        resultPath: output,
        external: false,
      );
      return;
    }
    await for (final MangaOcrVolumeEvent event in widget.engines.service
        .ocrFolder(imageDirPath: dir, volumeTitle: _title)) {
      if (event.finished) {
        yield MangaOcrBackgroundEvent.finished(
          pagesTotal: event.pagesTotal,
          resultPath: event.mangaJsonPath!,
          external: false,
          acceleration: event.acceleration,
        );
        continue;
      }
      final int pageIndex = event.pagesDone - 1;
      MokuroImage? page;
      if (pageIndex >= 0 && pageIndex < pages.length) {
        final result = await cache.read('manga_ocr', pageIndex);
        if (result != null) {
          page = buildMangaPayloadFromResults(
            <MangaOcrPageFile>[pages[pageIndex]],
            <OcrPageResult>[result],
          ).images.single;
        }
      }
      yield MangaOcrBackgroundEvent.progress(
        pagesDone: event.pagesDone,
        pagesTotal: event.pagesTotal,
        pageIndex: pageIndex,
        page: page,
        acceleration: event.acceleration,
      );
    }
  }

  Stream<MangaOcrBackgroundEvent> _backgroundLensEvents(String dir) async* {
    final List<MangaOcrPageFile> pages = enumerateMangaPages(Directory(dir));
    final int start =
        pages.isEmpty ? 0 : widget.startPage.clamp(0, pages.length - 1);
    final List<int> order = <int>[
      for (int index = start; index < pages.length; index++) index,
      for (int index = 0; index < start; index++) index,
    ];
    final GoogleLensPageCache cache = GoogleLensPageCache(
      Directory(p.join(
        dir,
        kMangaOcrOutDirName,
        kMangaOcrPagesCacheDirName,
        kGoogleLensEngineSignature,
      )),
    );
    final List<MokuroImage> cachedPages = <MokuroImage>[];
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final MokuroImage? cached = await cache.read(pageIndex, pages[pageIndex]);
      if (cached == null) {
        cachedPages.clear();
        break;
      }
      cachedPages.add(cached);
    }
    if (cachedPages.length == pages.length && pages.isNotEmpty) {
      final MokuroPayload payload = MokuroPayload(
        images: cachedPages,
        ocr: const MangaOcrMetadata(
          engine: 'google_lens',
          engineSignature: kGoogleLensEngineSignature,
          schemaVersion: 1,
        ),
      );
      final String output = await _writeCachedOutput(dir, payload);
      for (int orderIndex = 0; orderIndex < order.length; orderIndex++) {
        final int pageIndex = order[orderIndex];
        yield MangaOcrBackgroundEvent.progress(
          pagesDone: orderIndex + 1,
          pagesTotal: pages.length,
          pageIndex: pageIndex,
          page: cachedPages[pageIndex],
        );
      }
      yield MangaOcrBackgroundEvent.finished(
        pagesTotal: pages.length,
        resultPath: output,
        external: false,
      );
      return;
    }
    await for (final MangaOcrVolumeEvent event
        in widget.engines.lensRunner!.ocrFolder(
      imageDirPath: dir,
      volumeTitle: _title,
      startPage: widget.startPage,
      onlyMissing: widget.onlyMissing,
    )) {
      if (event.finished) {
        yield MangaOcrBackgroundEvent.finished(
          pagesTotal: event.pagesTotal,
          resultPath: event.mangaJsonPath!,
          external: false,
        );
        continue;
      }
      final int orderIndex = event.pagesDone - 1;
      final int? pageIndex = orderIndex >= 0 && orderIndex < order.length
          ? order[orderIndex]
          : null;
      final MokuroImage? page = pageIndex == null
          ? null
          : await cache.read(pageIndex, pages[pageIndex]);
      yield MangaOcrBackgroundEvent.progress(
        pagesDone: event.pagesDone,
        pagesTotal: event.pagesTotal,
        pageIndex: pageIndex,
        page: page,
      );
    }
  }

  Future<String> _writeCachedOutput(
    String dir,
    MokuroPayload payload,
  ) async {
    final File output = File(p.join(
      dir,
      kMangaOcrOutDirName,
      kMangaOcrOutputFileName,
    ));
    await output.parent.create(recursive: true);
    final File temporary = File('${output.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(mangaPayloadToJson(payload)),
      flush: true,
    );
    if (output.existsSync()) {
      await output.delete();
    }
    await temporary.rename(output.path);
    return output.path;
  }

  Stream<MangaOcrBackgroundEvent> _backgroundExternalEvents(String dir) async* {
    await for (final MokuroRunEvent event
        in widget.engines.externalRunner!.run(dir)) {
      if (event.finished) {
        yield MangaOcrBackgroundEvent.finished(
          pagesTotal: event.total,
          resultPath: event.mokuroPath!,
          external: true,
        );
      } else {
        yield MangaOcrBackgroundEvent.progress(
          pagesDone: event.done,
          pagesTotal: event.total,
        );
      }
    }
  }

  Stream<MangaOcrBackgroundEvent> _backgroundRemoteEvents(String dir) async* {
    final MangaOcrRemoteTarget? target = _remoteTarget;
    if (target == null) {
      throw StateError(t.manga_remote_ocr_no_host);
    }
    await for (final MangaOcrRemoteEvent event in widget.engines.remoteRunner!
        .run(target: target, imageDirPath: dir, volumeTitle: _title)) {
      if (event.finished) {
        yield MangaOcrBackgroundEvent.finished(
          pagesTotal: event.total,
          resultPath: event.mangaJsonPath!,
          external: false,
        );
      } else {
        yield MangaOcrBackgroundEvent.progress(
          pagesDone: event.done,
          pagesTotal: event.total,
        );
      }
    }
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
    if (widget.launchInBackground) {
      final String? bookKey = _createdBookKey;
      if (bookKey == null) {
        setState(() => _error = t.manga_ocr_wizard_failed);
        return;
      }
      Navigator.pop(
        context,
        MangaOcrBackgroundJob(
          bookKey: bookKey,
          managedDirectory: dir,
          engine: _engine,
          events: _backgroundEvents(dir),
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
    _runSub = widget.engines.lensRunner!
        .ocrFolder(
      imageDirPath: dir,
      volumeTitle: _title,
      startPage: widget.startPage,
      onlyMissing: widget.onlyMissing,
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
    _runSub = widget.engines.service
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
      onError: (Object e) => _onOcrError(e),
    );
  }

  void _runExternal(String dir) {
    _runSub = widget.engines.externalRunner!.run(dir).listen(
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
    _runSub = widget.engines.remoteRunner!
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
        // 书已在库，这条路径只把 OCR 结果贴回去，没有导入动作 —— 用 OCR 文案。
        HibikiToast.show(
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
      HibikiToast.show(
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
    // 整份覆写：不进 per-path 写锁就会整段吞掉用户刚在阅读器里框选回写的块
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
            // 已入库且每页都有 OCR（mokuro.moe 下载的卷天生如此）：说清「不需要」，
            // 而不是让用户对着一个禁用的按钮猜。
            if (_folderStatus == MangaOcrFolderStatus.alreadyOcred)
              _errorText(theme, t.manga_ocr_wizard_already_ocred),
            if (_folderStatus == MangaOcrFolderStatus.valid) ...<Widget>[
              const SizedBox(height: 12),
              _engineSelector(busy),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtrl,
                enabled: !busy && widget.existingBook == null,
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
    if (widget.existingBook != null) {
      return HibikiListItem(
        padding: EdgeInsets.zero,
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(widget.existingBook!.title),
        subtitle: Text(p.basename(widget.existingBook!.extractDir)),
      );
    }
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
    final ThemeData theme = Theme.of(context);
    // 主机模型未下载：在选项层就说清原因，而不是让用户传完整卷才在 start 阶段
    // 撞 models_not_ready（TODO-2635）。与 §_folderStatus 的说明式提示同款纪律。
    final Widget? remoteReason = _remoteModelsMissing
        ? _errorText(theme, t.manga_remote_ocr_not_ready)
        : null;
    if (!_builtinAvailable &&
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
      child: SegmentedButton<MangaOcrEngineId>(
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
      if (widget.existingBook == null)
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
