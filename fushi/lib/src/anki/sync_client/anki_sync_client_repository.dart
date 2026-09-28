import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/anki_sync/anki_sync_journal.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';

/// 「Anki 同步客户端」后端：设备上不装 Anki，Fushi 把卡写进本地 collection
/// （官方 rslib，经 `fushi-anki-sync`），再同步到 AnkiWeb 或用户自建的 Anki 同步服务器。
///
/// 字段渲染与 AnkiDroid / AnkiConnect 共用基类那一套（字段映射、标签、预检）；
/// 差别只在「媒体不上传」——收集成（媒体名, 本地路径）交给 helper 一起写进库。
/// 未同步的卡由 [AnkiSyncSession] 的日志兜底，整库下载后会重放。
///
/// 实例是无状态的：进程、库、日志都在 [session] 里（全 app 一份），
/// `createAnkiRepository()` 被频繁调用也只是新建一个薄壳。
class AnkiSyncClientRepository extends BaseAnkiRepository {
  AnkiSyncClientRepository({required AnkiSyncSession? session})
    : _session = session;

  /// null = 本机没有 `fushi-anki-sync`（平台 / 安装包不带）。
  final AnkiSyncSession? _session;

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

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    final AnkiSyncSession? session = _session;
    if (session == null) {
      return const AnkiFetchResult.error(
        'fushi-anki-sync is not available on this device.',
        code: AnkiErrorCode.syncClientUnavailable,
      );
    }
    try {
      final AnkiSyncMeta meta = await session.meta();
      final List<AnkiDeck> decks = <AnkiDeck>[
        for (final String d in meta.decks)
          AnkiDeck(id: stableIdFor(d), name: d),
      ];
      final List<AnkiNoteType> noteTypes = <AnkiNoteType>[
        for (final AnkiSyncNotetype n in meta.notetypes)
          AnkiNoteType(id: stableIdFor(n.name), name: n.name, fields: n.fields),
      ];
      if (decks.isEmpty || noteTypes.isEmpty) {
        return const AnkiFetchResult.error(
          'No decks or note types in the synced collection.',
        );
      }
      final AnkiSettings updated = await updateSettings((AnkiSettings current) {
        final AnkiDeck deck = selectDeckAfterFetch(decks, current);
        final AnkiNoteType noteType = selectNoteTypeAfterFetch(
          noteTypes,
          current,
        );
        return current.copyWith(
          selectedDeckId: deck.id,
          selectedDeckName: deck.name,
          selectedNoteTypeId: noteType.id,
          selectedNoteTypeName: noteType.name,
          availableDecks: decks,
          availableNoteTypes: noteTypes,
          fieldMappings: fieldMappingsAfterFetch(noteType, current),
        );
      });
      return AnkiFetchResult.success(
        decks: updated.availableDecks,
        noteTypes: updated.availableNoteTypes,
      );
    } on AnkiSyncNotSignedIn {
      return const AnkiFetchResult.error(
        'Sign in to the Anki sync server first.',
        code: AnkiErrorCode.syncClientSignedOut,
      );
    } catch (e) {
      return AnkiFetchResult.error('$e');
    }
  }

  /// 永不抛：任何异常都变成 [MineResult.error]（调用方的 switch 必须能跑到）。
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      return await _mineEntryInner(rawPayloadJson, context);
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

  Future<MineOutcome> _mineEntryInner(
    String rawPayloadJson,
    AnkiMiningContext context,
  ) async {
    final AnkiSyncSession? session = _session;
    if (session == null) {
      return MineOutcome.failure(
        'fushi-anki-sync is not available on this device.',
        errorCode: AnkiErrorCode.syncClientUnavailable,
      );
    }
    final AnkiSettings settings = await loadSettings();
    final AnkiDeck? deck = resolveSelectedDeck(settings);
    final AnkiNoteType? noteType = _selectedNoteType(settings);
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

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final AnkiSyncSession? session = _session;
    final AnkiNoteType? noteType = _selectedNoteType(await loadSettings());
    if (session == null || noteType == null || expression.isEmpty) return false;
    try {
      return await session.isDuplicate(
        notetype: noteType.name,
        firstField: expression,
      );
    } catch (_) {
      // 查重是每次查词都跑的高频路径：没登录 / helper 起不来时回「不重复」，
      // 真正制卡时 mineEntry 会把原因报给用户。
      return false;
    }
  }

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async {
    final AnkiSyncSession? session = _session;
    final AnkiNoteType? noteType = _selectedNoteType(await loadSettings());
    if (session == null || noteType == null || expression.isEmpty) {
      return const <MinedNoteRef>[];
    }
    try {
      return <MinedNoteRef>[
        for (final AnkiSyncNoteHit h in await session.findNotes(
          notetype: noteType.name,
          firstField: expression,
        ))
          MinedNoteRef(noteId: h.noteId, preview: h.preview),
      ];
    } catch (_) {
      return const <MinedNoteRef>[];
    }
  }

  /// 没有 Anki 界面可以打开，也不能在这里建笔记类型 / 牌组（牌组会在第一次
  /// 加卡时按名字自动建）：这些入口在这个后端上不可用。
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;

  AnkiNoteType? _selectedNoteType(AnkiSettings settings) =>
      settings.availableNoteTypes.firstWhereOrNull(
        (AnkiNoteType t) => t.id == settings.selectedNoteTypeId,
      ) ??
      settings.availableNoteTypes.firstWhereOrNull(
        (AnkiNoteType t) => t.name == settings.selectedNoteTypeName,
      );

  /// 与 AnkiDroid 后端同一形状：四路媒体并发准备，然后交给基类统一渲染。
  /// 媒体只登记进 [media]，由 helper 在加卡时写进库。
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
