import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:url_launcher/url_launcher.dart';

typedef AnkiMobileUrlOpener = Future<bool> Function(Uri uri);
typedef AnkiMobileInfoReader = Future<AnkiMobilePasteboardRead> Function();
typedef AnkiMobileBackgroundTaskHandler = Future<void> Function();
typedef _AnkiMobileLocalMediaRefBuilder =
    Future<String?> Function(String filePath, {String? mimePath});

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

const MethodChannel _ankiMobileChannel = MethodChannel(
  'app.fushi.reader/ankimobile',
);

/// 谁触发了「去读 AnkiMobile 回传结果」（BUG-2493）。
enum AnkiMobileInfoReturnTrigger {
  /// AnkiMobile 的 `x-success=fushi://ankiFetch` 真的送达了。
  urlCallback,

  /// app 回到前台（`AppLifecycleState.resumed`）——x-success 没送达时的兜底。
  appResumed,
}

/// 一次 `infoForAdding` 往返的状态机（BUG-2493）。
///
/// 往返有两个可能的终点：AnkiMobile 的 `x-success` 回调，以及 app 单纯回到前台
/// （回调没送达、用户手动切回、或 AnkiMobile 那侧根本没同意）。两条路都要能触发
/// 读剪贴板，但**同一次往返只许读一次**——剪贴板取走即清空，第二次读必然是
/// `empty`，会把刚刚成功落地的结果又用一条「AnkiMobile 没有回传配置」盖掉。
///
/// 进程级单例：`ankiRepositoryProvider` 会随「制卡到已配对设备」开关重建仓库实例，
/// 状态挂在实例上会在往返途中丢失。
class AnkiMobileInfoReturnCoordinator {
  AnkiMobileInfoReturnCoordinator();

  static final AnkiMobileInfoReturnCoordinator instance =
      AnkiMobileInfoReturnCoordinator();

  /// 已打开 AnkiMobile、结果还没取回。
  bool _awaitingReturn = false;

  /// 本进程内是否发起过请求或消费过一次回传。没发起过却收到 URL 回调 = 冷启动
  /// （进程被杀后由 x-success 拉起），这时内存里的 [_awaitingReturn] 已丢，仍应读
  /// 一次——但只读一次，冷启动后重复送达的同一条 URL 不再算数。
  bool _requestedThisProcess = false;

  Future<AnkiFetchResult>? _inFlight;

  bool get awaitingReturn => _awaitingReturn;

  void markRequested() {
    _awaitingReturn = true;
    _requestedThisProcess = true;
  }

  /// 该不该为这次 [trigger] 去读。
  bool shouldConsume(AnkiMobileInfoReturnTrigger trigger) {
    if (_inFlight != null) return false;
    switch (trigger) {
      case AnkiMobileInfoReturnTrigger.urlCallback:
        return _awaitingReturn || !_requestedThisProcess;
      case AnkiMobileInfoReturnTrigger.appResumed:
        return _awaitingReturn;
    }
  }

  /// 按状态机决定是否执行 [read]；不该读时返回 null（调用方什么都不做）。
  /// `notActive`（原生侧等前台超时、根本没读过剪贴板）不算终点：保留等待态，
  /// 让下一次回到前台再试。
  Future<AnkiFetchResult?> consume(
    AnkiMobileInfoReturnTrigger trigger,
    Future<AnkiFetchResult> Function() read,
  ) async {
    if (!shouldConsume(trigger)) return null;
    _awaitingReturn = false;
    _requestedThisProcess = true;
    final Future<AnkiFetchResult> future = read();
    _inFlight = future;
    try {
      final AnkiFetchResult result = await future;
      if (!_isRoundTripTerminal(trigger, result)) _awaitingReturn = true;
      return result;
    } finally {
      _inFlight = null;
    }
  }

  /// 这次读能不能关掉往返。
  ///
  /// - `notActive`（原生侧等前台超时、根本没读剪贴板）任何触发都不算终点。
  /// - **回到前台的兜底读只有真拿到结果才算终点**：用户打开 AnkiMobile 后先手动
  ///   切回来看一眼，这时 AnkiMobile 还没写剪贴板，读到 `empty`/`denied` 若就此
  ///   关闭往返，随后用户在 AnkiMobile 点同意送达的 `x-success` 回调会被
  ///   [shouldConsume] 拒掉——把 BUG-2493 描述的「回调送达却被丢弃」换个形态重引。
  /// - URL 回调是 AnkiMobile 写完剪贴板才发的权威信号，读到什么都是终点；
  ///   「同一往返只读一次」只需防它成功之后的 resume 重读。
  static bool _isRoundTripTerminal(
    AnkiMobileInfoReturnTrigger trigger,
    AnkiFetchResult result,
  ) {
    if (result is! AnkiFetchError) return true;
    if (result.code == AnkiErrorCode.ankiMobileNotActive) return false;
    return trigger == AnkiMobileInfoReturnTrigger.urlCallback;
  }
}

/// 从 `ankiRepositoryProvider` 给出的仓库里找出真正的 [AnkiMobileRepository]
/// （BUG-2493）：开了「制卡到已配对设备」时它被 [RemoteMiningAnkiRepository]
/// 包着，直接 `is` 判型会把整条回传链静默丢掉。不是 AnkiMobile 后端时返回 null
/// （iOS 改用 AnkiConnect 时就是这样，回传无事可做）。
AnkiMobileRepository? resolveAnkiMobileRepository(BaseAnkiRepository repo) {
  final BaseAnkiRepository unwrapped = repo is RemoteMiningAnkiRepository
      ? repo.local
      : repo;
  return unwrapped is AnkiMobileRepository ? unwrapped : null;
}

String _encodeAnkiMobileQueryComponent(String value) =>
    Uri.encodeComponent(value);

String _buildAnkiMobileQuery(Iterable<MapEntry<String, String>> entries) {
  return entries
      .map(
        (entry) =>
            '${_encodeAnkiMobileQueryComponent(entry.key)}='
            '${_encodeAnkiMobileQueryComponent(entry.value)}',
      )
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
    '$ankiMobileAddNoteCallback?${_buildAnkiMobileQuery(query)}',
  );
}

class AnkiMobileRepository extends BaseAnkiRepository {
  AnkiMobileRepository({
    AnkiMobileUrlOpener? openUrl,
    AnkiMobileInfoReader? readInfoForAddingJson,
    Duration mediaServerLifetime = const Duration(seconds: 60),
    AnkiMobileBackgroundTaskHandler? beginMediaImportBackgroundTask,
    AnkiMobileBackgroundTaskHandler? endMediaImportBackgroundTask,
    AnkiMobileInfoReturnCoordinator? infoReturnCoordinator,
  }) : _openUrl = openUrl ?? _openExternalUrl,
       _infoReturnCoordinator =
           infoReturnCoordinator ?? AnkiMobileInfoReturnCoordinator.instance,
       _readInfoForAddingJson =
           readInfoForAddingJson ?? _readInfoForAddingJsonFromPlatform,
       _mediaServerLifetime = mediaServerLifetime,
       _beginMediaImportBackgroundTask =
           beginMediaImportBackgroundTask ??
           _beginMediaImportBackgroundTaskFromPlatform,
       _endMediaImportBackgroundTask =
           endMediaImportBackgroundTask ??
           _endMediaImportBackgroundTaskFromPlatform;

  final AnkiMobileUrlOpener _openUrl;
  final AnkiMobileInfoReturnCoordinator _infoReturnCoordinator;
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
      '$ankiMobileInfoCallback?${_buildAnkiMobileQuery(query)}',
    );
    final opened = await _openUrl(uri);
    if (!opened) {
      return const AnkiFetchResult.error(
        'Could not open AnkiMobile. Install AnkiMobile and try again.',
        code: AnkiErrorCode.ankiMobileUnavailable,
      );
    }
    // 不是失败，是「等用户去 AnkiMobile 里点同意」的中间态：真正的结果随后经
    // `fushi://ankiFetch` 回调、或 app 回到前台（BUG-2493 兜底）进
    // [consumeInfoForAddingReturn]。
    _infoReturnCoordinator.markRequested();
    return const AnkiFetchResult.error(
      'AnkiMobile opened. Approve the request, then return to Fushi.',
      code: AnkiErrorCode.ankiMobileOpened,
    );
  }

  /// 往返终点的统一入口（BUG-2493）：由 [AnkiMobileInfoReturnCoordinator] 决定
  /// 这次 [trigger] 该不该真的去读剪贴板；不该读时返回 null，调用方不动 UI。
  Future<AnkiFetchResult?> consumeInfoForAddingReturn(
    AnkiMobileInfoReturnTrigger trigger,
  ) => _infoReturnCoordinator.consume(trigger, consumeInfoForAddingPasteboard);

  /// 无条件读一次剪贴板并落库。生产路径走 [consumeInfoForAddingReturn]，
  /// 这里保留为裸读取以便测试三态契约。
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
      final selectedNoteType = selectNoteTypeAfterFetch(
        info.noteTypes,
        current,
      );
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

    final noteType =
        settings.availableNoteTypes.firstWhereOrNull(
          (t) => t.id == settings.selectedNoteTypeId,
        ) ??
        (settings.selectedNoteTypeName != null
            ? settings.availableNoteTypes.firstWhereOrNull(
                (t) => t.name == settings.selectedNoteTypeName,
              )
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

    Future<String?> localMediaRef(String filePath, {String? mimePath}) async {
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
        charPositionTag: context.charPositionTag,
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
        final tempFile = File(
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}fushi_word_audio_'
          '${DateTime.now().microsecondsSinceEpoch}.${data.extension}',
        );
        try {
          await tempFile.writeAsBytes(data.bytes);
          final url = await localMediaRef(
            tempFile.path,
            mimePath: 'word_audio.${data.extension}',
          );
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
    final filename = ankiDictionaryMediaCacheFilename(
      media.dictionary,
      media.path,
    );
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
    final tempDir = await Directory.systemTemp.createTemp(
      'fushi_ankimobile_media_',
    );
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
    final snapshot = File(
      '${_tempDir.path}${Platform.pathSeparator}'
      '$id-$sourceName',
    );
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
      request.response.headers.set(
        HttpHeaders.accessControlAllowOriginHeader,
        '*',
      );
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
  const _ServedAnkiMobileMedia({required this.file, required this.mimeType});

  final File file;
  final String mimeType;
}

class _AnkiMobileAudioField {
  const _AnkiMobileAudioField(this.fieldValue);

  final String fieldValue;
}

class AnkiMobileInfoForAdding {
  const AnkiMobileInfoForAdding({required this.decks, required this.noteTypes});

  factory AnkiMobileInfoForAdding.fromJson(Map<String, dynamic> json) {
    final decksRaw = (json['decks'] as List? ?? const <Object?>[]);
    final noteTypesRaw = (json['notetypes'] as List? ?? const <Object?>[]);
    final decks = <AnkiDeck>[
      for (var i = 0; i < decksRaw.length; i++)
        AnkiDeck(id: i, name: _nameFromJsonItem(decksRaw[i])),
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
        id: id,
        name: raw?.toString() ?? '',
        fields: const [],
      );
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
