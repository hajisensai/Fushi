import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

import 'package:fushi_engine/anki_sync/anki_sync_journal.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';

/// 「Anki 同步客户端」的一次制卡：按 [AnkiSettings] 渲染字段（与 AnkiConnect /
/// AnkiDroid 同一套 [AnkiNoteComposer]），查重，写进 [AnkiSyncSession]。
///
/// app 的同步客户端后端与无头服务端的落地后端共用这一份——同一张卡在哪边落地，
/// 字段、标签、媒体名都一字不差。永不抛：失败一律变成 [MineOutcome]。
class AnkiSyncMiner with AnkiNoteComposer {
  AnkiSyncMiner(this.session);

  final AnkiSyncSession session;

  Future<MineOutcome> mine({
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      return await _mine(settings, rawPayloadJson, context);
    } on AnkiSyncNotSignedIn catch (e, stack) {
      return MineOutcome.failure(
        'Sign in to the Anki sync server first.',
        errorCode: AnkiErrorCode.syncClientSignedOut,
        error: e,
        stackTrace: stack,
      );
    } catch (e, stack) {
      return MineOutcome.failure('Anki sync: $e', error: e, stackTrace: stack);
    }
  }

  /// 由名字派生的稳定 id（FNV-1a 32 位）：helper 只给名字，按列表下标编号会在服务器
  /// 上多一个牌组后整体错位，把卡写进别的牌组。
  static int stableIdFor(String name) {
    int hash = 0x811c9dc5;
    for (final int byte in utf8.encode(name)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  /// 用本地库里的牌组 / 笔记类型刷新 [current]：选中项按 id → 名字对回，字段映射
  /// 沿用（选中 Lapis 时补 Lapis 默认映射）。库里没有牌组或笔记类型返回 null。
  AnkiSettings? applyMeta(AnkiSettings current, AnkiSyncMeta meta) {
    final List<AnkiDeck> decks = <AnkiDeck>[
      for (final String d in meta.decks) AnkiDeck(id: stableIdFor(d), name: d),
    ];
    final List<AnkiNoteType> noteTypes = <AnkiNoteType>[
      for (final AnkiSyncNotetype n in meta.notetypes)
        AnkiNoteType(id: stableIdFor(n.name), name: n.name, fields: n.fields),
    ];
    if (decks.isEmpty || noteTypes.isEmpty) return null;
    final AnkiDeck deck = selectDeckAfterFetch(decks, current);
    final AnkiNoteType noteType = selectNoteTypeAfterFetch(noteTypes, current);
    return current.copyWith(
      selectedDeckId: deck.id,
      selectedDeckName: deck.name,
      selectedNoteTypeId: noteType.id,
      selectedNoteTypeName: noteType.name,
      availableDecks: decks,
      availableNoteTypes: noteTypes,
      fieldMappings: fieldMappingsAfterFetch(noteType, current),
    );
  }

  /// 按设置选中的笔记类型（id 优先、名字兜底）。
  AnkiNoteType? selectedNoteType(AnkiSettings settings) =>
      settings.availableNoteTypes.firstWhereOrNull(
        (AnkiNoteType t) => t.id == settings.selectedNoteTypeId,
      ) ??
      settings.availableNoteTypes.firstWhereOrNull(
        (AnkiNoteType t) => t.name == settings.selectedNoteTypeName,
      );

  Future<MineOutcome> _mine(
    AnkiSettings settings,
    String rawPayloadJson,
    AnkiMiningContext context,
  ) async {
    final AnkiDeck? deck = resolveSelectedDeck(settings);
    final AnkiNoteType? noteType = selectedNoteType(settings);
    if (deck == null || noteType == null) {
      return const MineOutcome.notConfigured();
    }

    final AnkiMiningPayload payload;
    try {
      payload = AnkiMiningPayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map),
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Invalid card data (payload parse failed): $e',
        error: e,
        stackTrace: stack,
      );
    }

    final List<(String, String)> media = <(String, String)>[];
    final RenderedMinedFields rendered = await _render(
      settings: settings,
      payload: payload,
      context: context,
      media: media,
    );
    final Map<String, String> fields = rendered.fields;
    final List<String> ordered = <String>[
      for (final String f in noteType.fields) fields[f] ?? '',
    ];
    if (ordered.every((String v) => v.trim().isEmpty)) {
      return MineOutcome.failure(
        'All fields are empty — refusing to create a blank card. '
        'Check your note type field mappings.',
      );
    }
    final MineOutcome? rejected = preflightNoteFields(
      noteType,
      fields,
      fieldsForNoteType(noteType, fields),
    );
    if (rejected != null) return rejected;

    final bool allowDuplicate = settings.allowDupes || payload.allowDuplicate;
    if (!allowDuplicate &&
        await session.isDuplicate(
          notetype: noteType.name,
          firstField: ordered.first,
        )) {
      return const MineOutcome.duplicate();
    }

    final int noteId = await session.addNote(
      AnkiSyncNote(
        notetype: noteType.name,
        deck: deck.name,
        fields: ordered,
        tags: buildNoteTags(
          settings.tags,
          source: context.source,
          includeHibiki: settings.tagIncludeHibiki,
          includeCategory: settings.tagIncludeCategory,
          titleTag: context.bookTitleTag,
          collectionTag: context.collectionTag,
          charPositionTag: context.charPositionTag,
        ),
        media: media,
        allowDuplicate: allowDuplicate,
      ),
    );
    return MineOutcome.success(
      noteId: noteId,
      deckName: deck.name,
      audioWarning: rendered.audioWarning,
    );
  }

  /// 与 AnkiDroid 后端同一形状：四路媒体并发准备，交给 [renderMediaPayload] 统一渲染。
  /// 媒体只登记进 [media]（媒体名, 本地路径），由 helper 在加卡时写进库。
  Future<RenderedMinedFields> _render({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required List<(String, String)> media,
  }) async {
    Future<String?> addFile(String path, String prefix) async {
      final File file = File(path);
      if (!file.existsSync()) return null;
      final String name = await fushiAnkiMediaFilenameForBytesAsync(
        prefix: prefix,
        bytes: await file.readAsBytes(),
        sourceName: file.path,
        fallbackExtension: 'bin',
      );
      media.add((name, file.path));
      return name;
    }

    Future<AudioFetchOutcome> wordAudio() async {
      if (payload.audio.isEmpty) return const AudioFetchOutcome.none();
      final AnkiLocalAudio local = await materializeAnkiWordAudio(
        payload.audio,
        httpFailureReason: audioFetchHttpFailureReason,
        errorReason: audioFetchErrorReason,
      );
      final String? failure = local.failureReason;
      if (failure != null) return AudioFetchOutcome.failed(failure);
      final File? file = local.file;
      if (file == null) return const AudioFetchOutcome.none();
      final String? name = await addFile(file.path, 'fushi_audio_');
      return name == null
          ? const AudioFetchOutcome.none()
          : AudioFetchOutcome.stored(name);
    }

    Future<String?> dictionaryMedia(DictionaryMedia m) async {
      final String name = ankiDictionaryMediaCacheFilename(
        m.dictionary,
        m.path,
      );
      final File file = File(
        '${ankiDictionaryMediaCacheDirPath()}${Platform.pathSeparator}$name',
      );
      if (!file.existsSync()) return null;
      media.add((name, file.path));
      return ankiInlineMediaReference(name);
    }

    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      context.coverPath != null
          ? addFile(context.coverPath!, 'fushi_cover_')
          : Future<String?>.value(),
      context.sentenceAudioPath != null && !context.synchronizedVideo
          ? addFile(context.sentenceAudioPath!, 'fushi_audio_')
          : Future<String?>.value(),
      wordAudio(),
      buildDictionaryMediaTags(payload.dictionaryMedia, dictionaryMedia),
    ]);
    final String? cover = results[0] as String?;
    final String? sentenceAudio = results[1] as String?;
    final AudioFetchOutcome audio = results[2]! as AudioFetchOutcome;
    return renderMediaPayload(
      settings: settings,
      payload: payload,
      context: context,
      coverRef: cover != null ? coverMediaRef(cover) : null,
      sentenceAudioRef: sentenceAudio != null ? '[sound:$sentenceAudio]' : null,
      processedAudio: audio.ref != null ? '[sound:${audio.ref}]' : '',
      dictionaryMediaTags: results[3]! as Map<String, String>,
      audioWarning: audio.failureReason,
    );
  }
}
