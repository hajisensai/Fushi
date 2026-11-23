/// 漫画有声（演出稿 / AI 标注 / 生成）控制通道路由（CLI：`fushi_cli tts ...`；AI 助手的
/// 描述与撤销见 `op_descriptions_tts.dart`）。条目键一律 `book:<bookKey>`，只认本地漫画卷。
///
/// - 读：演出稿摘要（角色表、行数、未定说话人、要不要重新标注）、某页的行、标注 /
///   生成任务状态、可选的声音；
/// - 写：发起 / 取消标注（进程级 `MangaAnnotateTasks`，复核页同一张表）、改某句、改某
///   角色、单句换种子重生成（并保留）、按角色批量重生成（排进制作队列）、按句换上本地
///   音频（可只预检）、发起 / 取消整卷生成（全应用唯一的制作队列）、导入外部做好的成品
///   清单（`manifest.json`，与漫画卡「导入漫画有声」同一套校验与登记）。批量两项的本体
///   与撤销在 `ctl_tts_batch.dart`；有声漫画导出包的导出 / 导入在
///   `ctl_tts_package_routes.dart`。
///
/// 本卷标注在跑时改演出稿、重生成、发起生成一律 409（复核页同样锁住编辑）。业务与
/// 快照逻辑在 `ctl_tts_support.dart`，路由只做参数与门。
library;

import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_volume_busy.dart'
    show MangaVolumeBusyException;
import 'package:fushi/src/ops/ctl_tts_batch.dart';
import 'package:fushi/src/ops/ctl_tts_package_routes.dart';
import 'package:fushi/src/ops/ctl_tts_support.dart';
import 'package:fushi/src/ops/op_context.dart';

export 'package:fushi/src/ops/ctl_tts_support.dart'
    show kTtsMangaCtlRoot, kTtsVoicesCtlPath;

List<CtlRoute> buildTtsCtlRoutes(OpContext context) =>
    buildTtsCtlRoutesFor(ttsCtlDeps(context));

/// 路由表：依赖按 [deps] 注入，测试不必起真的任务表 / 队列 / 合成。
List<CtlRoute> buildTtsCtlRoutesFor(TtsCtlDeps deps) {
  final _TtsHandlers h = _TtsHandlers(deps);
  const String item = '$kTtsMangaCtlRoot/:key';
  return <CtlRoute>[
    CtlRoute.get(kTtsVoicesCtlPath, h.voices),
    CtlRoute.get(item, h.summary),
    CtlRoute.get('$item/pages/:page', h.page),
    CtlRoute.get('$item/status', h.status),
    CtlRoute.post('$item/annotate', h.annotate),
    CtlRoute.post('$item/annotate/cancel', h.cancelAnnotate),
    CtlRoute.put('$item/lines/:line', h.editLine),
    CtlRoute.post('$item/lines/:line/regenerate', h.regenerate),
    CtlRoute.post('$item/lines/replace', h.replaceLines),
    CtlRoute.put('$item/characters/:name', h.editCharacter),
    CtlRoute.post('$item/characters/:name/regenerate', h.regenerateCharacter),
    CtlRoute.post('$item/render', h.render),
    CtlRoute.post('$item/render/cancel', h.cancelRender),
    CtlRoute.post('$item/import', h.importManifest),
    ...buildTtsPackageCtlRoutes(deps),
  ];
}

class _TtsHandlers {
  _TtsHandlers(this._deps);

  final TtsCtlDeps _deps;

  Future<String> _bookKey(CtlCall call) {
    requireTtsMangaModule(_deps);
    return ttsMangaBookKey(_deps, call.params['key'] ?? '');
  }

  /// 写操作的卷：可写、且没有导出包的导入正占着它（所有写入口都经这里，导入落库时
  /// 标注 / 生成 / 改演出稿 / 换成品一律 409）。
  Future<String> _writableBookKey(CtlCall call) async {
    final String bookKey = await _bookKey(call);
    requireTtsWritable(_deps);
    requireNotImportingPackage(_deps, bookKey);
    return bookKey;
  }

  /// 可选的声音（声音预设 + 声音包参考音频组）与整卷生成的默认声音。
  Future<Object?> voices(CtlCall call) async {
    requireTtsMangaModule(_deps);
    return <String, Object?>{
      'voices': <Map<String, Object?>>[
        for (final TtsVoicePreset v in _deps.voices())
          <String, Object?>{
            'id': v.id,
            'name': v.name,
            'provider': v.providerId,
          },
      ],
      if (_deps.activeVoice() case final String active) 'active': active,
    };
  }

  Future<Object?> summary(CtlCall call) async {
    final String bookKey = await _bookKey(call);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final MangaRenderManifest? manifest = await MangaRenderManifest.load(
      mangaRenderManifestFile(_deps.appModel, bookKey),
    );
    return ttsMangaScriptSummary(volume, rendered: manifest != null);
  }

  Future<Object?> page(CtlCall call) async {
    final String bookKey = await _bookKey(call);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final int page = ttsMangaPageIndex(
      call.params['page'],
      volume.payload.images.length,
    );
    final MangaPageDirective? directive = volume.script.pages[page];
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'page': page + 1,
      'annotated': volume.script.annotatedPages.contains(page),
      'blocks': volume.payload.images[page].blocks.length,
      if (directive?.holdMs != null) 'holdMs': directive!.holdMs,
      if (directive?.leadMs != null) 'leadMs': directive!.leadMs,
      'lines': <Map<String, Object?>>[
        for (final MangaScriptLine l in volume.script.linesOnPage(page))
          ttsMangaLineJson(volume, l),
      ],
    };
  }

  /// 标注与生成任务（没有就是 null）。`taskId` 即条目键。
  Future<Object?> status(CtlCall call) async {
    final String bookKey = await _bookKey(call);
    final MangaAnnotateTask? task = _deps.annotateTasks().taskFor(bookKey);
    final TtsRenderJob? job = _deps.renderQueue().latestFor(bookKey);
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'annotate': task == null ? null : ttsAnnotateTaskJson(task),
      'render': job == null ? null : ttsRenderJobJson(job),
    };
  }

  /// 发起看图标注：`pages`（1 起）只标这些页，不给 = 标还没标过的页（OCR 过期则
  /// 整卷）；`roster` 是否先跑角色表（不给 = 自动）。页图会发给指派给「漫画演出标注」
  /// 的 AI 服务商：本机还没同意过上传时，`consentUpload` = 用户在这里表态同意（写入与
  /// 同意框相同的记录）；没给就 422，绝不在 app 里弹框把调用挂住。
  Future<Object?> annotate(CtlCall call) async {
    final String bookKey = await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    if (!await _deps.hasUploadConsent()) {
      if (call.optBool('consentUpload') != true) {
        throw const CtlFailure.rejected(
          '标注要把页图发给 AI 服务商，本机还没同意过：用户同意后带 consentUpload=true 再发起',
        );
      }
      await _deps.recordUploadConsent();
    }
    final AiProviderConfig? provider = _deps.provider();
    if (provider == null) {
      throw const CtlFailure.rejected('没有指派「漫画演出标注」的 AI 服务商（设置 › AI 里指派）');
    }
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final List<int>? pages = _pages(call, volume.payload.images.length);
    final MangaAnnotateTask task;
    try {
      task = _deps.annotateTasks().start(
        MangaAnnotateRequest.annotate(
          bookKey: bookKey,
          provider: provider,
          pages: pages,
          withRoster: call.optBool('roster'),
        ),
      );
    } on MangaAnnotateBusy {
      throw const CtlFailure.conflict('这一卷正在标注');
    } on MangaVolumeBusyException {
      throw const CtlFailure.conflict('这一卷正在导入有声漫画包，等它结束（tts package-task）');
    }
    watchMangaAnnotateResult(_deps, task);
    return <String, Object?>{
      ...ttsAnnotateTaskJson(task),
      'runId': ttsAnnotateRunId(task),
    };
  }

  List<int>? _pages(CtlCall call, int pageCount) {
    final Object? raw = call.body['pages'];
    if (raw == null) return null;
    if (raw is! List || raw.isEmpty) {
      throw const CtlFailure.badRequest('pages 应为非空的页码数组（1 起）');
    }
    return <int>{
      for (final Object? v in raw) ttsMangaPageIndex(v, pageCount),
    }.toList()..sort();
  }

  Future<Object?> cancelAnnotate(CtlCall call) async {
    final String bookKey = await _bookKey(call);
    final MangaAnnotateTasks tasks = _deps.annotateTasks();
    if (!tasks.isRunning(bookKey)) {
      throw const CtlFailure.notFound('这一卷没有正在跑的标注');
    }
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'cancelled': tasks.cancel(bookKey),
    };
  }

  /// 改一句：`speaker`（角色名 / narrator / unknown；新角色加 `newCharacter`）、
  /// `kind`、`beat`（毫秒）、`position`（页内第几句，1 起）、`say`（整句手填，空串清掉）、
  /// `fixes`（块下标 → 修正后的文字，空串删掉这处修正）。
  Future<Object?> editLine(CtlCall call) async {
    final String bookKey = await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final TtsLineEdit edit = editMangaLine(
      volume,
      call.params['line'] ?? '',
      call.body,
    );
    await mangaAudioScriptStoreFor(_deps.appModel).save(bookKey, volume.script);
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'line': ttsMangaLineJson(volume, edit.line),
      'revision': edit.revision,
      if (edit.addedCharacter != null) 'addedCharacter': edit.addedCharacter,
    };
  }

  /// 改某角色：`rename`（改名 / 合并，只改本卷）、`voice`（声音 id，空 = 清掉这一级
  /// 指派）+ 可选 `kind`（只指派这一类台词）+ `scope`（volume 只这一卷 / series 写系列）。
  /// 名字 `narrator` = 叙述类的声音。
  Future<Object?> editCharacter(CtlCall call) async {
    final String bookKey = await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final TtsCharacterEdit edit = await editMangaCharacter(
      _deps,
      volume,
      call.params['name'] ?? '',
      call.body,
    );
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'name': ttsSpeakerWire(edit.name),
      if (edit.renamedLines > 0) 'renamedLines': edit.renamedLines,
      'revision': edit.revision,
      if (edit.seriesKey != null) 'series': edit.seriesKey,
      if (edit.seriesRevision != null) 'seriesRevision': edit.seriesRevision,
    };
  }

  /// 单句换种子重生成并保留（`seed` 不给 = 随机）。这一句要已经生成过。
  Future<Object?> regenerate(CtlCall call) async {
    final String bookKey = await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    requireNotRendering(_deps, bookKey);
    await requireAppRenderedAudio(_deps, bookKey);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final String? blocker = mangaRenderBlocker(volume);
    if (blocker == 'manga_script_stale') {
      throw const CtlFailure.rejected('OCR 重跑过，演出稿要先重新标注');
    }
    return regenerateAndKeepMangaLine(
      _deps,
      volume,
      lineId: call.params['line'] ?? '',
      seed: call.optInt('seed'),
    );
  }

  /// 按句换上本地音频：`files`（行 ID → 音频绝对路径）或 `mapping`（这样一个 JSON 文件的
  /// 绝对路径），`dryRun` 只预检、返回逐句结果。只改本机生成的成品。
  Future<Object?> replaceLines(CtlCall call) async {
    final bool dryRun = call.optBool('dryRun') ?? false;
    final String bookKey = dryRun
        ? await _bookKey(call)
        : await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    requireNotRendering(_deps, bookKey);
    await requireAppRenderedAudio(_deps, bookKey);
    final Map<String, String> files = await mangaReplaceFilesOf(call.body);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    if (mangaRenderBlocker(volume) == 'manga_script_stale') {
      throw const CtlFailure.rejected('OCR 重跑过，演出稿要先重新标注');
    }
    return replaceMangaLinesWithLocalAudio(
      _deps,
      volume,
      files: files,
      dryRun: dryRun,
    );
  }

  /// 按角色批量重生成：这个角色（`kind` 只要这一类台词）已生成的合成句各换一个新种子，
  /// 排进制作队列；`dryRun` 只列出会重生成 / 跳过的句子。
  Future<Object?> regenerateCharacter(CtlCall call) async {
    final bool dryRun = call.optBool('dryRun') ?? false;
    final String bookKey = dryRun
        ? await _bookKey(call)
        : await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    requireNotRendering(_deps, bookKey);
    await requireAppRenderedAudio(_deps, bookKey);
    final String? kindRaw = call.optString('kind');
    final CastLineKind? kind = kindRaw == null
        ? null
        : CastLineKind.parse(kindRaw.trim());
    if (kindRaw != null && kind == null) {
      throw CtlFailure.badRequest('不认得的台词类型「$kindRaw」');
    }
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    if (mangaRenderBlocker(volume) == 'manga_script_stale') {
      throw const CtlFailure.rejected('OCR 重跑过，演出稿要先重新标注');
    }
    final String name = (call.params['name'] ?? '').trim();
    if (name.isEmpty) throw const CtlFailure.badRequest('缺角色名');
    return regenerateMangaCharacterLines(
      _deps,
      volume,
      name: name,
      kind: kind,
      dryRun: dryRun,
    );
  }

  /// 发起整卷生成（排进制作队列；同一卷已有未结束的任务时返回那个任务）。`voice` =
  /// 没有更细指派时用的声音，不给 = 这卷上次的声音 / 当前朗读声音。
  Future<Object?> render(CtlCall call) async {
    final String bookKey = await _writableBookKey(call);
    requireNotAnnotating(_deps, bookKey);
    final MangaAudioVolume volume = await loadTtsMangaVolume(_deps, bookKey);
    final String? blocker = mangaRenderBlocker(volume);
    if (blocker != null) {
      throw CtlFailure(422, blocker, switch (blocker) {
        'manga_no_pages' => '这一卷没有页',
        'manga_script_empty' => '演出稿里没有要读的句子（先标注：tts annotate）',
        'manga_script_stale' => 'OCR 重跑过，演出稿要先重新标注',
        _ => blocker,
      });
    }
    final String? voiceRaw = call.optString('voice');
    if (voiceRaw != null && !_deps.voiceIds().contains(voiceRaw)) {
      throw CtlFailure.badRequest('没有声音「$voiceRaw」（见 tts voices）');
    }
    final String? voice = voiceRaw ?? _deps.defaultVoiceFor(bookKey);
    if (voice == null) {
      throw const CtlFailure.rejected('没有可用的声音（先在朗读设置里选一个，或给 voice）');
    }
    final TtsRenderQueue queue = _deps.renderQueue();
    final TtsRenderJob? before = queue.latestFor(bookKey);
    final bool pending = before != null && !before.isTerminal;
    final TtsRenderJob job;
    try {
      job = await queue.enqueue(
        bookKey: bookKey,
        title: volume.row.title.isEmpty ? bookKey : volume.row.title,
        presetId: voice,
        kind: TtsRenderJobKind.manga,
      );
    } on TtsRenderRejected {
      throw const CtlFailure.conflict('这一卷正在导入有声漫画包，等它结束（tts package-task）');
    }
    return <String, Object?>{
      'taskId': ttsMangaWireKey(bookKey),
      if (pending) 'alreadyQueued': true,
      'render': ttsRenderJobJson(job),
    };
  }

  Future<Object?> cancelRender(CtlCall call) async {
    final String bookKey = await _bookKey(call);
    final TtsRenderQueue queue = _deps.renderQueue();
    final TtsRenderJob? job = queue.latestFor(bookKey);
    if (job == null || job.isTerminal) {
      throw const CtlFailure.notFound('这一卷没有在排队 / 在跑的生成任务');
    }
    await queue.cancel(job.id);
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'render': ttsRenderJobJson(job),
    };
  }

  /// 导入外部做好的成品清单（`manifest`：`manifest.json` 的绝对路径）：与漫画卡「导入
  /// 漫画有声」同一套校验（结构、页数与 OCR 签名与本卷一致、音频都在）与登记。没过校验
  /// 422（`code` 说明原因，消息带页数 / 缺失文件）；这一卷已有登记的有声成品时要
  /// `confirm=true` 才替换（否则 409 `manga_audio_exists`）。只登记、不复制或删除音频。
  Future<Object?> importManifest(CtlCall call) async {
    final String bookKey = await _writableBookKey(call);
    requireNotRendering(_deps, bookKey);
    final String raw = (call.optString('manifest') ?? '').trim();
    if (raw.isEmpty || !p.isAbsolute(raw)) {
      throw CtlFailure.badRequest(
        'manifest 应为成品清单 manifest.json 的绝对路径，收到「$raw」',
      );
    }
    final File file = File(p.normalize(raw));
    final FushiDatabase db = _deps.appModel.database;
    final MangaAudioManifestCheck check = await checkMangaAudioManifest(
      db,
      bookKey: bookKey,
      manifestFile: file,
    );
    if (check.failure case final MangaAudioImportResult failure) {
      throw _importFailure(failure, check, file);
    }
    final MangaRenderManifest manifest = check.manifest!;
    final AudiobookRow? existing = await db.getAudiobookByBookKey(bookKey);
    // 已登记成品的对齐路径（漫画有声即清单路径）；null = 这一卷还没有有声成品。
    final String? previous =
        existing != null && audiobookRowHasRegistration(existing)
        ? existing.alignmentPath
        : null;
    final bool replaces = previous != null;
    if (replaces && call.optBool('confirm') != true) {
      throw CtlFailure(
        409,
        'manga_audio_exists',
        '这一卷已有有声成品（$previous），导入会替换它：确认后带 confirm=true 再导入',
      );
    }
    await registerMangaAudio(
      db,
      bookKey: bookKey,
      manifestFile: file,
      manifest: manifest,
    );
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'imported': true,
      'manifest': file.absolute.path,
      'pages': manifest.pageCount,
      'lines': manifest.lines.length,
      'durationMs': manifest.lines.fold<int>(
        0,
        (int sum, MangaRenderedLine l) => sum + l.durationMs,
      ),
      'replaced': replaces,
      'previous': ?previous,
      'revision': await audiobookRegistrationRevision(db, bookKey),
    };
  }

  CtlFailure _importFailure(
    MangaAudioImportResult failure,
    MangaAudioManifestCheck check,
    File file,
  ) => switch (failure) {
    MangaAudioImportResult.invalid => CtlFailure(
      422,
      'manga_audio_invalid',
      '读不出成品清单或结构不对：${file.path}',
    ),
    MangaAudioImportResult.pageMismatch => CtlFailure(
      422,
      'manga_audio_page_mismatch',
      '清单 ${check.manifest?.pageCount} 页，这一卷 ${check.volumePages} 页：不是这一卷的成品',
    ),
    MangaAudioImportResult.ocrMismatch => const CtlFailure(
      422,
      'manga_audio_ocr_mismatch',
      '清单记的 OCR 签名与这一卷当前的 OCR 不符（OCR 重跑过），高亮会错位：先按当前 OCR 重新生成',
    ),
    MangaAudioImportResult.missingAudio => CtlFailure(
      422,
      'manga_audio_missing_audio',
      '清单引用的 ${check.missingFiles.length} 个音频文件不存在：'
          '${check.missingFiles.take(5).join('、')}'
          '${check.missingFiles.length > 5 ? ' …' : ''}',
    ),
    MangaAudioImportResult.imported => throw StateError('imported 不是失败'),
  };
}
