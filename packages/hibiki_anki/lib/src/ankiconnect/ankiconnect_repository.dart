import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../anki_media_dedup.dart';
import '../anki_models.dart';
import '../anki_note_type_definition.dart';
import '../base_anki_repository.dart';
import '../lapis_note_type.dart';
import '../lapis_styling.dart';
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

/// BUG-933：制卡「未响应」根因之一——旧代码在 **UI isolate** 对整段媒体字节同步跑
/// [_sha256Hex]（纯 Dart 逐字节 SHA256，几 MB 音频=数百万次迭代）和 [base64Encode]，
/// 阻塞主线程。这里把「哈希文件名 + base64」一次卸到后台 isolate，同段字节只跨 isolate
/// 拷贝一次。
///
/// 阈值兜底：词典外字（单卡可能数十个、每个仅几 KB）走同步分支——为几 KB 图各起一个
/// isolate 反而挤占资源、拖慢总时长（且不会 jank）；只有封面/音频等大媒体才卸后台。
const int _isolateMediaThresholdBytes = 64 * 1024;

/// AnkiConnect 上传路径：计算 sha256 文件名 + base64 数据。大媒体在后台 isolate 完成，
/// 小媒体同步完成。返回记录 `(filename, base64Data)` 供 `storeMediaFile`。
Future<({String filename, String base64Data})>
    hibikiAnkiMediaEncodeForUploadAsync({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  ({String filename, String base64Data}) encode() => (
        filename: hibikiAnkiMediaFilenameForBytes(
          prefix: prefix,
          bytes: bytes,
          sourceName: sourceName,
          fallbackExtension: fallbackExtension,
        ),
        base64Data: base64Encode(bytes),
      );
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<({String filename, String base64Data})>.value(encode());
  }
  return Isolate.run(encode);
}

/// AnkiDroid 路径：媒体由 platform channel 按文件路径落库（不走 base64），只需 sha256
/// 文件名。大媒体在后台 isolate 完成，小媒体同步完成。
Future<String> hibikiAnkiMediaFilenameForBytesAsync({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  String compute() => hibikiAnkiMediaFilenameForBytes(
        prefix: prefix,
        bytes: bytes,
        sourceName: sourceName,
        fallbackExtension: fallbackExtension,
      );
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<String>.value(compute());
  }
  return Isolate.run(compute);
}

/// [base64Encode] 的按需后台变体（BUG-933）：大媒体卸到 isolate，小媒体同步。用于
/// 文件名已定、只剩 base64 的路径（远端下载音频 / 词典外字上传）。
Future<String> hibikiAnkiBase64EncodeAsync(List<int> bytes) {
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<String>.value(base64Encode(bytes));
  }
  return Isolate.run(() => base64Encode(bytes));
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

final Expando<_MediaUploadCoordinator> _mediaUploadCoordinators =
    Expando<_MediaUploadCoordinator>('AnkiConnect media upload coordinators');

class _MediaUploadLeaseState {
  final Set<_MediaUploadTransaction> participants =
      Set<_MediaUploadTransaction>.identity();
  bool committed = false;
  Completer<void> changed = Completer<void>();
  Future<bool>? cleanupAttempt;

  void notifyChanged() {
    if (!changed.isCompleted) {
      changed.complete();
    }
    changed = Completer<void>();
  }
}

/// Coordinates compensation for the same media filename across concurrent note
/// transactions that share one AnkiConnect connection.
///
/// An existence check can race: two notes may both observe "absent" and upload
/// the same content-addressed filename. A failed transaction therefore releases
/// its lease and waits for every peer lease to settle before deleting. Once any
/// peer commits, the filename remains protected for the lifetime of this
/// connector so a stale negative existence result can never delete media
/// referenced by the peer's note.
class _MediaUploadCoordinator {
  _MediaUploadCoordinator(this.service);

  final AnkiConnectService service;
  final Map<String, _MediaUploadLeaseState> _states =
      <String, _MediaUploadLeaseState>{};

  Future<void> claim(
    _MediaUploadTransaction transaction,
    String filename,
  ) async {
    _MediaUploadLeaseState state =
        _states.putIfAbsent(filename, _MediaUploadLeaseState.new);
    while (state.cleanupAttempt != null) {
      await state.cleanupAttempt;
      state = _states.putIfAbsent(filename, _MediaUploadLeaseState.new);
    }
    if (state.participants.add(transaction)) {
      state.notifyChanged();
    }
  }

  void commit(_MediaUploadTransaction transaction, String filename) {
    final _MediaUploadLeaseState? state = _states[filename];
    if (state == null) return;
    state.committed = true;
    state.participants.remove(transaction);
    state.notifyChanged();
  }

  Future<bool> rollback(
    _MediaUploadTransaction transaction,
    String filename,
  ) async {
    final _MediaUploadLeaseState? state = _states[filename];
    if (state == null) return true;
    if (state.participants.remove(transaction)) {
      state.notifyChanged();
    }

    while (!state.committed && state.participants.isNotEmpty) {
      final Future<void> changed = state.changed.future;
      if (!state.committed && state.participants.isNotEmpty) {
        await changed;
      }
    }
    if (state.committed) return true;

    final Future<bool>? pendingCleanup = state.cleanupAttempt;
    if (pendingCleanup != null) return pendingCleanup;

    final Completer<bool> cleanup = Completer<bool>();
    state.cleanupAttempt = cleanup.future;
    try {
      await service.deleteMediaFile(filename);
      _states.remove(filename);
      cleanup.complete(true);
    } catch (error, stack) {
      // Keep the uncommitted state in the coordinator. The owning transaction
      // retains the filename and retries after every parallel media route has
      // settled instead of losing the candidate to a non-fatal audio warning.
      debugPrint(
        'AnkiConnect media rollback failed for $filename: $error\n$stack',
      );
      cleanup.complete(false);
    } finally {
      if (identical(state.cleanupAttempt, cleanup.future)) {
        state.cleanupAttempt = null;
      }
    }
    return cleanup.future;
  }
}

/// Tracks content-addressed media created while rendering one note.
///
/// Uploads stay parallel, but every filename is checked once before its first
/// write. Same-filename routes inside the transaction share one upload Future.
/// A failed upload attempts compensation immediately, while a retained
/// candidate is retried by [commit] after all routes settle. Cross-transaction
/// leases prevent a failed note from deleting media committed by a concurrent
/// peer. Files that existed before this attempt are never deletion candidates.
class _MediaUploadTransaction {
  _MediaUploadTransaction(this.service)
      : coordinator = _mediaUploadCoordinators[service] ??=
            _MediaUploadCoordinator(service);

  final AnkiConnectService service;
  final _MediaUploadCoordinator coordinator;
  final Map<String, Future<bool>> _existenceChecks = <String, Future<bool>>{};
  final Map<String, Future<void>> _uploads = <String, Future<void>>{};
  final Set<String> _newFiles = <String>{};
  final Set<String> _failedFiles = <String>{};

  Future<void> upload({
    required String filename,
    required Future<void> Function() write,
  }) =>
      _uploads[filename] ??= _upload(filename: filename, write: write);

  Future<void> _upload({
    required String filename,
    required Future<void> Function() write,
  }) async {
    final bool existedBefore = await (_existenceChecks[filename] ??=
        service.mediaFileExists(filename));
    if (!existedBefore) {
      // Register before the write: a lost storeMediaFile response may still
      // mean Anki committed the file, so the failure path must try to remove it.
      _newFiles.add(filename);
      await coordinator.claim(this, filename);
    }
    try {
      await write();
    } catch (_) {
      if (!existedBefore) {
        _failedFiles.add(filename);
        if (await coordinator.rollback(this, filename)) {
          _newFiles.remove(filename);
          _failedFiles.remove(filename);
        }
      }
      rethrow;
    }
  }

  Future<void> rollback() async {
    for (final String filename in _newFiles.toList(growable: false)) {
      if (await coordinator.rollback(this, filename)) {
        _newFiles.remove(filename);
        _failedFiles.remove(filename);
      }
    }
  }

  Future<void> commit() async {
    // A non-fatal remote-audio route catches its upload error and becomes an
    // audioWarning. Retry its retained cleanup candidate only after Future.wait
    // has settled all routes; never clear it merely because the card may commit.
    for (final String filename in _failedFiles.toList(growable: false)) {
      if (!await coordinator.rollback(this, filename)) {
        throw StateError(
          'Could not safely clean up failed Anki media upload: $filename',
        );
      }
      _newFiles.remove(filename);
      _failedFiles.remove(filename);
    }
    for (final String filename in _newFiles.toList(growable: false)) {
      coordinator.commit(this, filename);
      _newFiles.remove(filename);
    }
  }
}

/// 一条笔记的字段改写计划：[before] 是改写前的原值（journal 用来回溯），
/// [after] 是要写进 Anki 的新值。两者键集相同，只含真正会变的字段。
class _NoteFieldRewrite {
  const _NoteFieldRewrite({required this.before, required this.after});

  final Map<String, String> before;
  final Map<String, String> after;
}

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
      // 合集/系列名标签（同上开关）：视频=播放列表系列名、书籍=所属合集名；不属合集时 null。
      collectionTag: context.collectionTag,
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
        duplicateScope: settings.duplicateScope,
      );
      return MineOutcome.success(noteId: noteId, audioWarning: audioWarning);
    } on AnkiConnectDuplicateException {
      return const MineOutcome.duplicate();
    } on AnkiConnectCommitUnknownException catch (e, stack) {
      // Without a separate preflight query, a matching note after a lost
      // response could be either pre-existing or newly created. Do not run
      // another GUI-thread findNotes query or guess which case occurred.
      return MineOutcome.failure(
        _addNoteCommitUnknownMessage(),
        error: e,
        stackTrace: stack,
      );
    } on AnkiConnectException catch (e, stack) {
      return MineOutcome.failure(
        'AnkiConnect: ${e.message}',
        error: e,
        stackTrace: stack,
      );
    }
  }

  String _addNoteCommitUnknownMessage() =>
      'AnkiConnect may have created the card, but the response was lost. '
      'Hibiki could not safely confirm the result. Please check Anki before '
      'retrying.';

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
    bool keepEmpty = false,
  }) async {
    final _MediaUploadTransaction mediaTransaction =
        _MediaUploadTransaction(service);
    final List<Future<dynamic>> mediaFutures = <Future<dynamic>>[
      context.coverPath != null
          ? _storeLocalMedia(
              service,
              mediaTransaction,
              context.coverPath!,
              'hibiki_cover_',
            )
          : Future<String?>.value(null),
      context.sasayakiAudioPath != null
          ? _storeLocalMedia(
              service,
              mediaTransaction,
              context.sasayakiAudioPath!,
              'hibiki_audio_',
            )
          : Future<String?>.value(null),
      payload.audio.isNotEmpty
          ? _storeRemoteAudio(service, mediaTransaction, payload.audio)
          : Future<AudioFetchOutcome>.value(const AudioFetchOutcome.none()),
      buildDictionaryMediaTags(
        payload.dictionaryMedia,
        (media) => _storeDictionaryMedia(service, mediaTransaction, media),
      ),
    ];
    try {
      final List<dynamic> mediaResults = await Future.wait(mediaFutures);
      final String? coverMediaRef = mediaResults[0] as String?;
      final String? sasayakiMediaRef = mediaResults[1] as String?;
      final AudioFetchOutcome remoteAudio =
          mediaResults[2] as AudioFetchOutcome;
      final Map<String, String> dictionaryMediaTags =
          mediaResults[3] as Map<String, String>;

      final String? remoteAudioRef = remoteAudio.ref;
      final RenderedMinedFields rendered = renderMediaPayload(
        settings: settings,
        payload: payload,
        context: context,
        coverRef: coverMediaRef != null ? '<img src="$coverMediaRef">' : null,
        sasayakiRef:
            sasayakiMediaRef != null ? '[sound:$sasayakiMediaRef]' : null,
        processedAudio: remoteAudioRef != null ? '[sound:$remoteAudioRef]' : '',
        dictionaryMediaTags: dictionaryMediaTags,
        audioWarning: remoteAudio.failureReason,
        keepEmpty: keepEmpty,
      );
      await mediaTransaction.commit();
      return rendered;
    } catch (_) {
      // Future.wait completes only after every route settles by default, so all
      // successful parallel writes are known before compensation starts.
      await mediaTransaction.rollback();
      rethrow;
    }
  }

  /// TODO-270 C1：更新一张**已存在**的 Hibiki 制卡（[noteId]）的字段。
  ///
  /// 复用 [_renderMinedFields]（与制卡同一字段渲染 + 媒体上传链路）从
  /// [rawPayloadJson] + [context] 生成 fields，再调 [AnkiConnectService.updateNoteFields]
  /// 按 id 覆盖。与 [mineEntry] 一样保证**返回** [MineOutcome] 而非抛出（供调用方
  /// 统一 switch 处理 toast/UI）。不新增卡片、不改 tag、不查重（更新语义）。
  ///
  /// BUG-858：覆盖=整体替换。keepEmpty 令 [_renderMinedFields] 保留所有映射字段
  /// （含渲染为空的），使 `updateNoteFields` 真正按 id 替换每个映射字段（句子瞬时选区
  /// 为空时随之清空，不再静默保留旧句）。仅当**所有**字段渲染皆空白时拒绝——那是
  /// 「没有任何字段映射命中」会清空整卡，才拒绝；部分字段有内容时照常整体替换。
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
        keepEmpty: true,
      );
      final Map<String, String> fields = rendered.fields;

      // 所有映射字段渲染皆空白（含无字段映射）说明会把整卡清空——拒绝。部分字段
      // 有内容时按覆盖语义整体替换（空字段随之清空，Never break userspace 见 BUG-858）。
      if (fields.values.every((String v) => v.trim().isEmpty)) {
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
        scope: settings.duplicateScope,
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
        scope: settings.duplicateScope,
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
        scope: settings.duplicateScope,
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

  // ── note type 模板读写（Lapis 客制化/备份/自动迁移）────────────────────

  @override
  bool get supportsNoteTypeEditing => true;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
      String modelName) async {
    final service = await _getService();
    final List<String> existing = await service.getModelNames();
    if (!existing.contains(modelName)) return null;
    final List<String> fields = await service.getModelFields(modelName);
    final List<AnkiCardTemplate> templates =
        await service.modelTemplates(modelName);
    final String css = await service.modelStyling(modelName);
    return AnkiNoteTypeDefinition(
      name: modelName,
      fields: fields,
      templates: templates,
      css: css,
    );
  }

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async {
    final service = await _getService();
    await service.updateModelStyling(modelName, css);
    return true;
  }

  @override
  Future<bool> updateNoteTypeTemplates(
      String modelName, List<AnkiCardTemplate> templates) async {
    final service = await _getService();
    await service.updateModelTemplates(modelName, templates);
    return true;
  }

  // ── 媒体存储优化（字节级去重）──────────────────────────────────────

  @override
  bool get supportsMediaMaintenance => true;

  /// 媒体目录里的一个文件（媒体目录是扁平的，文件名即相对路径）。
  File _mediaFile(Directory mediaDir, String name) =>
      File('${mediaDir.path}${Platform.pathSeparator}$name');

  /// 媒体目录里每个文件的字节数（只 stat，不读内容）。
  Future<Map<String, int>> _scanMediaSizes(Directory mediaDir) async {
    final Map<String, int> sizes = <String, int>{};
    await for (final FileSystemEntity entity
        in mediaDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (name.isEmpty) continue;
      sizes[name] = await entity.length();
    }
    return sizes;
  }

  /// 只对「大小撞车」的候选算**全文件** sha256（大小不同不可能字节相同）。
  /// 判等永远是全文件哈希 + 删除前逐字节复核，绝不用截断哈希或感知哈希。
  Future<Map<String, String>> _hashSizeCollisions(
    Directory mediaDir,
    Map<String, int> sizes,
  ) async {
    final Map<int, List<String>> bySize = <int, List<String>>{};
    sizes.forEach(
        (String n, int s) => bySize.putIfAbsent(s, () => <String>[]).add(n));
    final Map<String, String> nameToHash = <String, String>{};
    for (final MapEntry<int, List<String>> entry in bySize.entries) {
      if (entry.value.length < 2) continue;
      for (final String name in entry.value) {
        final Uint8List bytes = await _mediaFile(mediaDir, name).readAsBytes();
        nameToHash[name] = crypto.sha256.convert(bytes).toString();
      }
    }
    return nameToHash;
  }

  /// 读出所有「会引用别的资源」的文本媒体（css/js/html/svg…）正文。
  ///
  /// 这是引用扫描的第四个面（前三个是笔记字段 / 卡模板 / styling）。缺了它，
  /// `_x.css` 里的 `url(_font.woff2)` 谁都查不到，而本模块又恰好优先保留 `_`
  /// 前缀资产，结果就是把仍在用的字体静默删掉。
  ///
  /// 用 `allowMalformed` 解码：正文可能不是合法 UTF-8（半个序列/别的编码），
  /// 解不动的部分变成替换字符，绝不因为一个坏文件抛异常中断整轮。
  Future<Map<String, String>> _readReferencingMedia(
    Directory mediaDir,
    Iterable<String> names,
  ) async {
    final Map<String, String> out = <String, String>{};
    for (final String name in names) {
      if (!isReferencingMediaFile(name)) continue;
      final File file = _mediaFile(mediaDir, name);
      if (!file.existsSync()) continue;
      out[name] = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }
    return out;
  }

  /// 删除前的最后一道闸：把副本与保留份**逐字节**比一遍。
  ///
  /// 哈希已经是全文件 sha256，这一步兜的是「扫描完到删除前文件被改动」的时间
  /// 差，以及任何哈希实现被换弱时的兜底。读不到或有一个字节不同就绝不删。
  Future<bool> _mediaBytesIdentical(
    Directory mediaDir,
    String a,
    String b,
  ) async {
    final File fa = _mediaFile(mediaDir, a);
    final File fb = _mediaFile(mediaDir, b);
    if (!fa.existsSync() || !fb.existsSync()) return false;
    final Uint8List ba = await fa.readAsBytes();
    final Uint8List bb = await fb.readAsBytes();
    if (ba.length != bb.length) return false;
    for (int i = 0; i < ba.length; i++) {
      if (ba[i] != bb[i]) return false;
    }
    return true;
  }

  /// styling 被去重改写后，把 Lapis 客制化指纹跟着对齐。
  ///
  /// 根因：`decideLapisStylingAction` 用 `lapisAppliedCssSha` 认「Anki 端这份
  /// CSS 是 Hibiki 自己推的产物」。去重改写 styling 后 Anki 端内容变了而指纹
  /// 没变，判定退化成 `foreignEdit` —— Lapis 的启动自动迁移从此**永久停手**，
  /// 用户完全无感知（模板再也不自动更新）。改写的确实是 Hibiki 自己的产物，
  /// 指纹理应跟着走。
  ///
  /// 只在改写前的内容确实等于已记录指纹时才对齐：本来就是用户手改（指纹对
  /// 不上）就保持对不上，不伪造一个「这是我推的」。
  Future<void> _realignLapisCssShaAfterRewrite({
    required String modelName,
    required String cssBefore,
    required String cssAfter,
  }) async {
    if (modelName != LapisNoteType.modelName) return;
    final AnkiSettings settings = await loadSettings();
    final String? recorded = settings.lapisAppliedCssSha;
    if (recorded == null || recorded != lapisCssSha256(cssBefore)) return;
    await updateSettings((AnkiSettings s) =>
        s.copyWith(lapisAppliedCssSha: lapisCssSha256(cssAfter)));
  }

  /// 一条笔记的字段改写计划（null = 这条笔记清不干净，整份副本不许删）。
  Future<_NoteFieldRewrite?> _planNoteFieldRewrite(
    AnkiConnectService service,
    int noteId,
    String dupe,
    String canonical,
  ) async {
    final Map<String, String>? fields = await service.notesInfo(noteId);
    if (fields == null) return null;
    final Map<String, String> before = <String, String>{};
    final Map<String, String> after = <String, String>{};
    fields.forEach((String key, String value) {
      final String rewritten = rewriteMediaReferences(value, dupe, canonical);
      if (rewritten == value) return;
      before[key] = value;
      after[key] = rewritten;
    });
    // 检索命中却一处也改不动：引用形态无法识别（或恰是别的更长文件名的子串，
    // 检索分不出来）——不删这份副本。
    if (after.isEmpty) return null;
    return _NoteFieldRewrite(before: before, after: after);
  }

  /// 干跑用：哪些 note type 的模板/styling 引用了 [dupe]（不改写，只统计）。
  Set<String> _modelsReferencing(
    List<String> modelNames,
    Map<String, List<AnkiCardTemplate>> modelTemplates,
    Map<String, String> modelCss,
    String dupe,
  ) {
    final Set<String> hits = <String>{};
    for (final String m in modelNames) {
      final bool inTemplates = modelTemplates[m]!.any((AnkiCardTemplate tpl) =>
          textReferencesMediaName(tpl.front, dupe) ||
          textReferencesMediaName(tpl.back, dupe));
      if (inTemplates || textReferencesMediaName(modelCss[m]!, dupe)) {
        hits.add(m);
      }
    }
    return hits;
  }

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
  }) async {
    final AnkiConnectService service = await _getService();
    final String mediaPath = await service.getMediaDirPath();
    final Directory mediaDir = Directory(mediaPath);
    // AnkiConnect 在远程主机上时拿到的路径本机不存在——按不支持处理，绝不
    // 盲扫错误目录。
    if (!mediaDir.existsSync()) return null;

    final Map<String, int> sizes = await _scanMediaSizes(mediaDir);
    final List<MediaDedupGroup> groups = planMediaDedupGroups(
      await _hashSizeCollisions(mediaDir, sizes),
      sizes: sizes,
    );
    // 媒体文件**内部**的引用只作为「不许删」的证据：本轮不改写媒体正文，
    // 所以只要还有人从里面引用，这份副本就留着。
    final Map<String, String> referencingMedia =
        await _readReferencingMedia(mediaDir, sizes.keys);

    // 模板/styling 快照一次抓全（随改写更新，避免每个副本重复拉取）。
    final List<String> modelNames = await service.getModelNames();
    final Map<String, List<AnkiCardTemplate>> modelTemplates =
        <String, List<AnkiCardTemplate>>{};
    final Map<String, String> modelCss = <String, String>{};
    for (final String m in modelNames) {
      modelTemplates[m] = await service.modelTemplates(m);
      modelCss[m] = await service.modelStyling(m);
    }

    int skippedCount = 0;
    final List<MediaDedupDeletion> deletions = <MediaDedupDeletion>[];
    final Set<int> notesRewritten = <int>{};
    final Set<String> modelsRewritten = <String>{};

    for (final MediaDedupGroup group in groups) {
      for (final String dupe in group.duplicates) {
        // ── 阶段一：全部判定与计划，一个字节都不写 ────────────────────
        // 顺序是刻意的：先把所有「不许删」的证据收齐再动手。上一版把模板/
        // styling 改写放在判定之前，跳过删除时已经把 Anki 端改脏了（Lapis
        // 指纹随之漂掉，自动迁移永久停手）。
        final List<int> noteIds = await service.findNotesByQuery('"$dupe"');
        final Map<int, _NoteFieldRewrite> notePlan = <int, _NoteFieldRewrite>{};
        bool referencesResolvable = true;
        for (final int id in noteIds) {
          final _NoteFieldRewrite? planned =
              await _planNoteFieldRewrite(service, id, dupe, group.canonical);
          if (planned == null) {
            referencesResolvable = false;
            continue;
          }
          notePlan[id] = planned;
        }

        // 媒体文件内部引用（css/js/svg 的 url()/@import/相对引用）。
        final bool referencedByMedia = referencingMedia.entries.any(
            (MapEntry<String, String> e) =>
                e.key != dupe && textReferencesMediaName(e.value, dupe));

        if (!referencesResolvable || referencedByMedia) {
          skippedCount++;
          continue;
        }

        // 字节级复核：与保留份必须逐字节相同才允许进入删除路径。
        if (!await _mediaBytesIdentical(mediaDir, dupe, group.canonical)) {
          skippedCount++;
          continue;
        }

        final MediaDedupDeletion planned = MediaDedupDeletion(
          filename: dupe,
          canonical: group.canonical,
          bytes: sizes[dupe] ?? 0,
        );

        if (dryRun) {
          deletions.add(planned);
          notesRewritten.addAll(notePlan.keys);
          modelsRewritten.addAll(
              _modelsReferencing(modelNames, modelTemplates, modelCss, dupe));
          continue;
        }

        // ── 阶段二：落地。笔记字段先写，复核通过后才动模板与文件 ────────
        for (final MapEntry<int, _NoteFieldRewrite> e in notePlan.entries) {
          // journal 带上改写**前**的原值：这是出事后能把字段还原回去的唯一
          // 依据，只记字段名等于没有保险带。
          await onJournal?.call(<String, dynamic>{
            'type': 'noteFields',
            'noteId': e.key,
            'from': dupe,
            'to': group.canonical,
            'before': e.value.before,
          });
          await service.updateNoteFields(e.key, e.value.after);
          notesRewritten.add(e.key);
        }

        // 复核：字段里彻底没有这个文件名了才继续。没清干净就到此为止——
        // 模板/styling 一个字都没动，Lapis 指纹不会漂。
        final List<int> remaining = await service.findNotesByQuery('"$dupe"');
        if (remaining.isNotEmpty) {
          skippedCount++;
          continue;
        }

        // 模板与 styling：模板先写（写坏了不影响指纹），styling 后写并当场
        // 对齐 Lapis 指纹。
        for (final String m in modelNames) {
          final List<AnkiCardTemplate> tmpls = modelTemplates[m]!;
          bool templatesChanged = false;
          final List<AnkiCardTemplate> newTmpls =
              tmpls.map((AnkiCardTemplate tpl) {
            final String front =
                rewriteMediaReferences(tpl.front, dupe, group.canonical);
            final String back =
                rewriteMediaReferences(tpl.back, dupe, group.canonical);
            if (front != tpl.front || back != tpl.back) {
              templatesChanged = true;
            }
            return AnkiCardTemplate(name: tpl.name, front: front, back: back);
          }).toList();
          final String css = modelCss[m]!;
          final String newCss =
              rewriteMediaReferences(css, dupe, group.canonical);
          final bool cssChanged = newCss != css;
          if (!templatesChanged && !cssChanged) continue;
          await onJournal?.call(<String, dynamic>{
            'type': 'model',
            'model': m,
            'from': dupe,
            'to': group.canonical,
          });
          if (templatesChanged) {
            await service.updateModelTemplates(m, newTmpls);
            modelTemplates[m] = newTmpls;
          }
          if (cssChanged) {
            await service.updateModelStyling(m, newCss);
            modelCss[m] = newCss;
            await _realignLapisCssShaAfterRewrite(
              modelName: m,
              cssBefore: css,
              cssAfter: newCss,
            );
          }
          modelsRewritten.add(m);
        }

        await onJournal?.call(<String, dynamic>{
          'type': 'delete',
          'filename': dupe,
          'canonical': group.canonical,
          'bytes': planned.bytes,
        });
        await service.deleteMediaFile(dupe);
        deletions.add(planned);
      }
    }

    return AnkiMediaDedupReport(
      dryRun: dryRun,
      groupCount: groups.length,
      deletions: deletions,
      notesRewritten: notesRewritten.length,
      modelsRewritten: modelsRewritten.length,
      skipped: skippedCount,
    );
  }

  Future<void> _uploadLocalFile(
    AnkiConnectService service, {
    required _MediaUploadTransaction mediaTransaction,
    required File file,
    required String filename,
    List<int>? bytes,
  }) async {
    await mediaTransaction.upload(
      filename: filename,
      write: () async {
        if (service.canReadLocalMediaPaths) {
          // Anki is on this machine: send a tiny JSON path instead of inflating
          // a multi-megabyte GIF by ~33% into base64 and making Anki parse it on
          // its GUI thread.
          await service.storeMediaFile(
            filename: filename,
            path: file.absolute.path,
          );
          return;
        }
        await service.storeMediaFile(
          filename: filename,
          data: await hibikiAnkiBase64EncodeAsync(
            bytes ?? await file.readAsBytes(),
          ),
        );
      },
    );
  }

  Future<String> _storeLocalMedia(
    AnkiConnectService service,
    _MediaUploadTransaction mediaTransaction,
    String filePath,
    String prefix,
  ) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Mining media file is missing', filePath);
    }
    final bytes = await file.readAsBytes();
    // BUG-1227：只算内容哈希定名；本机 Anki 走 path 上传，不再生成巨大 base64。
    final filename = await hibikiAnkiMediaFilenameForBytesAsync(
      prefix: prefix,
      bytes: bytes,
      sourceName: filePath,
    );
    // 上传失败必须向上抛，让 mineEntry 在 addNote 之前失败。绝不能返回 null 后继续
    // 创建一张无图/无句子音频卡，并把稍后落盘的媒体留成孤儿文件。
    await _uploadLocalFile(
      service,
      mediaTransaction: mediaTransaction,
      file: file,
      filename: filename,
      bytes: bytes,
    );
    return filename;
  }

  /// TODO-779：返回 [AudioFetchOutcome]（ref 成功 / failureReason 可见失败 / none
  /// 无音频）而非裸 `String?`，让非 200 与异常不再静默落空，而是把原因冒泡到
  /// [MineOutcome.audioWarning] 给用户看。`return null` 的拒绝坏字节语义不变。
  Future<AudioFetchOutcome> _storeRemoteAudio(
    AnkiConnectService service,
    _MediaUploadTransaction mediaTransaction,
    String url,
  ) async {
    try {
      File? audioFile;
      switch (AnkiAudioRef.classify(url)) {
        case AnkiAudioRefKind.empty:
          return const AudioFetchOutcome.none();
        case AnkiAudioRefKind.dataUri:
          // BUG-1050：查词弹窗把本地音频库命中的单词发音编码成 `data:` URI 塞进
          // fields['audio']。解码内联字节写入缓存文件，走与远端下载相同的入库尾部
          // （下方 storeMediaFile），不再当成不存在的本地文件丢弃。
          final data = AnkiAudioRef.decodeDataUri(url);
          if (data == null) return const AudioFetchOutcome.none();
          final cacheDir = Directory('${Directory.systemTemp.path}/anki-media');
          if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
          final filename = await hibikiAnkiMediaFilenameForBytesAsync(
            prefix: 'hibiki_audio_',
            bytes: data.bytes,
            sourceName: 'word_audio.${data.extension}',
            fallbackExtension: data.extension,
          );
          audioFile = File('${cacheDir.path}/$filename');
          await audioFile.writeAsBytes(data.bytes);
        case AnkiAudioRefKind.localFile:
          // file:// URI or a bare absolute path (Unix `/…` or Windows `C:\…`).
          final file = File(AnkiAudioRef.localPath(url));
          if (!file.existsSync()) return const AudioFetchOutcome.none();
          final bytes = await file.readAsBytes();
          final filename = await hibikiAnkiMediaFilenameForBytesAsync(
            prefix: 'hibiki_audio_',
            bytes: bytes,
            sourceName: file.path,
            fallbackExtension: 'mp3',
          );
          await _uploadLocalFile(
            service,
            mediaTransaction: mediaTransaction,
            file: file,
            filename: filename,
            bytes: bytes,
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
            // BUG-933：远端音频 sha256 卸到后台 isolate。
            final filename = await hibikiAnkiMediaFilenameForBytesAsync(
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
      final filename = audioFile.uri.pathSegments.last;
      await _uploadLocalFile(
        service,
        mediaTransaction: mediaTransaction,
        file: audioFile,
        filename: filename,
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

  Future<String> _storeDictionaryMedia(
    AnkiConnectService service,
    _MediaUploadTransaction mediaTransaction,
    DictionaryMedia media,
  ) async {
    // 命名/目录与主 app 的 writeDictionaryMediaCache 共用同一 helper（防漂移，
    // 否则文件名对不上→读不到→卡片留坏图）。HBK-AUDIT-062 无扩展名兜底已并入。
    final filename =
        ankiDictionaryMediaCacheFilename(media.dictionary, media.path);
    final file = File('${ankiDictionaryMediaCacheDirPath()}/$filename');
    if (!file.existsSync()) {
      throw FileSystemException('Dictionary media file is missing', file.path);
    }
    await _uploadLocalFile(
      service,
      mediaTransaction: mediaTransaction,
      file: file,
      filename: filename,
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
  }
}
