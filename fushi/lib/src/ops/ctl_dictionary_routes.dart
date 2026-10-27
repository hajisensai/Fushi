import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show PendingMineRow, PendingMineStatus;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/recommended_dictionary_installer.dart';
import 'package:fushi/src/ops/ctl_dictionary_json.dart';
import 'package:fushi/src/ops/ctl_dictionary_pack_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
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
List<CtlRoute> buildDictionaryCtlRoutes(OpContext context) {
  final _CtlDictionaryUpdateJobs jobs = _CtlDictionaryUpdateJobs();
  AppModel app() => context.appModel;
  BaseAnkiRepository anki() => context.ref.read(ankiRepositoryProvider);

  return <CtlRoute>[
    ...buildDictionaryPackCtlRoutes(context),
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
      final String? displayName = call.optString('displayName');
      final bool resetDisplayName = call.optBool('resetDisplayName') ?? false;
      final String? language = call.optString('language');
      // 混合词典的汉字部分（BUG-3573）：「汉字」分区里的开关与位置，与上面两项互不影响。
      final bool? kanjiEnabled = call.optBool('kanjiEnabled');
      final int? kanjiPosition = call.optInt('kanjiPosition');
      ctlCheckKanjiPartParams(
        target,
        kanjiEnabled: kanjiEnabled,
        kanjiPosition: kanjiPosition,
      );
      if (displayName != null && resetDisplayName) {
        throw const CtlFailure.badRequest(
          'displayName 与 resetDisplayName 不能同时给',
        );
      }
      if (enabled == null &&
          position == null &&
          displayName == null &&
          !resetDisplayName &&
          language == null &&
          kanjiEnabled == null &&
          kanjiPosition == null) {
        throw const CtlFailure.badRequest(
          '至少给 enabled / position / kanjiEnabled / kanjiPosition / '
          'displayName / resetDisplayName / language 之一',
        );
      }
      if (displayName != null || resetDisplayName) {
        // 词典管理页「重命名」同一入口（空 / 等于真名 = 清掉覆盖；同时清查词缓存）。
        await model.setDictionaryDisplayName(
          resolveCtlDictionary(model.dictionaries, target.name),
          resetDisplayName ? null : displayName,
        );
      }
      if (language != null) {
        // 词典管理页「内容语言」同一入口；null = 恢复自动（读包内 index.json 声明）。
        await model.setDictionaryLanguageOverride(
          resolveCtlDictionary(model.dictionaries, target.name),
          ctlParseLanguageOverride(language),
        );
      }
      if (enabled != null &&
          enabled == target.isHidden(JapaneseLanguage.instance)) {
        // 词典管理页的开关同一入口：toggle 内部持久化 + 引擎重载 + 清查词缓存。
        // 必须 await：写入失败要回给 HTTP 调用方，而不是漏成没人接的异步错误。
        await model.toggleDictionaryHidden(target);
      }
      if (position != null) {
        if (position < 1) throw const CtlFailure.badRequest('position 从 1 起算');
        // 与词典管理页 `_reorderDictionaries` 同语义：同类型分区内移动后整组改 order。
        // 「汉字」分区还含混合词典的汉字部分（BUG-3573），位置要按该分区数、写入
        // 走分区专用的 updateKanjiSectionOrder，否则纯 kanji 词典的 order 与混合
        // 词典的 kanjiOrder 各排各的。
        final List<Dictionary> reordered = ctlReorderDictionaries(
          _dictionariesOfType(model, target.type),
          target,
          position,
        );
        if (target.type == DictionaryType.kanji) {
          await model.updateKanjiSectionOrder(reordered);
        } else {
          await model.updateDictionaryOrder(reordered);
        }
      }
      if (kanjiEnabled != null) {
        // 词典管理页「汉字」分区开关同一入口（只写 kanjiHidden，术语部分不动）。
        await model.setDictionaryKanjiPartHidden(
          resolveCtlDictionary(model.dictionaries, target.name),
          !kanjiEnabled,
        );
      }
      if (kanjiPosition != null) {
        // 「汉字」分区重排同一入口：混合词典只写 kanjiOrder，纯 kanji 词典写 order。
        final Dictionary current = resolveCtlDictionary(
          model.dictionaries,
          target.name,
        );
        await model.updateKanjiSectionOrder(
          ctlReorderDictionaries(
            model.kanjiSectionDictionaries,
            current,
            kanjiPosition,
            section: DictionaryType.kanji,
          ),
        );
      }
      // `model.dictionaries` 借出的是拷贝、提交成功后才发布新状态：回的必须是
      // 提交后重新取的那本，而不是改之前借出的 [target]。
      return ctlDictionaryJson(
        resolveCtlDictionary(model.dictionaries, target.name),
      );
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
    CtlRoute.get('/api/admin/dictionaries/recommended', (CtlCall call) async {
      final AppModel model = app();
      final _RecommendedCatalog view = _recommendedCatalog(model, call);
      return <String, Object?>{
        'learning': view.learning,
        'gloss': view.gloss,
        'recommended': <Map<String, Object?>>[
          for (int i = 0; i < view.catalog.length; i++)
            ctlRecommendedDictionaryJson(
              view.catalog[i],
              index: i,
              installed: isRecommendedDictionaryInstalled(
                model.dictionaries,
                view.catalog[i],
              ),
              isDefault: view.defaults.contains(i),
            ),
        ],
      };
    }),
    CtlRoute.post('/api/admin/dictionaries/install', (CtlCall call) async {
      final AppModel model = app();
      final _RecommendedCatalog view = _recommendedCatalog(model, call);
      final List<String> keys = call.stringList('names');
      final bool useDefaults = call.optBool('defaults') ?? false;
      if (keys.isEmpty && !useDefaults) {
        throw const CtlFailure.badRequest(
          '至少给 names，或 defaults=true 装默认勾选的那几本',
        );
      }
      final List<RecommendedDictionary> picked = <RecommendedDictionary>[
        if (useDefaults)
          for (final int i in (view.defaults.toList()..sort())) view.catalog[i],
        for (final String key in keys)
          resolveCtlRecommendedDictionary(view.catalog, key),
      ];
      // 去重（defaults 与 names 可能重叠），保持先后顺序。
      final Set<String> seen = <String>{};
      final List<RecommendedDictionary> targets = <RecommendedDictionary>[
        for (final RecommendedDictionary r in picked)
          if (seen.add(r.matchPrefix)) r,
      ];
      return jobs.startInstall(
        model,
        targets,
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
      // `language`（可选）：调用方的查词语言，与扩展 / 对端同一分派点；缺省按本机
      // 当前查词语言。
      final DictionarySearchResult? result =
          await searchRemoteDictionaryForRequest(
            app().createRemoteLookupService(),
            term: term,
            wildcards: call.optBool('wildcards') ?? false,
            maximumTerms: limit,
            language: _ctlLookupLanguage(call),
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
        found = await searchRemoteDictionaryForRequest(
          app().createRemoteLookupService(),
          term: word,
          wildcards: false,
          maximumTerms: 10,
          language: _ctlLookupLanguage(call),
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
    // ── Anki 待发队列（设置 › Anki › 待发卡片页同一份存储 / 同一个补发入口） ──
    CtlRoute.get('/api/admin/anki/pending', (CtlCall call) async {
      final String? status = call.optString('status');
      final List<PendingMineRow> rows = await pendingMineStoreFor(app()).all();
      return <String, Object?>{
        'count': rows.length,
        'pending': <Map<String, Object?>>[
          for (final PendingMineRow r in rows)
            if (status == null || r.status == status) ctlPendingMineJson(r),
        ],
      };
    }),
    CtlRoute.post('/api/admin/anki/pending/send', (CtlCall call) async {
      // 「全部发送」同一个 flush(interactive: true)；给 id 则只发那一张。
      final PendingMiningAnkiRepository repo = _pendingRepo(anki());
      final String? id = call.optString('id');
      final PendingFlushReport report;
      if (id == null) {
        report = await repo.flush(interactive: true);
      } else {
        final PendingMineRow row = resolveCtlPendingMine(
          await repo.store.all(),
          id,
        );
        report = await repo.flushOne(row.id, interactive: true);
      }
      return ctlFlushReportJson(report);
    }),
    CtlRoute.post('/api/admin/anki/pending/discard-failed', (
      CtlCall call,
    ) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('丢弃待发卡需要 confirm=true');
      }
      final PendingMineStore store = pendingMineStoreFor(app());
      final List<PendingMineRow> failed = (await store.all())
          .where((PendingMineRow r) => r.status == PendingMineStatus.failed)
          .toList();
      for (final PendingMineRow row in failed) {
        await store.discard(row);
      }
      return <String, Object?>{'discarded': failed.length};
    }),
    CtlRoute.post('/api/admin/anki/pending/:id/retry', (CtlCall call) async {
      // 页面「重试」= store.retry（failed -> pending）；CLI 要拿到最终结果，
      // 重置后立即补发这一张。
      final PendingMiningAnkiRepository repo = _pendingRepo(anki());
      final PendingMineRow row = resolveCtlPendingMine(
        await repo.store.all(),
        call.params['id']!,
      );
      if (row.status == PendingMineStatus.sending) {
        throw const CtlFailure.conflict('这张卡正在发送中');
      }
      await repo.store.retry(row.id);
      final PendingFlushReport report = await repo.flushOne(
        row.id,
        interactive: true,
      );
      final PendingMineRow? after = await repo.store.byId(row.id);
      return <String, Object?>{
        ...ctlFlushReportJson(report),
        // 补发后这张卡还在队列里（失败 / 不可达）就带上最新状态，送达则省略。
        if (after != null) 'row': ctlPendingMineJson(after),
      };
    }),
    CtlRoute.delete('/api/admin/anki/pending/:id', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('丢弃待发卡需要 confirm=true');
      }
      final PendingMineStore store = pendingMineStoreFor(app());
      final PendingMineRow row = resolveCtlPendingMine(
        await store.all(),
        call.params['id']!,
      );
      if (row.status == PendingMineStatus.sending) {
        throw const CtlFailure.conflict('这张卡正在发送中，稍后再丢弃');
      }
      // 与页面「删除」同一入口。
      await store.discard(row);
      return <String, Object?>{
        'discarded': row.id,
        'expression': row.expression,
      };
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
    return _launch(
      model,
      kind: 'update',
      targetNames: <String>[for (final Dictionary d in targets) d.name],
      initialMessage: targets.first.effectiveDisplayName,
      wait: wait,
      work:
          (
            DictionaryDownloadJob job,
            List<Map<String, Object?>> results,
          ) async {
            for (final Dictionary dictionary in targets) {
              if (job.isCancelled) {
                results.add(_updateResult(dictionary, 'cancelled'));
                continue;
              }
              results.add(await _updateOne(model, dictionary, job));
            }
          },
    );
  }

  /// `dict install`：与词典管理页「推荐词典」弹窗同一条下载 + 导入路径
  /// （[downloadAndImportRecommendedDictionary]）。已装的跳过；取消只在两本之间或
  /// 下载阶段生效（导入阶段是不可分割的 FFI 调用）。
  Future<Map<String, Object?>> startInstall(
    AppModel model,
    List<RecommendedDictionary> targets, {
    required bool wait,
  }) {
    return _launch(
      model,
      kind: 'install',
      targetNames: <String>[
        for (final RecommendedDictionary r in targets) r.matchPrefix,
      ],
      initialMessage: targets.first.name,
      wait: wait,
      work:
          (
            DictionaryDownloadJob job,
            List<Map<String, Object?>> results,
          ) async {
            final Directory tempDir = recommendedDictionaryTempDir(model);
            try {
              for (final RecommendedDictionary rec in targets) {
                if (job.isCancelled) {
                  results.add(_installResult(rec, 'cancelled'));
                  continue;
                }
                if (isRecommendedDictionaryInstalled(model.dictionaries, rec)) {
                  results.add(_installResult(rec, 'alreadyInstalled'));
                  continue;
                }
                results.add(await _installOne(model, rec, job, tempDir));
              }
            } finally {
              // 取消 / 失败时一并清掉半个 zip，不留残渣（与词典页同款）。
              if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
            }
          },
    );
  }

  Future<Map<String, Object?>> _launch(
    AppModel model, {
    required String kind,
    required List<String> targetNames,
    required String initialMessage,
    required bool wait,
    required Future<void> Function(
      DictionaryDownloadJob job,
      List<Map<String, Object?>> results,
    )
    work,
  }) async {
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
      'kind': kind,
      'startedAt': DateTime.now().millisecondsSinceEpoch,
      'finished': false,
      'targets': targetNames,
      'results': results,
    };
    _last = record;
    final Future<bool> run = controller.run(
      initialMessage: initialMessage,
      body: (DictionaryDownloadJob job) async {
        try {
          await work(job, results);
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
        ErrorLogService.instance.log('CtlDictionary.$kind', e, stack);
        record['finished'] = true;
        record['error'] = '$e';
        return false;
      }),
    );
    return <String, Object?>{'started': true, ...record};
  }

  /// 单本安装：失败按「下载 / 导入」分阶段归因（与词典页 BUG-2188 同口径）。
  Future<Map<String, Object?>> _installOne(
    AppModel model,
    RecommendedDictionary rec,
    DictionaryDownloadJob job,
    Directory tempDir,
  ) async {
    bool downloaded = false;
    try {
      job.markDownloadPhase();
      job.progress.value = 0;
      job.message.value = rec.name;
      await downloadAndImportRecommendedDictionary(
        appModel: model,
        rec: rec,
        job: job,
        tempDir: tempDir,
        onBytes: (int received, int total) => job.message.value = total > 0
            ? '${rec.name} $received/$total'
            : rec.name,
        onDownloaded: () {
          downloaded = true;
          job.markImportPhase();
          job.progress.value = 0;
          job.message.value = rec.name;
        },
      );
      return _installResult(rec, 'installed');
    } catch (e, stack) {
      if (DictionaryDownloadController.isCancellation(e)) {
        return _installResult(rec, 'cancelled');
      }
      ErrorLogService.instance.log('CtlDictionaryInstall.one', e, stack);
      return _installResult(
        rec,
        'failed',
        stage: downloaded ? 'import' : 'download',
        error: '$e',
      );
    }
  }

  Map<String, Object?> _installResult(
    RecommendedDictionary rec,
    String status, {
    String? stage,
    String? error,
  }) => <String, Object?>{
    'key': rec.matchPrefix,
    'name': rec.name,
    'status': status,
    if (stage != null) 'stage': stage,
    if (error != null) 'error': error,
  };

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

/// 推荐词典目录视图：学习语言 / 释义语言 + 目录 + 默认勾选下标（词典页弹窗同口径）。
class _RecommendedCatalog {
  const _RecommendedCatalog({
    required this.learning,
    required this.gloss,
    required this.catalog,
    required this.defaults,
  });

  final String learning;
  final String gloss;
  final List<RecommendedDictionary> catalog;
  final Set<int> defaults;
}

_RecommendedCatalog _recommendedCatalog(AppModel model, CtlCall call) {
  final String learning = call.optString('learning') ?? 'ja';
  // 释义语言缺省取界面语言，不在支持表里退回英语（与词典页弹窗一致）。
  String gloss = call.optString('gloss') ?? model.appLocale.languageCode;
  if (!DictionaryDownloader.availableLanguages.containsKey(gloss)) {
    if (call.optString('gloss') != null) {
      throw CtlFailure.badRequest('不支持的释义语言：$gloss');
    }
    gloss = 'en';
  }
  if (!DictionaryDownloader.availableLanguages.containsKey(learning)) {
    throw CtlFailure.badRequest('不支持的学习语言：$learning');
  }
  final List<RecommendedDictionary> catalog =
      DictionaryDownloader.catalogForLearningLang(
        learningLang: learning,
        glossLang: gloss,
      );
  final Set<int> defaults =
      DictionaryDownloader.defaultSelectionForLearningLang(
        learningLang: learning,
        glossLang: gloss,
        workingCatalog: catalog,
      );
  return _RecommendedCatalog(
    learning: learning,
    gloss: gloss,
    catalog: catalog,
    defaults: defaults,
  );
}

PendingMiningAnkiRepository _pendingRepo(BaseAnkiRepository repo) {
  if (repo is PendingMiningAnkiRepository) return repo;
  throw const CtlFailure.unsupported('当前制卡链路没有待发队列');
}

List<Dictionary> _dictionariesOfType(AppModel model, DictionaryType type) =>
    switch (type) {
      DictionaryType.term => model.termDictionaries,
      DictionaryType.kanji => model.kanjiSectionDictionaries,
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

/// 控制通道查词请求里调用方声明的查词语言（[kRemoteLookupLanguageField]，查询参数或
/// body 均可）；空 / 缺省为 null，按本机当前查词语言。
String? _ctlLookupLanguage(CtlCall call) =>
    call.optString(kRemoteLookupLanguageField);
