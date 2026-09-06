import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:url_launcher/url_launcher.dart';

typedef AnkiMobileUrlOpener = Future<bool> Function(Uri uri);
typedef AnkiMobileInfoReader = Future<AnkiMobilePasteboardRead> Function();
typedef AnkiMobileBackgroundTaskHandler = Future<void> Function();
typedef _AnkiMobileLocalMediaRefBuilder = Future<String?> Function(
  String filePath, {
  String? mimePath,
});

const String ankiMobileInfoCallback = 'anki://x-callback-url/infoForAdding';
const String ankiMobileAddNoteCallback = 'anki://x-callback-url/addnote';
const String fushiAnkiFetchCallback = 'fushi://ankiFetch';
const String fushiAnkiSuccessCallback = 'fushi://ankiSuccess';

/// AnkiMobile 把 `infoForAdding` 的结果放在系统剪贴板上（自定义类型
/// `net.ankimobile.json`）。读取只有三种结局，且**用户的下一步动作各不相同**——
/// BUG-2150 之前它们被压成同一句「剪贴板上没有 AnkiMobile 配置」，把人带进死路。
enum AnkiMobilePasteboardStatus {
  /// 读到了 JSON。
  ok,

  /// 剪贴板上没有 AnkiMobile 的数据：通常是用户没在 AnkiMobile 里同意那次请求
  /// （官方手册：「If the user authorises the request…」），或 AnkiMobile 太老。
  empty,

  /// 数据在，但系统不让读：用户在 iOS 的「允许粘贴」提示里选了不允许，或此刻
  /// 根本弹不出那个提示。
  denied,

  /// app 一直没回到前台，剪贴板**压根没被读过**（原生侧等 active 超时）。
  /// 与 [denied] 必须分开：非 active 时读出来的三态恒为 denied（内容读不到、
  /// 类型元数据却看得见），合并会把「没回前台」谎报成「权限被拒」。
  notActive,
}

/// 一次剪贴板读取的结果。[json] 仅在 [status] == [AnkiMobilePasteboardStatus.ok]
/// 时有值。
class AnkiMobilePasteboardRead {
  const AnkiMobilePasteboardRead(this.status, {this.json});

  const AnkiMobilePasteboardRead.ok(String json)
      : this(AnkiMobilePasteboardStatus.ok, json: json);

  const AnkiMobilePasteboardRead.empty()
      : this(AnkiMobilePasteboardStatus.empty);

  const AnkiMobilePasteboardRead.denied()
      : this(AnkiMobilePasteboardStatus.denied);

  const AnkiMobilePasteboardRead.notActive()
      : this(AnkiMobilePasteboardStatus.notActive);

  final AnkiMobilePasteboardStatus status;
  final String? json;
}

const MethodChannel _ankiMobileChannel =
    MethodChannel('app.fushi.reader/ankimobile');

String _encodeAnkiMobileQueryComponent(String value) =>
    Uri.encodeComponent(value);

String _buildAnkiMobileQuery(Iterable<MapEntry<String, String>> entries) {
  return entries
      .map((entry) => '${_encodeAnkiMobileQueryComponent(entry.key)}='
          '${_encodeAnkiMobileQueryComponent(entry.value)}')
      .join('&');
}

Uri buildAnkiMobileAddNoteUri({
  required String deckName,
  required String noteTypeName,
  required Map<String, String> fields,
  required List<String> tags,
  required bool allowDuplicate,
  Uri? successCallback,
}) {
  final query = <MapEntry<String, String>>[
    MapEntry('deck', deckName),
    MapEntry('type', noteTypeName),
    for (final entry in fields.entries)
      MapEntry('fld${entry.key}', entry.value),
    if (tags.isNotEmpty) MapEntry('tags', tags.join(' ')),
    if (allowDuplicate) const MapEntry('dupes', '1'),
    if (successCallback != null)
      MapEntry('x-success', successCallback.toString()),
  ];
  return Uri.parse(
      '$ankiMobileAddNoteCallback?${_buildAnkiMobileQuery(query)}');
}

class AnkiMobileRepository extends BaseAnkiRepository {
  AnkiMobileRepository({
    AnkiMobileUrlOpener? openUrl,
    AnkiMobileInfoReader? readInfoForAddingJson,
    Duration mediaServerLifetime = const Duration(seconds: 60),
    AnkiMobileBackgroundTaskHandler? beginMediaImportBackgroundTask,
    AnkiMobileBackgroundTaskHandler? endMediaImportBackgroundTask,
  })  : _openUrl = openUrl ?? _openExternalUrl,
        _readInfoForAddingJson =
            readInfoForAddingJson ?? _readInfoForAddingJsonFromPlatform,
        _mediaServerLifetime = mediaServerLifetime,
        _beginMediaImportBackgroundTask = beginMediaImportBackgroundTask ??
            _beginMediaImportBackgroundTaskFromPlatform,
        _endMediaImportBackgroundTask = endMediaImportBackgroundTask ??
            _endMediaImportBackgroundTaskFromPlatform;

  final AnkiMobileUrlOpener _openUrl;
  final AnkiMobileInfoReader _readInfoForAddingJson;
  final Duration _mediaServerLifetime;
  final AnkiMobileBackgroundTaskHandler _beginMediaImportBackgroundTask;
  final AnkiMobileBackgroundTaskHandler _endMediaImportBackgroundTask;

  static Future<bool> _openExternalUrl(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// BUG-2150：原生侧返回 `{status, json}`，而不再是裸 JSON 字符串——「没读到」
  /// 必须能区分「AnkiMobile 没写」与「系统不让读」。未知/缺失一律按 empty 处理。
  static Future<AnkiMobilePasteboardRead>
      _readInfoForAddingJsonFromPlatform() async {
    final Map<Object?, Object?>? raw = await _ankiMobileChannel
        .invokeMethod<Map<Object?, Object?>>('consumeInfoForAddingPasteboard');
    if (raw == null) return const AnkiMobilePasteboardRead.empty();
    final String? json = raw['json'] as String?;
    switch (raw['status']) {
      case 'ok':
        if (json == null || json.trim().isEmpty) {
          return const AnkiMobilePasteboardRead.empty();
        }
        return AnkiMobilePasteboardRead.ok(json);
      case 'denied':
        return const AnkiMobilePasteboardRead.denied();
      case 'notActive':
        return const AnkiMobilePasteboardRead.notActive();
      default:
        return const AnkiMobilePasteboardRead.empty();
    }
  }

  static Future<void> _beginMediaImportBackgroundTaskFromPlatform() async {
    if (!Platform.isIOS) return;
    try {
      await _ankiMobileChannel.invokeMethod<void>(
        'beginMediaImportBackgroundTask',
      );
    } catch (e, stack) {
      debugPrint('AnkiMobile begin background task failed: $e\n$stack');
    }
  }

  static Future<void> _endMediaImportBackgroundTaskFromPlatform() async {
    if (!Platform.isIOS) return;
    try {
      await _ankiMobileChannel.invokeMethod<void>(
        'endMediaImportBackgroundTask',
      );
    } catch (e, stack) {
      debugPrint('AnkiMobile end background task failed: $e\n$stack');
    }
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    // BUG-558 定下的编码规则对整个类成立：query 一律走 `_buildAnkiMobileQuery`
    // （百分号编码、空格 `%20`），不要在这里退回 `Uri.replace(queryParameters:)`
    // ——那条路把空格编成 `+`，是同一个类里的第二套编码规则。
    const List<MapEntry<String, String>> query = <MapEntry<String, String>>[
      MapEntry('x-success', fushiAnkiFetchCallback),
    ];
    final uri = Uri.parse(
        '$ankiMobileInfoCallback?${_buildAnkiMobileQuery(query)}');
    final opened = await _openUrl(uri);
    if (!opened) {
      return const AnkiFetchResult.error(
        'Could not open AnkiMobile. Install AnkiMobile and try again.',
        code: AnkiErrorCode.ankiMobileUnavailable,
      );
    }
    // 不是失败，是「等用户去 AnkiMobile 里点同意」的中间态：真正的结果随后经
    // `fushi://ankiFetch` 回调进 [consumeInfoForAddingPasteboard]。
    return const AnkiFetchResult.error(
      'AnkiMobile opened. Approve the request, then return to Fushi.',
      code: AnkiErrorCode.ankiMobileOpened,
    );
  }

  Future<AnkiFetchResult> consumeInfoForAddingPasteboard() async {
    final read = await _readInfoForAddingJson();
    final String? raw = read.json;
    if (read.status == AnkiMobilePasteboardStatus.notActive) {
      return const AnkiFetchResult.error(
        'Fushi did not come back to the foreground in time, so the clipboard '
        'was never read. Return to Fushi and try again.',
        code: AnkiErrorCode.ankiMobileNotActive,
      );
    }
    if (read.status == AnkiMobilePasteboardStatus.denied) {
      return const AnkiFetchResult.error(
        'iOS blocked reading the clipboard. Choose Allow Paste when returning '
        'to Fushi, then try again.',
        code: AnkiErrorCode.ankiMobilePasteboardDenied,
      );
    }
    if (read.status != AnkiMobilePasteboardStatus.ok ||
        raw == null ||
        raw.trim().isEmpty) {
      return const AnkiFetchResult.error(
        "AnkiMobile didn't return any configuration. Approve the request in "
        'AnkiMobile, then come back to Fushi.',
        code: AnkiErrorCode.ankiMobilePasteboardEmpty,
      );
    }

    final AnkiMobileInfoForAdding info;
    try {
      info = AnkiMobileInfoForAdding.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      return AnkiFetchResult.error('Could not read AnkiMobile response: $e');
    }

    if (info.decks.isEmpty || info.noteTypes.isEmpty) {
      return const AnkiFetchResult.error(
        'AnkiMobile returned no decks or note types.',
        code: AnkiErrorCode.ankiMobileNoDecks,
      );
    }

    final updated = await updateSettings((current) {
      final selectedDeck = selectDeckAfterFetch(info.decks, current);
      final selectedNoteType =
          selectNoteTypeAfterFetch(info.noteTypes, current);
      return current.copyWith(
        selectedDeckId: selectedDeck.id,
        selectedDeckName: selectedDeck.name,
        selectedNoteTypeId: selectedNoteType.id,
        selectedNoteTypeName: selectedNoteType.name,
        availableDecks: info.decks,
        availableNoteTypes: info.noteTypes,
        fieldMappings: fieldMappingsAfterFetch(selectedNoteType, current),
      );
    });

    return AnkiFetchResult.success(
      decks: updated.availableDecks,
      noteTypes: updated.availableNoteTypes,
    );
  }

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
        'AnkiMobile: unexpected error.',
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
    final AnkiDeck? deck = resolveSelectedDeck(settings);
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

    _AnkiMobileMediaServer? mediaServer;
    Future<_AnkiMobileMediaServer>? mediaServerFuture;
    Timer? mediaServerCloseTimer;
    var mediaServerKeepAliveStarted = false;
    Future<void>? mediaServerCloseFuture;

    Future<void> closeMediaServerKeepAlive() {
      final pendingClose = mediaServerCloseFuture;
      if (pendingClose != null) return pendingClose;

      mediaServerCloseTimer?.cancel();
      mediaServerCloseTimer = null;
      final server = mediaServer;
      mediaServer = null;
      final shouldEndBackgroundTask = mediaServerKeepAliveStarted;
      mediaServerKeepAliveStarted = false;

      mediaServerCloseFuture = () async {
        await server?.close();
        if (shouldEndBackgroundTask) {
          await _endMediaImportBackgroundTask();
        }
      }();
      return mediaServerCloseFuture!;
    }

    Future<void> beginMediaServerKeepAliveIfNeeded() async {
      if (mediaServer == null ||
          mediaServerKeepAliveStarted ||
          mediaServerCloseFuture != null) {
        return;
      }

      await _beginMediaImportBackgroundTask();
      mediaServerKeepAliveStarted = true;

      void closeLater() {
        unawaited(closeMediaServerKeepAlive());
      }

      if (_mediaServerLifetime > Duration.zero) {
        mediaServerCloseTimer = Timer(_mediaServerLifetime, closeLater);
      } else {
        Timer.run(closeLater);
      }
    }

    Future<String?> localMediaRef(
      String filePath, {
      String? mimePath,
    }) async {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      mediaServerFuture ??= _AnkiMobileMediaServer.start();
      final server = await mediaServerFuture!;
      mediaServer = server;
      return server.addFile(file, mimePath: mimePath);
    }

    try {
      final rendered = await _renderMinedFieldsForAnkiMobile(
        settings: settings,
        payload: payload,
        context: context,
        localMediaRef: localMediaRef,
      );
      final fields = rendered.fields;
      if (fields.isEmpty) {
        await closeMediaServerKeepAlive();
        return MineOutcome.failure(
          'All fields are empty — refusing to create a blank card. '
          'Check your note type field mappings.',
        );
      }

      final tags = buildNoteTags(
        settings.tags,
        source: context.source,
        includeHibiki: settings.tagIncludeHibiki,
        includeCategory: settings.tagIncludeCategory,
        titleTag: context.bookTitleTag,
        collectionTag: context.collectionTag,
      );
      final success = Uri.parse(fushiAnkiSuccessCallback).replace(
        queryParameters: <String, String>{
          if (payload.expression.isNotEmpty) 'expression': payload.expression,
        },
      );
      final uri = buildAnkiMobileAddNoteUri(
        deckName: deck.name,
        noteTypeName: noteType.name,
        fields: fields,
        tags: tags,
        allowDuplicate: settings.allowDupes,
        successCallback: success,
      );

      // Start the iOS background task before switching apps, otherwise the
      // localhost server can be suspended before AnkiMobile downloads media.
      await beginMediaServerKeepAliveIfNeeded();
      final opened = await _openUrl(uri);
      if (!opened) {
        await closeMediaServerKeepAlive();
        return MineOutcome.failure(
          'Could not open AnkiMobile. Install AnkiMobile and try again.',
          errorCode: AnkiErrorCode.ankiMobileUnavailable,
        );
      }
      // BUG-1549：实际落卡的牌组名随成功结果带回（与其余后端对称）。
      return MineOutcome.success(
        deckName: deck.name,
        audioWarning: rendered.audioWarning,
      );
    } catch (_) {
      await closeMediaServerKeepAlive();
      rethrow;
    }
  }

  Future<RenderedMinedFields> _renderMinedFieldsForAnkiMobile({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required _AnkiMobileLocalMediaRefBuilder localMediaRef,
  }) async {
    final List<Future<dynamic>> mediaFutures = <Future<dynamic>>[
      context.coverPath != null
          ? localMediaRef(context.coverPath!)
          : Future<String?>.value(null),
      context.sentenceAudioPath != null
          ? localMediaRef(context.sentenceAudioPath!)
          : Future<String?>.value(null),
      _audioFieldForAnkiMobile(payload.audio, localMediaRef),
      buildDictionaryMediaTags(
        payload.dictionaryMedia,
        (media) => _dictionaryMediaUrl(media, localMediaRef),
      ),
    ];
    final mediaResults = await Future.wait(mediaFutures);
    final String? coverUrl = mediaResults[0] as String?;
    final String? sentenceAudioUrl = mediaResults[1] as String?;
    final _AnkiMobileAudioField audio =
        mediaResults[2] as _AnkiMobileAudioField;
    final Map<String, String> dictionaryMediaTags =
        mediaResults[3] as Map<String, String>;

    final AnkiMiningContext mediaContext = context.withMediaRefs(
      coverRef: coverUrl,
      sentenceAudioRef: sentenceAudioUrl,
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
      phoneticTranscriptions: payload.phoneticTranscriptions,
      popupSelectionText: payload.popupSelectionText,
      glossarySelectionHighlighted: payload.glossarySelectionHighlighted,
      audio: audio.fieldValue,
      selectedDictionary: payload.selectedDictionary,
      dictionaryMedia: payload.dictionaryMedia,
    );

    return RenderedMinedFields(
      buildMinedFields(
        fieldMappings: settings.fieldMappings,
        payload: mediaPayload,
        context: mediaContext,
        dictionaryMediaTags: dictionaryMediaTags,
        noteTypeName: settings.selectedNoteTypeName,
      ),
    );
  }

  Future<_AnkiMobileAudioField> _audioFieldForAnkiMobile(
    String audio,
    _AnkiMobileLocalMediaRefBuilder localMediaRef,
  ) async {
    switch (AnkiAudioRef.classify(audio)) {
      case AnkiAudioRefKind.empty:
        return const _AnkiMobileAudioField('');
      case AnkiAudioRefKind.remoteUrl:
        return _AnkiMobileAudioField(audio);
      case AnkiAudioRefKind.dataUri:
        // BUG-1050：查词弹窗把本地音频库命中的单词发音编码成 `data:` URI 塞进
        // fields['audio']。解码内联字节写临时文件，经本地媒体服务器（addFile 复制
        // 快照）转成 AnkiMobile 可取的 URL，与 localFile 走同一入库通道。
        final data = AnkiAudioRef.decodeDataUri(audio);
        if (data == null) return const _AnkiMobileAudioField('');
        final tempFile = File('${Directory.systemTemp.path}'
            '${Platform.pathSeparator}fushi_word_audio_'
            '${DateTime.now().microsecondsSinceEpoch}.${data.extension}');
        try {
          await tempFile.writeAsBytes(data.bytes);
          final url = await localMediaRef(tempFile.path,
              mimePath: 'word_audio.${data.extension}');
          if (url != null) return _AnkiMobileAudioField(url);
          return const _AnkiMobileAudioField('');
        } finally {
          if (tempFile.existsSync()) {
            try {
              tempFile.deleteSync();
            } catch (_) {}
          }
        }
      case AnkiAudioRefKind.localFile:
        final path = AnkiAudioRef.localPath(audio);
        final url = await localMediaRef(path);
        if (url != null) return _AnkiMobileAudioField(url);
        return const _AnkiMobileAudioField('');
    }
  }

  Future<String?> _dictionaryMediaUrl(
    DictionaryMedia media,
    _AnkiMobileLocalMediaRefBuilder localMediaRef,
  ) {
    final filename =
        ankiDictionaryMediaCacheFilename(media.dictionary, media.path);
    final path = '${ankiDictionaryMediaCacheDirPath()}/$filename';
    return localMediaRef(path, mimePath: filename);
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

class _AnkiMobileMediaServer {
  _AnkiMobileMediaServer._(this._server, this._tempDir) {
    _server.listen(_handleRequest);
  }

  final HttpServer _server;
  final Directory _tempDir;
  final Map<String, _ServedAnkiMobileMedia> _files =
      <String, _ServedAnkiMobileMedia>{};
  var _nextId = 0;
  var _closed = false;

  static Future<_AnkiMobileMediaServer> start() async {
    final tempDir =
        await Directory.systemTemp.createTemp('fushi_ankimobile_media_');
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      return _AnkiMobileMediaServer._(server, tempDir);
    } catch (_) {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
      rethrow;
    }
  }

  String addFile(File file, {String? mimePath}) {
    final sourceName = _safeMediaBasename(mimePath ?? file.path);
    final id = _nextId++;
    final path = '/media/$id-$sourceName';
    final snapshot = File('${_tempDir.path}${Platform.pathSeparator}'
        '$id-$sourceName');
    file.copySync(snapshot.path);
    _files[path] = _ServedAnkiMobileMedia(
      file: snapshot,
      mimeType: mimeTypeForPath(mimePath ?? file.path),
    );
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      path: path,
    ).toString();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _server.close(force: true);
    } finally {
      if (_tempDir.existsSync()) {
        try {
          await _tempDir.delete(recursive: true);
        } catch (e, stack) {
          debugPrint('AnkiMobile media temp cleanup failed: $e\n$stack');
        }
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      request.response.headers
          .set(HttpHeaders.accessControlAllowOriginHeader, '*');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final media = _files[request.uri.path];
      if (media == null || !media.file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.parse(media.mimeType);
      request.response.headers.contentLength = media.file.lengthSync();
      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }
      await request.response.addStream(media.file.openRead());
      await request.response.close();
    } catch (e, stack) {
      debugPrint('AnkiMobile media server request failed: $e\n$stack');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // The client may have gone away while AnkiMobile was switching apps.
      }
    }
  }

  static String _safeMediaBasename(String path) {
    final raw = path.split(RegExp(r'[/\\]')).last;
    final base = raw.isEmpty ? 'media.bin' : raw;
    return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

class _ServedAnkiMobileMedia {
  const _ServedAnkiMobileMedia({
    required this.file,
    required this.mimeType,
  });

  final File file;
  final String mimeType;
}

class _AnkiMobileAudioField {
  const _AnkiMobileAudioField(this.fieldValue);

  final String fieldValue;
}

class AnkiMobileInfoForAdding {
  const AnkiMobileInfoForAdding({
    required this.decks,
    required this.noteTypes,
  });

  factory AnkiMobileInfoForAdding.fromJson(Map<String, dynamic> json) {
    final decksRaw = (json['decks'] as List? ?? const <Object?>[]);
    final noteTypesRaw = (json['notetypes'] as List? ?? const <Object?>[]);
    final decks = <AnkiDeck>[
      for (var i = 0; i < decksRaw.length; i++)
        AnkiDeck(
          id: i,
          name: _nameFromJsonItem(decksRaw[i]),
        ),
    ].where((deck) => deck.name.isNotEmpty).toList(growable: false);
    final noteTypes = <AnkiNoteType>[
      for (var i = 0; i < noteTypesRaw.length; i++)
        _noteTypeFromJsonItem(i, noteTypesRaw[i]),
    ].where((noteType) => noteType.name.isNotEmpty).toList(growable: false);
    return AnkiMobileInfoForAdding(decks: decks, noteTypes: noteTypes);
  }

  final List<AnkiDeck> decks;
  final List<AnkiNoteType> noteTypes;

  static AnkiNoteType _noteTypeFromJsonItem(int id, Object? raw) {
    if (raw is! Map) {
      return AnkiNoteType(
          id: id, name: raw?.toString() ?? '', fields: const []);
    }
    final fieldsRaw = raw['fields'] as List? ?? const <Object?>[];
    return AnkiNoteType(
      id: id,
      name: raw['name']?.toString() ?? '',
      fields: fieldsRaw
          .map(_nameFromJsonItem)
          .where((field) => field.isNotEmpty)
          .toList(growable: false),
    );
  }

  static String _nameFromJsonItem(Object? raw) {
    if (raw is Map) return raw['name']?.toString() ?? '';
    return raw?.toString() ?? '';
  }
}
