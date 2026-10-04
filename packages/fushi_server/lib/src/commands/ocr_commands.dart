/// 离线漫画 OCR / 分镜命令：`ocr manga`、`ocr models`、`manga panels`、`manga panel-model`。
///
/// ```
/// fushi_server ocr manga <bookKey> [--pages 1-20,25] [--model manga_ocr] [--redo]
///                                  [--ai-refine [--ai-mode low_confidence|all]] [--json]
/// fushi_server ocr models [ls|pull|rm] [--model manga_ocr]          [--json]
/// fushi_server manga panels <image…> [--ltr]                         [--json]
/// fushi_server manga panel-model [status|pull]                       [--json]
/// ```
///
/// OCR 服务与运行中的 `serve` 同一套装配（`headless_host.dart`：每个本平台可用的本地
/// 模型一个 `MangaOcrServiceImpl`，ONNX 会话由 `installServerHostBindings` 装好的
/// FFI 工厂建）。结果落回书目录的 `manga.json`，形态与 app「对已入库漫画跑 OCR」一致：
/// - 整卷：`ocrFolder(<书目录>)` 的产物整份覆写 `manga.json`（同 app 向导
///   `_applyOcrToManagedBook`）；
/// - `--pages`：页级会话逐页识别进逐页缓存，再只把这些页的文字层并进现有
///   `manga.json`，其余页原样保留。
///
/// 进程内写 `manga.json` 是 tmp + rename 原子覆盖；**不与运行中的 serve 互斥**——
/// serve 开着时对同一本书跑离线 OCR，两边的写会互相覆盖（缺口盘点第 7 节的离线写锁
/// 还没有实现）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_asr_core/asr_core.dart' show DownloadableModelFile, ModelDownloadEvent, ModelFileDownloader;
import 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart' show findUsableOrtRuntime;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/media/manga/panel_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/native_libs.dart' show onnxRuntimeLibraryName;
import 'package:fushi_server/src/ocr_session_factory.dart' show serverOrtLibraryPath;
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

const String kOcrUsage = '''
ocr manga <bookKey> [--pages 1-20,25] [--model k] [--redo] [--ai-refine [--ai-mode low_confidence|all]]
                                                     对已入库漫画跑本地 OCR，结果写回书的 manga.json
ocr models [ls|pull|rm] [--model k]                   本地 OCR 模型（manga_ocr / manga_ctc / baberu）
manga panels <image…> [--ltr]                         分镜检测（默认日漫右→左阅读序）
manga panel-model [status|pull]                       分镜模型
（以上都支持 --json；--ai-refine 用配置文件 ai: 段的那一家提供商）''';

/// 页号选择（1 起、闭区间、逗号分隔：`1-20,25`）→ 0 起的升序去重页下标。
///
/// 语法错 / 越界抛 [FormatException]（调用方报 64）。
List<int> parsePageSelection(String spec, int pageCount) {
  final Set<int> picked = <int>{};
  for (final String raw in spec.split(',')) {
    final String part = raw.trim();
    if (part.isEmpty) continue;
    final List<String> bounds = part.split('-');
    if (bounds.length > 2) throw FormatException('页号范围写错了: "$part"');
    final int? from = int.tryParse(bounds.first.trim());
    final int? to = bounds.length == 2 ? int.tryParse(bounds.last.trim()) : from;
    if (from == null || to == null) throw FormatException('页号范围写错了: "$part"');
    if (from < 1 || to < from || to > pageCount) {
      throw FormatException('页号 "$part" 越界（本书 1-$pageCount 页）');
    }
    for (int page = from; page <= to; page++) {
      picked.add(page - 1);
    }
  }
  if (picked.isEmpty) throw FormatException('没有选中任何页: "$spec"');
  return picked.toList()..sort();
}

/// 本平台能跑的本地 OCR 模型（key → 服务），与 `HeadlessHost` 的 `ocrModelServices` 同口径。
Map<String, MangaOcrServiceImpl> serverOcrModelServices() => <String, MangaOcrServiceImpl>{
  for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
    if (MangaOcrLocalModel.forPlatform(model.key) == model) model.key: MangaOcrServiceImpl(localModel: model),
};

/// 本机有没有能用的 onnxruntime（判据与 FFI 会话工厂加载时逐字一致）；没有返回原因。
String? serverOrtProblem() {
  final String? override = serverOrtLibraryPath;
  final String? found = findUsableOrtRuntime(candidates: override == null ? null : <String>[override]);
  if (found != null) return null;
  return 'onnxruntime 动态库不可用：在配置里设 ort_library_path，或把 ${override ?? onnxRuntimeLibraryName()} '
      '放到可执行文件旁 / 系统库路径（ASR_ONNXRUNTIME_LIB 也认）';
}

String _modelName(String key) => switch (key) {
  'manga_ocr' => 'manga-ocr（经典）',
  'manga_ctc' => '漫画 CTC（快速）',
  'baberu' => 'Baberu',
  _ => key,
};

/// 原子覆写 manga.json（tmp + rename 直接覆盖，不先删目标）。
Future<void> _writeMangaJson(String path, MokuroPayload payload) async {
  final File temporary = File('$path.${pid}_${DateTime.now().microsecondsSinceEpoch}.tmp');
  await temporary.writeAsString(jsonEncode(mangaPayloadToJson(payload)), flush: true);
  await temporary.rename(path);
}

/// 把 [fresh] 里各页的文字层并进 [existing]（按归一 url 对页，其余页原样）。返回合并结果与
/// 实际并进的页数。
({MokuroPayload payload, int merged}) mergeMangaOcrPages(MokuroPayload existing, MokuroPayload fresh) {
  final Map<String, MokuroImage> byUrl = <String, MokuroImage>{
    for (final MokuroImage image in fresh.images) normalizeMangaUrl(image.url): image,
  };
  int merged = 0;
  final List<MokuroImage> images = <MokuroImage>[];
  for (final MokuroImage image in existing.images) {
    final MokuroImage? update = byUrl[normalizeMangaUrl(image.url)];
    if (update == null) {
      images.add(image);
      continue;
    }
    merged++;
    images.add(MokuroImage(url: image.url, size: update.size, blocks: update.blocks));
  }
  return (payload: MokuroPayload(images: images, ocr: existing.ocr), merged: merged);
}

class OcrCommands extends CliModule {
  const OcrCommands({CommandIo io = const CommandIo()}) : _io = io;

  final CommandIo _io;

  @override
  List<String> get commands => const <String>['ocr', 'manga'];

  @override
  void register(ArgParser parser) {
    final ArgParser ocr = parser.addCommand('ocr');
    addJsonFlag(ocr.addCommand('manga'))
      ..addOption('pages', help: '只识别这些页（1 起：1-20,25）；缺省整卷')
      ..addOption('model', help: '本地模型 key（manga_ocr / manga_ctc / baberu）', defaultsTo: 'manga_ocr')
      ..addFlag('redo', negatable: false, help: '丢掉已有逐页缓存重新识别')
      ..addFlag('ai-refine', negatable: false, help: '用配置文件 ai: 段的大模型重读块内文字')
      ..addOption('ai-mode', allowed: <String>['low_confidence', 'all'], defaultsTo: 'low_confidence');
    addJsonFlag(ocr.addCommand('models')).addOption('model', help: '模型 key（pull 缺省 manga_ocr；rm 必填）');
    final ArgParser manga = parser.addCommand('manga');
    addJsonFlag(manga.addCommand('panels')).addFlag('ltr', negatable: false, help: '左→右阅读序（美漫 / 条漫）');
    addJsonFlag(manga.addCommand('panel-model'));
  }

  @override
  String get usage => kOcrUsage;

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final ArgResults? leaf = command.command;
    if (leaf == null) {
      return _io.usage(
        '缺少子命令',
        name == 'ocr' ? 'ocr manga <bookKey> … | ocr models [ls|pull|rm]' : 'manga panels <image…> | manga panel-model',
      );
    }
    switch ('$name ${leaf.name}') {
      case 'ocr manga':
        return _ocrManga(leaf, ctx);
      case 'ocr models':
        return _models(leaf, ctx);
      case 'manga panels':
        return _panels(leaf, ctx);
      default:
        return _panelModel(leaf, ctx);
    }
  }

  // ── ocr models ──────────────────────────────────────────────────────

  Future<int> _models(ArgResults leaf, CliContext ctx) async {
    const String usageLine = 'ocr models [ls|pull|rm] [--model k] [--json]';
    final String action = leaf.rest.isEmpty ? 'ls' : leaf.rest.first;
    if (!const <String>{'ls', 'pull', 'rm'}.contains(action) || leaf.rest.length > 1) {
      return _io.usage('未知动作 "${leaf.rest.join(' ')}"', usageLine);
    }
    final String? key = leaf['model'] as String?;
    if (action == 'rm' && key == null) return _io.usage('rm 要用 --model 点名删哪个模型', usageLine);
    final bool json = wantsJson(leaf);
    return ctx.withRuntime((ServerRuntime rt) async {
      final Map<String, MangaOcrServiceImpl> services = serverOcrModelServices();
      if (action == 'ls') return _modelsLs(services, json: json);
      final String target = key ?? MangaOcrLocalModel.mangaOcr.key;
      final MangaOcrServiceImpl? service = services[target];
      if (service == null) return _unknownModel(target, services);
      if (action == 'rm') {
        final int freed = await service.deleteModels();
        if (json) {
          _io.json(<String, Object?>{'model': target, 'freedBytes': freed});
        } else {
          _io.out.writeln('已删除 $target 模型，释放 $freed 字节');
        }
        return kExitOk;
      }
      String last = '';
      try {
        await for (final MangaOcrDownloadEvent e in service.downloadModels()) {
          final String line = '${e.fileName} ${e.receivedBytes}/${e.totalBytes}${e.done ? ' done' : ''}';
          if (line != last) _io.err.writeln(line);
          last = line;
        }
      } on Exception catch (e, stack) {
        rt.log.log('cli.ocr.models.pull($target)', e, stack);
        _io.err.writeln('下载 $target 模型失败: $e');
        return kExitUnavailable;
      }
      final MangaOcrModelStatus status = await service.modelStatus();
      if (json) {
        _io.json(<String, Object?>{'model': target, 'ready': status.allReady, 'diskBytes': status.diskBytes});
      } else {
        _io.out.writeln('$target: ${status.allReady ? '模型已就绪' : '下载结束但模型仍不齐'}');
      }
      return status.allReady ? kExitOk : kExitFailure;
    });
  }

  int _unknownModel(String key, Map<String, MangaOcrServiceImpl> services) {
    final bool known = MangaOcrLocalModel.values.any((MangaOcrLocalModel m) => m.key == key);
    if (!known) {
      return _io.usage('未知模型 "$key"（可用: ${services.keys.join(' / ')}）', 'ocr … --model <key>');
    }
    _io.err.writeln('模型 $key 不支持本平台（${Platform.operatingSystem}）；可用: ${services.keys.join(' / ')}');
    return kExitUnavailable;
  }

  Future<int> _modelsLs(Map<String, MangaOcrServiceImpl> services, {required bool json}) async {
    final String? ortProblem = serverOrtProblem();
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (final MapEntry<String, MangaOcrServiceImpl> entry in services.entries) {
      final MangaOcrModelStatus status = await entry.value.modelStatus();
      rows.add(<String, Object?>{
        'key': entry.key,
        'name': _modelName(entry.key),
        'ready': status.allReady,
        'obtainedBytes': status.obtainedBytes,
        'diskBytes': status.diskBytes,
        'totalBytes': status.totalBytes,
        'acceleratorMissingBytes': status.acceleratorMissingBytes,
      });
    }
    if (json) {
      _io.json(<String, Object?>{'runtimeAvailable': ortProblem == null, 'runtimeProblem': ortProblem, 'models': rows});
      return kExitOk;
    }
    if (ortProblem != null) _io.out.writeln('! $ortProblem');
    for (final Map<String, Object?> row in rows) {
      _io.out.writeln(
        '${'${row['key']}'.padRight(10)} ${row['ready'] == true ? 'ready  ' : 'missing'} '
        '${row['obtainedBytes']}/${row['totalBytes']} bytes（磁盘 ${row['diskBytes']}）  ${row['name']}',
      );
    }
    return kExitOk;
  }

  // ── ocr manga ───────────────────────────────────────────────────────

  Future<int> _ocrManga(ArgResults leaf, CliContext ctx) async {
    const String usageLine = 'ocr manga <bookKey> [--pages 1-20] [--model k] [--redo] [--ai-refine] [--json]';
    if (leaf.rest.length != 1) return _io.usage('要且只要一个 bookKey', usageLine);
    final String bookKey = leaf.rest.single;
    final bool json = wantsJson(leaf);
    return ctx.withRuntime((ServerRuntime rt) async {
      final EpubBookRow? row = await rt.db.getEpubBook(bookKey);
      if (row == null) {
        _io.err.writeln('库里没有这本书: $bookKey');
        return kExitNoInput;
      }
      if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) {
        _io.err.writeln('$bookKey 不是漫画（format=${row.format}）');
        return kExitFailure;
      }
      final String dir = row.extractDir;
      final List<MangaOcrPageFile> pages = enumerateMangaPages(Directory(dir));
      if (pages.isEmpty) {
        _io.err.writeln('书目录里没有页图: $dir');
        return kExitFailure;
      }
      List<int>? selection;
      final String? pagesSpec = leaf['pages'] as String?;
      if (pagesSpec != null) {
        try {
          selection = parsePageSelection(pagesSpec, pages.length);
        } on FormatException catch (e) {
          return _io.usage(e.message, usageLine);
        }
      }
      final String key = leaf['model'] as String;
      final Map<String, MangaOcrServiceImpl> services = serverOcrModelServices();
      final MangaOcrServiceImpl? service = services[key];
      if (service == null) return _unknownModel(key, services);
      final String? ortProblem = serverOrtProblem();
      if (ortProblem != null) {
        _io.err.writeln(ortProblem);
        return kExitUnavailable;
      }
      if (!(await service.modelStatus()).allReady) {
        _io.err.writeln('$key 模型未下载：先跑 fushi_server ocr models pull --model $key');
        return kExitUnavailable;
      }
      MangaAiOcrRefiner? refiner;
      AiProviderConfig? provider;
      if (leaf['ai-refine'] as bool) {
        provider = rt.config.ai?.provider();
        if (provider == null) {
          _io.err.writeln(
            '--ai-refine 需要可用的 AI 提供商：在配置文件里填 ai: 段'
            '${rt.config.ai?.problem() == null ? '' : '（当前: ${rt.config.ai!.problem()}）'}，或经 WebUI 设置',
          );
          return kExitUnavailable;
        }
        refiner = MangaAiOcrRefiner(provider: provider, mode: MangaAiOcrMode.fromStorageKey(leaf['ai-mode'] as String));
      }
      final MangaAiOcrCache? aiCache = provider == null ? null : MangaAiOcrCache.forVolume(dir, provider);

      final String cacheDir = await service.resolvePageCacheDirPath(imageDirPath: dir);
      final bool redo = leaf['redo'] as bool;
      final List<MangaOcrPageFile> targets = selection == null
          ? pages
          : <MangaOcrPageFile>[for (final int i in selection) pages[i]];
      if (redo) {
        if (selection == null) {
          final Directory cache = Directory(cacheDir);
          if (await cache.exists()) await cache.delete(recursive: true);
        } else {
          for (final MangaOcrPageFile page in targets) {
            final File cached = File(p.join(cacheDir, ocrPageCacheFileName(page.relativeUrl)));
            if (await cached.exists()) await cached.delete();
          }
        }
        await aiCache?.clear();
      }

      final String mangaJsonPath = p.join(dir, row.epubPath);
      MokuroPayload payload;
      try {
        if (selection == null) {
          payload = await _runWholeVolume(service, dir, row.title);
        } else {
          final MokuroPayload fresh = await _runPages(service, dir, cacheDir, targets);
          final File existing = File(mangaJsonPath);
          if (!await existing.exists()) {
            _io.err.writeln('书目录里没有 ${row.epubPath}，--pages 无处合并；去掉 --pages 跑整卷');
            return kExitFailure;
          }
          final ({MokuroPayload payload, int merged}) merged = mergeMangaOcrPages(
            parseMangaJson(await existing.readAsString()),
            fresh,
          );
          if (merged.merged < fresh.images.length) {
            _io.err.writeln('有 ${fresh.images.length - merged.merged} 页在 ${row.epubPath} 里对不上，未写入');
          }
          payload = merged.payload;
        }
      } on Object catch (e, stack) {
        // 任务边界：OCR 管线 / ORT 的任何失败都如实报出并记日志，退出码 1。
        rt.log.log('cli.ocr.manga($bookKey)', e, stack);
        _io.err.writeln('OCR 失败: $e');
        return kExitFailure;
      }

      Map<String, Object?>? aiReport;
      if (refiner != null) {
        final Set<String> processed = <String>{for (final MangaOcrPageFile page in targets) page.relativeUrl};
        final ({MokuroPayload payload, Map<String, Object?> report}) refined = await _refine(
          refiner,
          aiCache!,
          dir,
          payload,
          processed,
          leaf['ai-mode'] as String,
        );
        payload = refined.payload;
        aiReport = refined.report;
      }
      await _writeMangaJson(mangaJsonPath, payload);
      if (json) {
        _io.json(<String, Object?>{
          'bookKey': bookKey,
          'model': key,
          'pagesTotal': pages.length,
          'pagesProcessed': targets.length,
          'mode': selection == null ? 'volume' : 'pages',
          'mangaJson': mangaJsonPath,
          if (aiReport != null) 'ai': aiReport,
        });
      } else {
        _io.out.writeln('OCR 完成: $bookKey（${targets.length}/${pages.length} 页，模型 $key）→ $mangaJsonPath');
        if (aiReport != null) _io.out.writeln('大模型重读: $aiReport');
      }
      return kExitOk;
    });
  }

  /// 整卷：`ocrFolder` 跑完给出产物 manga.json，读出来交给调用方整份覆写。
  Future<MokuroPayload> _runWholeVolume(MangaOcrServiceImpl service, String dir, String title) async {
    String? resultPath;
    await for (final MangaOcrVolumeEvent e in service.ocrFolder(imageDirPath: dir, volumeTitle: title)) {
      if (e.finished) {
        resultPath = e.mangaJsonPath;
      } else {
        _io.err.writeln('page ${e.pagesDone}/${e.pagesTotal}');
      }
    }
    final String? path = resultPath;
    if (path == null) throw StateError('OCR 任务结束但没有产出 manga.json');
    return parseMangaJson(await File(path).readAsString());
  }

  /// 指定页：页级会话逐页识别进逐页缓存（与阅读器「边看边 OCR」同一缓存），再按页名
  /// 读回组装成只含这些页的 payload。
  Future<MokuroPayload> _runPages(
    MangaOcrServiceImpl service,
    String dir,
    String cacheDir,
    List<MangaOcrPageFile> targets,
  ) async {
    final MangaOcrPageSession session = await service.openPageSession(imageDirPath: dir);
    try {
      for (int i = 0; i < targets.length; i++) {
        await session.ocrPage(targets[i].relativeUrl);
        _io.err.writeln('page ${i + 1}/${targets.length} ${targets[i].relativeUrl}');
      }
    } finally {
      await session.close();
    }
    final MangaOcrFilePageCache cache = MangaOcrFilePageCache(
      cacheDir: Directory(cacheDir),
      pageNames: <String>[for (final MangaOcrPageFile page in targets) page.relativeUrl],
      pageFiles: <File>[for (final MangaOcrPageFile page in targets) page.file],
    );
    final List<OcrPageResult> results = <OcrPageResult>[];
    for (int i = 0; i < targets.length; i++) {
      final OcrPageResult? result = await cache.read('manga_ocr', i);
      if (result == null) throw StateError('页 ${targets[i].relativeUrl} 识别后没有逐页缓存');
      results.add(result);
    }
    return buildMangaPayloadFromResults(targets, results);
  }

  /// 大模型重读本次处理过的页（[processed] = 页的归一 url）。任何失败保留本地文字。
  Future<({MokuroPayload payload, Map<String, Object?> report})> _refine(
    MangaAiOcrRefiner refiner,
    MangaAiOcrCache cache,
    String dir,
    MokuroPayload payload,
    Set<String> processed,
    String mode,
  ) async {
    int candidates = 0;
    int replaced = 0;
    int cached = 0;
    final Set<String> failures = <String>{};
    final List<MokuroImage> images = <MokuroImage>[];
    for (final MokuroImage image in payload.images) {
      final String url = normalizeMangaUrl(image.url);
      if (!processed.contains(url)) {
        images.add(image);
        continue;
      }
      final Uint8List bytes = await File(p.joinAll(<String>[dir, ...url.split('/')])).readAsBytes();
      final ({MokuroImage page, MangaAiOcrPageStats stats}) result = await refiner.refinePage(
        image,
        bytes,
        cache: cache,
      );
      images.add(result.page);
      candidates += result.stats.candidates;
      replaced += result.stats.replaced;
      cached += result.stats.cached;
      final String? failure = result.stats.failure;
      if (failure != null) failures.add(failure);
      _io.err.writeln(
        'ai ${images.length}/${payload.images.length} 替换 ${result.stats.replaced}/${result.stats.candidates}',
      );
    }
    return (
      payload: MokuroPayload(images: images, ocr: payload.ocr),
      report: <String, Object?>{
        'mode': mode,
        'candidates': candidates,
        'replaced': replaced,
        'cached': cached,
        if (failures.isNotEmpty) 'failures': failures.toList(),
      },
    );
  }

  // ── manga panels ────────────────────────────────────────────────────

  Future<int> _panels(ArgResults leaf, CliContext ctx) async {
    if (leaf.rest.isEmpty) return _io.usage('缺少图片路径', 'manga panels <image…> [--ltr] [--json]');
    final List<String> images = <String>[for (final String raw in leaf.rest) p.normalize(p.absolute(raw))];
    final List<String> missing = <String>[
      for (final String path in images)
        if (!File(path).existsSync()) path,
    ];
    if (missing.isNotEmpty) {
      for (final String path in missing) {
        _io.err.writeln('找不到: $path');
      }
      return kExitNoInput;
    }
    final PanelReadingDirection direction = leaf['ltr'] as bool ? PanelReadingDirection.ltr : PanelReadingDirection.rtl;
    final bool json = wantsJson(leaf);
    return ctx.withRuntime((ServerRuntime rt) async {
      final File model = await _panelModelFile(rt);
      if (!await verifyMangaPanelModelFile(model)) {
        _io.err.writeln('分镜模型未就绪：先跑 fushi_server manga panel-model pull');
        return kExitUnavailable;
      }
      final String? ortProblem = serverOrtProblem();
      if (ortProblem != null) {
        _io.err.writeln(ortProblem);
        return kExitUnavailable;
      }
      final OcrSessionFactory Function()? builder = ocrSessionFactoryBuilder;
      if (builder == null) throw StateError('ocrSessionFactoryBuilder 未装配（installServerHostBindings 没跑）');
      final OcrSession session = await builder().createSession(
        model.path,
        providers: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
      );
      final PanelDetector detector = OnnxPanelDetector(session, modelRevision: kMangaPanelModelManifest.revision);
      final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
      try {
        for (final String path in images) {
          final Uint8List bytes = await File(path).readAsBytes();
          final PanelDetectionResult result = await detector.detectPrepared(
            pageKey: path,
            direction: direction,
            prepare: () => Isolate.run(() => preprocessPanelPageBytes(bytes)),
          );
          rows.add(<String, Object?>{
            'path': path,
            'status': result.status.name,
            if (result.error != null) 'error': result.error,
            'panels': <Map<String, Object?>>[
              for (final PanelRect r in result.panels)
                <String, Object?>{'left': r.left, 'top': r.top, 'right': r.right, 'bottom': r.bottom, 'score': r.score},
            ],
            'textBoxes': result.textBoxes.length,
          });
        }
      } finally {
        await detector.close();
      }
      final bool anyFailed = rows.any(
        (Map<String, Object?> r) =>
            r['status'] == PanelDetectionStatus.failed.name || r['status'] == PanelDetectionStatus.unavailable.name,
      );
      if (json) {
        _io.json(<String, Object?>{'direction': direction.name, 'images': rows});
      } else {
        for (final Map<String, Object?> row in rows) {
          final List<Map<String, Object?>> panels = (row['panels']! as List<Object?>).cast<Map<String, Object?>>();
          _io.out.writeln(
            '${row['path']}: ${row['status']}，${panels.length} 格'
            '${row['error'] == null ? '' : '（${row['error']}）'}',
          );
          for (int i = 0; i < panels.length; i++) {
            final Map<String, Object?> r = panels[i];
            String f(String k) => (r[k]! as double).toStringAsFixed(3);
            _io.out.writeln(
              '  #${i + 1} [${f('left')}, ${f('top')}, ${f('right')}, ${f('bottom')}] score ${f('score')}',
            );
          }
        }
      }
      return anyFailed ? kExitFailure : kExitOk;
    });
  }

  /// 与 app `manga_panel_model_service.dart` 同一落点：`<support>/manga_panel_detector/<文件名>`
  /// （同一份数据目录理论上可被桌面 Fushi 直接打开）。
  Future<File> _panelModelFile(ServerRuntime rt) async =>
      File(p.join(rt.paths.support.path, 'manga_panel_detector', kMangaPanelModelManifest.fileName));

  Future<int> _panelModel(ArgResults leaf, CliContext ctx) async {
    const String usageLine = 'manga panel-model [status|pull] [--json]';
    final String action = leaf.rest.isEmpty ? 'status' : leaf.rest.first;
    if (!const <String>{'status', 'pull'}.contains(action) || leaf.rest.length > 1) {
      return _io.usage('未知动作 "${leaf.rest.join(' ')}"', usageLine);
    }
    final bool json = wantsJson(leaf);
    return ctx.withRuntime((ServerRuntime rt) async {
      final File model = await _panelModelFile(rt);
      if (action == 'pull' && !await verifyMangaPanelModelFile(model)) {
        try {
          await _downloadPanelModel(model);
        } on Exception catch (e, stack) {
          rt.log.log('cli.manga.panelModel.pull', e, stack);
          _io.err.writeln('下载分镜模型失败: $e');
          return kExitUnavailable;
        }
        if (!await verifyMangaPanelModelFile(model)) {
          // 校验不过的文件留着只会让下次 status 继续报坏：删掉，下次重下。
          if (await model.exists()) await model.delete();
          _io.err.writeln('下载的分镜模型校验失败（大小 / SHA-256 与清单不符），已删除');
          return kExitFailure;
        }
      }
      final bool ready = await verifyMangaPanelModelFile(model);
      final int bytes = await model.exists() ? await model.length() : 0;
      if (json) {
        _io.json(<String, Object?>{
          'ready': ready,
          'path': model.path,
          'bytes': bytes,
          'expectedBytes': kMangaPanelModelManifest.bytes,
          'revision': kMangaPanelModelManifest.revision,
        });
      } else {
        _io.out.writeln('分镜模型: ${ready ? '就绪' : (bytes > 0 ? '文件损坏 / 不符' : '未下载')}  ${model.path}');
      }
      return ready || action == 'status' ? kExitOk : kExitFailure;
    });
  }

  /// 走与 OCR / ASR 模型同一个共享下载器（`.part` + 续传 + 原子 rename、经全应用代理），
  /// 落盘后由调用方按清单 SHA-256 校验。
  Future<void> _downloadPanelModel(File model) async {
    final ModelFileDownloader downloader = ModelFileDownloader(
      createClient: () => createAppHttpClient(),
      urlCandidates: (DownloadableModelFile file) => <String>[file.url],
    );
    final int expected = kMangaPanelModelManifest.bytes ?? 0;
    await for (final ModelDownloadEvent e in downloader.downloadAll(
      files: const <DownloadableModelFile>[_PanelModelFile()],
      targetDir: model.parent,
      isReady: (File file) => file.existsSync() && file.lengthSync() == expected,
    )) {
      _io.err.writeln('${e.fileName} ${e.receivedBytes}/${e.totalBytes}${e.done ? ' done' : ''}');
    }
  }
}

class _PanelModelFile implements DownloadableModelFile {
  const _PanelModelFile();

  @override
  String get fileName => kMangaPanelModelManifest.fileName;

  @override
  String get url => kMangaPanelModelManifest.assetUrl;

  @override
  int get expectedBytes => kMangaPanelModelManifest.bytes ?? 0;
}
