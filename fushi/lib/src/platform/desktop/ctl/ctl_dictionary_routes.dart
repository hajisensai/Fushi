import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_dictionary_json.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// dictionary 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/dictionary_commands.dart`）。
///
/// 词典管理 / 导入 / 在线更新 / 查词走 [AppModel] 上与词典管理页同一组方法；
/// Anki 走 app 内查词页制卡用的 [ankiRepositoryProvider]（带待发队列 / 制卡到主机
/// 的装配，与 `dictionary_page_mixin.onMineEntry` 同一入口）。
///
/// 「查词」本身不受 [ModuleId.lookup] 门控：那个模块只关查词页入口，不关查词能力
/// （见 `module_id.dart`）。
List<CtlRoute> buildDictionaryCtlRoutes(DesktopCtlContext context) {
  final _CtlDictionaryUpdateJobs jobs = _CtlDictionaryUpdateJobs();
  AppModel app() => context.appModel;
  BaseAnkiRepository anki() => context.ref.read(ankiRepositoryProvider);

  return <CtlRoute>[
    // ── 词典仓库 ────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/dictionaries', (CtlCall call) async {
      final String? type = call.optString('type');
      final List<Dictionary> sorted = ctlSortedDictionaries(app().dictionaries);
      return <String, Object?>{
        'dictionaries': <Map<String, Object?>>[
          for (final Dictionary d in sorted)
            if (type == null || d.type.name == type) ctlDictionaryJson(d),
        ],
      };
    }),
    CtlRoute.put('/api/admin/dictionaries/:name', (CtlCall call) async {
      final AppModel model = app();
      final Dictionary target = resolveCtlDictionary(
        model.dictionaries,
        call.params['name']!,
      );
      final bool? enabled = call.optBool('enabled');
      final int? position = call.optInt('position');
      if (enabled == null && position == null) {
        throw const CtlFailure.badRequest('至少给 enabled 或 position 之一');
      }
      if (enabled != null &&
          enabled == target.isHidden(JapaneseLanguage.instance)) {
        // 词典管理页的开关同一入口：toggle 内部持久化 + 引擎重载 + 清查词缓存。
        model.toggleDictionaryHidden(target);
      }
      if (position != null) {
        if (position < 1) throw const CtlFailure.badRequest('position 从 1 起算');
        // 与词典管理页 `_reorderDictionaries` 同语义：同类型分区内移动后整组改 order。
        model.updateDictionaryOrder(
          ctlReorderDictionaries(
            _dictionariesOfType(model, target.type),
            target,
            position,
          ),
        );
      }
      return ctlDictionaryJson(target);
    }),
    CtlRoute.delete('/api/admin/dictionaries/:name', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('删除词典需要 confirm=true');
      }
      final AppModel model = app();
      final Dictionary target = resolveCtlDictionary(
        model.dictionaries,
        call.params['name']!,
      );
      if (model.dictionaryDownloadController.isBusy) {
        throw const CtlFailure.conflict('词典正在下载 / 导入，稍后再删');
      }
      // deleteDictionary 内部吞异常并弹 toast，这里按删后状态判定成败。
      await model.deleteDictionary(target);
      final bool stillThere = model.dictionaries.any(
        (Dictionary d) => d.name == target.name,
      );
      if (stillThere) {
        throw CtlFailure.conflict('词典「${target.name}」删除失败，详见 app 错误日志');
      }
      return <String, Object?>{'deleted': target.name};
    }),
    CtlRoute.post('/api/admin/dictionaries/import', (CtlCall call) async {
      final List<String> paths = call.stringList('paths');
      if (paths.isEmpty) throw const CtlFailure.badRequest('paths 缺失');
      return _importDictionaries(app(), paths);
    }),
    CtlRoute.post('/api/admin/dictionaries/update', (CtlCall call) async {
      return jobs.start(
        app(),
        call.stringList('names'),
        wait: call.optBool('wait') ?? false,
      );
    }),
    CtlRoute.get('/api/admin/dictionaries/job', (CtlCall call) async {
      return jobs.status(app().dictionaryDownloadController);
    }),
    CtlRoute.post('/api/admin/dictionaries/job/cancel', (CtlCall call) async {
      final DictionaryDownloadController controller =
          app().dictionaryDownloadController;
      if (!controller.isBusy) {
        throw const CtlFailure.conflict('没有正在进行的词典任务');
      }
      if (!controller.canCancel) {
        throw const CtlFailure.conflict('任务已进入导入阶段，不能取消');
      }
      controller.requestCancel();
      return <String, Object?>{'cancelRequested': true};
    }),
    CtlRoute.get('/api/admin/dictionaries/search', (CtlCall call) async {
      final String term = call.requireString('term');
      final int limit = call.optInt('limit') ?? 10;
      if (limit < 1) throw const CtlFailure.badRequest('limit 必须 ≥ 1');
      // 与浏览器扩展 `/api/lookup/dictionary`（buildRemoteDictionaryLookupResponse）
      // 同一个查词服务：同一套清洗 / 缓存 / 隐藏词典过滤，只是不要 popupJson。
      final DictionarySearchResult? result = await app()
          .createRemoteLookupService()
          .searchDictionary(
            term: term,
            wildcards: call.optBool('wildcards') ?? false,
            maximumTerms: limit,
          );
      return ctlSearchResultJson(
        term,
        result,
        maxMeaningChars: call.optInt('maxMeaningChars') ?? 0,
      );
    }),

    // ── Anki ────────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/anki', (CtlCall call) async {
      final AppModel model = app();
      final BaseAnkiRepository repo = anki();
      final AnkiSettings settings = await repo.loadSettings();
      final bool probe = call.optBool('probe') ?? true;
      final AnkiFetchResult? fetch = probe
          ? await repo.fetchConfiguration()
          : null;
      final PlatformServices services = model.platformServices;
      final String backend = _ankiBackendName(services);
      final AnkiSyncSession? session = services.useAnkiSyncClient
          ? services.ankiSyncSession
          : null;
      return <String, Object?>{
        'backend': backend,
        'mineToServer': model.mineToServerEnabled,
        'configured': settings.isConfigured,
        'deck': settings.selectedDeckName,
        'model': settings.selectedNoteTypeName,
        'allowDuplicates': settings.allowDupes,
        if (backend == 'ankiConnect')
          'ankiConnect': <String, Object?>{
            'host': settings.ankiConnectHost,
            'port': settings.ankiConnectPort,
            'https': settings.ankiConnectUseHttps,
            // 只报「设没设」，绝不回显 key 本身。
            'apiKeySet': settings.ankiConnectApiKey.isNotEmpty,
          },
        if (session != null) 'sync': _ankiSyncStateJson(session.state),
        'probed': probe,
        if (fetch is AnkiFetchSuccess) ...<String, Object?>{
          'available': true,
          'deckCount': fetch.decks.length,
          'modelCount': fetch.noteTypes.length,
        },
        if (fetch is AnkiFetchError) ...<String, Object?>{
          'available': false,
          'error': AnkiViewModel.localizeAnkiFetchError(
            fetch.message,
            fetch.code,
          ),
        },
      };
    }),
    CtlRoute.get('/api/admin/anki/decks', (CtlCall call) async {
      final BaseAnkiRepository repo = anki();
      final AnkiFetchSuccess fetched = await _fetchAnkiConfiguration(repo);
      return <String, Object?>{
        'decks': ctlAnkiDecksJson(fetched.decks, await repo.loadSettings()),
      };
    }),
    CtlRoute.get('/api/admin/anki/models', (CtlCall call) async {
      final BaseAnkiRepository repo = anki();
      final AnkiFetchSuccess fetched = await _fetchAnkiConfiguration(repo);
      return <String, Object?>{
        'models': ctlAnkiModelsJson(
          fetched.noteTypes,
          await repo.loadSettings(),
        ),
      };
    }),
    CtlRoute.put('/api/admin/anki/settings', (CtlCall call) async {
      final String? deckName = call.optString('deck');
      final String? modelName = call.optString('model');
      if (deckName == null && modelName == null) {
        throw const CtlFailure.badRequest('至少给 deck 或 model 之一');
      }
      final AnkiFetchSuccess fetched = await _fetchAnkiConfiguration(anki());
      // 与 Anki 设置页的下拉同一入口（selectDeck / selectNoteType；后者会按 Lapis
      // 预设重置字段映射，与设置页行为一致）。
      final AnkiViewModel viewModel = context.ref.read(
        ankiViewModelProvider.notifier,
      );
      if (deckName != null) {
        final AnkiDeck? deck = _byName(
          fetched.decks,
          deckName,
          (AnkiDeck d) => d.name,
        );
        if (deck == null) throw CtlFailure.notFound('Anki 里没有牌组「$deckName」');
        await viewModel.selectDeck(deck);
      }
      if (modelName != null) {
        final AnkiNoteType? type = _byName(
          fetched.noteTypes,
          modelName,
          (AnkiNoteType t) => t.name,
        );
        if (type == null) {
          throw CtlFailure.notFound('Anki 里没有笔记类型「$modelName」');
        }
        await viewModel.selectNoteType(type);
      }
      final AnkiSettings settings = await anki().loadSettings();
      return <String, Object?>{
        'deck': settings.selectedDeckName,
        'model': settings.selectedNoteTypeName,
      };
    }),
    CtlRoute.post('/api/admin/anki/mine', (CtlCall call) async {
      final String word = call.requireString('word');
      final String? reading = call.optString('reading');
      final String? glossary = call.optString('glossary');
      final bool lookup = call.optBool('lookup') ?? true;
      DictionarySearchResult? found;
      if (lookup && (reading == null || glossary == null)) {
        found = await app().createRemoteLookupService().searchDictionary(
          term: word,
          wildcards: false,
          maximumTerms: 10,
        );
      }
      final Map<String, String> fields = buildCtlMineFields(
        word: word,
        reading: reading,
        sentence: call.optString('sentence'),
        glossary: glossary,
        extra: _stringMap(call.body['fields']),
        lookup: found,
        allowDuplicate: call.optBool('allowDuplicate') ?? false,
      );
      final String? source = call.optString('source');
      // 与查词页「+」（dictionary_page_mixin.onMineEntry）同一 repo.mineEntry；
      // 结果分类与浏览器扩展 /api/mine 同一个 remoteMineResultFromOutcome。
      final MineOutcome outcome = await anki().mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: AnkiMiningContext(
          sentence: fields['sentence'] ?? '',
          documentTitle: source,
          source: AnkiMiningSource.book,
        ),
      );
      final RemoteMineResult view = remoteMineResultFromOutcome(outcome);
      return <String, Object?>{
        'ok':
            outcome.result == MineResult.success ||
            outcome.result == MineResult.queued,
        'result': outcome.result.name,
        if (outcome.noteId != null) 'noteId': outcome.noteId,
        if (outcome.deckName != null) 'deckName': outcome.deckName,
        if (view.message != null) 'message': view.message,
        if (view.detail != null) 'detail': view.detail,
        'expression': fields['expression'],
        'reading': fields['reading'],
        'glossaryFilled': (fields['glossary'] ?? '').isNotEmpty,
      };
    }),
    CtlRoute.get('/api/admin/anki/duplicate', (CtlCall call) async {
      final String expression = call.requireString('expression');
      final String reading = call.optString('reading') ?? '';
      // 与扩展 /api/duplicate、查词页 checkDuplicate 同一 repo.isDuplicate。
      final bool duplicate = await anki().isDuplicate(expression, reading);
      return <String, Object?>{
        'expression': expression,
        'reading': reading,
        'duplicate': duplicate,
      };
    }),
    CtlRoute.post('/api/admin/anki/sync', (CtlCall call) async {
      final PlatformServices services = app().platformServices;
      final AnkiSyncSession? session = services.useAnkiSyncClient
          ? services.ankiSyncSession
          : null;
      if (session == null) {
        throw const CtlFailure.unsupported(
          '当前 Anki 后端不是「Anki 同步客户端」，没有可触发的同步；AnkiConnect 请在 Anki 桌面端同步',
        );
      }
      try {
        return _ankiSyncStateJson(await session.syncNow());
      } on AnkiSyncNotSignedIn {
        throw const CtlFailure.rejected('Anki 同步客户端未登录，请先在设置 › Anki 里登录');
      } on AnkiSyncHasUnsyncedNotes catch (e) {
        throw CtlFailure.conflict('还有 ${e.count} 张卡未同步，操作被拒绝');
      }
    }),
  ];
}

// ── 词典导入 ──────────────────────────────────────────────────────────────

/// 与词典管理页「导入词典」（`_importDictionaryPaths`）同一拆分：`.css` 作为样式附件，
/// 其余逐个经 [AppModel.importDictionary]；目录走 [AppModel.importDictionaryFromDirectory]。
/// 整批跑在 [DictionaryDownloadController] 的互斥 `run` 里（与「从文件覆盖更新」同款），
/// 避免与在线更新共用 `import_temp` 暂存目录互相踩。
Future<Map<String, Object?>> _importDictionaries(
  AppModel model,
  List<String> paths,
) async {
  final List<File> cssFiles = <File>[];
  final List<FileSystemEntity> packages = <FileSystemEntity>[];
  for (final String raw in paths) {
    final FileSystemEntityType kind = FileSystemEntity.typeSync(raw);
    if (kind == FileSystemEntityType.notFound) {
      throw CtlFailure.notFound('文件不存在：$raw');
    }
    if (kind == FileSystemEntityType.directory) {
      packages.add(Directory(raw));
    } else if (raw.toLowerCase().endsWith('.css')) {
      cssFiles.add(File(raw));
    } else {
      packages.add(File(raw));
    }
  }
  if (packages.isEmpty) {
    throw const CtlFailure.badRequest('没有可导入的词典包（只给了 .css）');
  }
  final DictionaryDownloadController controller =
      model.dictionaryDownloadController;
  if (controller.isBusy) {
    throw const CtlFailure.conflict('已有词典下载 / 导入任务在进行（fushi_cli dict job 查看）');
  }
  final Set<String> before = model.dictionaries
      .map((Dictionary d) => d.name)
      .toSet();
  final List<Map<String, Object?>> results = <Map<String, Object?>>[];
  bool memoryError = false;
  final bool ran = await controller.run(
    initialMessage: packages.first.path,
    body: (DictionaryDownloadJob job) async {
      job.markImportPhase();
      for (final FileSystemEntity entity in packages) {
        final Set<String> namesBefore = model.dictionaries
            .map((Dictionary d) => d.name)
            .toSet();
        try {
          if (entity is Directory) {
            await model.importDictionaryFromDirectory(
              directory: entity,
              progressNotifier: job.message,
              countNotifier: ValueNotifier<int?>(null),
              totalNotifier: ValueNotifier<int?>(null),
              onImportSuccess: () {},
              onMemoryError: () => memoryError = true,
            );
          } else {
            await model.importDictionary(
              file: entity as File,
              progressNotifier: job.message,
              cssFiles: cssFiles,
              onImportSuccess: () {},
              onMemoryError: () => memoryError = true,
            );
          }
          final List<String> added = model.dictionaries
              .map((Dictionary d) => d.name)
              .where((String n) => !namesBefore.contains(n))
              .toList();
          results.add(<String, Object?>{
            'path': entity.path,
            'ok': true,
            'added': added,
            // 同名已存在时导入管理器按「已是最新」跳过，不算失败。
            if (added.isEmpty) 'message': job.message.value,
          });
        } catch (e, stack) {
          ErrorLogService.instance.log('CtlDictionaryImport', e, stack);
          results.add(<String, Object?>{
            'path': entity.path,
            'ok': false,
            'error': '$e',
          });
        }
      }
      // 结果交回 CLI，不在 app 里再弹汇总 toast。
      return null;
    },
  );
  if (!ran) {
    throw const CtlFailure.conflict('已有词典下载 / 导入任务在进行（fushi_cli dict job 查看）');
  }
  final List<String> added = model.dictionaries
      .map((Dictionary d) => d.name)
      .where((String n) => !before.contains(n))
      .toList();
  return <String, Object?>{
    'ok': results.every((Map<String, Object?> r) => r['ok'] == true),
    'added': added,
    'results': results,
    if (memoryError) 'memoryError': true,
  };
}

// ── 在线更新（后台任务） ──────────────────────────────────────────────────

/// `dict update` 的后台任务记录。词典下载控制器本身是互斥的（同时最多一个任务），
/// 这里只额外记住「最近一次 CLI 发起的更新」的逐本结果，供 `dict job` 查询。
class _CtlDictionaryUpdateJobs {
  int _nextId = 1;
  Map<String, Object?>? _last;

  Future<Map<String, Object?>> start(
    AppModel model,
    List<String> names, {
    required bool wait,
  }) async {
    final List<Dictionary> targets;
    if (names.isEmpty) {
      targets = model.dictionaries
          .where((Dictionary d) => d.isUpdatable)
          .toList();
    } else {
      targets = <Dictionary>[
        for (final String n in names)
          resolveCtlDictionary(model.dictionaries, n),
      ];
      final List<String> offline = targets
          .where((Dictionary d) => !d.isUpdatable)
          .map((Dictionary d) => d.name)
          .toList();
      if (offline.isNotEmpty) {
        throw CtlFailure.rejected(
          '这些词典没有在线来源，不能在线更新：${offline.join('、')}（可用 dict import 覆盖）',
        );
      }
    }
    if (targets.isEmpty) {
      return <String, Object?>{'started': false, 'message': '没有可在线更新的词典'};
    }
    final DictionaryDownloadController controller =
        model.dictionaryDownloadController;
    if (controller.isBusy) {
      throw const CtlFailure.conflict(
        '已有词典下载 / 导入任务在进行（fushi_cli dict job 查看）',
      );
    }
    final int id = _nextId++;
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    final Map<String, Object?> record = <String, Object?>{
      'id': id,
      'startedAt': DateTime.now().millisecondsSinceEpoch,
      'finished': false,
      'targets': <String>[for (final Dictionary d in targets) d.name],
      'results': results,
    };
    _last = record;
    final Future<bool> run = controller.run(
      initialMessage: targets.first.effectiveDisplayName,
      body: (DictionaryDownloadJob job) async {
        try {
          for (final Dictionary dictionary in targets) {
            if (job.isCancelled) {
              results.add(_updateResult(dictionary, 'cancelled'));
              continue;
            }
            results.add(await _updateOne(model, dictionary, job));
          }
        } finally {
          record['finished'] = true;
          record['finishedAt'] = DateTime.now().millisecondsSinceEpoch;
        }
        return null;
      },
    );
    if (wait) {
      await run;
      return record;
    }
    unawaited(
      run.catchError((Object e, StackTrace stack) {
        ErrorLogService.instance.log('CtlDictionaryUpdate', e, stack);
        record['finished'] = true;
        record['error'] = '$e';
        return false;
      }),
    );
    return <String, Object?>{'started': true, ...record};
  }

  /// 单本：与词典管理页「更新」按钮（`_updateSingleDictionary`）同一判定——拉远端
  /// index 比 revision，有新版才经 [AppModel.redownloadAndReimportDictionary]
  /// 下载并以这本为显式替换目标重导。
  Future<Map<String, Object?>> _updateOne(
    AppModel model,
    Dictionary dictionary,
    DictionaryDownloadJob job,
  ) async {
    try {
      job.markDownloadPhase();
      job.message.value = dictionary.effectiveDisplayName;
      final DictionaryRemoteIndexResult remote =
          await DictionaryUpdateService.fetchRemoteIndexResult(
            dictionary.indexUrl,
          );
      if (!remote.succeeded) return _updateResult(dictionary, 'checkFailed');
      if (!DictionaryUpdateService.needsUpdate(
        dictionary.revision,
        remote.revision,
      )) {
        return _updateResult(dictionary, 'latest');
      }
      await model.redownloadAndReimportDictionary(dictionary, remote, job);
      return _updateResult(dictionary, 'updated', revision: remote.revision);
    } catch (e, stack) {
      if (DictionaryDownloadController.isCancellation(e)) {
        return _updateResult(dictionary, 'cancelled');
      }
      ErrorLogService.instance.log('CtlDictionaryUpdate.one', e, stack);
      return _updateResult(dictionary, 'failed', error: '$e');
    }
  }

  Map<String, Object?> _updateResult(
    Dictionary dictionary,
    String status, {
    String? revision,
    String? error,
  }) => <String, Object?>{
    'name': dictionary.name,
    'status': status,
    'from': dictionary.revision,
    if (revision != null) 'to': revision,
    if (error != null) 'error': error,
  };

  Map<String, Object?> status(
    DictionaryDownloadController controller,
  ) => <String, Object?>{
    'busy': controller.isBusy,
    'phase': controller.phase.value.name,
    'message': controller.message.value,
    if (controller.detail.value.isNotEmpty) 'detail': controller.detail.value,
    'progress': controller.progress.value,
    'cancellable': controller.canCancel,
    'last': _last,
  };
}

// ── 小工具 ────────────────────────────────────────────────────────────────

List<Dictionary> _dictionariesOfType(AppModel model, DictionaryType type) =>
    switch (type) {
      DictionaryType.term => model.termDictionaries,
      DictionaryType.kanji => model.kanjiDictionaries,
      DictionaryType.frequency => model.freqDictionaries,
      DictionaryType.pitch => model.pitchDictionaries,
    };

String _ankiBackendName(PlatformServices services) {
  if (services.useAnkiSyncClient) return 'ankiSyncClient';
  if (services.isDesktop || services.useAnkiConnectOnMobile) {
    return 'ankiConnect';
  }
  return services.isIOS ? 'ankiMobile' : 'ankiDroid';
}

Map<String, Object?> _ankiSyncStateJson(AnkiSyncState state) =>
    <String, Object?>{
      'phase': state.phase.name,
      'unsynced': state.unsynced,
      'failing': state.failing,
      if (state.lastSyncAt != null) 'lastSyncAt': state.lastSyncAt,
      if (state.lastError != null) 'lastError': state.lastError,
      if (state.message != null) 'message': state.message,
    };

/// 拉 Anki 实时配置（与设置页「刷新」同一个 fetchConfiguration）；不可用抛 422。
Future<AnkiFetchSuccess> _fetchAnkiConfiguration(
  BaseAnkiRepository repo,
) async {
  final AnkiFetchResult result = await repo.fetchConfiguration();
  return switch (result) {
    AnkiFetchSuccess() => result,
    AnkiFetchError(:final String message, :final String? code) =>
      throw CtlFailure.rejected(
        'Anki 不可用：${AnkiViewModel.localizeAnkiFetchError(message, code)}',
      ),
  };
}

T? _byName<T>(List<T> items, String name, String Function(T) nameOf) {
  for (final T item in items) {
    if (nameOf(item) == name) return item;
  }
  final String lower = name.toLowerCase();
  for (final T item in items) {
    if (nameOf(item).toLowerCase() == lower) return item;
  }
  return null;
}

Map<String, String> _stringMap(Object? raw) {
  if (raw == null) return const <String, String>{};
  if (raw is! Map) throw const CtlFailure.badRequest('fields 必须是对象');
  return <String, String>{
    for (final MapEntry<Object?, Object?> e in raw.entries)
      if (e.key != null && e.value != null) '${e.key}': '${e.value}',
  };
}
