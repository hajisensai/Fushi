import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../anki_models.dart';
import '../base_anki_repository.dart';
import '../ankiconnect/ankiconnect_repository.dart';
import '../lapis_note_type.dart';

class AnkiRepository extends BaseAnkiRepository {
  static const _channel = MethodChannel('app.hibiki.reader/anki');
  static const _legacyDeckKey = 'last_selected_deck';

  @override
  Future<AnkiSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(BaseAnkiRepository.settingsKey);
    if (raw == null) {
      await _migrateFromLegacy(prefs);
      final migrated = prefs.getString(BaseAnkiRepository.settingsKey);
      if (migrated != null) {
        try {
          return AnkiSettings.fromJson(
              jsonDecode(migrated) as Map<String, dynamic>);
        } catch (e, stack) {
          debugPrint('AnkiRepository.loadSettings.legacy: $e\n$stack');
        }
      }
      return const AnkiSettings();
    }
    try {
      return AnkiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, stack) {
      debugPrint('AnkiRepository.loadSettings: $e\n$stack');
      return const AnkiSettings();
    }
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    try {
      await _channel.invokeMethod('requestAnkidroidPermissions');
      final decksRaw = await _channel.invokeMethod('getDecks') as Map?;
      final modelsRaw = await _channel.invokeMethod('getModelList') as Map?;
      if (decksRaw == null || modelsRaw == null) {
        return const AnkiFetchResult.error('AnkiDroid is not available.');
      }

      // HBK-AUDIT-063: AnkiDroid deck/model ids are 13-digit epoch longs. The
      // StandardMessageCodec normally decodes them as Dart int, but a JSON
      // string id (or any contract drift) would make an unchecked `as int`
      // throw a CastError that escapes the PlatformException-only catch. Parse
      // ids and names defensively instead.
      final decks = decksRaw.entries
          .map((e) =>
              AnkiDeck(id: _asInt(e.key), name: e.value?.toString() ?? ''))
          .toList();

      final noteTypes = <AnkiNoteType>[];
      for (final entry in modelsRaw.entries) {
        final name = entry.value?.toString() ?? '';
        final fieldsRaw =
            await _channel.invokeMethod('getFieldList', {'model': name});
        final fields = List<String>.from(fieldsRaw as List? ?? []);
        noteTypes.add(
            AnkiNoteType(id: _asInt(entry.key), name: name, fields: fields));
      }

      if (decks.isEmpty || noteTypes.isEmpty) {
        return const AnkiFetchResult.error(
            'No AnkiDroid decks or note types found.');
      }

      final updated = await updateSettings((current) {
        final selectedDeck = selectDeckAfterFetch(decks, current);
        final selectedNoteType = selectNoteTypeAfterFetch(noteTypes, current);
        return current.copyWith(
          selectedDeckId: selectedDeck.id,
          selectedDeckName: selectedDeck.name,
          selectedNoteTypeId: selectedNoteType.id,
          selectedNoteTypeName: selectedNoteType.name,
          availableDecks: decks,
          availableNoteTypes: noteTypes,
          fieldMappings: fieldMappingsAfterFetch(selectedNoteType, current),
        );
      });
      return AnkiFetchResult.success(
        decks: updated.availableDecks,
        noteTypes: updated.availableNoteTypes,
      );
    } on PlatformException catch (e) {
      // TODO-292: carry the stable channel error code (e.g.
      // ANKI_COLLECTION_UNAVAILABLE) back to the UI so it can map a known
      // failure to a localized, actionable hint instead of AnkiDroid's raw
      // English exception text. The verbatim message is still kept as the
      // fallback for unclassified errors (code == null).
      return AnkiFetchResult.error(
        e.message ?? 'Could not access AnkiDroid. Grant permission and retry.',
        code: e.code,
      );
    } catch (e, stack) {
      // HBK-AUDIT-063: a malformed/typed channel response (TypeError,
      // FormatException, etc.) must not crash the fetch out of the provider;
      // surface it as a fetch error instead.
      debugPrint('AnkiRepository.fetchConfiguration: $e\n$stack');
      return const AnkiFetchResult.error(
          'Unexpected response from AnkiDroid. Update AnkiDroid and retry.');
    }
  }

  /// HBK-AUDIT-063: coerce an untyped platform-channel id to int. AnkiDroid
  /// deck/model ids are epoch-based longs; accept either a Dart int or a
  /// stringified long without throwing an uncaught CastError.
  static int _asInt(Object? value) {
    if (value is int) return value;
    return int.parse(value.toString());
  }

  // BUG-077: mirror AnkiConnectRepository — never let mineEntry throw. The
  // popup mine button disables itself and awaits this Future; an escape would
  // hang the '+' with no toast. Convert any unhandled error into
  // MineResult.error so the caller's switch always runs.
  //
  // BUG-089: carry the real cause back to the UI via MineOutcome (errorDetail
  // for the toast, error/stackTrace for ErrorLogService) instead of swallowing
  // it in debugPrint.
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      return await _mineEntryInner(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'AnkiDroid: unexpected error: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<MineOutcome> _mineEntryInner({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final settings = await loadSettings();

    final deck = settings.availableDecks
            .firstWhereOrNull((d) => d.id == settings.selectedDeckId) ??
        (settings.selectedDeckName != null
            ? settings.availableDecks
                .firstWhereOrNull((d) => d.name == settings.selectedDeckName)
            : null);
    if (deck == null) return const MineOutcome.notConfigured();

    final noteType = settings.availableNoteTypes
            .firstWhereOrNull((t) => t.id == settings.selectedNoteTypeId) ??
        (settings.selectedNoteTypeName != null
            ? settings.availableNoteTypes.firstWhereOrNull(
                (t) => t.name == settings.selectedNoteTypeName)
            : null);
    if (noteType == null) return const MineOutcome.notConfigured();

    final AnkiMiningPayload payload;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map);
      payload = AnkiMiningPayload.fromJson(json);
    } catch (e, stack) {
      return MineOutcome.failure(
        'Invalid card data (payload parse failed): $e',
        error: e,
        stackTrace: stack,
      );
    }

    final fields = await _renderMinedFields(
      settings: settings,
      payload: payload,
      context: context,
    );

    if (!settings.allowDupes) {
      final firstFieldValue = noteType.fields.isNotEmpty
          ? (fields[noteType.fields.first] ?? '')
          : '';
      if (firstFieldValue.isNotEmpty) {
        final readingIdx =
            _findReadingFieldIndex(noteType, settings.fieldMappings);
        try {
          final isDupe = await _channel.invokeMethod('checkForDuplicates', {
            'models': [noteType.name],
            'key': firstFieldValue,
            'reading': payload.reading,
            'readingFieldIndices': [readingIdx],
          });
          if (isDupe == true) return const MineOutcome.duplicate();
        } catch (e, stack) {
          debugPrint('AnkiRepository.mineEntry.dupeCheck: $e\n$stack');
        }
      }
    }

    final fieldArray = noteType.fields.map((f) => fields[f] ?? '').toList();
    // AddContentApi accepts an array of empty strings and creates a blank note
    // that the channel reports as success. Refuse if nothing rendered into any
    // field (HBK-AUDIT-018).
    if (fieldArray.every((v) => v.trim().isEmpty)) {
      return MineOutcome.failure(
        'All fields are empty — refusing to create a blank card. '
        'Check your note type field mappings.',
      );
    }
    // TODO-062: append the `hibiki` tag (de-duped, order preserved) to the
    // user's configured tags via the shared base helper — same behavior as the
    // AnkiConnect backend.
    final tags = buildNoteTags(
      settings.tags,
      source: context.source,
      includeHibiki: settings.tagIncludeHibiki,
      includeCategory: settings.tagIncludeCategory,
      // TODO-681 / BUG-393：调用方按「自动添加书名到标签」开关注入已清洗书名/番名标签
      // （书籍/视频同语义）；关闭或无标题时为 null，buildNoteTags 不追加。
      titleTag: context.bookTitleTag,
    );

    try {
      // TODO-270 B：接住 native addNote 返回的真实 note id（Long → int），带回
      // MineOutcome.success，供「制卡后更新已有卡片」（updateMinedNote）按 id 覆盖
      // 字段使用。与 AnkiConnect 后端对称。旧版 native 返回字符串 "Added note"（无 id），
      // 升级前装的 app 仍可工作：_asNoteId 解析失败时返回 null = 优雅降级（弹窗进不了
      // 「最新可改」第三态，与现状一致，Never break userspace）。
      final dynamic addResult =
          await _channel.invokeMethod('addNote', <String, dynamic>{
        'deck': deck.name,
        'model': noteType.name,
        'fields': fieldArray,
        'tags': tags,
      });
      return MineOutcome.success(noteId: _asNoteId(addResult));
    } on PlatformException catch (e, stack) {
      return MineOutcome.failure(
        'AnkiDroid: ${e.message ?? e.code}',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// TODO-270 B：把 native addNote 返回值解析成 note id。新版 native 返回 `Long`
  /// （平台通道解码成 Dart `int`）；旧版返回常量字符串 `"Added note"`（无 id）或
  /// 测试桩可能返回 `true`。无法解析成正整数时返回 `null`（优雅降级，弹窗据此不进
  /// 「最新可改」第三态）。
  static int? _asNoteId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    final int? parsed = int.tryParse(value?.toString() ?? '');
    return parsed;
  }

  /// TODO-270 C2：把 [payload] + [context] 按 [settings] 的字段映射渲染成 Anki note
  /// 字段（含并发媒体写入）。制卡（[_mineEntryInner]）与更新已制卡片
  /// （[updateMinedNote]）共用这一段，避免两份漂移——与 AnkiConnect 的
  /// [AnkiConnectRepository] `_renderMinedFields` 对称。
  ///
  /// BUG-166: 封面、句子(sasayaki)音频、单词远程音频、N 条词典外字这几路媒体写入
  /// 彼此独立（每路一次 AnkiDroid `addFileToMedia` 平台通道往返 + 文件读取/SHA256），
  /// 一次性 `Future.wait` 并发，总耗时从「各路之和」降到「最慢一路」。
  Future<Map<String, String>> _renderMinedFields({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
  }) async {
    final List<Future<dynamic>> mediaFutures = <Future<dynamic>>[
      context.coverPath != null
          ? _addCoverImage(context.coverPath!)
          : Future<String?>.value(null),
      context.sasayakiAudioPath != null
          ? _addSasayakiAudio(context.sasayakiAudioPath!)
          : Future<String?>.value(null),
      payload.audio.isNotEmpty
          ? _addRemoteAudio(payload.audio)
          : Future<String?>.value(null),
      buildDictionaryMediaTags(payload.dictionaryMedia, _addDictionaryMedia),
    ];
    final List<dynamic> mediaResults = await Future.wait(mediaFutures);
    final String? coverRef = mediaResults[0] as String?;
    final String? sasayakiRef = mediaResults[1] as String?;
    final String? rawAudio = mediaResults[2] as String?;
    final Map<String, String> dictionaryMediaTags =
        mediaResults[3] as Map<String, String>;

    final mediaContext = AnkiMiningContext(
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      documentTitle: context.documentTitle,
      coverPath: coverRef,
      sasayakiAudioPath: sasayakiRef,
      sentenceOffset: context.sentenceOffset,
    );

    final processedAudio = rawAudio != null ? '[sound:$rawAudio]' : '';

    final mediaPayload = AnkiMiningPayload(
      expression: payload.expression,
      reading: payload.reading,
      matched: payload.matched,
      furiganaPlain: payload.furiganaPlain,
      frequenciesHtml: payload.frequenciesHtml,
      freqHarmonicRank: payload.freqHarmonicRank,
      glossary: payload.glossary,
      glossaryFirst: payload.glossaryFirst,
      singleGlossaries: payload.singleGlossaries,
      pitchPositions: payload.pitchPositions,
      pitchCategories: payload.pitchCategories,
      popupSelectionText: payload.popupSelectionText,
      audio: processedAudio,
      selectedDictionary: payload.selectedDictionary,
      dictionaryMedia: payload.dictionaryMedia,
    );

    return buildMinedFields(
      fieldMappings: settings.fieldMappings,
      payload: mediaPayload,
      context: mediaContext,
      dictionaryMediaTags: dictionaryMediaTags,
    );
  }

  /// TODO-270 C2：更新一张**已存在**的 AnkiDroid 制卡（[noteId]）的字段。
  ///
  /// 复用 [_renderMinedFields]（与制卡同一字段渲染 + 媒体写入链路）从
  /// [rawPayloadJson] + [context] 生成 fields，再经平台通道 `updateNoteFields`
  /// 按 id 覆盖（native 端只覆盖给出的字段，未给出的保留）。与 [mineEntry] 一样
  /// 保证**返回** [MineOutcome] 而非抛出（供调用方统一 switch 处理 toast/UI）。
  /// 不新增卡片、不改 tag、不查重（更新语义）——与 AnkiConnect 后端对称。
  ///
  /// 渲染出的 fields 为空（什么都没渲染出来）时拒绝更新，避免把已有卡片清空。
  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      final settings = await loadSettings();

      final AnkiMiningPayload payload;
      try {
        final json =
            Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map);
        payload = AnkiMiningPayload.fromJson(json);
      } catch (e, stack) {
        return MineOutcome.failure(
          'Invalid card data (payload parse failed): $e',
          error: e,
          stackTrace: stack,
        );
      }

      final fields = await _renderMinedFields(
        settings: settings,
        payload: payload,
        context: context,
      );

      // 渲染为空说明没有任何字段映射命中，更新会把已有卡片清空——拒绝。
      if (fields.isEmpty) {
        return MineOutcome.failure(
          'All fields are empty — refusing to clear an existing card. '
          'Check your note type field mappings.',
        );
      }

      try {
        await _channel.invokeMethod('updateNoteFields', <String, dynamic>{
          'noteId': noteId,
          'fieldValues': fields,
        });
        return MineOutcome.success(noteId: noteId);
      } on PlatformException catch (e, stack) {
        return MineOutcome.failure(
          'AnkiDroid: ${e.message ?? e.code}',
          error: e,
          stackTrace: stack,
        );
      }
    } catch (e, stack) {
      return MineOutcome.failure(
        'AnkiDroid: unexpected error: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// TODO-270 C2：按 [noteId] 覆盖该 note 的给定字段（字段名 → 值，未给出的字段
  /// 保留）。直接经平台通道 `updateNoteFields` 调 AnkiDroid `AddContentApi`。
  /// 与 AnkiConnect 的 `AnkiConnectService.updateNoteFields` 对称的低层入口；高层「制卡后覆盖」
  /// 走 [updateMinedNote]（含字段渲染 + 媒体写入）。带固定 [noteId] 幂等。
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    await _channel.invokeMethod('updateNoteFields', <String, dynamic>{
      'noteId': noteId,
      'fieldValues': fields,
    });
  }

  /// TODO-270 C2：读取 [noteId] 对应 note 的现有字段（字段名 → 值），用于覆盖前
  /// 回显/合并。note 不存在时返回 `null`。直接经平台通道 `notesInfo` 调 AnkiDroid
  /// `AddContentApi.getNote`（native 端把位置数组按 model 字段名拍平成
  /// name→value）。与 AnkiConnect 的 `AnkiConnectService.notesInfo` 对称。
  Future<Map<String, String>?> notesInfo(int noteId) async {
    final result = await _channel.invokeMethod('notesInfo', <String, dynamic>{
      'noteId': noteId,
    });
    if (result is! Map) return null;
    return result.map(
      (dynamic key, dynamic value) =>
          MapEntry<String, String>(key.toString(), value?.toString() ?? ''),
    );
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final settings = await loadSettings();
    final noteType = settings.selectedNoteType;
    if (noteType == null) return false;
    final readingIdx = _findReadingFieldIndex(noteType, settings.fieldMappings);
    try {
      final result = await _channel.invokeMethod('checkForDuplicates', {
        'models': [noteType.name],
        'key': expression,
        'reading': reading,
        'readingFieldIndices': [readingIdx],
      });
      return result == true;
    } catch (e, stack) {
      debugPrint('AnkiRepository.isDuplicate: $e\n$stack');
      return false;
    }
  }

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    await _channel.invokeMethod('requestAnkidroidPermissions');
    final models = await _channel.invokeMethod('getModelList') as Map?;
    final exists =
        models?.values.any((v) => v?.toString() == template.name) ?? false;
    if (exists) return false;
    await _channel.invokeMethod('createNoteType', <String, dynamic>{
      'noteTypeName': template.name,
      'noteTypeFields': template.fields,
      'cardName': template.cardName,
      'front': template.front,
      'back': template.back,
      'css': template.css,
    });
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    await _channel.invokeMethod('requestAnkidroidPermissions');
    final decks = await _channel.invokeMethod('getDecks') as Map?;
    final exists = decks?.values.any((v) => v?.toString() == name) ?? false;
    if (exists) return false;
    await _channel.invokeMethod('createDeck', <String, dynamic>{
      'deckName': name,
    });
    return true;
  }

  Future<String?> _addCoverImage(String path) async {
    final preferredName =
        await _preferredMediaNameForFile(path, 'hibiki_cover_');
    if (preferredName == null) return null;
    final raw = await _addMediaFile(path, preferredName, mimeTypeForPath(path));
    return raw != null
        ? '<img src="${const HtmlEscape().convert(raw)}">'
        : null;
  }

  Future<String?> _addSasayakiAudio(String path) async {
    final preferredName =
        await _preferredMediaNameForFile(path, 'hibiki_audio_');
    if (preferredName == null) return null;
    final raw = await _addMediaFile(path, preferredName, mimeTypeForPath(path));
    return raw != null ? '[sound:$raw]' : null;
  }

  Future<String?> _preferredMediaNameForFile(
    String path,
    String prefix, {
    String fallbackExtension = 'bin',
  }) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return hibikiAnkiMediaFilenameForBytes(
      prefix: prefix,
      bytes: bytes,
      sourceName: file.path,
      fallbackExtension: fallbackExtension,
    );
  }

  Future<String?> _addRemoteAudio(String url) async {
    try {
      File? audioFile;
      switch (AnkiAudioRef.classify(url)) {
        case AnkiAudioRefKind.empty:
          return null;
        case AnkiAudioRefKind.localFile:
          // file:// URI or a bare absolute path (Unix `/…` or Windows `C:\…`).
          final file = File(AnkiAudioRef.localPath(url));
          final preferredName = await _preferredMediaNameForFile(
            file.path,
            'hibiki_audio_',
            fallbackExtension: 'mp3',
          );
          if (preferredName == null) return null;
          return _addMediaFile(
            file.path,
            preferredName,
            mimeTypeForPath(preferredName),
          );
        case AnkiAudioRefKind.remoteUrl:
          final client = HttpClient();
          try {
            final request = await client.getUrl(Uri.parse(url));
            final response = await request.close();
            // A non-200 returns an HTML/JSON error body; writing it verbatim to
            // .mp3 would embed a broken "audio" file into the card
            // (HBK-AUDIT-019).
            if (response.statusCode != 200) {
              debugPrint(
                  'AnkiRepository._addRemoteAudio: HTTP ${response.statusCode} for $url');
              return null;
            }
            final bytes =
                await response.fold<List<int>>([], (a, b) => a..addAll(b));
            final cacheDir = await _mediaCacheDir();
            final ext = _audioExtension(response.headers.contentType, url);
            final preferredName = hibikiAnkiMediaFilenameForBytes(
              prefix: 'hibiki_audio_',
              bytes: bytes,
              sourceName: url,
              fallbackExtension: ext,
            );
            audioFile = File('${cacheDir.path}/$preferredName');
            await audioFile.writeAsBytes(bytes);
          } finally {
            client.close();
          }
      }
      // Every switch branch above either returns or assigns audioFile, so it is
      // non-null here; only existence can still fail (missing local file or a
      // download that produced no file).
      if (!audioFile.existsSync()) return null;
      return _addMediaFile(
        audioFile.path,
        audioFile.uri.pathSegments.last,
        mimeTypeForPath(audioFile.path),
      );
    } catch (e, stack) {
      debugPrint('AnkiRepository._addRemoteAudio: $e\n$stack');
      return null;
    }
  }

  Future<String?> _addDictionaryMedia(DictionaryMedia media) async {
    try {
      final cacheDir = await _mediaCacheDir();
      // 命名与主 app 的 writeDictionaryMediaCache 共用同一 helper（防漂移；也修了旧
      // split('.').last 在无扩展名时把整串当扩展名的边角）。
      final filename = ankiDictionaryMediaCacheFilename(media.path);
      final file = File('${cacheDir.path}/$filename');
      if (!file.existsSync()) return null;
      final result =
          await _addMediaFile(file.path, filename, mimeTypeForPath(media.path));
      return result != null ? ankiInlineMediaReference(result) : null;
    } catch (e, stack) {
      debugPrint('AnkiRepository._addDictionaryMedia: $e\n$stack');
      return null;
    }
  }

  Future<String?> _addMediaFile(
      String filePath, String preferredName, String mimeType) async {
    try {
      final result =
          await _channel.invokeMethod('addFileToMedia', <String, dynamic>{
        'filename': filePath,
        'preferredName': preferredName,
        'mimeType': mimeType,
      });
      return result as String?;
    } catch (e, stack) {
      debugPrint('AnkiRepository._addMediaFile $preferredName: $e\n$stack');
      return null;
    }
  }

  Future<Directory> _mediaCacheDir() async {
    final dir = Directory('${Directory.systemTemp.path}/anki-media');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _audioExtension(ContentType? contentType, String url) {
    switch (contentType?.mimeType) {
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/aac':
        return 'aac';
      case 'audio/mp4':
      case 'audio/x-m4a':
        return 'm4a';
      case 'audio/wav':
      case 'audio/x-wav':
        return 'wav';
      case 'audio/ogg':
      case 'audio/opus':
        return 'ogg';
      case 'audio/webm':
        return 'webm';
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
    }
    final path = Uri.tryParse(url)?.path ?? url;
    final lastDot = path.lastIndexOf('.');
    final lastSlash = path.lastIndexOf('/');
    if (lastDot > lastSlash && lastDot < path.length - 1) {
      return path.substring(lastDot + 1).toLowerCase();
    }
    return 'mp3';
  }

  int _findReadingFieldIndex(
      AnkiNoteType noteType, Map<String, String> fieldMappings) {
    for (var i = 0; i < noteType.fields.length; i++) {
      final handlebar = fieldMappings[noteType.fields[i]] ?? '';
      if (handlebar == '{reading}') return i;
    }
    return -1;
  }

  Future<void> _migrateFromLegacy(SharedPreferences prefs) async {
    final legacyDeck = prefs.getString(_legacyDeckKey);
    if (legacyDeck != null && legacyDeck != 'Default') {
      final settings = AnkiSettings(selectedDeckName: legacyDeck);
      await prefs.setString(
          BaseAnkiRepository.settingsKey, jsonEncode(settings.toJson()));
    }
  }
}
