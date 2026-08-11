import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';

/// 加载一条词典媒体（外字/内嵌图）的字节。默认走 `FushiDicts.getMediaFile`。
typedef DictMediaByteLoader = Uint8List? Function(
    String dictionary, String path);

/// 读取本地文件字节（封面/音频临时文件）。默认走 `dart:io File`；文件缺失返回 null。
typedef LocalFileByteLoader = Future<Uint8List?> Function(String path);

/// BUG-1185：把「已配对主机拒绝了互联 token」上报给用户可见的通道（toast）。
/// 注入而非直接调 UI，是为了让 repository 保持无 Flutter 依赖、可纯 Dart 单测。
typedef RemoteMiningAuthReporter = void Function(String message);

/// 「制卡到服务端」的 Anki 仓库包装：把 [mineEntry]/[isDuplicate] 经互联链路转发给已配对
/// 主机（主机用它自己的 Anki 后端 + 字段映射/牌组落卡），其余**配置类**方法
/// （[fetchConfiguration]/[createDeck]/[createNoteType]）委派给包装的本地仓库 [_local]，
/// 以便设置页在开关开启时仍能正常配置本地 Anki（供开关关闭时使用）。
///
/// 覆盖/查看类方法（[updateMinedNote]/[findOverwriteTargetNoteId]/[findMatchingNotes]/
/// [noteFields]/[openNoteInAnki]）保留基类降级默认（不委派本地——那会在远端制卡时错误地
/// 操作**本机** Anki 的卡片；远端 note id 本就为 null，本会话覆写第三态不激活，与 AnkiDroid
/// 现状一致）。
///
/// 媒体的四个来源在客户端就地读成字节再随请求发出（服务端未必装同款词典/无法访问本机文件）：
/// 封面 ← `context.coverPath`；句子音频 ← `context.sasayakiAudioPath`；单词音频 ←
/// `fields['audio']`（仅本地文件搬字节，`http` URL 留给服务端下载）；词典外字 ←
/// `FushiDicts.getMediaFile`。
class RemoteMiningAnkiRepository extends BaseAnkiRepository {
  RemoteMiningAnkiRepository({
    required BaseAnkiRepository local,
    required RemoteMineSender client,
    DictMediaByteLoader? dictMediaLoader,
    LocalFileByteLoader? fileByteLoader,
    RemoteMiningAuthReporter? onAuthRejected,
  })  : _local = local,
        _client = client,
        _dictMediaLoader = dictMediaLoader ?? _defaultDictMediaLoader,
        _fileByteLoader = fileByteLoader ?? _defaultFileByteLoader,
        _onAuthRejected = onAuthRejected;

  /// 主机拒绝互联 token 时给用户看的话。制卡失败与查重失败共用同一句，
  /// 因为它们是同一个 token 被同一台主机拒绝。
  static const String tokenRejectedMessage =
      'The paired device rejected the interconnect token. Re-pair the device.';

  final BaseAnkiRepository _local;
  final RemoteMineSender _client;
  final DictMediaByteLoader _dictMediaLoader;
  final LocalFileByteLoader _fileByteLoader;
  final RemoteMiningAuthReporter? _onAuthRejected;

  /// 同一个 repository 实例只报一次「token 被拒」——查重是每次查词都跑的高频路径，
  /// 逐次弹 toast 会刷屏。provider 在开关/配对变化时会重建实例，届时自然重新提示。
  bool _authRejectedReported = false;

  static Uint8List? _defaultDictMediaLoader(String dictionary, String path) =>
      FushiDicts.instance.getMediaFile(dictionary, path);

  static Future<Uint8List?> _defaultFileByteLoader(String path) async {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final ForwardedMinePayload payload = await _buildForwardedPayload(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    try {
      final Map<String, dynamic>? json = await _client.mineForward(payload);
      return _withLocalDeckNameFallback(_outcomeFromResponse(json));
    } on SyncAuthError {
      return MineOutcome.failure(
        tokenRejectedMessage,
        errorCode: AnkiErrorCode.connectionUnknown,
      );
    } catch (e, st) {
      return MineOutcome.failure(
        'Failed to forward the card to the paired device: $e',
        errorCode: AnkiErrorCode.connectionUnknown,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// BUG-1185：远端查重。可重试失败仍 fail-soft（client 层已降级为
  /// [RemoteDuplicateCheck.notDuplicate]），绝不让远端抖动阻断查词。
  ///
  /// token 被主机拒绝时查重**根本没执行**：这不是「不重复」，是「不知道」。基类
  /// [BaseAnkiRepository.isDuplicate] 的 `Future<bool>` 契约（一路铺到 popup.js 的
  /// ✓/➕ 两态按钮）表达不了第三态，所以在这一层把它**报给用户**——用户至少知道
  /// 「配对已失效、查重结果不可信」，而不是静默收到一个错误答案。返回值仍取 false
  /// （保持 ➕ 可点）：用户真按下去时 [mineEntry] 会用同一句话明确失败，不会悄悄多出
  /// 一张重复卡；若反过来谎报 true，用户只会以为卡已做好并就此走开。
  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final RemoteDuplicateCheck check =
        await _client.isDuplicate(expression: expression, reading: reading);
    if (check == RemoteDuplicateCheck.authRejected) {
      _reportAuthRejectedOnce();
      return false;
    }
    return check == RemoteDuplicateCheck.duplicate;
  }

  void _reportAuthRejectedOnce() {
    if (_authRejectedReported) return;
    _authRejectedReported = true;
    _onAuthRejected?.call(tokenRejectedMessage);
  }

  Future<ForwardedMinePayload> _buildForwardedPayload({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    // 封面 + 句子音频：context 里是本地文件路径，读成字节。
    final Uint8List? coverBytes = await _readPath(context.coverPath);
    final Uint8List? sentenceAudioBytes =
        await _readPath(context.sentenceAudioPath);

    // 单词音频 + 词典外字：从 rawPayloadJson 解析。解析失败不致命——仍转发文本卡。
    Uint8List? wordAudioBytes;
    String? wordAudioExt;
    List<ForwardedDictMedia> dictMedia = const <ForwardedDictMedia>[];
    try {
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
          jsonDecode(rawPayloadJson) as Map<String, dynamic>);
      final AnkiAudioRefKind audioKind = AnkiAudioRef.classify(parsed.audio);
      if (audioKind == AnkiAudioRefKind.localFile) {
        final String localPath = AnkiAudioRef.localPath(parsed.audio);
        wordAudioBytes = await _readPath(localPath);
        wordAudioExt = _extOf(localPath);
      } else if (audioKind == AnkiAudioRefKind.dataUri) {
        // BUG-1050：`data:` 内联单词发音（本地音频库命中）——解码成字节转发给主机，
        // 否则互联「制卡到服务端」丢单词音频（与本地落卡同一根因）。
        final AnkiAudioData? data = AnkiAudioRef.decodeDataUri(parsed.audio);
        if (data != null) {
          wordAudioBytes = data.bytes;
          wordAudioExt = data.extension;
        }
      }
      dictMedia = _collectDictionaryMedia(parsed.dictionaryMedia);
    } catch (_) {
      // 非结构化 payload（视频等直接传 fields）——无词典外字/本地音频要搬。
    }

    return ForwardedMinePayload(
      rawPayloadJson: rawPayloadJson,
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      documentTitle: context.documentTitle,
      sentenceOffset: context.sentenceOffset,
      source: context.source?.name,
      bookTitleTag: context.bookTitleTag,
      coverBytes: coverBytes,
      coverExt: _extOf(context.coverPath),
      sentenceAudioBytes: sentenceAudioBytes,
      sentenceAudioExt: _extOf(context.sentenceAudioPath),
      wordAudioBytes: wordAudioBytes,
      wordAudioExt: wordAudioExt,
      dictionaryMedia: dictMedia,
    );
  }

  List<ForwardedDictMedia> _collectDictionaryMedia(
      List<DictionaryMedia> media) {
    final List<ForwardedDictMedia> out = <ForwardedDictMedia>[];
    for (final DictionaryMedia m in media) {
      if (m.dictionary.isEmpty || m.path.isEmpty) continue;
      final Uint8List? bytes = _dictMediaLoader(m.dictionary, m.path);
      if (bytes == null || bytes.isEmpty) continue;
      out.add(ForwardedDictMedia(
          dictionary: m.dictionary, path: m.path, bytes: bytes));
    }
    return out;
  }

  Future<Uint8List?> _readPath(String? path) async {
    if (path == null || path.isEmpty) return null;
    return _fileByteLoader(path);
  }

  static String? _extOf(String? path) {
    if (path == null || path.isEmpty) return null;
    final String base = path.split(RegExp(r'[/\\]')).last;
    final int dot = base.lastIndexOf('.');
    if (dot < 0 || dot == base.length - 1) return null;
    return base.substring(dot + 1);
  }

  MineOutcome _outcomeFromResponse(Map<String, dynamic>? json) {
    if (json == null) {
      return MineOutcome.failure(
        'No paired device is reachable for server-side mining.',
        errorCode: AnkiErrorCode.connectionUnknown,
      );
    }
    final String result = json['result']?.toString() ?? MineResult.error.name;
    final String? message = json['message'] as String?;
    final String? detail = json['detail'] as String?;
    if (result == MineResult.success.name) {
      // BUG-1549：主机回传它实际落卡的牌组名（主机侧配置的 deck）；旧版本主机
      // 无此字段 → null，由 [_withLocalDeckNameFallback] 降级到本地设置名。
      return MineOutcome.success(
        deckName: json['deckName'] as String?,
        audioWarning: message,
      );
    }
    if (result == MineResult.duplicate.name) {
      return const MineOutcome.duplicate();
    }
    if (result == MineResult.notConfigured.name) {
      return const MineOutcome.notConfigured();
    }
    return MineOutcome.failure(
      message ?? detail ?? 'The paired device failed to create the card.',
    );
  }

  /// BUG-1549：旧版本主机的转发响应不带 `deckName`——降级用**本地**设置解析的
  /// 牌组名补上（与旧行为一致：此前成功 toast 本来就显示本地
  /// `loadSettings().selectedDeckName`）。新主机回传后此降级不再触发。
  Future<MineOutcome> _withLocalDeckNameFallback(MineOutcome outcome) async {
    if (outcome.result != MineResult.success) return outcome;
    if (outcome.deckName != null && outcome.deckName!.isNotEmpty) {
      return outcome;
    }
    // 补名只是给 toast 用的装饰——本地设置读不到（存储异常等）时绝不能把一次
    // 已成功的远端制卡变成失败，原样返回（toast 无牌组名，与旧降级一致）。
    try {
      final AnkiSettings settings = await _local.loadSettings();
      final String? localDeckName =
          resolveSelectedDeck(settings)?.name ?? settings.selectedDeckName;
      return MineOutcome.success(
        noteId: outcome.noteId,
        deckName: localDeckName,
        audioWarning: outcome.audioWarning,
      );
    } catch (_) {
      return outcome;
    }
  }

  // ---- 配置类：委派本地仓库，保持设置页可配置本地 Anki ----

  @override
  Future<AnkiFetchResult> fetchConfiguration() => _local.fetchConfiguration();

  @override
  Future<bool> createDeck(String name) => _local.createDeck(name);

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      _local.createNoteType(template);

  // Lapis 模板读写也是配置类：委派本地仓库（设置页在「制卡到已配对设备」
  // 开启时仍配置/备份/客制化本机 Anki 的模板，与 createNoteType 同语义）。
  @override
  bool get supportsNoteTypeEditing => _local.supportsNoteTypeEditing;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String modelName) =>
      _local.readNoteTypeDefinition(modelName);

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) =>
      _local.updateNoteTypeStyling(modelName, css);

  @override
  Future<bool> updateNoteTypeTemplates(
          String modelName, List<AnkiCardTemplate> templates) =>
      _local.updateNoteTypeTemplates(modelName, templates);

  // 媒体去重同为配置/维护类：作用于本机 Anki，委派本地仓库。
  @override
  bool get supportsMediaMaintenance => _local.supportsMediaMaintenance;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) =>
      _local.runMediaDedup(
        dryRun: dryRun,
        onJournal: onJournal,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
}
