import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../anki_models.dart';
import '../base_anki_repository.dart';
import '../lapis_note_type.dart';
import 'ankiconnect_service.dart';

const int _uint32Mask = 0xffffffff;

const List<int> _sha256K = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

String hibikiAnkiMediaFilenameForBytes({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  final String ext = _mediaExtensionFromSource(
    sourceName,
    fallbackExtension: fallbackExtension,
  );
  return '${_safeMediaPrefix(prefix)}${_sha256Hex(bytes)}.$ext';
}

String _safeMediaPrefix(String prefix) {
  final String safe = prefix.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return safe.isEmpty ? 'hibiki_media_' : safe;
}

String _mediaExtensionFromSource(
  String sourceName, {
  required String fallbackExtension,
}) {
  final String fallback =
      _safeMediaExtension(fallbackExtension, fallback: 'bin');
  final Uri? uri = Uri.tryParse(sourceName);
  final String path = (uri != null && uri.path.isNotEmpty)
      ? uri.path
      : sourceName.replaceAll('\\', '/');
  final String name = path.split('/').last;
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return fallback;
  return _safeMediaExtension(name.substring(dot + 1), fallback: fallback);
}

String _safeMediaExtension(String extension, {required String fallback}) {
  final String safe =
      extension.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (safe.isEmpty || safe.length > 12) return fallback;
  return safe;
}

String _sha256Hex(List<int> bytes) {
  final List<int> padded = <int>[
    for (final int byte in bytes) byte & 0xff,
    0x80,
  ];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final int bitLength = bytes.length * 8;
  for (int shift = 56; shift >= 0; shift -= 8) {
    padded.add((bitLength >> shift) & 0xff);
  }

  final List<int> h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final List<int> w = List<int>.filled(64, 0);

  for (int chunk = 0; chunk < padded.length; chunk += 64) {
    for (int i = 0; i < 16; i++) {
      final int j = chunk + i * 4;
      w[i] = ((padded[j] << 24) |
              (padded[j + 1] << 16) |
              (padded[j + 2] << 8) |
              padded[j + 3]) &
          _uint32Mask;
    }
    for (int i = 16; i < 64; i++) {
      final int s0 =
          _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _uint32Mask;
    }

    int a = h[0];
    int b = h[1];
    int c = h[2];
    int d = h[3];
    int e = h[4];
    int f = h[5];
    int g = h[6];
    int hh = h[7];

    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final int ch = (e & f) ^ ((~e) & g);
      final int temp1 = (hh + s1 + ch + _sha256K[i] + w[i]) & _uint32Mask;
      final int s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = (s0 + maj) & _uint32Mask;

      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & _uint32Mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _uint32Mask;
    }

    h[0] = (h[0] + a) & _uint32Mask;
    h[1] = (h[1] + b) & _uint32Mask;
    h[2] = (h[2] + c) & _uint32Mask;
    h[3] = (h[3] + d) & _uint32Mask;
    h[4] = (h[4] + e) & _uint32Mask;
    h[5] = (h[5] + f) & _uint32Mask;
    h[6] = (h[6] + g) & _uint32Mask;
    h[7] = (h[7] + hh) & _uint32Mask;
  }

  return h.map((int word) => word.toRadixString(16).padLeft(8, '0')).join();
}

int _rotr32(int value, int shift) =>
    ((value >> shift) | (value << (32 - shift))) & _uint32Mask;

class AnkiConnectRepository extends BaseAnkiRepository {
  AnkiConnectRepository({AnkiConnectService? service})
      : _fixedService = service;

  final AnkiConnectService? _fixedService;
  AnkiConnectService? _cachedService;
  String _cachedHost = '';
  int _cachedPort = 0;
  String _cachedApiKey = '';

  AnkiConnectService _serviceForSettings(AnkiSettings settings) {
    if (_fixedService != null) return _fixedService;
    if (_cachedService != null &&
        _cachedHost == settings.ankiConnectHost &&
        _cachedPort == settings.ankiConnectPort &&
        _cachedApiKey == settings.ankiConnectApiKey) {
      return _cachedService!;
    }
    _cachedHost = settings.ankiConnectHost;
    _cachedPort = settings.ankiConnectPort;
    _cachedApiKey = settings.ankiConnectApiKey;
    _cachedService = AnkiConnectService(
      host: settings.ankiConnectHost,
      port: settings.ankiConnectPort,
      apiKey: settings.ankiConnectApiKey,
    );
    return _cachedService!;
  }

  Future<AnkiConnectService> _getService() async =>
      _serviceForSettings(await loadSettings());

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    final AnkiConnectService service = await _getService();
    try {
      final connectionError = await service.checkConnection();
      if (connectionError != null) {
        return AnkiFetchResult.error(connectionError);
      }

      final deckNames = await service.getDeckNames();
      final modelNames = await service.getModelNames();

      if (deckNames.isEmpty || modelNames.isEmpty) {
        return const AnkiFetchResult.error(
            'No Anki decks or note types found.');
      }

      final decks = <AnkiDeck>[];
      for (var i = 0; i < deckNames.length; i++) {
        decks.add(AnkiDeck(id: i, name: deckNames[i]));
      }

      final noteTypes = <AnkiNoteType>[];
      for (var i = 0; i < modelNames.length; i++) {
        final fields = await service.getModelFields(modelNames[i]);
        noteTypes.add(AnkiNoteType(id: i, name: modelNames[i], fields: fields));
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
    } on AnkiConnectException catch (e) {
      return AnkiFetchResult.error(e.message);
    } catch (e) {
      // TODO-752a：连接/网络异常按稳定码分类，主 app 据码本地化展示。绝不把
      // socket/http 的 toString()（可能含 latin1 误解码乱码）当 message 透传给
      // 用户——[message] 仅作主 app 映射缺失时的英文回退。
      final String code = classifyAnkiConnectError(e);
      return AnkiFetchResult.error(
        ankiConnectErrorHint(code, host: service.host, port: service.port),
        code: code,
      );
    }
  }

  // BUG-077: the popup mine button disables itself and `await`s this Future
  // (popup.js), so a thrown exception leaves the '+' stuck forever with no
  // feedback. mineEntry's contract is to *return* a MineOutcome — guarantee it
  // here so the caller's switch (toast + button restore) always runs. The inner
  // body still has unguarded calls (loadSettings, handlebar render, HTML
  // normalize); this is the single place that converts any escape into
  // MineResult.error.
  //
  // BUG-089: carry the real cause back to the UI via MineOutcome (errorDetail
  // for the toast, error/stackTrace for ErrorLogService) instead of swallowing
  // it in debugPrint, which only surfaces when the user manually enables the
  // debug log.
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
      return _mineFailureFor(e, stack);
    }
  }

  /// TODO-752a：把 mineEntry / updateMinedNote 的顶层异常统一映射成 [MineOutcome]。
  /// 网络异常（socket/timeout/http）按稳定码分类，errorDetail 只放**英文回退**文案，
  /// errorCode 交给主 app 映射本地化 toast；OS 原文（可能含 latin1 误解码乱码）只进
  /// [MineOutcome.error]（诊断日志）。其余（payload/handlebar/HTML 等编程错误）走
  /// connectionUnknown 的通用文案，同样不把 `$e` 透传给用户（旧实现
  /// 'unexpected error: $e' 会泄漏乱码）。保持 mineEntry 的「永不抛出」契约（BUG-077）：
  /// 本方法不触网、不取服务，绝不抛。
  MineOutcome _mineFailureFor(Object e, StackTrace stack) {
    if (e is SocketException ||
        e is TimeoutException ||
        e is http.ClientException) {
      final String code = classifyAnkiConnectError(e);
      return MineOutcome.failure(
        ankiConnectErrorHint(code),
        errorCode: code,
        error: e,
        stackTrace: stack,
      );
    }
    // 非网络异常（payload/handlebar/HTML 等）不属于连接错误，不套 connectionUnknown，
    // 只给干净的英文 errorDetail（无 `$e`）走主 app 的 card_export_failed_detail 包装。
    return MineOutcome.failure(
      'AnkiConnect: unexpected error.',
      error: e,
      stackTrace: stack,
    );
  }

  Future<MineOutcome> _mineEntryInner({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final settings = await loadSettings();
    final service = _serviceForSettings(settings);

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

    final rendered = await _renderMinedFields(
      service: service,
      settings: settings,
      payload: payload,
      context: context,
    );
    final Map<String, String> fields = rendered.fields;
    // TODO-779: 单词远程音频下载失败时带可见原因到成功 toast（卡片仍建好）。
    final String? audioWarning = rendered.audioWarning;

    String? addNoteReconcileFieldName;
    String? addNoteReconcileFieldValue;
    bool addNoteReconcileAllowed = false;
    if (!settings.allowDupes) {
      final firstFieldName =
          noteType.fields.isNotEmpty ? noteType.fields.first : null;
      final firstFieldValue =
          firstFieldName != null ? (fields[firstFieldName] ?? '') : '';
      if (firstFieldValue.isNotEmpty) {
        // HBK-AUDIT-060: fail closed. A failed dupe query must not fall through
        // to addNote as if the entry were unique — that silently bypasses the
        // no-duplicates guarantee. Surface the failure as an error instead.
        try {
          final isDupe = await service.isDuplicate(
            deckName: deck.name,
            fieldName: firstFieldName!,
            fieldValue: firstFieldValue,
          );
          if (isDupe) return const MineOutcome.duplicate();
          addNoteReconcileFieldName = firstFieldName;
          addNoteReconcileFieldValue = firstFieldValue;
          addNoteReconcileAllowed = true;
        } catch (e, stack) {
          // TODO-752a：查重失败常因连不上 AnkiConnect（socket/timeout/http）。统一经
          // [_mineFailureFor]：网络异常按稳定码分类本地化，OS 原文仅进诊断日志，绝不
          // 把 `$e` 透传给用户。
          return _mineFailureFor(e, stack);
        }
      }
    }

    // BUG/TODO-062: every Hibiki-mined card gets the `hibiki` tag appended to
    // the user's configured tags (de-duped, order preserved) via the shared
    // base helper, so both backends behave identically.
    final tags = buildNoteTags(
      settings.tags,
      source: context.source,
      includeHibiki: settings.tagIncludeHibiki,
      includeCategory: settings.tagIncludeCategory,
      // TODO-681 / BUG-393：调用方按「自动添加书名到标签」开关注入已清洗书名/番名标签
      // （书籍/视频同语义）；关闭或无标题时为 null，buildNoteTags 不追加。
      titleTag: context.bookTitleTag,
    );

    // `fields` only holds entries that rendered to a non-empty value; if it is
    // empty, nothing rendered and adding the note would create a blank card
    // reported as success (HBK-AUDIT-018).
    if (fields.isEmpty) {
      return MineOutcome.failure(
        'All fields are empty — refusing to create a blank card. '
        'Check your note type field mappings.',
      );
    }
    try {
      // TODO-270 A：接住 addNote 返回的 note id，带回 MineOutcome.success，供
      // 后续「更新已制卡片」（updateMinedNote）按 id 覆盖字段使用。
      final int? noteId = await service.addNote(
        deckName: deck.name,
        modelName: noteType.name,
        fields: fields,
        tags: tags,
        allowDuplicate: settings.allowDupes,
      );
      return MineOutcome.success(noteId: noteId, audioWarning: audioWarning);
    } on AnkiConnectCommitUnknownException catch (e, stack) {
      if (!addNoteReconcileAllowed ||
          addNoteReconcileFieldName == null ||
          addNoteReconcileFieldValue == null) {
        return MineOutcome.failure(
          _addNoteCommitUnknownMessage(),
          error: e,
          stackTrace: stack,
        );
      }
      try {
        final matches = await service.findNotesByField(
          deckName: deck.name,
          fieldName: addNoteReconcileFieldName,
          fieldValue: addNoteReconcileFieldValue,
        );
        if (matches.length == 1) {
          return MineOutcome.success(
            noteId: matches.single,
            audioWarning: audioWarning,
          );
        }
        return MineOutcome.failure(
          _addNoteCommitUnknownMessage(matchCount: matches.length),
          error: e,
          stackTrace: stack,
        );
      } catch (reconcileError, reconcileStack) {
        return MineOutcome.failure(
          _addNoteCommitUnknownMessage(
            extra: 'The follow-up Anki check also failed: $reconcileError',
          ),
          error: reconcileError,
          stackTrace: reconcileStack,
        );
      }
    } on AnkiConnectException catch (e, stack) {
      return MineOutcome.failure(
        'AnkiConnect: ${e.message}',
        error: e,
        stackTrace: stack,
      );
    }
  }

  String _addNoteCommitUnknownMessage({int? matchCount, String? extra}) {
    final buffer = StringBuffer(
      'AnkiConnect may have created the card, but the response was lost.',
    );
    if (matchCount == null) {
      buffer.write(' Hibiki could not uniquely confirm the new note.');
    } else if (matchCount == 0) {
      buffer
          .write(' Hibiki found no matching note, so the result is uncertain.');
    } else {
      buffer.write(
        ' Hibiki found $matchCount matching notes and could not uniquely confirm which one was new.',
      );
    }
    if (extra != null && extra.isNotEmpty) {
      buffer.write(' $extra');
    }
    buffer.write(' Please check Anki before retrying.');
    return buffer.toString();
  }

  /// 把 [payload] + [context] 按 [settings] 的字段映射渲染成 Anki note 字段。
  ///
  /// BUG-166: 制卡慢的根因——封面、句子(sasayaki)音频、单词远程音频、N 条
  /// 词典外字这几路媒体上传彼此独立，过去被串成一条 `await` 链（每路一次
  /// AnkiConnect `storeMediaFile` 往返），一张带封面+音频+外字的卡会累加
  /// 5~8 次串行往返。`storeMediaFile` 是幂等纯写入（文件名由内容 SHA256 决定，
  /// 不同文件互不冲突），并发安全。把互相独立的几路一次性 `Future.wait` 并发，
  /// 总耗时从「各路之和」降到「最慢一路」。
  ///
  /// TODO-270 C1：制卡（[_mineEntryInner]）与更新已制卡片（[updateMinedNote]）
  /// 共用这一段渲染，避免两份漂移。
  ///
  /// TODO-779：返回 [RenderedMinedFields]（fields + audioWarning）而非裸字段 map，
  /// 把单词远程音频下载失败的可见原因带给成功分支。
  Future<RenderedMinedFields> _renderMinedFields({
    required AnkiConnectService service,
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
  }) async {
    final List<Future<dynamic>> mediaFutures = <Future<dynamic>>[
      context.coverPath != null
          ? _storeLocalMedia(service, context.coverPath!, 'hibiki_cover_')
          : Future<String?>.value(null),
      context.sasayakiAudioPath != null
          ? _storeLocalMedia(
              service, context.sasayakiAudioPath!, 'hibiki_audio_')
          : Future<String?>.value(null),
      payload.audio.isNotEmpty
          ? _storeRemoteAudio(service, payload.audio)
          : Future<AudioFetchOutcome>.value(const AudioFetchOutcome.none()),
      buildDictionaryMediaTags(
        payload.dictionaryMedia,
        (media) => _storeDictionaryMedia(service, media),
      ),
    ];
    final List<dynamic> mediaResults = await Future.wait(mediaFutures);
    final String? coverMediaRef = mediaResults[0] as String?;
    final String? sasayakiMediaRef = mediaResults[1] as String?;
    final AudioFetchOutcome remoteAudio = mediaResults[2] as AudioFetchOutcome;
    final Map<String, String> dictionaryMediaTags =
        mediaResults[3] as Map<String, String>;

    final String? remoteAudioRef = remoteAudio.ref;
    final String processedAudio =
        remoteAudioRef != null ? '[sound:$remoteAudioRef]' : '';

    final mediaContext = AnkiMiningContext(
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      documentTitle: context.documentTitle,
      coverPath: coverMediaRef != null ? '<img src="$coverMediaRef">' : null,
      sasayakiAudioPath:
          sasayakiMediaRef != null ? '[sound:$sasayakiMediaRef]' : null,
      sentenceOffset: context.sentenceOffset,
    );

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

    return RenderedMinedFields(
      buildMinedFields(
        fieldMappings: settings.fieldMappings,
        payload: mediaPayload,
        context: mediaContext,
        dictionaryMediaTags: dictionaryMediaTags,
      ),
      audioWarning: remoteAudio.failureReason,
    );
  }

  /// TODO-270 C1：更新一张**已存在**的 Hibiki 制卡（[noteId]）的字段。
  ///
  /// 复用 [_renderMinedFields]（与制卡同一字段渲染 + 媒体上传链路）从
  /// [rawPayloadJson] + [context] 生成 fields，再调 [AnkiConnectService.updateNoteFields]
  /// 按 id 覆盖。与 [mineEntry] 一样保证**返回** [MineOutcome] 而非抛出（供调用方
  /// 统一 switch 处理 toast/UI）。不新增卡片、不改 tag、不查重（更新语义）。
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
      final service = _serviceForSettings(settings);

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

      final rendered = await _renderMinedFields(
        service: service,
        settings: settings,
        payload: payload,
        context: context,
      );
      final Map<String, String> fields = rendered.fields;

      // 渲染为空说明没有任何字段映射命中，更新会把已有卡片清空——拒绝。
      if (fields.isEmpty) {
        return MineOutcome.failure(
          'All fields are empty — refusing to clear an existing card. '
          'Check your note type field mappings.',
        );
      }

      try {
        await service.updateNoteFields(noteId, fields);
        // TODO-779: 覆盖路径同样把音频下载失败原因带给成功 toast。
        return MineOutcome.success(
          noteId: noteId,
          audioWarning: rendered.audioWarning,
        );
      } on AnkiConnectException catch (e, stack) {
        return MineOutcome.failure(
          'AnkiConnect: ${e.message}',
          error: e,
          stackTrace: stack,
        );
      }
    } catch (e, stack) {
      return _mineFailureFor(e, stack);
    }
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final settings = await loadSettings();
    final deck = settings.availableDecks
            .firstWhereOrNull((d) => d.id == settings.selectedDeckId) ??
        (settings.selectedDeckName != null
            ? settings.availableDecks
                .firstWhereOrNull((d) => d.name == settings.selectedDeckName)
            : null);
    final noteType = settings.selectedNoteType;
    if (deck == null || noteType == null || noteType.fields.isEmpty) {
      return false;
    }
    try {
      final service = _serviceForSettings(settings);
      return await service.isDuplicate(
        deckName: deck.name,
        fieldName: noteType.fields.first,
        fieldValue: expression,
      );
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.isDuplicate: $e\n$stack');
      return false;
    }
  }

  // TODO-614：scope=all 时复用「与查重同一条件」（deck + 第一字段=expression）经
  // findNotes 反查已存在卡的 note id，多张命中取**最近一张**（note id 最大 = Anki
  // 创建时间戳最新）。scope=latest 直接回 null（不查 Anki，等价旧行为）。查询失败
  // 静默降级为 null（与 isDuplicate 同样 fail-soft，绝不让覆写探测把制卡链路搞崩）。
  @override
  Future<int?> findOverwriteTargetNoteId(
      String expression, String reading) async {
    final settings = await loadSettings();
    if (settings.overwriteScope != AnkiOverwriteScope.all) return null;
    if (expression.isEmpty) return null;
    final deck = settings.availableDecks
            .firstWhereOrNull((d) => d.id == settings.selectedDeckId) ??
        (settings.selectedDeckName != null
            ? settings.availableDecks
                .firstWhereOrNull((d) => d.name == settings.selectedDeckName)
            : null);
    final noteType = settings.selectedNoteType;
    if (deck == null || noteType == null || noteType.fields.isEmpty) {
      return null;
    }
    try {
      final service = _serviceForSettings(settings);
      final matches = await service.findNotesByField(
        deckName: deck.name,
        fieldName: noteType.fields.first,
        fieldValue: expression,
      );
      if (matches.isEmpty) return null;
      // 取最近一张：Anki note id 是创建时间戳（毫秒），越大越新。多张同条件命中
      // 时不弹选（用户明确要求别复杂），直接覆写最近那张。
      return matches.reduce((a, b) => a > b ? a : b);
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.findOverwriteTargetNoteId: $e\n$stack');
      return null;
    }
  }

  // TODO-1007/1008：反查**所有**与当前查词同条件（deck + 第一字段=expression）的已存在
  // 卡，返回 noteId + 一行预览，**不看 overwriteScope**——别处/上次会话建的卡也要能被
  // 发现。先 findNotes 拿全部 id，再 notesInfo 批量拉第一字段做预览。按 id 降序（最近在前）。
  // 任一步失败静默回空列表（与 isDuplicate 同样 fail-soft）。
  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
      String expression, String reading) async {
    if (expression.isEmpty) return const <MinedNoteRef>[];
    final settings = await loadSettings();
    final deck = settings.availableDecks
            .firstWhereOrNull((d) => d.id == settings.selectedDeckId) ??
        (settings.selectedDeckName != null
            ? settings.availableDecks
                .firstWhereOrNull((d) => d.name == settings.selectedDeckName)
            : null);
    final noteType = settings.selectedNoteType;
    if (deck == null || noteType == null || noteType.fields.isEmpty) {
      return const <MinedNoteRef>[];
    }
    try {
      final service = _serviceForSettings(settings);
      final List<int> ids = await service.findNotesByField(
        deckName: deck.name,
        fieldName: noteType.fields.first,
        fieldValue: expression,
      );
      if (ids.isEmpty) return const <MinedNoteRef>[];
      ids.sort((a, b) => b.compareTo(a)); // 最近（id 大）在前
      final Map<int, Map<String, String>> infos =
          await service.notesInfoMany(ids);
      final String firstField = noteType.fields.first;
      return ids.map((id) {
        final fields = infos[id];
        final String raw = fields == null ? '' : (fields[firstField] ?? '');
        return MinedNoteRef(
          noteId: id,
          preview: BaseAnkiRepository.previewFromFieldValue(raw),
        );
      }).toList();
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.findMatchingNotes: $e');
      debugPrint('$stack');
      return const <MinedNoteRef>[];
    }
  }

  // TODO-1007/1008：读取一张已存在 note 的现有字段，供 note viewer 只读展示。
  @override
  Future<Map<String, String>?> noteFields(int noteId) async {
    try {
      final service = await _getService();
      return await service.notesInfo(noteId);
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.noteFields: $e');
      debugPrint('$stack');
      return null;
    }
  }

  // TODO-1007/1008：在 Anki 桌面端打开浏览器并选中该 note（guiBrowse(nid:<id>)）。
  @override
  Future<bool> openNoteInAnki(int noteId) async {
    try {
      final service = await _getService();
      await service.guiBrowse(noteId);
      return true;
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.openNoteInAnki: $e');
      debugPrint('$stack');
      return false;
    }
  }

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    final service = await _getService();
    final existing = await service.getModelNames();
    if (existing.contains(template.name)) return false;
    await service.createModel(template);
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    final service = await _getService();
    final existing = await service.getDeckNames();
    if (existing.contains(name)) return false;
    await service.createDeck(name);
    return true;
  }

  Future<String?> _storeLocalMedia(
    AnkiConnectService service,
    String filePath,
    String prefix,
  ) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final filename = hibikiAnkiMediaFilenameForBytes(
        prefix: prefix,
        bytes: bytes,
        sourceName: filePath,
      );
      await service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      return filename;
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeLocalMedia: $e\n$stack');
      return null;
    }
  }

  /// TODO-779：返回 [AudioFetchOutcome]（ref 成功 / failureReason 可见失败 / none
  /// 无音频）而非裸 `String?`，让非 200 与异常不再静默落空，而是把原因冒泡到
  /// [MineOutcome.audioWarning] 给用户看。`return null` 的拒绝坏字节语义不变。
  Future<AudioFetchOutcome> _storeRemoteAudio(
      AnkiConnectService service, String url) async {
    try {
      File? audioFile;
      switch (AnkiAudioRef.classify(url)) {
        case AnkiAudioRefKind.empty:
          return const AudioFetchOutcome.none();
        case AnkiAudioRefKind.localFile:
          // file:// URI or a bare absolute path (Unix `/…` or Windows `C:\…`).
          final file = File(AnkiAudioRef.localPath(url));
          if (!file.existsSync()) return const AudioFetchOutcome.none();
          final bytes = await file.readAsBytes();
          final filename = hibikiAnkiMediaFilenameForBytes(
            prefix: 'hibiki_audio_',
            bytes: bytes,
            sourceName: file.path,
            fallbackExtension: 'mp3',
          );
          await service.storeMediaFile(
            filename: filename,
            data: base64Encode(bytes),
          );
          return AudioFetchOutcome.stored(filename);
        case AnkiAudioRefKind.remoteUrl:
          final client = HttpClient();
          try {
            final request = await client.getUrl(Uri.parse(url));
            final response = await request.close();
            // A non-200 returns an HTML/JSON error body; writing it verbatim to
            // .mp3 would embed a broken "audio" file into the card
            // (HBK-AUDIT-019). TODO-779: surface the failure instead of dropping
            // it silently — the card is still created, only the audio is missing.
            if (response.statusCode != 200) {
              final reason =
                  audioFetchHttpFailureReason(response.statusCode, url);
              debugPrint('AnkiConnectRepository._storeRemoteAudio: $reason');
              return AudioFetchOutcome.failed(reason);
            }
            final bytes =
                await response.fold<List<int>>([], (a, b) => a..addAll(b));
            final cacheDir =
                Directory('${Directory.systemTemp.path}/anki-media');
            if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
            // HBK-AUDIT-062: derive the real extension from the response
            // Content-Type (falling back to the URL path, then mp3) so non-mp3
            // audio is not mislabeled as .mp3 in Anki.
            final ext = _audioExtension(response.headers.contentType, url);
            final filename = hibikiAnkiMediaFilenameForBytes(
              prefix: 'hibiki_audio_',
              bytes: bytes,
              sourceName: url,
              fallbackExtension: ext,
            );
            audioFile = File('${cacheDir.path}/$filename');
            await audioFile.writeAsBytes(bytes);
          } finally {
            client.close();
          }
      }
      // Every switch branch above either returns or assigns audioFile, so it is
      // non-null here; only existence can still fail (missing local file or a
      // download that produced no file).
      if (!audioFile.existsSync()) return const AudioFetchOutcome.none();
      final bytes = await audioFile.readAsBytes();
      final filename = audioFile.uri.pathSegments.last;
      await service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      return AudioFetchOutcome.stored(filename);
    } catch (e, stack) {
      // TODO-779: a thrown exception (DNS/connection/timeout) is also a visible
      // audio failure — the card is still created, surface the reason.
      final reason = audioFetchErrorReason(e, url);
      debugPrint('AnkiConnectRepository._storeRemoteAudio: $reason\n$stack');
      return AudioFetchOutcome.failed(reason);
    }
  }

  /// HBK-AUDIT-062: resolve a remote audio file extension from the response
  /// Content-Type, falling back to the URL path extension, then `mp3`.
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
    // Fall back to the extension embedded in the URL path, then mp3.
    final path = Uri.tryParse(url)?.path ?? url;
    final lastDot = path.lastIndexOf('.');
    final lastSlash = path.lastIndexOf('/');
    if (lastDot > lastSlash && lastDot < path.length - 1) {
      return path.substring(lastDot + 1).toLowerCase();
    }
    return 'mp3';
  }

  Future<String?> _storeDictionaryMedia(
    AnkiConnectService service,
    DictionaryMedia media,
  ) async {
    try {
      // 命名/目录与主 app 的 writeDictionaryMediaCache 共用同一 helper（防漂移，
      // 否则文件名对不上→读不到→卡片留坏图）。HBK-AUDIT-062 无扩展名兜底已并入。
      final filename = ankiDictionaryMediaCacheFilename(media.path);
      final file = File('${ankiDictionaryMediaCacheDirPath()}/$filename');
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      await service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      // 返回**裸文件名**（与 AnkiDroid 经 ankiInlineMediaReference 对称）。义项 HTML
      // 已是 <img src="hoshi_dict_N.ext">，buildMinedFields 用 replaceAll 把 src 里的占位符
      // 替换成真实文件名；这里若返回完整 <img>/[sound:] 标签会嵌进 src 成
      // <img src="<img src=...>"> 嵌套坏图（外字不显示）。两端共用 ankiInlineMediaReference
      // 这一裸化单一真相，杜绝再次漂移回完整标签。
      final mime = mimeTypeForPath(filename);
      final wrapped = mime.startsWith('audio/')
          ? '[sound:$filename]'
          : '<img src="$filename">';
      return ankiInlineMediaReference(wrapped);
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeDictionaryMedia: $e\n$stack');
      return null;
    }
  }
}
