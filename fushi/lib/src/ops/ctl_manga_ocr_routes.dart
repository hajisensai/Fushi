import 'package:material_ui/material_ui.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/manga_book_ocr.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart'
    show hasGoogleLensDisclosure, recordGoogleLensDisclosureAccepted;
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 漫画 OCR 路由（CLI：`fushi_cli ocr ...`）。
///
/// - 启动：[mangaOcrTargetsForBook] 定目标（书架卡菜单「识别文字」同一判据：本地卷
///   未识别就排整卷，在线作品排已下载未识别的章；`force` = 阅读器「重新识别本卷」的
///   整卷重跑）+ [enqueueMangaOcrTargets] 排任务（引擎按用户偏好解析）；Google Lens
///   上传同意不弹框，由 `consentUpload` 显式表态；
/// - 进度：app 级 [MangaOcrJobRegistry]（任务寿命不绑页面，书架横幅同一份）；
/// - 取消：[MangaOcrJobRegistry.cancel]（横幅「取消」按钮同一方法）。
List<CtlRoute> buildMangaOcrCtlRoutes(OpContext context) {
  final _MangaOcrHandlers h = _MangaOcrHandlers(context);
  return <CtlRoute>[
    CtlRoute.get(kMangaOcrCtlPath, h.status),
    CtlRoute.post(kMangaOcrCtlPath, h.start),
    CtlRoute.post('$kMangaOcrCtlPath/cancel', h.cancel),
  ];
}

const String kMangaOcrCtlPath = '/api/admin/library/ocr';

/// `ocr start --engine` 的值域：引擎偏好键（设置里存的同一套字符串），不含 auto。
final List<String> kMangaOcrCtlEngineKeys = <String>[
  for (final MangaOcrEnginePreference p in MangaOcrEnginePreference.values)
    if (p.explicitEngine != null) p.key,
];

/// `--engine` 值 → 引擎；不认识（含 auto）返回 null。
MangaOcrEngineId? parseMangaOcrCtlEngine(String raw) {
  final MangaOcrEnginePreference pref = MangaOcrEnginePreferenceKey.fromKey(
    raw.trim(),
  );
  return pref.key == raw.trim() ? pref.explicitEngine : null;
}

/// 本机此刻可用的引擎键（整卷 OCR 向导里可选的那组：同一个
/// [MangaOcrEngineAvailability.isUsable] 判据）。
List<String> mangaOcrCtlUsableEngineKeys(MangaOcrEngineAvailability a) =>
    <String>[
      for (final MangaOcrEnginePreference p in MangaOcrEnginePreference.values)
        if (p.explicitEngine case final MangaOcrEngineId id when a.isUsable(id))
          p.key,
    ];

/// 一个任务的进度 JSON（[lastEvent] 为 null = 刚开始、还没报过进度）。
Map<String, Object?> mangaOcrCtlJobJson({
  required String bookKey,
  required String? directory,
  required MangaOcrBackgroundEvent? lastEvent,
  required List<String> queuedDirectories,
  required bool ended,
  required bool cancelled,
  Object? error,
}) => <String, Object?>{
  'key': LibraryCtlKey(LibraryCtlStore.book, bookKey).wire,
  'state': error != null
      ? 'failed'
      : cancelled
      ? 'cancelled'
      : ended
      ? 'done'
      : directory == null
      ? 'queued'
      : 'running',
  if (directory != null) 'directory': p.basename(directory),
  if (lastEvent != null) ...<String, Object?>{
    'pagesDone': lastEvent.pagesDone,
    'pagesTotal': lastEvent.pagesTotal,
    // 远程引擎的上传段：计数是已上传页数，识别段会从 0 重数（BUG-3605）。
    if (lastEvent.uploading) 'phase': 'uploading',
  },
  'queued': queuedDirectories.length,
  if (error != null) 'error': '$error',
};

class _MangaOcrHandlers {
  _MangaOcrHandlers(this._context);

  final OpContext _context;

  AppModel get _app => _context.appModel;
  MangaOcrJobRegistry get _registry =>
      _context.ref.read(mangaOcrJobRegistryProvider);

  void _requireManga() {
    if (!_app.moduleVisibility.isEnabled(LibraryCtlKind.manga.module)) {
      throw const CtlFailure.rejected('漫画模块已在设置里关闭');
    }
  }

  Future<EpubBookRow> _mangaRow(String raw) async {
    final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
    if (key == null || key.store != LibraryCtlStore.book) {
      throw CtlFailure.badRequest('漫画条目键应为 book:<bookKey>，收到「$raw」');
    }
    final EpubBookRow? row = await _app.database.getEpubBook(key.id);
    if (row == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
    if (row.format != BookFormat.manga.dbValue) {
      throw CtlFailure.rejected('${key.wire} 不是漫画');
    }
    return row;
  }

  Map<String, Object?> _jobJson(String bookKey) {
    final MangaOcrRunningJob? job = _registry.running(bookKey);
    return mangaOcrCtlJobJson(
      bookKey: bookKey,
      directory: job?.job.managedDirectory,
      lastEvent: job?.lastEvent,
      queuedDirectories: _registry.queuedDirectories(bookKey),
      ended: job?.isEnded ?? false,
      cancelled: job?.isCancelled ?? false,
      error: job?.error,
    );
  }

  /// 不带 key：全部在跑 / 排队的任务；带 key：这本漫画的任务（没有任务时
  /// `state: idle`）。
  Future<Object?> status(CtlCall call) async {
    final String? raw = call.optString('key');
    if (raw != null) {
      final EpubBookRow row = await _mangaRow(raw);
      final MangaOcrRunningJob? job = _registry.running(row.bookKey);
      if (job == null && _registry.queuedDirectories(row.bookKey).isEmpty) {
        return <String, Object?>{
          'key': LibraryCtlKey(LibraryCtlStore.book, row.bookKey).wire,
          'state': 'idle',
          'pending': (await pendingMangaOcrTargets(row)).length,
        };
      }
      return _jobJson(row.bookKey);
    }
    final Set<String> bookKeys = <String>{
      for (final MangaOcrRunningJob job in _registry.all) job.bookKey,
    };
    return <String, Object?>{
      'jobs': <Map<String, Object?>>[
        for (final String bookKey in bookKeys) _jobJson(bookKey),
      ],
    };
  }

  /// `force`：连已识别的部分一起整卷重跑（阅读器「重新识别本卷」同一语义，丢逐页
  /// 缓存）。`consentUpload`：引擎是 Google Lens 且本机还没同意过上传时，代用户在
  /// 命令行显式同意（写入与同意框相同的同意记录）；没给就回 422 说明需要同意，
  /// 绝不在 app 里弹框把命令挂住。
  Future<Object?> start(CtlCall call) async {
    _requireManga();
    if (_app.isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
    final EpubBookRow row = await _mangaRow(call.requireString('key'));
    final bool force = call.optBool('force') == true;
    final bool consent = call.optBool('consentUpload') == true;
    final String? engineRaw = call.optString('engine');
    MangaOcrEngineId? engineChoice;
    if (engineRaw != null) {
      engineChoice = parseMangaOcrCtlEngine(engineRaw);
      if (engineChoice == null) {
        throw CtlFailure.badRequest(
          'engine「$engineRaw」不认识，可选：${kMangaOcrCtlEngineKeys.join(' / ')}',
        );
      }
    }
    final List<MangaOcrTarget> targets = await mangaOcrTargetsForBook(
      row,
      force: force,
    );
    if (targets.isEmpty) {
      throw CtlFailure.conflict(
        force
            ? '没有可识别的部分（在线作品还没有已下载的章）'
            : '没有需要识别的部分（本地卷已识别 / 在线作品没有已下载未识别的章；整卷重跑用 --force）',
      );
    }
    final NavigatorState? navigator = _context.navigator;
    if (navigator == null || !navigator.mounted) {
      throw const CtlFailure.conflict('主界面还没就绪');
    }
    final MangaOcrWizardEngines engines = MangaOcrWizardEngines.resolve(
      context: navigator.context,
      db: _app.database,
    );
    if (engineChoice != null) {
      // 与整卷 OCR 向导同一组可选引擎、同一判据；只作用于本次任务（向导也不写偏好）。
      final MangaOcrEngineAvailability availability =
          await probeMangaOcrEngines(engines);
      if (!availability.isUsable(engineChoice)) {
        final List<String> usable = mangaOcrCtlUsableEngineKeys(availability);
        throw CtlFailure.rejected(
          '引擎「$engineRaw」在本机现在不可用（模型没下 / 没配置 / 平台不支持）；'
          '可用：${usable.isEmpty ? '无' : usable.join(' / ')}',
        );
      }
    }
    if (!navigator.mounted) throw const CtlFailure.conflict('主界面已关闭');
    bool lensConsentMissing = false;
    final int queued = await enqueueMangaOcrTargets(
      context: navigator.context,
      appModel: _app,
      registry: _registry,
      targets: targets,
      enginesOverride: engines,
      engineChoice: engineChoice,
      lensGate: (BuildContext _) async {
        if (await hasGoogleLensDisclosure()) return true;
        if (consent) {
          await recordGoogleLensDisclosureAccepted();
          return true;
        }
        lensConsentMissing = true;
        return false;
      },
    );
    if (queued == 0) {
      if (lensConsentMissing) {
        throw const CtlFailure.rejected(
          '当前 OCR 引擎是 Google Lens，会把漫画页面上传给 Google；'
          '本机还没同意过。确认上传请加 --consent-upload（或在设置里换成本地引擎）',
        );
      }
      throw const CtlFailure.rejected('没有可用的 OCR 引擎，见 app 内提示');
    }
    return <String, Object?>{
      'queued': queued,
      'force': force,
      if (engineRaw != null) 'engine': engineRaw,
      ..._jobJson(row.bookKey),
    };
  }

  Future<Object?> cancel(CtlCall call) async {
    final EpubBookRow row = await _mangaRow(call.requireString('key'));
    final bool active =
        _registry.running(row.bookKey) != null ||
        _registry.queuedDirectories(row.bookKey).isNotEmpty;
    if (!active) throw const CtlFailure.conflict('这本漫画没有在跑的 OCR 任务');
    await _registry.cancel(row.bookKey);
    return <String, Object?>{
      'key': LibraryCtlKey(LibraryCtlStore.book, row.bookKey).wire,
      'cancelled': true,
    };
  }
}
