// spec 2026-07-10 — the DEFERRED overlay bridge handlers, extracted VERBATIM
// from GlobalLookupController (TODO-617/1188/1225 lineage) so the persistent
// clipboard panel (the second bare-WebView2 window) resolves the same nine
// natively-deferred popup.js bridges (audio ×3, favorite ×2, mine ×2,
// overwrite ×2) through the same authority — never a copy (spec red line: the
// two surfaces must not drift).
//
// Every handler ALWAYS resolves (even on error / no model) so an awaiting
// popup.js button never freezes; replies are pushed through the caller's
// channel-bound [OverlayBridgeResolver] (GlobalLookupChannel.resolveBridge for
// the transient overlay, the panel channel's resolveBridge for the panel).

import 'dart:async';
import 'dart:convert';

import 'package:hibiki/src/lookup/global_lookup_log.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Pushes a deferred-bridge reply back to the owning overlay window's JS realm
/// (window.__hibikiBridgeResolve via the channel's resolveBridge).
typedef OverlayBridgeResolver = Future<void> Function(int id, Object? value);

/// 可选的场景制卡委托。瞬态查词窗仍负责解析 popup.js payload 和统计；委托只替换
/// 最终的创建/覆盖写入，以便 Hook 查词附加精确台词、游戏画面和句子音频。
typedef OverlayMiningHandler = Future<Map<String, Object?>> Function({
  required Map<String, String> fields,
  int? updateNoteId,
});

/// Dispatches [handler] if it is one of the nine natively-DEFERRED bridges.
/// Returns true when handled (the caller's _onJsMessage returns immediately);
/// false = not a deferred bridge, the caller keeps its own dispatch.
///
/// [sentenceContext] is the surface's captured sentence (剪贴板全文 for the
/// clipboard panel, UIA-captured foreground line for the transient overlay). It
/// is the mine/overwrite `{sentence}` fallback: JS `buildMinePayload` never
/// sends a `sentence` field for these app-external surfaces (the source text
/// lives in another app), so without this the mined card's sentence field was
/// always empty. The controller already holds this string for the sentence
/// banner; here it doubles as the mine sentence (per the clipboard-panel spec
/// intent). [resolveMineSentence] still prefers a JS-sent `fields['sentence']`
/// when present, so this is a pure fallback and never overrides real data.
bool maybeHandleOverlayDeferredBridge({
  required AppModel? model,
  required Object? handler,
  required Map<String, Object?> message,
  required OverlayBridgeResolver resolveBridge,
  String sentenceContext = '',
  OverlayMiningHandler? miningHandler,
}) {
  switch (handler) {
    case 'resolveWordAudio':
    case 'queryLocalAudio':
    case 'playWordAudio':
      unawaited(_handleAudioBridge(
          model, handler! as String, message, resolveBridge));
      return true;
    case 'favoriteEntry':
    case 'favoriteCheck':
      unawaited(_handleFavoriteBridge(
          model, handler! as String, message, resolveBridge));
      return true;
    case 'mineEntry':
      unawaited(_handleMineBridge(
        model,
        message,
        resolveBridge,
        sentenceContext,
        miningHandler,
      ));
      return true;
    case 'duplicateCheck':
      unawaited(_handleDuplicateBridge(model, message, resolveBridge));
      return true;
    // BUG-1063 —— app 外「卡已存在」操作面板的两根数据桥。面板本身画在 popup.js
    // 自己的 WebView 里（app 外没有 Flutter 层可以呈现对话框，见文件尾注），Dart
    // 只提供数据与「在 Anki 中打开」这一个副作用；覆写/新增复用既有
    // updateEntry / mineEntry 两根桥，不另开写路径。
    case 'findMinedMatches':
      unawaited(_handleFindMinedMatchesBridge(model, message, resolveBridge));
      return true;
    case 'openMinedNote':
      unawaited(_handleOpenMinedNoteBridge(model, message, resolveBridge));
      return true;
    case 'overwriteTargetNoteId':
      unawaited(_handleOverwriteTargetBridge(model, message, resolveBridge));
      return true;
    case 'updateEntry':
      unawaited(_handleUpdateBridge(
        model,
        message,
        resolveBridge,
        sentenceContext,
        miningHandler,
      ));
      return true;
    default:
      return false;
  }
}

/// The `{sentence}` value for an app-external mine/overwrite: a JS-sent
/// `fields['sentence']` wins when non-empty (future-proof), otherwise the
/// surface's captured [sentenceContext] (剪贴板全文 / UIA 前台句). Pure so the
/// resolution is unit-testable without a live Anki backend or Windows overlay.
String resolveMineSentence(Map<String, String> fields, String sentenceContext) {
  final String fromJs = fields['sentence'] ?? '';
  return fromJs.isNotEmpty ? fromJs : sentenceContext;
}

int? _bridgeIdOf(Map<String, Object?> message) => (message['__bridgeId'] is num)
    ? (message['__bridgeId'] as num).toInt()
    : null;

Map<Object?, Object?> _firstMapArg(Map<String, Object?> message) {
  final Object? args = message['args'];
  return (args is List && args.isNotEmpty && args.first is Map)
      ? (args.first as Map)
      : const <Object?, Object?>{};
}

/// Resolves a deferred audio bridge call and pushes the reply back to the
/// overlay (resolveBridge). Always resolves — even on error / no model — so
/// the awaiting ♪ button never freezes.
Future<void> _handleAudioBridge(
  AppModel? model,
  String handler,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
) async {
  final int? id = _bridgeIdOf(message);
  Object? reply;
  try {
    final Map<Object?, Object?> data = _firstMapArg(message);
    if (model == null) {
      reply = handler == 'playWordAudio' ? false : null;
    } else if (handler == 'playWordAudio') {
      final String url = data['url']?.toString() ?? '';
      final bool ok = url.isEmpty
          ? false
          : await TtsChannel.instance.playAudioRef(
              url,
              volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
            );
      reply = ok;
    } else {
      // resolveWordAudio / queryLocalAudio -> the configured-source URL.
      final String expression = data['expression']?.toString() ?? '';
      final String reading = data['reading']?.toString() ?? '';
      // Diagnostic: which audio sources are configured/enabled? A null reply
      // with 0 enabled sources = nothing to query (config), not a wiring bug.
      glog('audio: resolve "$expression"/"$reading" '
          'enabled=${model.enabledAudioSources} '
          'configs=${model.audioSourceConfigs.length}');
      reply = expression.isEmpty
          ? null
          : await resolveWordAudioWebViewUrl(model, expression, reading);
    }
  } catch (e, st) {
    glog('audio: EXCEPTION $e\n$st');
    reply = handler == 'playWordAudio' ? false : null;
  }
  if (id != null) {
    glog('audio: $handler -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// TODO-1188 — resolves a DEFERRED favorite bridge call (favoriteEntry toggles
/// the FavoriteWords row and returns the NEW state; favoriteCheck just reads
/// the current state) and pushes the resulting bool back to the overlay iframe
/// so popup.js flips the ☆/★ star. Always resolves — even on error / no model.
/// The DB logic mirrors the in-app
/// [DictionaryPageMixin.onFavoriteEntry]/[onFavoriteCheck].
Future<void> _handleFavoriteBridge(
  AppModel? model,
  String handler,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
) async {
  final int? id = _bridgeIdOf(message);
  bool reply = false;
  try {
    final Map<Object?, Object?> data = _firstMapArg(message);
    final String expression = data['expression']?.toString() ?? '';
    final String reading = data['reading']?.toString() ?? '';
    if (model != null && expression.isNotEmpty) {
      reply = await _toggleOrCheckFavorite(
        model,
        toggle: handler == 'favoriteEntry',
        expression: expression,
        reading: reading,
      );
    }
  } catch (e, st) {
    glog('favorite: EXCEPTION $e\n$st');
    reply = false;
  }
  if (id != null) {
    glog('favorite: $handler -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// TODO-1188 — favorite toggle ([toggle] true) or read ([toggle] false)
/// against the FavoriteWords table. Uses [kStatSourceBook] so the
/// (expression, reading, sourceType) uniqueness key is SHARED with in-book
/// favorites (consistent ★ across surfaces). No toast: the main window is
/// backgrounded behind the external app; the star flip is the feedback.
Future<bool> _toggleOrCheckFavorite(
  AppModel model, {
  required bool toggle,
  required String expression,
  required String reading,
}) async {
  final HibikiDatabase db = model.database;
  final bool already = await db.isFavoriteWord(
    expression: expression,
    reading: reading,
    sourceType: kStatSourceBook,
  );
  if (!toggle) {
    return already; // favoriteCheck: report the current state, no write.
  }
  if (already) {
    await db.removeFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: kStatSourceBook,
    );
    return false;
  }
  await db.addFavoriteWord(
    expression: expression,
    reading: reading,
    glossary: '',
    sourceType: kStatSourceBook,
    dateKey: statTodayKey(),
  );
  return true;
}

/// TODO-1188 follow-up — resolves a DEFERRED mineEntry bridge call and pushes
/// the {ankiConnect, noteId} result back so popup.js flips the ➕ button
/// (parseMineResult). Mirrors the in-app [DictionaryPageMixin.onMineEntry].
/// Always resolves — even on error / no model — so ➕ never freezes.
Future<void> _handleMineBridge(
  AppModel? model,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
  String sentenceContext,
  OverlayMiningHandler? miningHandler,
) async {
  final int? id = _bridgeIdOf(message);
  Map<String, Object?> reply = const <String, Object?>{
    'ankiConnect': false,
    'noteId': null,
  };
  try {
    final Map<Object?, Object?> raw = _firstMapArg(message);
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        e.key.toString(): e.value?.toString() ?? '',
    };
    final String expression = fields['expression'] ?? '';
    if (model != null && expression.isNotEmpty) {
      if (miningHandler == null) {
        reply = await _mineEntry(model, fields, sentenceContext);
      } else {
        await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
        reply = await miningHandler(fields: fields);
        if (reply['ankiConnect'] == true) {
          unawaited(
            _recordMinedStats(
              model,
              fields,
              (reply['noteId'] as num?)?.toInt(),
              resolveMineSentence(fields, sentenceContext),
            ),
          );
        }
      }
    }
  } catch (e, st) {
    glog('mine: EXCEPTION $e\n$st');
    reply = const <String, Object?>{'ankiConnect': false, 'noteId': null};
  }
  if (id != null) {
    glog('mine: mineEntry -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// TODO-1188 follow-up — mines [fields] to Anki through the same
/// [BaseAnkiRepository.mineEntry] path the in-app dictionary popup uses,
/// records mined-count + mined-sentence stats on success (source
/// [kStatSourceBook]), and returns the popup.js-shaped {ankiConnect, noteId}
/// reply. Gaiji bytes are flushed to the Anki media cache first
/// ([writeDictionaryMediaCache]) so dictionary media embeds rather than
/// degrading to alt text. App-external lookup has NO screenshot /
/// sentence-audio media context (the source text lives in another app), but the
/// SENTENCE itself is the surface's captured text ([sentenceContext] — 剪贴板全文
/// for the clipboard panel, UIA 前台句 for the transient overlay), resolved via
/// [resolveMineSentence]. `{sentence}` bolds the matched word from
/// `payload.matched`, same as in-app onMineEntry.
Future<Map<String, Object?>> _mineEntry(
  AppModel model,
  Map<String, String> fields,
  String sentenceContext,
) async {
  await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
  final String sentence = resolveMineSentence(fields, sentenceContext);
  final BaseAnkiRepository repo = model.platformServices.createAnkiRepository();
  final MineOutcome outcome = await repo.mineEntry(
    rawPayloadJson: jsonEncode(fields),
    context: AnkiMiningContext(
      sentence: sentence,
      source: AnkiMiningSource.book,
    ),
  );
  // 与 in-app onMineEntry 同判据：仅 MineResult.success 回 ankiConnect=true +
  // noteId（AnkiConnect 非空进「最新可改」态；AnkiDroid 恒 null=优雅降级）。
  final bool success = outcome.result == MineResult.success;
  if (success) {
    unawaited(_recordMinedStats(model, fields, outcome.noteId, sentence));
  }
  return <String, Object?>{
    'ankiConnect': success,
    'noteId': success ? outcome.noteId : null,
  };
}

/// TODO-1188 follow-up — records one mined-count + one mined-sentence history
/// row on a successful app-external mine (source [kStatSourceBook]; no book
/// locator). Best-effort: any failure is logged and swallowed.
Future<void> _recordMinedStats(
  AppModel model,
  Map<String, String> fields,
  int? noteId,
  String sentence,
) async {
  try {
    final HibikiDatabase db = model.database;
    final String dateKey = statTodayKey();
    await db.addMiningCount(sourceType: kStatSourceBook, dateKey: dateKey);
    // TODO-1204：并行写 per-book 制卡计数（app 外查词无书 → bookKey/title 空，
    // 只进统计页「查词」汇总。addMiningCount 保留不动，Never break userspace）。
    await db.addMineCountPerBook(sourceType: kStatSourceBook, dateKey: dateKey);
    await db.addMinedSentence(
      source: kStatSourceBook,
      dateKey: dateKey,
      expression: fields['expression'] ?? '',
      reading: fields['reading'] ?? '',
      glossary: fields['glossary'] ?? '',
      // 与制卡卡片同一句（剪贴板全文 / UIA 前台句），制卡历史行不再空句。
      sentence: sentence,
      noteId: noteId,
    );
  } catch (e, st) {
    glog('mine: record stats FAILED (non-fatal): $e\n$st');
  }
}

/// TODO-1188 follow-up — resolves a DEFERRED duplicateCheck bridge call via
/// [BaseAnkiRepository.isDuplicate] (the same repo path in-app checkDuplicate
/// uses) so popup.js paints ✓ (already mined) / ➕ (mineable). Always resolves.
Future<void> _handleDuplicateBridge(
  AppModel? model,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
) async {
  final int? id = _bridgeIdOf(message);
  bool reply = false;
  try {
    final Map<Object?, Object?> data = _firstMapArg(message);
    final String expression = data['expression']?.toString() ?? '';
    final String reading = data['reading']?.toString() ?? '';
    if (model != null && expression.isNotEmpty) {
      final BaseAnkiRepository repo =
          model.platformServices.createAnkiRepository();
      reply = await repo.isDuplicate(expression, reading);
    }
  } catch (e, st) {
    glog('duplicate: EXCEPTION $e\n$st');
    reply = false;
  }
  if (id != null) {
    glog('duplicate: duplicateCheck -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// BUG-1063 — resolves a DEFERRED `findMinedMatches` call: the app-external
/// surfaces' equivalent of the in-app [runAnkiMinedCardAction] pre-step. Returns
/// EVERY Anki note matching [expression]/[reading]
/// ([BaseAnkiRepository.findMatchingNotes] — the same call the in-app action
/// dialog makes) as a popup.js-shaped list `[{noteId, preview}, ...]`, so the
/// in-page action panel can list the existing cards. An empty list means「探测时
/// 显示已制卡但现在查不到」(deleted elsewhere) — popup.js then falls through to a
/// plain re-mine, mirroring the in-app `matches.isEmpty -> mineNew()` branch.
/// Always resolves so the ✓ button never freezes.
Future<void> _handleFindMinedMatchesBridge(
  AppModel? model,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
) async {
  final int? id = _bridgeIdOf(message);
  List<Map<String, Object?>> reply = const <Map<String, Object?>>[];
  try {
    final Map<Object?, Object?> data = _firstMapArg(message);
    final String expression = data['expression']?.toString() ?? '';
    final String reading = data['reading']?.toString() ?? '';
    if (model != null && expression.isNotEmpty) {
      final BaseAnkiRepository repo =
          model.platformServices.createAnkiRepository();
      final List<MinedNoteRef> matches =
          await repo.findMatchingNotes(expression, reading);
      reply = <Map<String, Object?>>[
        for (final MinedNoteRef note in matches)
          <String, Object?>{'noteId': note.noteId, 'preview': note.preview},
      ];
    }
  } catch (e, st) {
    glog('mined-matches: EXCEPTION $e\n$st');
    reply = const <Map<String, Object?>>[];
  }
  if (id != null) {
    glog('mined-matches: findMinedMatches -> ${reply.length} hit(s) (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// BUG-1063 — resolves a DEFERRED `openMinedNote` call by opening note [noteId]
/// in Anki ([BaseAnkiRepository.openNoteInAnki]: AnkiConnect guiBrowse /
/// AnkiDroid ACTION_VIEW), the same jump the in-app action dialog's 「查看·打开」
/// performs. Replies with the bool so the panel can show a failure hint instead
/// of pretending it worked. Always resolves.
Future<void> _handleOpenMinedNoteBridge(
  AppModel? model,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
) async {
  final int? id = _bridgeIdOf(message);
  bool reply = false;
  try {
    final Map<Object?, Object?> data = _firstMapArg(message);
    final Object? rawNoteId = data['noteId'];
    final int? noteId =
        (rawNoteId is num) ? rawNoteId.toInt() : int.tryParse('$rawNoteId');
    if (model != null && noteId != null) {
      final BaseAnkiRepository repo =
          model.platformServices.createAnkiRepository();
      reply = await repo.openNoteInAnki(noteId);
    }
  } catch (e, st) {
    glog('mined-open: EXCEPTION $e\n$st');
    reply = false;
  }
  if (id != null) {
    glog('mined-open: openMinedNote -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// TODO-1225 — resolves a DEFERRED `overwriteTargetNoteId` probe via
/// [BaseAnkiRepository.findOverwriteTargetNoteId] (same path as the in-app
/// [DictionaryPageMixin.findOverwriteTargetNoteId]). Non-null only when
/// [AnkiSettings.overwriteScope] is `all` AND the backend (AnkiConnect) can
/// resolve one; popup.js expects a BARE number (or null). Always resolves.
Future<void> _handleOverwriteTargetBridge(
  AppModel? model,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
) async {
  final int? id = _bridgeIdOf(message);
  int? reply;
  try {
    final Map<Object?, Object?> data = _firstMapArg(message);
    final String expression = data['expression']?.toString() ?? '';
    final String reading = data['reading']?.toString() ?? '';
    if (model != null && expression.isNotEmpty) {
      final BaseAnkiRepository repo =
          model.platformServices.createAnkiRepository();
      reply = await repo.findOverwriteTargetNoteId(expression, reading);
    }
  } catch (e, st) {
    glog('overwrite-target: EXCEPTION $e\n$st');
    reply = null;
  }
  if (id != null) {
    glog('overwrite-target: overwriteTargetNoteId -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// TODO-1225 — resolves a DEFERRED `updateEntry` bridge call: OVERWRITES an
/// EXISTING note ([noteId]) in place via [BaseAnkiRepository.updateMinedNote]
/// (the SAME contract as the in-app [DictionaryPageMixin.onUpdateEntry]).
/// popup.js sends `{ noteId, fields }` (fields one level down). Always
/// resolves — even on error / no model / missing note id.
Future<void> _handleUpdateBridge(
  AppModel? model,
  Map<String, Object?> message,
  OverlayBridgeResolver resolveBridge,
  String sentenceContext,
  OverlayMiningHandler? miningHandler,
) async {
  final int? id = _bridgeIdOf(message);
  Map<String, Object?> reply = const <String, Object?>{
    'ankiConnect': false,
    'noteId': null,
  };
  try {
    final Map<Object?, Object?> envelope = _firstMapArg(message);
    final int? noteId = (envelope['noteId'] is num)
        ? (envelope['noteId'] as num).toInt()
        : null;
    final Object? rawFields = envelope['fields'];
    final Map<Object?, Object?> raw =
        rawFields is Map ? rawFields : const <Object?, Object?>{};
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        e.key.toString(): e.value?.toString() ?? '',
    };
    final String expression = fields['expression'] ?? '';
    if (model != null && noteId != null && expression.isNotEmpty) {
      if (miningHandler == null) {
        reply = await _updateEntry(model, noteId, fields, sentenceContext);
      } else {
        await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
        reply = await miningHandler(fields: fields, updateNoteId: noteId);
      }
    }
  } catch (e, st) {
    glog('update: EXCEPTION $e\n$st');
    reply = const <String, Object?>{'ankiConnect': false, 'noteId': null};
  }
  if (id != null) {
    glog('update: updateEntry -> reply=$reply (id=$id)');
    unawaited(resolveBridge(id, reply));
  }
}

/// TODO-1225 — overwrites note [noteId] with [fields] through
/// [BaseAnkiRepository.updateMinedNote] WITHOUT recording stats (an overwrite
/// fixes an existing card in place; it does not count). Returns the
/// popup.js-shaped {ankiConnect, noteId} reply.
Future<Map<String, Object?>> _updateEntry(
  AppModel model,
  int noteId,
  Map<String, String> fields,
  String sentenceContext,
) async {
  await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
  final BaseAnkiRepository repo = model.platformServices.createAnkiRepository();
  final MineOutcome outcome = await repo.updateMinedNote(
    noteId: noteId,
    rawPayloadJson: jsonEncode(fields),
    context: AnkiMiningContext(
      sentence: resolveMineSentence(fields, sentenceContext),
      source: AnkiMiningSource.book,
    ),
  );
  final bool success = outcome.result == MineResult.success;
  return <String, Object?>{
    'ankiConnect': success,
    'noteId': success ? outcome.noteId : null,
  };
}
