import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';

import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show
        audiobookRegistrationRevision,
        captureAudiobookRegistration,
        restoreAudiobookRegistration;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_tts_batch.dart' show revertMangaLineBatch;
import 'package:fushi/src/ops/ctl_tts_support.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 漫画有声（演出稿 / AI 标注 / 生成）的操作描述（路由见 `ctl_tts_routes.dart`）。
///
/// 写操作的撤销（fushi/CLAUDE.md §13）：
/// - 改某句 / 改某角色：执行前给演出稿拍快照（页 / 整份 + 系列声音指派），撤销时
///   演出稿还是改完时的样子才放回，之后被手改过报 superseded；
/// - 发起标注：撤销 = 取消任务（还在跑时）+ 把演出稿与失败账本放回标注前；
/// - 单句重生成：撤销 = 放回旧音频（保留前已备份）、清单 / 演出稿 / 账本恢复；
/// - 按句换本地音频 / 按角色批量重生成：执行前把要动的句子与旧音频备份成一份快照，
///   撤销时逐句核对还是这次改出来的样子才放回（批量重生成还在跑时先取消），之后又被
///   改过的句子不覆盖（partial / superseded）；
/// - 取消整卷生成：撤销 = 重新排上；
/// - 发起整卷生成：生成完成后新音频覆盖旧音频、旧的恢复不了，所以是 irreversible
///   （执行前确认），进行中可用 `tts.manga.render-cancel` 取消；
/// - 取消标注：已标的页保留，没有可恢复的东西，irreversible。
/// - 导入成品清单：执行前给登记（音频 / 对齐四列、整组 cue、断点）拍快照，撤销时登记
///   还是导入后的样子（指纹相同）才放回，之后被重新生成 / 补句 / 再导入改过报
///   superseded。只动登记，不删音频文件。
List<OpDescription> describeTtsOps(OpDescribeKit kit) {
  final OpAvailability Function() manga = kit.whenModule(ModuleId.manga);
  final TtsCtlDeps deps = ttsCtlDeps(kit.context);
  const String item = '$kTtsMangaCtlRoot/:key';

  Future<String> bookKeyOf(CtlCall call) =>
      ttsMangaBookKey(deps, call.params['key'] ?? '');

  Future<OpTaskStatus> statusOf(String taskId, String field) async {
    final Object? raw = await kit.callRoute(
      'GET',
      '$item/status',
      params: <String, String>{'key': taskId},
    );
    final Object? task = raw is Map ? raw[field] : null;
    if (task is! Map) {
      return OpTaskStatus(
        terminal: true,
        summary: '$field task of $taskId is gone',
        data: raw,
      );
    }
    final String status = '${task['status']}';
    final bool terminal = field == 'annotate'
        ? status != 'running'
        : status == TtsRenderJobStatus.done.name ||
              status == TtsRenderJobStatus.failed.name ||
              status == TtsRenderJobStatus.cancelled.name;
    final bool ok = status == (field == 'annotate' ? 'completed' : 'done');
    final Object? error = task['error'];
    return OpTaskStatus(
      terminal: terminal,
      succeeded: terminal && ok,
      summary:
          '$field $status ${task['done']}/${task['total']}'
          '${error == null ? '' : ': $error'}',
      data: task,
    );
  }

  return <OpDescription>[
    OpDescription(
      id: 'tts.voices',
      method: 'GET',
      pattern: kTtsVoicesCtlPath,
      summary:
          'Voices usable for manga audio (voice presets and voice-pack '
          'reference groups): ids for voice assignment and rendering.',
      availability: manga,
    ),
    OpDescription(
      id: 'tts.manga.script',
      method: 'GET',
      pattern: item,
      summary:
          'Manga audio script summary of a local manga volume: cast list with '
          'line counts and voices, line counts, unknown-speaker lines, whether '
          'it must be re-annotated (OCR re-run) and whether audio exists.',
      availability: manga,
      params: const <OpParam>[_keyParam],
    ),
    OpDescription(
      id: 'tts.manga.page',
      method: 'GET',
      pattern: '$item/pages/:page',
      summary:
          'Script lines of one page in reading order (line id, text, speaker, '
          'kind, beat, seed, manual text, review flag).',
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.string(
          'page',
          description: 'Page number, 1-based.',
          required: true,
          inPath: true,
        ),
      ],
    ),
    OpDescription(
      id: 'tts.manga.status',
      method: 'GET',
      pattern: '$item/status',
      summary:
          'Annotation task and render job of a manga volume (null = none).',
      availability: manga,
      params: const <OpParam>[_keyParam],
    ),
    OpDescription(
      id: 'tts.manga.annotate',
      method: 'POST',
      pattern: '$item/annotate',
      summary:
          'Start AI annotation of a manga volume in the background (who speaks '
          'each line, line kind, pacing). Sends page images and OCR text to '
          'the AI provider assigned to manga audio annotation; at least one '
          'image request per page. Undo cancels it and restores the script '
          'from before.',
      risk: OpRisk.write,
      confirm: true,
      longRunning: true,
      taskStatus: (String id) => statusOf(id, 'annotate'),
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.stringList(
          'pages',
          description:
              'Only these page numbers (1-based). Default: pages not '
              'annotated yet (whole volume when OCR changed).',
        ),
        OpParam.boolean(
          'roster',
          description: 'Run the cast-list pass first (default: automatic).',
        ),
        OpParam.userGate(
          'consentUpload',
          description:
              'User agreed to upload manga pages to the AI provider (needed '
              'once per device).',
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async {
          final String bookKey = await bookKeyOf(call);
          return <String, Object?>{
            'bookKey': bookKey,
            ...await captureMangaAnnotateSnapshot(deps, bookKey),
          };
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  'runId': result is Map ? result['runId'] : null,
                },
        describe: (Map<String, Object?> p) =>
            'annotation of ${ttsMangaWireKey('${p['bookKey']}')}',
        revert: (Map<String, Object?> payload) =>
            revertMangaAnnotate(deps, payload),
      ),
    ),
    OpDescription(
      id: 'tts.manga.annotate-cancel',
      method: 'POST',
      pattern: '$item/annotate/cancel',
      summary:
          'Stop the running annotation of a manga volume (pages already '
          'annotated are kept).',
      risk: OpRisk.irreversible,
      availability: manga,
      params: const <OpParam>[_keyParam],
    ),
    OpDescription(
      id: 'tts.manga.line.edit',
      method: 'PUT',
      pattern: '$item/lines/:line',
      summary:
          'Edit one script line: speaker, kind, extra pause after it, its '
          'position on the page, manual text, or OCR typo fixes. The line is '
          'marked as user-edited (kept on re-annotation).',
      risk: OpRisk.write,
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        _lineParam,
        OpParam.string(
          'speaker',
          description:
              'Cast name from tts.manga.script, or narrator / unknown.',
        ),
        OpParam.boolean(
          'newCharacter',
          description: 'speaker is a new character: add it to the cast list.',
        ),
        OpParam.string(
          'kind',
          description: 'Line kind.',
          enumValues: <String>[
            'narration',
            'monologue',
            'thought',
            'spoken',
            'shout',
            'mutter',
            'skip',
          ],
        ),
        OpParam.integer(
          'beat',
          description: 'Extra pause after the line, ms (0-10000).',
        ),
        OpParam.integer(
          'position',
          description: 'New position among the lines of its page, 1-based.',
        ),
        OpParam.string(
          'say',
          description:
              'Text to read instead of the OCR text; empty string clears it.',
        ),
        OpParam.object(
          'fixes',
          description:
              'OCR typo fixes: {block index: corrected text}; an empty text '
              'removes that fix. Block indexes come from the line.',
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async => captureMangaLineSnapshot(
          deps,
          await bookKeyOf(call),
          call.params['line'] ?? '',
        ),
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) 'revision': result['revision'],
                  if (result is Map && result['addedCharacter'] != null)
                    'addedCharacter': result['addedCharacter'],
                },
        describe: (Map<String, Object?> p) =>
            'page ${(p['page'] is int ? p['page']! as int : 0) + 1} of '
            '${ttsMangaWireKey('${p['bookKey']}')}',
        revert: (Map<String, Object?> payload) =>
            revertMangaLineEdit(deps, payload),
      ),
    ),
    OpDescription(
      id: 'tts.manga.character.edit',
      method: 'PUT',
      pattern: '$item/characters/:name',
      summary:
          'Edit a character of a manga volume: rename / merge into another '
          'name (this volume only), and / or assign a voice (all its lines, or '
          'one line kind) for this volume or the whole series. Name narrator = '
          'the narration voice.',
      risk: OpRisk.write,
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.string(
          'name',
          description: 'Cast name, or narrator.',
          required: true,
          inPath: true,
        ),
        OpParam.string(
          'rename',
          description: 'New name (an existing name merges the two).',
        ),
        OpParam.string(
          'voice',
          description:
              'Voice id from tts.voices; empty string clears this assignment.',
        ),
        OpParam.string(
          'kind',
          description: 'Assign the voice only for this line kind.',
          enumValues: <String>[
            'narration',
            'monologue',
            'thought',
            'spoken',
            'shout',
            'mutter',
          ],
        ),
        OpParam.string(
          'scope',
          description:
              'Where the voice assignment goes: volume (default) or series.',
          enumValues: <String>['volume', 'series'],
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async {
          final String bookKey = await bookKeyOf(call);
          final bool series = '${call.body['scope'] ?? ''}'.trim() == 'series';
          return captureMangaCharacterSnapshot(
            deps,
            bookKey,
            series ? await ttsMangaSeriesKey(deps, bookKey) : null,
          );
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) 'revision': result['revision'],
                  if (result is Map && result['seriesRevision'] != null)
                    'seriesRevision': result['seriesRevision'],
                },
        describe: (Map<String, Object?> p) =>
            'cast of ${ttsMangaWireKey('${p['bookKey']}')}',
        revert: (Map<String, Object?> payload) =>
            revertMangaCharacterEdit(deps, payload),
      ),
    ),
    OpDescription(
      id: 'tts.manga.line.regenerate',
      method: 'POST',
      pattern: '$item/lines/:line/regenerate',
      summary:
          'Re-synthesize one already rendered line with another seed and keep '
          'it (same voice). Undo puts the previous audio back.',
      risk: OpRisk.write,
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        _lineParam,
        OpParam.integer(
          'seed',
          description: 'Seed (0-4294967295). Default: random.',
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async {
          final String bookKey = await bookKeyOf(call);
          final String lineId = call.params['line'] ?? '';
          return <String, Object?>{
            'bookKey': bookKey,
            'lineId': lineId,
            ...await captureMangaRegenSnapshot(deps, bookKey, lineId),
          };
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) ...<String, Object?>{
                    'file': result['file'],
                    'seed': result['seed'],
                    'backup': result['backup'],
                  },
                },
        describe: (Map<String, Object?> p) =>
            'line ${p['lineId']} seed ${p['seed']}',
        revert: (Map<String, Object?> payload) =>
            revertMangaRegen(deps, payload),
      ),
    ),
    OpDescription(
      id: 'tts.manga.lines.replace',
      method: 'POST',
      pattern: '$item/lines/replace',
      summary:
          'Replace the audio of already rendered lines with local audio files '
          '(line id -> absolute path; WAV / FLAC / MP3 / M4A / AAC / OGG / '
          'OPUS). Every line is checked first (in the script and the rendered '
          'audio, file exists, known format); dryRun only returns the per-line '
          'check. All-or-nothing: the files are copied into the app, shaped '
          'like the other lines, and the line keeps this audio on later '
          're-renders; audio paths, cue durations and the resume position are '
          'updated for these lines only. Only audio rendered on this device '
          '(not an imported manifest). Undo puts the previous audio back.',
      risk: OpRisk.write,
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.object(
          'files',
          description:
              'Line id (tts.manga.page) -> absolute path of the local audio '
              'file. Give this or mapping.',
        ),
        OpParam.string(
          'mapping',
          description:
              'Absolute path of a JSON file holding the same object (relative '
              'paths in it are resolved against its folder).',
        ),
        OpParam.boolean(
          'dryRun',
          description: 'Only check every line, change nothing.',
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async => <String, Object?>{
          'bookKey': await bookKeyOf(call),
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) 'backup': result['backup'],
                  if (result is Map) 'replaced': result['replaced'],
                },
        describe: (Map<String, Object?> p) =>
            '${p['replaced'] ?? 0} lines of '
            '${ttsMangaWireKey('${p['bookKey']}')} to local audio',
        revert: (Map<String, Object?> payload) =>
            revertMangaLineBatch(deps, payload),
      ),
    ),
    OpDescription(
      id: 'tts.manga.character.regenerate',
      method: 'POST',
      pattern: '$item/characters/:name/regenerate',
      summary:
          'Re-synthesize every already rendered line of one character (only '
          'one line kind with kind) with new seeds, queued as one render '
          'task (same voices; lines from an audiobook or local audio are '
          'skipped; a line that fails keeps its old audio). dryRun only lists '
          'the lines. Undo cancels it while queued / running and puts the '
          'previous audio back.',
      risk: OpRisk.write,
      longRunning: true,
      taskStatus: (String id) => statusOf(id, 'render'),
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.string(
          'name',
          description:
              'Cast name from tts.manga.script, or narrator / unknown.',
          required: true,
          inPath: true,
        ),
        OpParam.string(
          'kind',
          description: 'Only lines of this kind (spoken, thought, ...).',
        ),
        OpParam.boolean(
          'dryRun',
          description: 'Only list the lines, change nothing.',
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async => <String, Object?>{
          'bookKey': await bookKeyOf(call),
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) 'backup': result['backup'],
                  'name': call.params['name'],
                },
        describe: (Map<String, Object?> p) =>
            'regenerate ${p['name']} of ${ttsMangaWireKey('${p['bookKey']}')}',
        revert: (Map<String, Object?> payload) =>
            revertMangaLineBatch(deps, payload),
      ),
    ),
    OpDescription(
      id: 'tts.manga.render',
      method: 'POST',
      pattern: '$item/render',
      summary:
          'Queue rendering the whole manga volume to audio (one file per line, '
          'imported as an audiobook of the manga). Finished audio replaces the '
          'previous audio of the volume and cannot be restored; while it is '
          'still queued / running, tts.manga.render-cancel stops it.',
      risk: OpRisk.irreversible,
      longRunning: true,
      taskStatus: (String id) => statusOf(id, 'render'),
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.string(
          'voice',
          description:
              'Voice id (tts.voices) for lines without a finer assignment. '
              'Default: the voice of the last render, else the active voice.',
        ),
      ],
    ),
    OpDescription(
      id: 'tts.manga.render-cancel',
      method: 'POST',
      pattern: '$item/render/cancel',
      summary:
          'Cancel the queued / running render of a manga volume. Undo queues '
          'it again.',
      risk: OpRisk.write,
      availability: manga,
      params: const <OpParam>[_keyParam],
      undo: kit.inverseRouteUndo(
        payloadOf: (CtlCall call, Object? result) => <String, Object?>{
          'id': result is Map && result['render'] is Map
              ? (result['render']! as Map)['id']
              : null,
        },
        describe: (Map<String, Object?> p) => 'render job ${p['id']}',
        inverse: (Map<String, Object?> payload) async {
          final Object? id = payload['id'];
          if (id == null) throw const CtlFailure.notFound('没有任务 id');
          await deps.renderQueue().retry('$id');
          return null;
        },
      ),
    ),
    OpDescription(
      id: 'tts.manga.import',
      method: 'POST',
      pattern: '$item/import',
      summary:
          'Import a finished manga audio manifest (manifest.json made by an '
          'external pipeline or another device) as the audio of a local manga '
          'volume: same checks as the manga card import (structure, page count '
          'and OCR signature match the volume, every audio file exists). '
          'Replacing audio already registered for the volume needs confirm. '
          'Audio files are referenced in place, not copied. Undo restores the '
          'previous registration.',
      risk: OpRisk.write,
      availability: manga,
      params: const <OpParam>[
        _keyParam,
        OpParam.string(
          'manifest',
          description: 'Absolute path of the manifest.json.',
          required: true,
        ),
        OpParam.userGate(
          'confirm',
          description:
              'User agreed to replace the audio already registered for this '
              'volume (only needed when it has one).',
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async {
          final String bookKey = await bookKeyOf(call);
          return <String, Object?>{
            'bookKey': bookKey,
            'before': await captureAudiobookRegistration(
              deps.appModel.database,
              bookKey,
            ),
          };
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) 'revision': result['revision'],
                  if (result is Map) 'manifest': result['manifest'],
                },
        describe: (Map<String, Object?> p) =>
            'manga audio of ${ttsMangaWireKey('${p['bookKey']}')} '
            'from ${p['manifest']}',
        revert: (Map<String, Object?> payload) async {
          final String bookKey = '${payload['bookKey']}';
          final TtsRenderJob? job = deps.renderQueue().latestFor(bookKey);
          if (job != null && !job.isTerminal) {
            return const OpUndoOutcome.failed('这一卷正在生成，结束后再撤销');
          }
          final String? now = await audiobookRegistrationRevision(
            deps.appModel.database,
            bookKey,
          );
          if (now == null || now != payload['revision']) {
            return const OpUndoOutcome.superseded('导入之后这一卷的有声成品又被改过，没有覆盖');
          }
          final Object? before = payload['before'];
          if (before is! Map) {
            return const OpUndoOutcome.failed('撤销载荷里没有导入前的登记');
          }
          await restoreAudiobookRegistration(
            deps.appModel.database,
            bookKey,
            Map<String, Object?>.from(before),
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  ];
}

const OpParam _keyParam = OpParam.string(
  'key',
  description: 'Manga item key (book:...).',
  required: true,
  inPath: true,
);

const OpParam _lineParam = OpParam.string(
  'line',
  description: 'Line id from tts.manga.page.',
  required: true,
  inPath: true,
);
